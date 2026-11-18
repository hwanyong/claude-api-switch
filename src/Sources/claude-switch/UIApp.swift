import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var status = StatusInfo()
    var lastGather: Date?
    var refreshing = false
    var lastResult = ""
    var policies: [BackendKind: ContextPolicy] = [:]
    var loads: [SessionLoad] = []
    var residency: Residency?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.unknown)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
        logEvent("app.start", ["lang": kLangPublic()])
        refreshAsync()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        if lastGather == nil || Date().timeIntervalSince(lastGather!) > 15 { refreshAsync() }
    }

    // MARK: refresh

    func refreshAsync() {
        guard !refreshing else { return }
        refreshing = true
        let watch = Store.load().policyFor?.values.contains { $0.watchMenu ?? true } ?? true
        DispatchQueue.global(qos: .userInitiated).async {
            let st = gatherStatus()
            var pols: [BackendKind: ContextPolicy] = [:]
            for k in [BackendKind.strata, .lmstudio] where st.backends.first(where: { $0.kind == k })?.present == true {
                pols[k] = policyFor(k)
            }
            let res = strataResidency()
            let seen = watch ? scanSessions(minutes: 120, limit: 8) : []
            let live = watch ? Watch.live() : []
            var merged = live
            for x in seen where !merged.contains(where: { $0.project == x.project && abs($0.used - x.used) < 4096 }) { merged.append(x) }
            merged.sort { $0.used > $1.used }
            DispatchQueue.main.async {
                self.status = st
                self.policies = pols
                self.residency = res
                self.loads = merged
                self.lastGather = Date()
                self.refreshing = false
                self.setIcon(st.currentKind)
            }
        }
    }

    func backend(_ k: BackendKind) -> Backend? { status.backends.first { $0.kind == k } }

    func describeCurrent() -> String {
        switch status.currentKind {
        case .official:
            return T("menu.official") + ((backend(.official)?.serving ?? true) ? "" : "  ⚠")
        case .custom:
            return "custom · " + (status.currentBase ?? "?")
        default:
            let b = backend(status.currentKind)
            let dot = (b?.serving ?? false) ? "●" : "○"
            return "\(b?.title ?? status.currentKind.rawValue) \(dot)" +
                   (status.currentModel.map { " · \($0)" } ?? "")
        }
    }

    // MARK: icon

    func setIcon(_ kind: BackendKind) {
        let sym = NSImage(systemSymbolName: "switch.2",
                          accessibilityDescription: T("app.name"))
            ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                       accessibilityDescription: T("app.name"))
        sym?.isTemplate = true
        let color: NSColor
        let worst = loads.compactMap { $0.pctBudget }.max() ?? 0
        switch kind {
        case .official: color = .secondaryLabelColor
        case .lmstudio: color = .systemGreen
        case .strata:   color = .systemOrange
        default:        color = .systemGray
        }
        let tint: NSColor
        if worst >= 100 { tint = .systemRed }
        else if worst >= 80 { tint = .systemYellow }
        else { tint = color }
        item.button?.image = sym
        item.button?.attributedTitle = NSAttributedString(
            string: " ●",
            attributes: [.foregroundColor: tint, .font: NSFont.systemFont(ofSize: 9)])
    }

    // MARK: menu

    @discardableResult
    func addDisabled(_ menu: NSMenu, _ text: String) -> NSMenuItem {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.isEnabled = false
        menu.addItem(it)
        return it
    }

    func colored(_ base: String, _ suffix: String) -> NSAttributedString {
        let a = NSMutableAttributedString(string: base)
        a.append(NSAttributedString(string: suffix,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        return a
    }

    func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()

        addDisabled(menu, "Claude API Switch")
        addDisabled(menu, "  " + T("menu.current") + ": " + describeCurrent())
        addDisabled(menu, "  " + T("state.newsession"))
        if !lastResult.isEmpty { addDisabled(menu, "  " + lastResult) }
        if let pct = loads.compactMap({ $0.pctBudget }).max(), pct >= 80 {
            addDisabled(menu, "  " + (pct >= 100 ? "⛔ " : "⚠ ") + T("menu.ctx.sessions")
                        + " " + String(Int(pct)) + "%")
        }
        menu.addItem(.separator())

        // switch items
        for kind in [BackendKind.official, .lmstudio, .strata] {
            let key: String = kind == .official ? "menu.official"
                : kind == .lmstudio ? "menu.lmstudio" : "menu.strata"
            let it = NSMenuItem(title: T(key), action: #selector(doSwitch(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = kind.rawValue
            it.state = (status.currentKind == kind) ? .on : .off
            var suffix = ""
            if kind == .official, !(backend(.official)?.serving ?? true) { suffix = "  (⚠)" }
            if kind != .official, !(backend(kind)?.serving ?? false) { suffix = "  (\(T("state.down")))" }
            if !suffix.isEmpty { it.attributedTitle = colored(T(key), suffix) }
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // models
        let modelsItem = NSMenuItem(title: T("menu.models"), action: nil, keyEquivalent: "")
        let modelsSub = NSMenu()
        let cfgSel = Store.load().modelFor
        for kind in [BackendKind.lmstudio, .strata] {
            guard let b = backend(kind), !b.models.isEmpty else { continue }
            let group = NSMenuItem(title: b.title, action: nil, keyEquivalent: "")
            let gsub = NSMenu()
            for m in b.models {
                let ctx = m.ctx.map { " · \($0 / 1000)k" } ?? ""
                let mi = NSMenuItem(title: m.id + ctx,
                                    action: #selector(doSwitchWithModel(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ["kind": kind.rawValue, "model": m.id]
                let sel = cfgSel?[kind.rawValue] ?? b.model
                mi.state = (sel == m.id) ? .on : .off
                gsub.addItem(mi)
            }
            group.submenu = gsub
            modelsSub.addItem(group)
        }
        modelsItem.submenu = modelsSub
        menu.addItem(modelsItem)

        // context / compaction policy
        let ctxItem = NSMenuItem(title: T("menu.context"), action: nil, keyEquivalent: "")
        let ctxSub = NSMenu()
        for kind in [BackendKind.strata, .lmstudio] {
            guard let p = policies[kind] else { continue }
            addDisabled(ctxSub, kindTitle(kind))
            addDisabled(ctxSub, "  " + policyLine(p) + "  (" + p.windowReason + ")")
            for w in p.warnings.prefix(3) {
                addDisabled(ctxSub, "  " + (w.level == .danger ? "⛔ " : "⚠ ") + w.text)
            }
        }
        if !loads.isEmpty {
            ctxSub.addItem(.separator())
            addDisabled(ctxSub, T("menu.ctx.sessions"))
            for l in loads.prefix(5) {
                let pct = l.pctBudget.map { String(Int($0)) + "%" } ?? (l.pctWindow.map { String(Int($0)) + "%" } ?? "?")
                let flag = (l.pctBudget.map { $0 >= 100 ? " ⛔" : ($0 >= 80 ? " ⚠" : "") } ?? "")
                addDisabled(ctxSub, "  " + l.project + "  " + fmtTokens(l.used) + " " + pct + flag)
            }
        }
        ctxSub.addItem(.separator())
        let ov = Store.load().policyFor ?? [:]
        for (key, sel, action) in [
            ("menu.ctx.statusline", (ov[statusKind.rawValue]?.statusLine ?? true), #selector(doToggleStatusline)),
            ("menu.ctx.watch", (ov[statusKind.rawValue]?.watchMenu ?? true), #selector(doToggleWatch)),
            ("menu.ctx.autowin", !(ov[statusKind.rawValue]?.autoWindow ?? false), #selector(doToggleAutoWindow))] {
            let mi = NSMenuItem(title: T(key), action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = statusKind.rawValue
            mi.state = sel ? .on : .off
            ctxSub.addItem(mi)
        }
        let rewrite = NSMenuItem(title: T("menu.ctx.rebuild"),
                                 action: #selector(doRewriteProfiles), keyEquivalent: "")
        rewrite.target = self
        ctxSub.addItem(rewrite)
        ctxItem.submenu = ctxSub
        menu.addItem(ctxItem)

        // server
        let serverItem = NSMenuItem(title: T("menu.server"), action: nil, keyEquivalent: "")
        let serverSub = NSMenu()
        let lmServing = backend(.lmstudio)?.serving ?? false
        let lmToggle = NSMenuItem(title: lmServing ? T("menu.lm.stop") : T("menu.lm.start"),
                                  action: #selector(doLMToggle), keyEquivalent: "")
        lmToggle.target = self
        serverSub.addItem(lmToggle)
        let strataLaunch = NSMenuItem(title: T("menu.strata.launch"),
                                      action: #selector(doStrataLaunch), keyEquivalent: "")
        strataLaunch.target = self
        serverSub.addItem(strataLaunch)
        serverItem.submenu = serverSub
        menu.addItem(serverItem)
        menu.addItem(.separator())

        // tools
        let refresh = NSMenuItem(title: T("menu.refresh"),
                                 action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let newSess = NSMenuItem(title: T("menu.newsession"), action: nil, keyEquivalent: "")
        let newSub = NSMenu()
        for kind in [BackendKind.lmstudio, .strata] {
            let mi = NSMenuItem(title: backend(kind)?.title ?? kind.rawValue,
                                action: #selector(doCopyCommand(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = kind.rawValue
            newSub.addItem(mi)
        }
        newSess.submenu = newSub
        menu.addItem(newSess)

        let restoreItem = NSMenuItem(title: T("menu.restore"), action: nil, keyEquivalent: "")
        let restoreSub = NSMenu()
        let backups = SettingsEditor().listBackups()
        if backups.isEmpty {
            let none = NSMenuItem(title: "(없음 / none)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            restoreSub.addItem(none)
        } else {
            for f in backups.prefix(10) {
                let mi = NSMenuItem(title: f, action: #selector(doRestore(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = Paths.backups + "/" + f
                restoreSub.addItem(mi)
            }
        }
        restoreItem.submenu = restoreSub
        menu.addItem(restoreItem)

        let openSet = NSMenuItem(title: T("menu.open.settings"),
                                 action: #selector(doOpenSettings), keyEquivalent: "")
        openSet.target = self
        menu.addItem(openSet)
        let openLog = NSMenuItem(title: T("menu.open.log"),
                                 action: #selector(doOpenLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)
        menu.addItem(.separator())

        // autostart
        let auto = NSMenuItem(title: T("menu.autostart"),
                              action: #selector(doToggleAutostart), keyEquivalent: "")
        auto.target = self
        auto.state = autostartEnabled() ? .on : .off
        menu.addItem(auto)

        let quit = NSMenuItem(title: T("menu.quit"), action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: actions

    func runWork(_ work: @escaping () -> SwitchResult) {
        let sym = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        sym?.isTemplate = true
        item.button?.image = sym
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            DispatchQueue.main.async {
                self.lastResult = (r.ok ? "✓ " : "✗ ") + r.message
                if !r.ok { NSSound.beep() }
                logEvent("ui.result", ["ok": r.ok, "message": r.message])
                self.refreshing = false
                self.refreshAsync()
            }
        }
    }

    @objc func doSwitch(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String, let kind = BackendKind(rawValue: k) else { return }
        runWork { switchTo(kind) }
    }

    @objc func doSwitchWithModel(_ s: NSMenuItem) {
        guard let d = s.representedObject as? [String: String],
              let k = d["kind"], let kind = BackendKind(rawValue: k),
              let model = d["model"] else { return }
        runWork { switchTo(kind, model: model) }
    }

    @objc func doLMToggle() {
        let serving = backend(.lmstudio)?.serving ?? false
        runWork {
            if serving {
                stopLMStudioServer()
                return SwitchResult(ok: true, message: "LM Studio server stopped")
            } else {
                let ok = startLMStudioServer()
                return SwitchResult(ok: ok, message: ok ? "LM Studio server started"
                                                        : T("note.lm.startfail"))
            }
        }
    }

    @objc func doStrataLaunch() {
        runWork {
            guard launchStrataApp() else {
                return SwitchResult(ok: false, message: "Strata.app not found")
            }
            if let b = waitForStrataServing(timeout: 40) {
                return SwitchResult(ok: true, message: "Strata serving at \(b.base ?? "")")
            }
            return SwitchResult(ok: false, message: T("note.strata.down"))
        }
    }


    /// which backend's overrides the toggles edit: the current one if local, else strata
    var statusKind: BackendKind {
        status.currentKind == .lmstudio ? .lmstudio : .strata
    }

    @objc func doToggleStatusline(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String, let kind = BackendKind(rawValue: k) else { return }
        var ov = Store.policy(kind)
        ov.statusLine = !(ov.statusLine ?? true)
        Store.setPolicy(kind, ov)
        lastResult = "✓ " + T("menu.ctx.statusline") + ": " + ((ov.statusLine ?? true) ? "on" : "off")
        logEvent("policy.statusline", ["kind": k, "on": ov.statusLine ?? true])
        rebuildMenu()
    }

    @objc func doToggleWatch(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String, let kind = BackendKind(rawValue: k) else { return }
        var ov = Store.policy(kind)
        ov.watchMenu = !(ov.watchMenu ?? true)
        Store.setPolicy(kind, ov)
        lastResult = "✓ " + T("menu.ctx.watch") + ": " + ((ov.watchMenu ?? true) ? "on" : "off")
        logEvent("policy.watch", ["kind": k, "on": ov.watchMenu ?? true])
        rebuildMenu()
    }

    @objc func doToggleAutoWindow(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String, let kind = BackendKind(rawValue: k) else { return }
        var ov = Store.policy(kind)
        ov.autoWindow = !(ov.autoWindow ?? false)
        Store.setPolicy(kind, ov)
        lastResult = "✓ " + T("menu.ctx.autowin") + ": " + ((ov.autoWindow ?? false) ? "off (window published)" : "on (warn only)")
        logEvent("policy.autowindow", ["kind": k, "auto_only": ov.autoWindow ?? false])
        rebuildMenu()
    }

    @objc func doRewriteProfiles() {
        runWork {
            var lines: [String] = []
            var any = false
            for kind in [BackendKind.strata, .lmstudio] {
                if let p = writeProfileFile(kind: kind, model: nil) {
                    any = true
                    lines.append("\(kind.rawValue): \(p.path)")
                    lines.append(policyLine(p.policy))
                }
            }
            if !any { return SwitchResult(ok: false, message: T("switch.fail")) }
            return SwitchResult(ok: true, message: lines.joined(separator: " · "))
        }
    }

    @objc func doRefresh() {
        lastGather = nil
        refreshing = false
        refreshAsync()
    }

    @objc func doCopyCommand(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String, let kind = BackendKind(rawValue: k) else { return }
        runWork {
            guard let p = writeProfileFile(kind: kind, model: nil) else {
                return SwitchResult(ok: false, message: "\(kind.rawValue): not serving")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.command, forType: .string)
            return SwitchResult(ok: true, message: "클립보드 복사: \(p.command)")
        }
    }

    @objc func doRestore(_ s: NSMenuItem) {
        guard let file = s.representedObject as? String else { return }
        runWork {
            do {
                _ = try SettingsEditor().restore(backupFile: file)
                return SwitchResult(ok: true, message: "복원 완료: \((file as NSString).lastPathComponent)")
            } catch let e as SettingsFailure {
                return SwitchResult(ok: false, message: e.message)
            } catch {
                return SwitchResult(ok: false, message: "\(error)")
            }
        }
    }

    @objc func doOpenSettings() {
        _ = runProcess("/usr/bin/open", ["-t", Paths.settings], timeout: 5)
    }

    @objc func doOpenLog() {
        ensureDir(Paths.appSupport)
        _ = runProcess("/usr/bin/open", [Paths.appSupport], timeout: 5)
    }

    @objc func doToggleAutostart() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            lastResult = "⚠ " + T("menu.autostart") + ": .app 번들에서만 지원"
            return
        }
        do {
            if autostartEnabled() {
                try SMAppService.mainApp.unregister()
                lastResult = "✓ " + T("menu.autostart") + ": off"
            } else {
                try SMAppService.mainApp.register()
                lastResult = "✓ " + T("menu.autostart") + ": on"
            }
            logEvent("autostart", ["enabled": autostartEnabled()])
            rebuildMenu()
        } catch {
            lastResult = "✗ autostart: \(error.localizedDescription)"
            rebuildMenu()
        }
    }

    func autostartEnabled() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc func doQuit() { NSApp.terminate(nil) }
}

func kLangPublic() -> String {
    return (Locale.current as NSLocale).object(forKey: .languageCode) as? String ?? "en"
}
