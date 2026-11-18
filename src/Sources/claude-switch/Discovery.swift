import Foundation
import AppKit

// MARK: - Strata discovery (no public docs; instance JSONs are the source)

struct StrataInstance {
    var path: String
    var host: String
    var port: Int
    var apiKey: String
    var modelName: String
    var alias: String?
    var logPath: String?          // engine log: the source of the residency numbers
    var maxContext: Int?          // --max-context from the engine args
}

/// int argument value following a flag in the engine args list.
private func argInt(_ args: [String], _ flag: String) -> Int? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Int(args[i + 1])
}

func strataInstances() -> [StrataInstance] {
    var out: [StrataInstance] = []
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: Paths.strataInstances) else { return [] }
    for f in files where f.hasSuffix(".json") {
        let full = Paths.strataInstances + "/" + f
        guard let obj = jsonRead(full) as? [String: Any],
              let host = obj["host"] as? String,
              let port = obj["port"] as? Int else { continue }
        let args = (obj["args"] as? [String]) ?? []
        let inst = StrataInstance(path: full, host: host, port: port,
                                  apiKey: (obj["api_key"] as? String) ?? "",
                                  modelName: (obj["model_name"] as? String) ?? "",
                                  alias: nil,
                                  logPath: obj["log"] as? String,
                                  maxContext: argInt(args, "--max-context")
                                      ?? argInt(args, "--ctx-size"))
        // model_name may be "id" or have an alias list elsewhere; keep as-is.
        out.append(inst)
    }
    return out.sorted { $0.port < $1.port }
}

/// Residency numbers for the running engine (log tail + engine args).
func strataResidency() -> Residency? {
    guard let inst = strataInstances().first, let log = inst.logPath else { return nil }
    return strataResidency(logPath: log, maxContext: inst.maxContext)
}

func discoverStrata() -> Backend {
    var b = Backend(kind: .strata, title: T("menu.strata"))
    let insts = strataInstances()
    b.present = !insts.isEmpty
    for inst in insts {
        let base = "http://\(inst.host):\(inst.port)"
        let r = fetchModels(base: base, token: inst.apiKey.isEmpty ? nil : inst.apiKey)
        if r.ok {
            b.serving = true
            b.base = base
            b.token = inst.apiKey
            b.models = r.models
            // prefer model listed in instance file, else first
            let hit = r.models.first { $0.id == inst.modelName || $0.aliases.contains(inst.modelName) }
            b.model = hit?.id ?? (inst.modelName.isEmpty ? r.models.first?.id : inst.modelName)
            if let ctx = hit?.ctx { b.notes.append("ctx \(ctx)") }
            break
        }
    }
    if b.present && !b.serving {
        b.notes.append(T("note.strata.down"))
        if let inst = insts.first { b.base = "http://\(inst.host):\(inst.port)" }
    }
    return b
}

// MARK: - declared endpoint (address, key and model typed in by the user)

/// The endpoint declared with `custom set` or the menu item. Detection stays live:
/// GET /v1/models decides "serving", and its meta.n_ctx decides the model window.
func discoverCustom(cfg: StoreConfig) -> Backend {
    var b = Backend(kind: .custom, title: T("menu.custom"))
    guard let c = cfg.custom, !c.base.isEmpty else { return b }
    let base = c.base.hasSuffix("/") ? String(c.base.dropLast()) : c.base
    b.present = true
    b.base = base
    b.token = c.token
    if let t = c.title, !t.isEmpty { b.title = t }
    else if let host = URL(string: base)?.host { b.title = host }

    let r = fetchModels(base: base, token: c.token)
    guard r.ok else {
        b.notes.append(r.error ?? "http not ok")
        return b
    }
    b.serving = true
    b.models = r.models
    let sel = cfg.modelFor?["custom"] ?? c.model
    let hit = r.models.first { m in m.id == sel || (sel != nil && m.aliases.contains(sel!)) }
    b.model = hit?.id ?? sel ?? r.models.first?.id
    if let ctx = hit?.ctx { b.notes.append("ctx \(ctx)") }
    return b
}

// MARK: - LM Studio (Bionic) discovery

func findLmsBinary() -> String? {
    let fm = FileManager.default
    if fm.isExecutableFile(atPath: Paths.lmsBin) { return Paths.lmsBin }
    for p in ["/usr/local/bin/lms", "/opt/homebrew/bin/lms"] where fm.isExecutableFile(atPath: p) {
        return p
    }
    return nil
}

func lmAppExists() -> Bool {
    FileManager.default.fileExists(atPath: "/Applications/Bionic.app") ||
    FileManager.default.fileExists(atPath: "/Applications/LM Studio.app")
}

/// Port from `lms server status`, if running.
func lmStatusPort() -> Int? {
    guard let lms = findLmsBinary() else { return nil }
    let r = runProcess(lms, ["server", "status"], timeout: 10)
    let text = r.out + " " + r.err
    if let re = try? NSRegularExpression(pattern: #"port\s+(\d+)"#, options: [.caseInsensitive]) {
        if let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let rng = Range(m.range(at: 1), in: text),
           let port = Int(text[rng]) {
            return port
        }
    }
    return nil
}

func lmConfigPort() -> Int? {
    guard let obj = jsonRead(Paths.lmServerConfig) as? [String: Any],
          let p = obj["port"] as? Int else { return nil }
    return p
}

func discoverLMStudio(cfg: StoreConfig) -> Backend {
    var b = Backend(kind: .lmstudio, title: T("menu.lmstudio"))
    b.present = lmAppExists() || findLmsBinary() != nil
    var ports: [Int] = []
    if let p = lmStatusPort() { ports.append(p) }
    if let p = lmConfigPort(), !ports.contains(p) { ports.append(p) }
    if !ports.contains(1234) { ports.append(1234) }

    let token = (cfg.lmstudioToken?.isEmpty == false) ? cfg.lmstudioToken : "lmstudio"
    for port in ports {
        let base = "http://127.0.0.1:\(port)"
        let r = fetchModels(base: base, token: token)
        if r.ok {
            b.serving = true
            b.base = base
            b.token = token
            b.models = r.models
            b.model = cfg.modelFor?["lmstudio"] ?? r.models.first?.id
            break
        }
    }
    if !b.serving, let p = ports.first { b.base = "http://127.0.0.1:\(p)" }
    return b
}

func startLMStudioServer(waitSeconds: TimeInterval = 25) -> Bool {
    guard let lms = findLmsBinary() else { return false }
    _ = runProcess(lms, ["server", "start"], timeout: 30)
    let deadline = Date().addingTimeInterval(waitSeconds)
    while Date() < deadline {
        if let port = lmStatusPort() {
            if fetchModels(base: "http://127.0.0.1:\(port)", token: "lmstudio").ok { return true }
        }
        for p in [lmConfigPort(), 1234] {
            if let p = p, fetchModels(base: "http://127.0.0.1:\(p)", token: "lmstudio").ok { return true }
        }
        Thread.sleep(forTimeInterval: 1.0)
    }
    return false
}

func stopLMStudioServer() {
    guard let lms = findLmsBinary() else { return }
    _ = runProcess(lms, ["server", "stop"], timeout: 15)
}

func launchStrataApp() -> Bool {
    let url = URL(fileURLWithPath: "/Applications/Strata.app")
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    NSWorkspace.shared.openApplication(at: url,
        configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    return true
}

/// Wait until Strata endpoint answers (model already loaded), or timeout.
func waitForStrataServing(timeout: TimeInterval = 30) -> Backend? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let b = discoverStrata()
        if b.serving { return b }
        Thread.sleep(forTimeInterval: 1.0)
    }
    return nil
}
