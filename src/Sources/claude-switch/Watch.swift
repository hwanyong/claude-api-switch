import Foundation

// MARK: - live context load of a claude session

struct SessionLoad {
    var id: String
    var project: String
    var model: String
    var used: Int          // tokens in context (input + cache create + cache read)
    var window: Int?       // the window Claude Code believes it has
    var budget: Int?       // our resident budget per session
    var at: Date

    var pctWindow: Double? {
        guard let w = window, w > 0 else { return nil }
        return Double(used) / Double(w) * 100
    }
    var pctBudget: Double? {
        guard let b = budget, b > 0 else { return nil }
        return Double(used) / Double(b) * 100
    }
}

/// State written by "statusline" (and read by the menu). Sessions we have seen,
/// plus the last engine residency sample (so statusline stays cheap).
struct WatchState: Codable {
    struct Eng: Codable {
        var at: Date
        var capMib: Int?
        var slots: Int?
        var bytesPerToken: Double?
        var prefillTps: Double?
        var budgetTokens: Int?
        var evictions: Int?
        var parked: Int?
    }
    struct Live: Codable {
        var at: Date
        var project: String
        var model: String
        var used: Int
        var window: Int?
        var budget: Int?
    }
    var engine: Eng?
    var sessions: [String: Live]?
    var lastEvictions: Int?
}

enum Watch {
    static var path: String { Paths.appSupport + "/watch.json" }

    static func load() -> WatchState {
        guard let data = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(WatchState.self, from: data) else { return WatchState() }
        return s
    }
    static func save(_ s: WatchState) {
        ensureDir(Paths.appSupport)
        guard let dec = try? JSONEncoder().encode(s),
              let obj = try? JSONSerialization.jsonObject(with: dec),
              let pretty = try? JSONSerialization.data(withJSONObject: obj,
                   options: [.prettyPrinted, .sortedKeys]) else { return }
        try? pretty.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Reuse the residency sample if it is fresher than `maxAge`, else re-read the log.
    static func residency(maxAge: TimeInterval = 30) -> Residency? {
        let st = load()
        if let e = st.engine, Date().timeIntervalSince(e.at) < maxAge,
           let cap = e.capMib, let bpt = e.bytesPerToken {
            var r = Residency(capMib: cap, slots: e.slots, bytesPerToken: bpt,
                              prefillTps: e.prefillTps, parkedConvs: e.parked,
                              evictions: e.evictions)
            r.budgetTokensOverride = e.budgetTokens
            return r
        }
        var r: Residency
        guard let rr = strataResidency() else { return nil }
        r = rr
        var s = st
        if let ev = r.evictions, let last = s.lastEvictions { r.evictionsDelta = max(0, ev - last) }
        s.engine = WatchState.Eng(at: Date(), capMib: r.capMib, slots: r.slots,
                       bytesPerToken: r.bytesPerToken, prefillTps: r.prefillTps,
                       budgetTokens: r.budgetTokens, evictions: r.evictions, parked: r.parkedConvs)
        if let ev = r.evictions, let last = s.lastEvictions, ev > last {
            logEvent("resident.evictions", ["from": last, "to": ev,
                                            "parked": r.parkedConvs ?? 0,
                                            "budget_tokens": r.budgetTokens ?? 0])
        }
        s.lastEvictions = r.evictions
        save(s)
        return r
    }

    static func record(sessionId: String, _ live: WatchState.Live) {
        var s = load()
        var m = s.sessions ?? [:]
        m[sessionId] = live
        // drop stale entries
        for (k, v) in m where Date().timeIntervalSince(v.at) > 6 * 3600 { m.removeValue(forKey: k) }
        s.sessions = m
        save(s)
    }

    static func live(under: TimeInterval = 120) -> [SessionLoad] {
        let st = load()
        return (st.sessions ?? [:]).values.compactMap { l in
            guard Date().timeIntervalSince(l.at) < under else { return nil }
            return SessionLoad(id: "", project: l.project, model: l.model, used: l.used,
                               window: l.window, budget: l.budget, at: l.at)
        }.sorted { $0.used > $1.used }
    }
}

// MARK: - statusline: the in-session warning surface

/// claude calls the profile's statusLine command and pipes a session JSON on stdin.
/// We reuse its own context_window numbers, compare them to the resident budget,
/// and print one line. Exit 0 always: a statusline must never break a session.
func statuslineMain() -> Int32 {
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return 0 }
    let cw = obj["context_window"] as? [String: Any]
    let used = (cw?["total_input_tokens"] as? Int) ?? 0
    let window = (cw?["context_window_size"] as? Int)
    let model = ((obj["model"] as? [String: Any])?["display_name"] as? String) ?? ""
    let dir = ((obj["workspace"] as? [String: Any])?["current_dir"] as? String) ?? ""
    let sid = (obj["session_id"] as? String) ?? ""
    let project = ((dir as NSString).lastPathComponent)

    // Which backend is this session on? The profile env is inherited by the child.
    let env = ProcessInfo.processInfo.environment
    let base = env[ENV_BASE]
    var kind: BackendKind = .official
    if let base {
        if strataInstances().contains(where: { "http://\($0.host):\($0.port)" == base }) { kind = .strata }
        else if base.contains("127.0.0.1:1234") { kind = .lmstudio }
        else { kind = .custom }
    }

    var budget: Int?
    if isLocalKind(kind, base: base) {
        let ov = Store.load().policyFor?[kind.rawValue] ?? BackendPolicy()
        // The residency numbers come from log lines only the Strata engine writes,
        // so no other backend gets a budget figure it did not produce.
        let res = kind == .strata ? Watch.residency() : nil
        let p = derivePolicy(kind: kind, model: model,
                             modelWindow: window ?? parseTokenAmount(env[ENV_MAXCTX] ?? ""),
                             residency: res, ov: ov, base: base)
        budget = p.perSessionBudget
    }

    if !sid.isEmpty {
        Watch.record(sessionId: sid, WatchState.Live(at: Date(), project: project, model: model,
                                                     used: used, window: window, budget: budget))
    }

    // Chain the user's own status line (the command in settings.json) and append
    // the resident-token warning to it, instead of replacing their line.
    var head = ""
    if let cmd = userStatusLineCommand() {
        let r = runShell(cmd, input: raw, timeout: 3)
        head = (r.out.split(separator: "\n").first).map(String.init) ?? ""
    }

    var seg = ""
    if !model.isEmpty { seg += model + " " }
    seg += fmtTokens(used)
    if let w = window, w > 0 {
        seg += "/" + fmtTokens(w) + " (" + String(Int(Double(used) / Double(w) * 100)) + "%)"
    }
    var parts: [String] = []
    if !head.isEmpty { parts.append(head) }
    parts.append(seg)
    if let b = budget, b > 0 {
        let pct = Int(Double(used) / Double(b) * 100)
        if used >= b {
            parts.append("⛔ resident " + String(pct) + "% of budget: /compact now")
        } else if used >= b * 8 / 10 {
            parts.append("⚠ resident " + String(pct) + "% of " + fmtTokens(b))
        }
    }
    print(parts.joined(separator: "  "))
    return 0
}

// MARK: - transcript scan: sessions that were not started from a profile

/// Read the tail of a transcript and take the newest assistant usage block.
func transcriptLoad(_ path: String) -> (used: Int, model: String, at: Date?)? {
    guard let text = tailText(path, maxBytes: 262_144) else { return nil }
    let lines = text.split(separator: "\n").reversed()
    for line in lines {
        guard line.contains("\"usage\""), line.contains("assistant") else { continue }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { continue }
        let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
        if used == 0 { continue }
        return (used, (msg["model"] as? String) ?? "", fileMTime(path))
    }
    return nil
}

/// Sessions active in the last `minutes` across all projects.
func scanSessions(minutes: Int = 120, limit: Int = 12) -> [SessionLoad] {
    let fm = FileManager.default
    let cut = Date().addingTimeInterval(-Double(minutes * 60))
    var out: [SessionLoad] = []
    let projDir = Paths.claudeDir + "/projects"
    guard let projs = try? fm.contentsOfDirectory(atPath: projDir) else { return [] }
    for proj in projs {
        let full = projDir + "/" + proj
        guard let files = try? fm.contentsOfDirectory(atPath: full) else { continue }
        for f in files where f.hasSuffix(".jsonl") {
            let p = full + "/" + f
            guard let mt = fileMTime(p), mt > cut else { continue }
            if let l = transcriptLoad(p) {
                out.append(SessionLoad(id: String(f.dropLast(6)),
                                       project: (proj as NSString).lastPathComponent,
                                       model: l.model, used: l.used, window: nil,
                                       budget: nil, at: l.at ?? mt))
            }
        }
    }
    return out.sorted { $0.used > $1.used }.prefix(limit).map { $0 }
}
