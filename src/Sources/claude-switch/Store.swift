import Foundation

/// Per-backend context policy overrides. Everything left nil is derived:
/// window = min(cold re-read patience x prefill tok/s, resident KV budget / sessions,
/// model n_ctx), so a local session never grows past what the engine can keep in RAM.
struct BackendPolicy: Codable {
    var compactWindow: Int?        // nil = derive; set autoWindow true to leave Claude Code's own auto
    var autoWindow: Bool?          // true = never publish a window (warn only)
    var sessions: Int?             // how many local sessions run at once
    var coldPrefillSeconds: Int?   // how long a cold re-read may take
    var hard: Bool?                // publish as env var (beats /autocompact) not setting
    var statusLine: Bool?          // inject the resident-token status line
    var watchMenu: Bool?           // show live token load in the menu bar
}

struct StoreConfig: Codable {
    var modelFor: [String: String]?   // backend kind -> selected model id
    var lmstudioToken: String?
    var language: String?             // "ko" | "en" | nil(auto)
    var policyFor: [String: BackendPolicy]?   // backend kind -> context policy
}

enum Store {
    static func load() -> StoreConfig {
        guard let data = FileManager.default.contents(atPath: Paths.configFile),
              let cfg = try? JSONDecoder().decode(StoreConfig.self, from: data) else {
            return StoreConfig()
        }
        return cfg
    }

    static func save(_ cfg: StoreConfig) {
        ensureDir(Paths.appSupport)
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.configFile), options: .atomic)
    }

    static func policy(_ kind: BackendKind) -> BackendPolicy {
        return load().policyFor?[kind.rawValue] ?? BackendPolicy()
    }

    static func setPolicy(_ kind: BackendKind, _ p: BackendPolicy) {
        var cfg = load()
        var pf = cfg.policyFor ?? [:]
        pf[kind.rawValue] = p
        cfg.policyFor = pf
        save(cfg)
    }

    static func setModel(kind: String, model: String) {
        var cfg = load()
        var mf = cfg.modelFor ?? [:]
        mf[kind] = model
        cfg.modelFor = mf
        save(cfg)
    }
}
