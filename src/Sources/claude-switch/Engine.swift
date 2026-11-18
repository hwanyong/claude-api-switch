import Foundation

struct SwitchResult {
    var ok: Bool
    var message: String
    var backup: String? = nil
}

// MARK: - status

func gatherStatus() -> StatusInfo {
    let cfg = Store.load()
    let ed = SettingsEditor()
    let env = ed.currentEnv()

    var st = StatusInfo()
    let lm = discoverLMStudio(cfg: cfg)
    let str = discoverStrata()

    var official = Backend(kind: .official, title: T("menu.official"), present: true)
    let kc = runProcess("/usr/bin/security",
                        ["find-generic-password", "-s", "Claude Safe Storage"], timeout: 5)
    official.serving = (kc.code == 0)
    if !official.serving {
        official.notes.append("keychain credential not found (login may be required)")
    }

    let cus = discoverCustom(cfg: cfg)
    st.backends = [official, lm, str, cus]

    if let base = env[ENV_BASE] {
        if let sb = str.base, base == sb {
            st.currentKind = .strata
        } else if let lb = lm.base, base == lb {
            st.currentKind = .lmstudio
        } else if strataInstances().contains(where: { "http://\($0.host):\($0.port)" == base }) {
            st.currentKind = .strata
        } else {
            st.currentKind = .custom
        }
    } else {
        st.currentKind = .official
    }
    st.currentModel = env[ENV_MODEL]
    st.currentBase = env[ENV_BASE]
    return st
}

// MARK: - env construction

func envSet(base: String, token: String?, model: String?) -> [String: String] {
    var s = [ENV_BASE: base, ENV_ATTR: "0"]
    if let t = token, !t.isEmpty { s[ENV_TOKEN] = t }
    if let m = model, !m.isEmpty {
        s[ENV_MODEL] = m
        s[ENV_SMALL] = m
        s[ENV_SONNET] = m
        s[ENV_OPUS] = m
        s[ENV_HAIKU] = m
    }
    return s
}

func backendFor(_ kind: BackendKind) -> Backend? {
    let cfg = Store.load()
    switch kind {
    case .lmstudio: return discoverLMStudio(cfg: cfg)
    case .strata:   return discoverStrata()
    case .custom:   return discoverCustom(cfg: cfg)
    default:        return nil
    }
}

// MARK: - context policy

/// Executable to call back into for the profile status line.
func selfExe() -> String {
    if let p = Bundle.main.executablePath, FileManager.default.isExecutableFile(atPath: p) { return p }
    return CommandLine.arguments.first ?? "claude-switch"
}

/// Real context window of a model as the backend reports it (/v1/models meta.n_ctx).
func modelWindow(_ b: Backend, _ model: String?) -> Int? {
    if let m = model, let hit = b.models.first(where: { $0.id == m || $0.aliases.contains(m) }), let c = hit.ctx {
        return c
    }
    return b.models.compactMap { $0.ctx }.max()
}

/// The user's own compaction settings, as Claude Code would apply them.
/// The profile never raises these; it only pins a smaller window, and says so.
func userCompact(model: String?) -> (window: Int?, enabled: Bool) {
    let doc = (try? SettingsEditor().readDoc()) ?? [:]
    let enabled = (doc["autoCompactEnabled"] as? Bool) ?? true
    var w: Int? = nil
    if let v = doc["autoCompactWindow"] as? Int { w = v }
    else if let v = doc["autoCompactWindow"] as? String { w = parseTokenAmount(v) }
    if let m = model, let ms = doc["modelSettings"] as? [String: Any],
       let entry = ms[m] as? [String: Any] {
        if let v = entry["autoCompactWindow"] as? Int { w = v }
        else if let v = entry["autoCompactWindow"] as? String { w = parseTokenAmount(v) }
    }
    return (w, enabled)
}

/// The user's own status line, so our warning can be appended instead of replacing it.
func userStatusLineCommand() -> String? {
    let doc = (try? SettingsEditor().readDoc()) ?? [:]
    guard let sl = doc["statusLine"] as? [String: Any],
          (sl["type"] as? String) == "command",
          let cmd = sl["command"] as? String, !cmd.isEmpty else { return nil }
    if cmd.contains(selfExe()) { return nil }   // our own, avoids recursion
    return cmd
}

/// The policy that a session on this backend should run under.
func policyFor(_ kind: BackendKind, model: String? = nil) -> ContextPolicy {
    let cfg = Store.load()
    let ov = cfg.policyFor?[kind.rawValue] ?? BackendPolicy()
    guard kind != .official else {
        return derivePolicy(kind: kind, model: model, modelWindow: nil, residency: nil, ov: ov)
    }
    let b = backendFor(kind) ?? Backend(kind: kind, title: "?")
    let sel = model ?? cfg.modelFor?[kind.rawValue] ?? b.model
    let res = (kind == .strata) ? Watch.residency() : nil
    let uc = userCompact(model: sel)
    return derivePolicy(kind: kind, model: sel, modelWindow: modelWindow(b, sel),
                        residency: res, ov: ov, base: b.base, userWindow: uc.window,
                        autoCompactEnabled: uc.enabled)
}

// MARK: - switching

func switchTo(_ kind: BackendKind, model: String? = nil, autoStart: Bool = true) -> SwitchResult {
    let ed = SettingsEditor()
    let cfg = Store.load()
    logEvent("switch.start", ["to": kind.rawValue, "model": model ?? ""])

    switch kind {
    case .official:
        do {
            let b = try ed.apply(set: [:], remove: MANAGED_KEYS, tag: "to-official")
            logEvent("switch.ok", ["to": "official", "backup": b ?? ""])
            return SwitchResult(ok: true,
                message: T("switch.ok") + " → " + T("menu.official"), backup: b)
        } catch let e as SettingsFailure {
            logEvent("switch.fail", ["to": "official", "error": e.message])
            return SwitchResult(ok: false, message: e.message)
        } catch {
            logEvent("switch.fail", ["to": "official", "error": "\(error)"])
            return SwitchResult(ok: false, message: "\(error)")
        }

    case .lmstudio, .strata, .custom:
        var b = backendFor(kind) ?? Backend(kind: kind, title: "?")
        // A declared endpoint has nothing we can start: the user starts that server.
        if !b.serving && autoStart, kind != .custom {
            if kind == .lmstudio {
                if startLMStudioServer() { b = discoverLMStudio(cfg: cfg) }
            } else {
                if launchStrataApp(), let bb = waitForStrataServing(timeout: 30) { b = bb }
            }
        }
        guard b.serving, let base = b.base else {
            var msg = T("note.custom.down")
            if kind == .lmstudio { msg = T("note.lm.startfail") }
            else if kind == .strata { msg = T("note.strata.down") }
            logEvent("switch.fail", ["to": kind.rawValue, "error": msg])
            return SwitchResult(ok: false, message: msg)
        }
        let sel = model ?? cfg.modelFor?[kind.rawValue] ?? b.model
        var note = ""
        if let mid = sel, let m = b.models.first(where: { $0.id == mid }), let ctx = m.ctx, ctx < 25000 {
            note = "  ⚠ ctx \(ctx) < 25k"
        }
        let pol = policyFor(kind, model: sel)
        do {
            var set = envSet(base: base, token: b.token, model: sel)
            for (k, v) in policyEnv(pol) { set[k] = v }
            let bk = try ed.apply(set: set, remove: [ENV_APIKEY], tag: "to-\(kind.rawValue)")
            if let m = sel { Store.setModel(kind: kind.rawValue, model: m) }
            logEvent("switch.ok", ["to": kind.rawValue, "base": base, "model": sel ?? "",
                                   "token": b.token ?? "", "backup": bk ?? ""])
            var w = ""
            if let worst = pol.warnings.first(where: { $0.level == .danger }) ?? pol.warnings.first {
                w = "\n⚠ " + worst.text
            }
            return SwitchResult(ok: true,
                message: T("switch.ok") + " → \(b.title) · \(sel ?? "-")" + note + w, backup: bk)
        } catch let e as SettingsFailure {
            logEvent("switch.fail", ["to": kind.rawValue, "error": e.message])
            return SwitchResult(ok: false, message: e.message)
        } catch {
            logEvent("switch.fail", ["to": kind.rawValue, "error": "\(error)"])
            return SwitchResult(ok: false, message: "\(error)")
        }

    default:
        return SwitchResult(ok: false, message: "unsupported target: \(kind.rawValue)")
    }
}

// MARK: - session launcher profile file

/// Writes ~/.claude/profiles/<kind>.json — a full Claude Code settings file:
/// env block + the context policy (autoCompactWindow / window env) + the resident
/// token status line. Returns (path, command, policy).
func writeProfileFile(kind: BackendKind, model: String?,
                      statusLine: Bool? = nil) -> (path: String, command: String, policy: ContextPolicy)? {
    guard kind == .lmstudio || kind == .strata || kind == .custom else { return nil }
    let cfg = Store.load()
    guard let b = backendFor(kind), b.serving, let base = b.base else { return nil }
    let sel = model ?? cfg.modelFor?[kind.rawValue] ?? b.model
    var set = envSet(base: base, token: b.token, model: sel)
    let pol = policyFor(kind, model: sel)
    for (k, v) in policyEnv(pol) { set[k] = v }

    let ov = cfg.policyFor?[kind.rawValue] ?? BackendPolicy()
    let wantLine = statusLine ?? (ov.statusLine ?? true)
    let cmd: String? = wantLine ? "\"\(selfExe())\" statusline || true" : nil

    var doc: [String: Any] = ["env": set]
    let st = policySettings(pol, statusLineCommand: cmd)
    for (k, v) in st { doc[k] = v }
    doc["_ccswitch"] = [
        "kind": kind.rawValue, "model": sel ?? "",
        "compact_window": pol.compactWindow ?? 0,
        "model_window": pol.modelWindow ?? 0,
        "resident_budget_tokens": pol.resident?.budgetTokens ?? 0,
        "resident_cap_mib": pol.resident?.capMib ?? 0,
        "sessions": pol.sessions,
        "reason": pol.windowReason,
        "written": ISO8601DateFormatter().string(from: Date())
    ] as [String: Any]

    ensureDir(Paths.profiles)
    let path = Paths.profiles + "/" + kind.rawValue + ".json"
    // The profile holds the endpoint key: owner-only from the first byte.
    guard jsonWrite(path, doc, fileMode: 0o600) else { return nil }
    logEvent("profile.write", ["kind": kind.rawValue, "model": sel ?? "",
                               "compact_window": pol.compactWindow ?? 0,
                               "model_window": pol.modelWindow ?? 0,
                               "resident_tokens": pol.resident?.budgetTokens ?? 0,
                               "statusline": wantLine])
    return (path, "claude --settings \"\(path)\"", pol)
}

// MARK: - health check

func checkBackend(_ kind: BackendKind) -> SwitchResult {
    guard let b = backendFor(kind), b.serving, let base = b.base else {
        return SwitchResult(ok: false, message: "\(kind.rawValue): not serving")
    }
    // Probe up to 4 models (selected first) — some entries are non-chat models
    // (audio/embedding) that hang or 400 on /v1/messages.
    let cfg = Store.load()
    var tried: [String] = []
    if let sel = cfg.modelFor?[kind.rawValue] ?? b.model { tried.append(sel) }
    for m in b.models where tried.count < 4 {
        if !tried.contains(m.id) { tried.append(m.id) }
    }
    var last: (ok: Bool, status: Int, error: String?) = (false, 0, "no models")
    for m in tried {
        last = probeMessages(base: base, token: b.token, model: m, timeout: 12)
        if last.ok {
            return SwitchResult(ok: true, message: "\(b.title): OK (HTTP 200) model=\(m)")
        }
    }
    return SwitchResult(ok: false,
        message: "\(b.title): " + (last.error ?? "HTTP \(last.status)"))
}
