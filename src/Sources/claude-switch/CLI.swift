import Foundation

func cliMain(_ args: [String]) -> Int32 {
    func opt(_ name: String) -> String? {
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        return nil
    }
    let cmd = args[0]
    let rest = Array(args.dropFirst())

    switch cmd {
    case "status":
        let st = gatherStatus()
        if args.contains("--json") {
            var backends: [[String: Any]] = []
            for b in st.backends {
                backends.append([
                    "kind": b.kind.rawValue, "title": b.title,
                    "present": b.present, "serving": b.serving,
                    "base": b.base ?? "", "model": b.model ?? "",
                    "token": b.token.map { maskSecret($0) } ?? "",
                    "models": b.models.map { m in
                        var d: [String: Any] = ["id": m.id]
                        if let c = m.ctx { d["n_ctx"] = c }
                        return d
                    },
                    "notes": b.notes
                ])
            }
            let out: [String: Any] = [
                "current": ["kind": st.currentKind.rawValue,
                            "model": st.currentModel ?? "",
                            "base": st.currentBase ?? ""],
                "backends": backends
            ]
            if let d = try? JSONSerialization.data(withJSONObject: out,
                    options: [.prettyPrinted, .withoutEscapingSlashes]) {
                print(String(data: d, encoding: .utf8) ?? "")
            }
        } else {
            print("current: \(st.currentKind.rawValue)" +
                  (st.currentModel.map { " · \($0)" } ?? "") +
                  (st.currentBase.map { " · \($0)" } ?? ""))
            for b in st.backends {
                print(String(format: "  %-10@ %@", b.kind.rawValue as NSString,
                      (b.serving ? "serving" : (b.present ? "stopped" : "absent"))))
                if let base = b.base { print("     base: \(base)") }
                for m in b.models.prefix(12) {
                    let ctx = m.ctx.map { " (\($0) ctx)" } ?? ""
                    print("     model: \(m.id)\(ctx)")
                }
                for n in b.notes { print("     note: \(n)") }
            }
        }
        return 0

    case "list":
        for k in ["official", "lmstudio", "strata"] { print(k) }
        return 0

    case "switch":
        guard let target = rest.first, let kind = BackendKind(rawValue: target) else {
            print("usage: switch official|lmstudio|strata [--model id] [--no-autostart]"); return 2
        }
        let r = switchTo(kind, model: opt("--model"), autoStart: !args.contains("--no-autostart"))
        print(r.message)
        return r.ok ? 0 : 1

    case "models":
        guard let target = rest.first, let kind = BackendKind(rawValue: target) else {
            print("usage: models lmstudio|strata"); return 2
        }
        guard let b = backendFor(kind), b.serving else { print("not serving"); return 1 }
        for m in b.models {
            let ctx = m.ctx.map { " n_ctx=\($0)" } ?? ""
            let al = m.aliases.isEmpty ? "" : " aliases=\(m.aliases.joined(separator: ","))"
            print(m.id + ctx + al)
        }
        return 0

    case "check":
        guard let target = rest.first, let kind = BackendKind(rawValue: target) else {
            print("usage: check official|lmstudio|strata"); return 2
        }
        if kind == .official {
            let kc = runProcess("/usr/bin/security",
                ["find-generic-password", "-s", "Claude Safe Storage"], timeout: 5)
            print("official: keychain credential " + (kc.code == 0 ? "found" : "MISSING"))
            return kc.code == 0 ? 0 : 1
        }
        let r = checkBackend(kind)
        print(r.message)
        return r.ok ? 0 : 1

    case "profile":
        guard let target = rest.first, let kind = BackendKind(rawValue: target) else {
            print("usage: profile lmstudio|strata [--model id] [--statusline|--no-statusline]"); return 2
        }
        let line: Bool? = args.contains("--no-statusline") ? false : (args.contains("--statusline") ? true : nil)
        if let p = writeProfileFile(kind: kind, model: opt("--model"), statusLine: line) {
            print(p.path)
            print(p.command)
            print("  " + policyLine(p.policy) + "  (" + p.policy.windowReason + ")")
            for w in p.policy.warnings { print("  " + (w.level == .danger ? "⛔ " : "⚠ ") + w.text) }
            return 0
        }
        print("cannot write profile (backend not serving?)")
        return 1

    case "policy":
        // policy [kind] [--window 120k] [--sessions N] [--wait S] [--hard|--soft] [--json]
        var kindArg: String? = nil
        for a in rest where !a.hasPrefix("-") { kindArg = a; break }
        let kinds: [BackendKind] = kindArg != nil
            ? (BackendKind(rawValue: kindArg!).map { [$0] } ?? [])
            : [.strata, .lmstudio]
        if kindArg != nil && kinds.isEmpty { print("unknown backend: \(kindArg!)"); return 2 }
        // flags edit the stored override before printing
        for kind in kinds {
            var ov = Store.policy(kind)
            var touched = false
            if let w = opt("--window") {
                if w == "auto" || w == "off" { ov.compactWindow = nil; ov.autoWindow = (w == "off") }
                else if let v = parseTokenAmount(w) { ov.compactWindow = v }
                else { print("bad --window: \(w)"); return 2 }
                touched = true
            }
            if let n = opt("--sessions"), let v = Int(n) { ov.sessions = max(1, v); touched = true }
            if let n = opt("--wait"), let v = Int(n) { ov.coldPrefillSeconds = max(0, v); touched = true }
            if args.contains("--hard") { ov.hard = true; touched = true }
            if args.contains("--soft") { ov.hard = false; touched = true }
            if args.contains("--no-statusline") { ov.statusLine = false; touched = true }
            if args.contains("--statusline") { ov.statusLine = true; touched = true }
            if touched { Store.setPolicy(kind, ov) }
        }
        for kind in kinds {
            let p = policyFor(kind)
            if args.contains("--json") {
                var d: [String: Any] = [
                    "kind": kind.rawValue, "model": p.model ?? "",
                    "compact_window": p.compactWindow ?? 0, "reason": p.windowReason,
                    "model_window": p.modelWindow ?? 0, "sessions": p.sessions,
                    "cold_prefill_seconds": p.coldPrefillSeconds, "hard": p.hard,
                    "warnings": p.warnings.map { ["level": $0.level == .danger ? "danger" : ($0.level == .caution ? "caution" : "info"), "text": $0.text] }
                ]
                if let r = p.resident {
                    d["resident"] = [
                        "cap_mib": r.capMib ?? 0, "slots": r.slots ?? 0,
                        "bytes_per_token": r.bytesPerToken ?? 0,
                        "prefill_tok_s": r.prefillTps ?? 0,
                        "budget_tokens": r.budgetTokens ?? 0,
                        "parked": r.parkedConvs ?? 0, "evictions": r.evictions ?? 0,
                        "log": r.logPath
                    ]
                }
                if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
                    print(String(data: data, encoding: .utf8) ?? "")
                }
                continue
            }
            print("\(kind.rawValue): \(policyLine(p))  [\(p.windowReason)]")
            var pub: [String] = []
            if let w = p.compactWindow {
                pub.append((p.hard ? "env " + ENV_ACWINDOW + "=" : "settings autoCompactWindow=") + String(w))
            } else { pub.append("compact window: untouched (warn only)") }
            if let mw = p.modelWindow { pub.append("env " + ENV_MAXCTX + "=" + String(mw)) }
            print("  publish: " + pub.joined(separator: " + "))
            if let uw = p.userWindow { print("  your settings.json window: " + fmtTokens(uw)) }
            for w in p.warnings { print("  " + (w.level == .danger ? "⛔ " : "⚠ ") + w.text) }
        }
        return 0

    case "statusline":
        return statuslineMain()

    case "watch":
        let mins = Int(opt("--minutes") ?? "") ?? 120
        let live = Watch.live()
        let seen = scanSessions(minutes: mins)
        var rows: [SessionLoad] = live
        for s in seen where !rows.contains(where: { $0.project == s.project && abs($0.used - s.used) < 4096 }) {
            rows.append(s)
        }
        rows.sort { $0.used > $1.used }
        if args.contains("--json") {
            let arr: [[String: Any]] = rows.map {
                ["project": $0.project, "model": $0.model, "used": $0.used,
                 "window": $0.window ?? 0, "budget": $0.budget ?? 0,
                 "at": ISO8601DateFormatter().string(from: $0.at), "source": $0.window == nil ? "transcript" : "statusline"]
            }
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
                print(String(data: data, encoding: .utf8) ?? "")
            }
            return 0
        }
        if let r = strataResidency() {
            print("engine: cap \(r.capMib.map(String.init) ?? "?") MiB, slots \(r.slots.map(String.init) ?? "?"), "
                  + "\(r.bytesPerToken.map { "\(Int($0/1024)) kB/token" } ?? "?"), "
                  + "cold \(r.prefillTps.map { "\(Int($0)) tok/s" } ?? "?")")
            print("resident budget: \(fmtTokens(r.budgetTokens)) tokens "
                  + "(parked \(r.parkedConvs.map(String.init) ?? "?") conversations, evictions \(r.evictions.map(String.init) ?? "?"))")
        }
        if rows.isEmpty { print("no active sessions in the last \(mins) min") }
        for s in rows.prefix(15) {
            var line = "  " + s.project + "  " + fmtTokens(s.used)
            if let w = s.window { line += "/" + fmtTokens(w) }
            if let b = s.budget { line += " budget " + fmtTokens(b) }
            if let pct = s.pctBudget {
                line += " (" + String(Int(pct)) + "%)"
                if pct >= 100 { line += " ⛔ /compact now" } else if pct >= 80 { line += " ⚠" }
            }
            if !s.model.isEmpty { line += "  " + s.model }
            print(line)
        }
        return 0

    case "backups":
        for f in SettingsEditor().listBackups() { print(Paths.backups + "/" + f) }
        return 0

    case "restore":
        let ed = SettingsEditor()
        var f = rest.first ?? "latest"
        if f == "latest" { f = ed.listBackups().first.map { Paths.backups + "/" + $0 } ?? "" }
        if f.isEmpty { print("no backups"); return 1 }
        if !f.hasPrefix("/") { f = Paths.backups + "/" + f }
        do {
            _ = try ed.restore(backupFile: f)
            print("restored from \(f)")
            return 0
        } catch let e as SettingsFailure { print(e.message); return 1 }
        catch { print("\(error)"); return 1 }

    default:
        printUsage()
        return 2
    }
}

func printUsage() {
    print("""
    claude-switch — Claude Code API 스위치 (메뉴바 앱 CLI 모드)

      status [--json]                 현재 상태/감지 결과
      list                            지원 백엔드
      switch <kind> [--model id]      전역 전환 (official|lmstudio|strata)
      models <kind>                   감지된 모델 목록
      check <kind>                    /v1/messages 왕복 확인
      profile <kind> [--model id]     세션형 런처 프로파일 생성+명령 출력
      policy [kind] [flags] [--json]  auto-compact 창/상주 예산 계산·저장
                                      (--window 120k|auto, --sessions N, --wait S, --hard/--soft)
      watch [--minutes N] [--json]    세션별 컨텍스트 토큰 부하
      statusline                      (claude statusLine 훅: stdin JSON → 경고 한 줄)
      backups                         백업 목록
      restore <file|latest>           백업 복원
    """)
}
