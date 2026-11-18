import Foundation

// MARK: - token amount helpers ("120k" | "200000" | "auto")

func parseTokenAmount(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    if t.isEmpty || t == "auto" { return nil }
    let num = t.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    guard let v = Double(num), v > 0 else { return nil }
    if t.hasSuffix("m") { return Int(v * 1_000_000) }
    if t.hasSuffix("k") { return Int(v * 1_000) }
    return Int(v)
}

func fmtTokens(_ n: Int?) -> String {
    guard let n = n else { return "?" }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    return "\(Int((Double(n) / 1000).rounded()))k"
}

// MARK: - what the local engine can keep resident (measured from its own log)

struct Residency {
    var logPath: String = ""
    var capMib: Int?
    var slots: Int?
    var bytesPerToken: Double?
    var prefillTps: Double?
    var parkedConvs: Int?
    var parkedTokens: Int?
    var parkedBytes: Int?
    var evictions: Int?
    var engineMaxContext: Int?
    var sampledAt: Date?
    /// Evictions added since the previous sample (0 = cache stable).
    var evictionsDelta: Int?
    /// Set when the value came from the cached watch sample instead of the log.
    var budgetTokensOverride: Int?

    var capBytes: Int? { capMib.map { $0 * 1024 * 1024 } }
    var budgetTokens: Int? {
        if let o = budgetTokensOverride { return o }
        guard let cb = capBytes, let bpt = bytesPerToken, bpt > 0 else { return nil }
        return Int(Double(cb) / bpt)
    }
}

func tailText(_ path: String, maxBytes: Int = 3_000_000) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let len = fh.seekToEndOfFile()
    let start = len > UInt64(maxBytes) ? len - UInt64(maxBytes) : 0
    fh.seek(toFileOffset: start)
    return String(data: fh.readDataToEndOfFile(), encoding: .utf8)
}

private func matches(_ text: String, _ pattern: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let r = NSRange(text.startIndex..., in: text)
    return re.matches(in: text, range: r).compactMap { m in
        var out: [String] = []
        for g in 1..<m.numberOfRanges {
            guard let rng = Range(m.range(at: g), in: text) else { out.append(""); continue }
            out.append(String(text[rng]))
        }
        return out
    }
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Parse the engine log for the numbers that define "resident".
func strataResidency(logPath: String, maxContext: Int?) -> Residency? {
    var r = Residency(logPath: logPath, engineMaxContext: maxContext)
    guard let text = tailText(logPath) else { return nil }
    r.sampledAt = fileMTime(logPath)

    if let last = matches(text, "conversation cache sized from the free RAM: (\\d+) MiB for up to (\\d+) parked").last,
       let mib = Int(last.first ?? "") {
        r.capMib = mib
        r.slots = Int(last[1])
    }
    if let last = matches(text, "parked=\\d+ bytes=(\\d+) evictions=(\\d+)").last {
        r.parkedBytes = Int(last.first ?? "")
        r.evictions = Int(last[1])
    }
    let parks = matches(text, "parked (\\d+) tokens in [\\d.]+ ms; parked=(\\d+) bytes=(\\d+) evictions=\\d+ snapshot_bytes=(\\d+)")
    var perTok: [Double] = []
    var prev: (tok: Double, bytes: Double)?
    for p in parks {
        guard let tok = Double(p[0]), let snap = Double(p[3]) else { continue }
        r.parkedConvs = Int(p[1]); r.parkedTokens = Int(tok)
        if let pv = prev, tok - pv.tok > 2000, snap - pv.bytes > 0 {
            perTok.append((snap - pv.bytes) / (tok - pv.tok))
        }
        prev = (tok, snap)
    }
    r.bytesPerToken = median(perTok)
    let reads = matches(text, "\\+ (\\d+) read in (\\d+) ms \\(([\\d.]+) tok/s\\)")
    r.prefillTps = median(reads.compactMap { Double($0[2]) })
    return r
}

// MARK: - the per-profile context policy

enum WarnLevel { case info, caution, danger }

/// Backends that run on this machine, where the KV cache decides what a session
/// may hold. The official API does not.
func isLocalKind(_ k: BackendKind) -> Bool { k == .strata || k == .lmstudio }

func kindTitle(_ k: BackendKind) -> String {
    switch k {
    case .lmstudio: return T("menu.lmstudio")
    case .strata: return T("menu.strata")
    case .official: return T("menu.official")
    default: return k.rawValue
    }
}

struct PolicyWarning {
    var level: WarnLevel
    var text: String
}

struct ContextPolicy {
    var kind: BackendKind
    var model: String?
    var modelWindow: Int?
    var compactWindow: Int?
    var windowReason: String
    var sessions: Int
    var coldPrefillSeconds: Int
    var hard: Bool
    var userWindow: Int?          // autoCompactWindow already in the user's settings.json
    var autoCompactEnabled: Bool
    var resident: Residency?
    var warnings: [PolicyWarning] = []

    var isLocal: Bool { isLocalKind(kind) }
    var perSessionBudget: Int? {
        guard let b = resident?.budgetTokens else { return nil }
        return b / max(1, sessions)
    }
}

let DEFAULT_SESSIONS: Int = 2
let DEFAULT_COLD_PREFILL_S: Int = 300
let MIN_COMPACT_WINDOW: Int = 32_000
let WINDOW_ROUND: Int = 4_000

/// Derive the policy for one backend+model. `ov` carries the user's overrides.
func derivePolicy(kind: BackendKind, model: String?, modelWindow: Int?,
                  residency: Residency?, ov: BackendPolicy,
                  userWindow: Int? = nil, autoCompactEnabled: Bool = true) -> ContextPolicy {
    let sessions = max(1, ov.sessions ?? DEFAULT_SESSIONS)
    let waitS = max(0, ov.coldPrefillSeconds ?? DEFAULT_COLD_PREFILL_S)
    var p = ContextPolicy(kind: kind, model: model, modelWindow: modelWindow,
                          compactWindow: nil, windowReason: "auto",
                          sessions: sessions, coldPrefillSeconds: waitS, hard: ov.hard ?? false,
                          userWindow: userWindow, autoCompactEnabled: autoCompactEnabled,
                          resident: residency, warnings: [])
    var wants = [Int]()
    var why: [String] = []

    if let w = ov.compactWindow { wants.append(w); why.append("user") }
    if isLocalKind(kind), !(ov.autoWindow ?? false) {
        if let tps = residency?.prefillTps, waitS > 0 {
            wants.append(Int(tps * Double(waitS)))
            why.append("cold re-read \(waitS)s @ \(Int(tps)) tok/s")
        }
        if let b = residency?.budgetTokens {
            wants.append(b / sessions)
            why.append("resident \(fmtTokens(b)) / \(sessions)")
        }
        if let mw = modelWindow {
            wants.append(mw - WINDOW_ROUND * 2)
            why.append("model window")
        }
    }

    if ov.autoWindow ?? false {
        p.windowReason = "auto (Claude Code decides; warnings only)"
        buildWarnings(&p)
        return p
    }
    if !autoCompactEnabled {
        // Nothing bounds the session at all — publishing a window would be a lie.
        p.windowReason = "autoCompactEnabled=false in settings.json"
        buildWarnings(&p)
        return p
    }
    if let pick = wants.min(), pick > 0 {
        var w = (pick / WINDOW_ROUND) * WINDOW_ROUND
        if let mw = modelWindow { w = min(w, mw) }
        if w < MIN_COMPACT_WINDOW, let mw = modelWindow, mw > MIN_COMPACT_WINDOW {
            w = MIN_COMPACT_WINDOW
        }
        w = max(w, MIN_COMPACT_WINDOW)
        p.windowReason = why.isEmpty ? "user" : why.joined(separator: ", ")
        if let uw = userWindow, uw <= w {
            // The user's own settings.json value is already tighter: leave it alone.
            p.windowReason = "settings.json autoCompactWindow " + fmtTokens(uw) + " is already ≤ target " + fmtTokens(w)
        } else {
            p.compactWindow = w
        }
    }

    buildWarnings(&p)
    return p
}

private func buildWarnings(_ p: inout ContextPolicy) {
    let r = p.resident
    if p.isLocal {
        if p.modelWindow == nil {
            p.warnings.append(PolicyWarning(level: .caution, text: T("policy.nowindow")))
        }
        if r?.budgetTokens == nil {
            p.warnings.append(PolicyWarning(level: .info, text: T("policy.noresidency")))
        }
    }
    if !p.autoCompactEnabled && p.isLocal {
        p.warnings.insert(PolicyWarning(level: .danger, text: T("policy.compactoff")), at: 0)
    }
    if let uw = p.userWindow, let target = p.compactWindow, uw > target {
        p.warnings.append(PolicyWarning(level: .caution,
            text: T("policy.override") + " " + fmtTokens(uw) + " → " + fmtTokens(target)))
    }
    if let r = r, let b = r.budgetTokens, let uw = p.userWindow, uw * p.sessions > b, p.compactWindow == nil {
        p.warnings.append(PolicyWarning(level: .danger,
            text: T("policy.overbudget") + " " + T("policy.yourwindow") + " "
                  + fmtTokens(uw * p.sessions) + " > " + fmtTokens(b)))
    }
    if let r = r, let b = r.budgetTokens, let w = p.compactWindow {
        let need = w * p.sessions
        if need > b {
            p.warnings.append(PolicyWarning(level: .danger,
                text: T("policy.overbudget") + " " + fmtTokens(need) + " > " + fmtTokens(b)))
        }
        if let slots = r.slots, p.sessions > slots {
            p.warnings.append(PolicyWarning(level: .danger,
                text: T("policy.overslots") + ": " + String(p.sessions) + " > " + String(slots)))
        }
        if let d = r.evictionsDelta, d > 0, let tps = r.prefillTps, let w = p.compactWindow {
            p.warnings.append(PolicyWarning(level: .danger,
                text: T("policy.evicted") + " " + String(d) + " (" +
                      String(Int(Double(w) / tps)) + "s " + T("policy.coldre") + ")"))
        } else if let ev = r.evictions, ev > 0 {
            p.warnings.append(PolicyWarning(level: .info,
                text: "engine evictions=" + String(ev) + " since start, parked=" +
                      (r.parkedConvs.map(String.init) ?? "?") + "/" +
                      (r.slots.map(String.init) ?? "?")))
        }
        if let pk = r.parkedConvs, let sl = r.slots, pk >= sl {
            p.warnings.append(PolicyWarning(level: .caution, text: T("policy.cache-full")))
        }
        if let mw = p.modelWindow, mw > b {
            p.warnings.append(PolicyWarning(level: .caution,
                text: T("policy.windowoverslot") + " " + fmtTokens(mw) + " > " + fmtTokens(b)))
        }
    }
}

// MARK: - what to write into a session profile

/// env: make the window real for models Claude Code does not know (2.1.325 guesses
/// a window for an unknown model and then enforces that guess).
func policyEnv(_ p: ContextPolicy) -> [String: String] {
    var e: [String: String] = [:]
    if let mw = p.modelWindow, mw > 0 { e[ENV_MAXCTX] = String(mw) }
    if let w = p.compactWindow, p.hard { e[ENV_ACWINDOW] = String(w) }
    return e
}

/// settings block of the profile file. The settings form keeps /autocompact usable
/// inside the session; the env form (p.hard) wins over it.
func policySettings(_ p: ContextPolicy, statusLineCommand: String?) -> [String: Any] {
    var s: [String: Any] = [:]
    if let w = p.compactWindow, !p.hard { s["autoCompactWindow"] = w }
    if let cmd = statusLineCommand {
        s["statusLine"] = ["type": "command", "command": cmd]
    }
    return s
}

func policyLine(_ p: ContextPolicy) -> String {
    var s = "window " + fmtTokens(p.compactWindow) + " / model " + fmtTokens(p.modelWindow)
    if let r = p.resident, let b = r.budgetTokens {
        s += " · resident " + fmtTokens(b)
        if let slots = r.slots { s += "/\(slots) slots" }
        if let bpt = r.bytesPerToken { s += " · \(Int(bpt / 1024))kB/tok" }
        if let tps = r.prefillTps { s += " · \(Int(tps)) tok/s cold" }
    }
    s += " · ×\(p.sessions)"
    return s
}
