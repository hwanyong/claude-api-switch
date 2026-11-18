import Foundation

// MARK: - Managed environment keys

let ENV_BASE = "ANTHROPIC_BASE_URL"
let ENV_TOKEN = "ANTHROPIC_AUTH_TOKEN"
let ENV_MODEL = "ANTHROPIC_MODEL"
let ENV_SMALL = "ANTHROPIC_SMALL_FAST_MODEL"
let ENV_SONNET = "ANTHROPIC_DEFAULT_SONNET_MODEL"
let ENV_OPUS = "ANTHROPIC_DEFAULT_OPUS_MODEL"
let ENV_HAIKU = "ANTHROPIC_DEFAULT_HAIKU_MODEL"
let ENV_ATTR = "CLAUDE_CODE_ATTRIBUTION_HEADER"
let ENV_APIKEY = "ANTHROPIC_API_KEY"
// Context-window truth. Claude Code 2.1.325 guesses a window for a model it does
// not know (any local model id) and then enforces that guess, so the profile must
// state the real one. MAX_CONTEXT_TOKENS = the model's real n_ctx;
// AUTO_COMPACT_WINDOW = the hard form of autoCompactWindow (wins over /autocompact).
let ENV_MAXCTX = "CLAUDE_CODE_MAX_CONTEXT_TOKENS"
let ENV_ACWINDOW = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"

/// Every key this app may add or remove in settings.json "env".
let MANAGED_KEYS = [ENV_BASE, ENV_TOKEN, ENV_MODEL, ENV_SMALL, ENV_SONNET,
                    ENV_OPUS, ENV_HAIKU, ENV_ATTR, ENV_APIKEY, ENV_MAXCTX, ENV_ACWINDOW]

// MARK: - Model types

enum BackendKind: String, Codable {
    case official, lmstudio, strata, custom, unknown
}

struct ModelInfo {
    var id: String
    var aliases: [String] = []
    var ctx: Int?
}

struct Backend {
    var kind: BackendKind
    var title: String
    var present = false   // app / instance data found
    var serving = false   // endpoint answers /v1/models
    var base: String?
    var token: String?
    var model: String?    // preferred/default model id
    var models: [ModelInfo] = []
    var notes: [String] = []
}

struct StatusInfo {
    var currentKind: BackendKind = .official
    var currentModel: String?
    var currentBase: String?
    var backends: [Backend] = []
    var gatheredAt = Date()
}

// MARK: - Paths

enum Paths {
    static let home = NSHomeDirectory()
    // Claude Code honors CLAUDE_CONFIG_DIR; follow the same rule so tests can isolate.
    static let configDirOverride = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    static var claudeDir: String { configDirOverride ?? home + "/.claude" }
    static var settings: String { claudeDir + "/settings.json" }
    static var profiles: String { claudeDir + "/profiles" }
    static let appSupport = home + "/Library/Application Support/ClaudeAPISwitch"
    static let backups = appSupport + "/backups"
    static let configFile = appSupport + "/config.json"
    static let logFile = appSupport + "/switch.jsonl"
    static var lockFile: String { claudeDir + "/.ccswitch.lock" }
    static let strataInstances = home + "/.strata/data/native-instances"
    static let lmServerConfig = home + "/.lmstudio/.internal/http-server-config.json"
    static let lmsBin = home + "/.lmstudio/bin/lms"
}

@discardableResult
func ensureDir(_ path: String) -> Bool {
    try? FileManager.default.createDirectory(atPath: path,
        withIntermediateDirectories: true, attributes: nil)
    return FileManager.default.fileExists(atPath: path)
}

// MARK: - JSON helpers

func jsonRead(_ path: String) -> Any? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// Atomic write: tmp in the same directory, mode set on the tmp, fsync, rename.
/// The mode goes on the tmp file because rename carries it over: a file that holds
/// an API key is never briefly readable by the rest of the account.
@discardableResult
func jsonWrite(_ path: String, _ obj: Any, fileMode: Int = 0o644) -> Bool {
    let dir = (path as NSString).deletingLastPathComponent
    ensureDir(dir)
    let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return false }
    let tmp = path + ".ccswitch.tmp"
    do {
        try data.write(to: URL(fileURLWithPath: tmp))
        try? FileManager.default.setAttributes([.posixPermissions: fileMode], ofItemAtPath: tmp)
        if let fh = FileHandle(forWritingAtPath: tmp) { try? fh.synchronize(); try? fh.close() }
        // POSIX rename: atomic within the same directory, works if dest exists or not.
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
        return true
    } catch {
        try? FileManager.default.removeItem(atPath: tmp)
        return false
    }
}

func fileMTime(_ path: String) -> Date? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    return attrs[.modificationDate] as? Date
}

// MARK: - Process helper

struct ProcResult {
    var code: Int32 = -1
    var out: String = ""
    var err: String = ""
}

func runProcess(_ launch: String, _ args: [String], timeout: TimeInterval = 15) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let oPipe = Pipe(), ePipe = Pipe()
    p.standardOutput = oPipe
    p.standardError = ePipe
    var res = ProcResult()
    let sem = DispatchSemaphore(value: 0)
    p.terminationHandler = { proc in
        res.code = proc.terminationStatus
        sem.signal()
    }
    do { try p.run() } catch { res.err = "\(error)"; return res }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        p.terminationHandler = nil
        p.interrupt(); p.terminate()
        res.err = "timeout"
        return res
    }
    res.out = String(data: oPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    res.err = String(data: ePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return res
}

// MARK: - shell helper with stdin (for chaining the user's own status line)

func runShell(_ cmd: String, input: Data, timeout: TimeInterval = 3) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let iPipe = Pipe(), oPipe = Pipe(), ePipe = Pipe()
    p.standardInput = iPipe
    p.standardOutput = oPipe
    p.standardError = ePipe
    var res = ProcResult()
    let sem = DispatchSemaphore(value: 0)
    p.terminationHandler = { proc in res.code = proc.terminationStatus; sem.signal() }
    do { try p.run() } catch { res.err = "\(error)"; return res }
    DispatchQueue.global().async {
        try? iPipe.fileHandleForWriting.write(contentsOf: input)
        try? iPipe.fileHandleForWriting.close()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        p.terminationHandler = nil
        p.interrupt(); p.terminate()
        res.err = "timeout"
        return res
    }
    res.out = String(data: oPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    res.err = String(data: ePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return res
}

// MARK: - Logging (secrets masked)

func maskSecret(_ s: String) -> String {
    if s.count <= 8 { return "****" }
    return String(s.prefix(4)) + "…" + String(s.suffix(4))
}

func logEvent(_ event: String, _ fields: [String: Any] = [:]) {
    ensureDir(Paths.appSupport)
    var rec: [String: Any] = [
        "ts": ISO8601DateFormatter().string(from: Date()),
        "event": event
    ]
    for (k, v) in fields {
        if k.lowercased().contains("token") || k.lowercased().contains("key") || k == "api_key",
           let s = v as? String {
            rec[k] = maskSecret(s)
        } else {
            rec[k] = v
        }
    }
    guard let line = try? JSONSerialization.data(withJSONObject: rec, options: []) else { return }
    var payload = line
    payload.append(Data("\n".utf8))
    guard let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: Paths.logFile)) else {
        try? payload.write(to: URL(fileURLWithPath: Paths.logFile))
        return
    }
    fh.seekToEndOfFile()
    fh.write(payload)
    try? fh.close()
}

// MARK: - Localization

private let kLang: String = {
    if let o = Store.load().language, o == "en" || o == "ko" { return o }
    return Locale.current.language.languageCode?.identifier == "ko" ? "ko" : "en"
}()

func T(_ key: String) -> String {
    let pair = STRINGS[key] ?? (key, key)
    return kLang == "ko" ? pair.1 : pair.0
}

let STRINGS: [String: (String, String)] = [
    "app.name": ("Claude API Switch", "Claude API 스위치"),
    "menu.current": ("Current", "현재"),
    "menu.switch": ("Switch", "전환"),
    "menu.official": ("Official Claude API", "공식 Claude API"),
    "menu.lmstudio": ("LM Studio (Bionic)", "LM Studio (Bionic)"),
    "menu.strata": ("Strata", "Strata"),
    "menu.custom": ("Custom endpoint", "커스텀 엔드포인트"),
    "menu.custom.set": ("Set custom endpoint…", "커스텀 엔드포인트 설정…"),
    "menu.custom.clear": ("Remove custom endpoint", "커스텀 엔드포인트 삭제"),
    "menu.models": ("Model", "모델"),
    "menu.server": ("Server", "서버"),
    "menu.lm.start": ("Start LM Studio server", "LM Studio 서버 시작"),
    "menu.lm.stop": ("Stop LM Studio server", "LM Studio 서버 중지"),
    "menu.strata.launch": ("Launch Strata app", "Strata 앱 실행"),
    "menu.refresh": ("Check status now", "지금 상태 점검"),
    "menu.newsession": ("Copy new-session command", "새 세션 실행 명령 복사"),
    "menu.restore": ("Restore backup", "백업 복원"),
    "menu.open.settings": ("Open settings.json", "settings.json 열기"),
    "menu.open.log": ("Open log", "로그 열기"),
    "menu.autostart": ("Start at login", "로그인 시 자동 시작"),
    "menu.quit": ("Quit", "종료"),
    "state.serving": ("serving", "응답 중"),
    "state.down": ("stopped", "꺼짐"),
    "state.unknown": ("unknown", "확인 필요"),
    "state.newsession": ("Applies to NEW claude sessions", "새로 시작하는 세션부터 적용됩니다"),
    "note.strata.down": ("Strata is not serving. Start the app and load a model.",
                         "Strata가 서빙 중이 아닙니다. 앱을 실행하고 모델을 불러오세요."),
    "note.lm.startfail": ("Could not start LM Studio server.", "LM Studio 서버를 시작하지 못했습니다."),
    "note.custom.down": ("Custom endpoint does not answer GET /v1/models.",
                         "커스텀 엔드포인트가 GET /v1/models 에 응답하지 않습니다."),
    "menu.context": ("Context / compaction", "컨텍스트 · 컴팩션"),
    "menu.ctx.statusline": ("Resident token warning in session", "세션 내 상주 토큰 경고"),
    "menu.ctx.watch": ("Token load in menu bar", "메뉴바에 토큰 부하 표시"),
    "menu.ctx.rebuild": ("Rewrite session profiles now", "세션 프로파일 즉시 다시 쓰기"),
    "menu.ctx.autowin": ("Compact window by Claude Code (warn only)", "컴팩션 창은 Claude 기본 (경고만)"),
    "menu.ctx.sessions": ("Live token load", "실시간 토큰 부하"),
    "switch.ok": ("Switched", "전환 완료"),
    "switch.fail": ("Switch failed", "전환 실패"),
    "policy.nowindow": ("model window unknown: /v1/models reports no n_ctx, so the real window cannot be stated",
                        "모델 컨텍스트 창 미확인: /v1/models에 n_ctx가 없어 실제 창을 지정할 수 없음"),
    "policy.noresidency": ("engine residency not measured: no conversation-cache lines in the engine log",
                           "엔진 상주량 미측정: 엔진 로그에 conversation cache 기록이 없음"),
    "policy.overbudget": ("resident KV budget exceeded:", "상주 KV 예산 초과:"),
    "policy.overslots": ("more sessions than parked conversation slots", "파킹 대화 슬롯보다 많은 세션"),
    "policy.windowoverslot": ("model window exceeds resident budget:", "모델 창이 상주 예산을 초과:"),
    "policy.evicted": ("conversations evicted since last check:", "최근 확인 후 대화 추방:"),
    "policy.coldre": ("cold re-read each", "매번 콜드 재읽기"),
    "policy.cache-full": ("parked conversations at the slot limit", "파킹 대화가 슬롯 한계"),
    "policy.compactoff": ("autoCompactEnabled=false: nothing bounds the session, it grows until prompt-too-long",
                          "autoCompactEnabled=false: 세션을 막는 장치가 없음, prompt-too-long까지 성장"),
    "policy.override": ("profile overrides settings.json autoCompactWindow:", "프로파일이 settings.json의 autoCompactWindow를 덮어씀:"),
    "policy.yourwindow": ("settings.json window", "settings.json 창"),
    "ui.none": ("(none)", "(없음)"),
    "ui.ok": ("OK", "확인"),
    "ui.cancel": ("Cancel", "취소"),
    "ui.clipboard": ("Copied to clipboard:", "클립보드 복사:"),
    "ui.restored": ("Restored:", "복원 완료:"),
    "ui.autostart.bundleOnly": ("supported only from a .app bundle", ".app 번들에서만 지원"),
    "dialog.base": ("Endpoint base URL (no /v1 suffix):", "엔드포인트 주소 (/v1 접미사 없이):"),
    "dialog.token": ("API key, optional:", "API 키 (선택):"),
    "dialog.model": ("Model id, optional:", "모델 id (선택):"),
    "cli.usage": ("""
    claude-switch: Claude Code API switch (menu bar app, CLI mode)

      status [--json]                  current backend + detection
      list                             supported backends
      switch <kind> [--model id]       global switch (official|lmstudio|strata|custom)
      custom set --base URL [--token K] [--model id] [--title NAME]
                                       declare one Anthropic-compatible endpoint
      custom show | custom clear       print / remove the declared endpoint
      models <kind>                    detected models (n_ctx included)
      check <kind>                     POST /v1/messages round trip
      profile <kind> [--model id]      write a session profile + print its command
      policy [kind] [flags] [--json]   auto-compact window / resident budget
                                       (--window 120k|auto, --sessions N, --wait S, --hard/--soft)
      watch [--minutes N] [--json]     per-session context token load
      statusline                       (claude statusLine hook: stdin JSON -> one line)
      backups                          backup list
      restore <file|latest>            restore a backup
    """, """
    claude-switch: Claude Code API 스위치 (메뉴바 앱 CLI 모드)

      status [--json]                  현재 백엔드 + 감지 결과
      list                             지원 백엔드
      switch <kind> [--model id]       전역 전환 (official|lmstudio|strata|custom)
      custom set --base URL [--token K] [--model id] [--title NAME]
                                       Anthropic 호환 엔드포인트 하나 선언
      custom show | custom clear       선언된 엔드포인트 출력 / 삭제
      models <kind>                    감지된 모델 목록 (n_ctx 포함)
      check <kind>                     POST /v1/messages 왕복 확인
      profile <kind> [--model id]      세션 프로파일 생성 + 명령 출력
      policy [kind] [flags] [--json]   auto-compact 창/상주 예산
                                       (--window 120k|auto, --sessions N, --wait S, --hard/--soft)
      watch [--minutes N] [--json]     세션별 컨텍스트 토큰 부하
      statusline                       (claude statusLine 훅: stdin JSON → 한 줄)
      backups                          백업 목록
      restore <file|latest>            백업 복원
    """),
]
