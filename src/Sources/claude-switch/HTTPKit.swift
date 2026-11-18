import Foundation

struct HTTPResp {
    var status: Int = 0
    var data: Data = Data()
    var error: String?
}

func httpRequest(_ urlString: String,
                 method: String = "GET",
                 headers: [String: String] = [:],
                 body: Data? = nil,
                 timeout: TimeInterval = 5) -> HTTPResp {
    guard let url = URL(string: urlString) else {
        return HTTPResp(error: "bad url: \(urlString)")
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = timeout
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout + 2
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)

    let sem = DispatchSemaphore(value: 0)
    var resp = HTTPResp()
    let task = session.dataTask(with: req) { data, response, error in
        if let e = error {
            resp.error = e.localizedDescription
        } else if let http = response as? HTTPURLResponse {
            resp.status = http.statusCode
            resp.data = data ?? Data()
        }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 2) == .timedOut {
        task.cancel()
        resp.error = "timeout"
    }
    session.finishTasksAndInvalidate()
    return resp
}

/// Parse a /v1/models payload into ModelInfo list.
func parseModels(_ data: Data) -> [ModelInfo] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = obj["data"] as? [[String: Any]] else { return [] }
    var out: [ModelInfo] = []
    for m in arr {
        guard let id = m["id"] as? String else { continue }
        var info = ModelInfo(id: id)
        info.aliases = (m["aliases"] as? [String]) ?? []
        if let meta = m["meta"] as? [String: Any], let ctx = meta["n_ctx"] as? Int {
            info.ctx = ctx
        }
        out.append(info)
    }
    return out
}

/// GET /v1/models. Tries auth styles: none, x-api-key, bearer.
func fetchModels(base: String, token: String?) -> (ok: Bool, models: [ModelInfo], status: Int, error: String?) {
    let url = base.hasSuffix("/") ? String(base.dropLast()) + "/v1/models" : base + "/v1/models"
    var attempts: [[String: String]] = [[:]]
    if let t = token, !t.isEmpty {
        attempts.append(["x-api-key": t])
        attempts.append(["Authorization": "Bearer \(t)"])
    }
    var last = HTTPResp()
    for h in attempts {
        let r = httpRequest(url, headers: h)
        last = r
        if r.status == 200 {
            return (true, parseModels(r.data), 200, nil)
        }
    }
    return (false, [], last.status, last.error ?? "http \(last.status)")
}

/// Minimal POST /v1/messages round-trip used by "check status".
func probeMessages(base: String, token: String?, model: String?, timeout: TimeInterval = 25) -> (ok: Bool, status: Int, error: String?) {
    let url = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/v1/messages"
    let body: [String: Any] = [
        "model": model ?? "default",
        "max_tokens": 4,
        "messages": [["role": "user", "content": "ping"]]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        return (false, 0, "encode error")
    }
    var headers = ["content-type": "application/json", "anthropic-version": "2023-06-01"]
    if let t = token, !t.isEmpty { headers["x-api-key"] = t }
    let r = httpRequest(url, method: "POST", headers: headers, body: data, timeout: timeout)
    if r.status == 200 { return (true, 200, nil) }
    let msg = String(data: r.data.prefix(300), encoding: .utf8) ?? ""
    return (false, r.status, (r.error ?? "http \(r.status)") + (msg.isEmpty ? "" : " — \(msg)"))
}
