import Foundation

// Upstream.swift — wrapping other MCP servers.
//
// WHY THIS IS NOT JUST A PROXY. A client that can reach session-viewer can usually reach
// `arra-oracle` directly too, so re-exposing its tools under a new name buys nothing and
// costs a hop. What is NOT available any other way is a TOPIC THAT SPANS SOURCES: one saved
// investigation that asks the local session index and an upstream the same question and
// keeps both answers together over time. Proxying is the mechanism; the topic is the point.
//
// Config is EXPLICIT, in `upstreams.json` next to the database — deliberately not read from
// `~/.claude.json`. Two reasons: that file is the user's client configuration and its schema
// is not ours to depend on, and silently inheriting every server the user has configured
// would make this process a credential and capability aggregation point nobody asked for.
// Wrapping something is a decision, so it is written down.
//
//   [
//     {"name": "oracle", "transport": "stdio",
//      "command": "/Users/example/.local/bin/bun", "args": ["/path/to/server.ts"]},
//     {"name": "memory", "transport": "http", "url": "https://…/mcp"}
//   ]

public struct Upstream: Codable, Equatable {
    public let name: String
    public let transport: String        // "stdio" | "http"
    public var command: String?
    public var args: [String]?
    public var url: String?
    /// Seconds to wait for one request. An upstream that hangs must not hang us.
    public var timeout: Double?

    /// Re-expose this upstream's tools in our own tools/list?
    ///
    /// DEFAULT FALSE, and the default is the point. Wrapping a server for COMPOSITION —
    /// so a topic can ask it a question — is a different decision from re-advertising its
    /// entire tool surface. Doing both by default put 30 Oracle tools into a client that
    /// already had Oracle connected directly, doubling them and taking this server from
    /// 13 tools to 43, past Cursor's 40-tool cap.
    ///
    /// Composition works either way; `expose` only controls tools/list.
    public var expose: Bool?

    var isExposed: Bool { expose ?? false }

    /// "auto" (default), "modern", or "legacy".
    ///
    /// THIS FIELD EXISTS BECAUSE THE SPEC HAS TWO ERAS AND MOST SERVERS ARE STILL IN THE OLD
    /// ONE. Protocol 2026-07-28 is stateless — you just send your request. Everything
    /// through 2025-11-25 requires an `initialize` handshake first, and a server in that era
    /// answers a bare `tools/list` with nothing at all: measured against `arra-oracle-v3`,
    /// a bare request produced an immediate EOF (324 ms, read as "unreachable"), while the
    /// same binary with a handshake returned protocolVersion 2025-06-18 and 30 tools.
    /// A wrapper that assumes one era silently sees the other as broken.
    public var era: String?

    var effectiveTimeout: Double { timeout ?? 20 }
    var effectiveEra: String { era ?? "auto" }
}

public func loadUpstreams(dbPath: String) -> [Upstream] {
    let dir = (dbPath as NSString).deletingLastPathComponent
    let path = dir + "/upstreams.json"
    guard let d = FileManager.default.contents(atPath: path) else { return [] }
    guard let list = try? JSONDecoder().decode([Upstream].self, from: d) else {
        FileHandle.standardError.write("[mcp] upstreams.json is not a valid array of upstreams\n".data(using: .utf8)!)
        return []
    }
    return list
}

/// One JSON-RPC round trip to an upstream. Returns the `result` object, or nil.
///
/// Synchronous by design: this is called from a request handler that must produce one
/// answer, and an async hop would only move the waiting somewhere less visible.
func upstreamCall(_ up: Upstream, method: String, params: [String: Any]?) -> [String: Any]? {
    var req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
    if let params { req["params"] = params }
    // Carry our protocol version ONLY to a modern upstream.
    //
    // A per-request version is a MODERN-ERA construct: it exists because there is no
    // handshake to have agreed at. A legacy server has already negotiated its version
    // during `initialize` — telling it, on the very next line, that the protocol is
    // 2026-07-28 contradicts what it just agreed to. Measured against arra-oracle-v3
    // (2025-06-18): with `_meta` attached it answered `initialize` and then went silent on
    // `tools/list` — no error, no exit, just nothing, until our 60 s timeout. The identical
    // request without `_meta` returned 30 tools.
    //
    // This is the dual-era trap in one line: a wrapper that speaks one era at everyone gets
    // silence from the other half and reads it as "unreachable".
    if up.effectiveEra == "modern" {
        req["_meta"] = ["io.modelcontextprotocol/protocol-version": MCP_PROTOCOL_VERSION]
    }
    guard let body = try? JSONSerialization.data(withJSONObject: req) else { return nil }

    switch up.transport {
    case "stdio":  return upstreamStdio(up, body: body)
    case "http":   return upstreamHTTP(up, body: body)
    default:
        FileHandle.standardError.write("[mcp] upstream \(up.name): unknown transport \(up.transport)\n".data(using: .utf8)!)
        return nil
    }
}

/// stdio upstream: spawn, write one line, read one line, reap.
///
/// A process per call, not a persistent one. The modern protocol is stateless — there is no
/// session to keep alive — and a long-lived child would need supervision, restart, and
/// draining that buys nothing when each call is independent. It does mean paying process
/// startup per call, which is why `tools/list` results are cached by the caller.
func upstreamStdio(_ up: Upstream, body: Data) -> [String: Any]? {
    switch up.effectiveEra {
    case "legacy": return upstreamStdioRun(up, body: body, handshake: true)
    case "modern": return upstreamStdioRun(up, body: body, handshake: false)
    default:
        // AUTO: try stateless first — cheaper, and the direction the spec is moving — then
        // fall back to a handshake. The fallback costs one extra process spawn on legacy
        // servers, which is why `era` can be pinned once known.
        if let r = upstreamStdioRun(up, body: body, handshake: false) { return r }
        // The retry must also DROP `_meta`: the modern attempt attached it, and sending it
        // to a legacy server is precisely what makes that server go quiet.
        return upstreamStdioRun(up, body: stripMeta(body), handshake: true)
    }
}

/// Remove `_meta` from an outbound request — see the note in `upstreamCall`.
func stripMeta(_ body: Data) -> Data {
    guard var o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
    o.removeValue(forKey: "_meta")
    return (try? JSONSerialization.data(withJSONObject: o)) ?? body
}

/// `handshake` prepends the legacy `initialize` + `notifications/initialized` pair. Both
/// must go down the SAME process's stdin as the real request — the handshake establishes a
/// session, and a session does not survive the process it was made in.
func upstreamStdioRun(_ up: Upstream, body: Data, handshake: Bool) -> [String: Any]? {
    guard let cmd = up.command else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = up.args ?? []
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = stderr

    do { try p.run() } catch {
        FileHandle.standardError.write("[mcp] upstream \(up.name): launch failed: \(error)\n".data(using: .utf8)!)
        return nil
    }

    var payload = Data()
    if handshake {
        let initReq: [String: Any] = [
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "session-viewer", "version": "1.0.0"],
            ],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: initReq) {
            payload.append(d); payload.append(0x0A)
        }
        if let d = try? JSONSerialization.data(withJSONObject:
            ["jsonrpc": "2.0", "method": "notifications/initialized"] as [String: Any]) {
            payload.append(d); payload.append(0x0A)
        }
    }
    payload.append(body)
    payload.append(0x0A)
    if ProcessInfo.processInfo.environment["SV_MCP_DEBUG"] != nil {
        FileHandle.standardError.write("[mcp] --> \(String(data: payload, encoding: .utf8) ?? "?")".data(using: .utf8)!)
    }
    stdin.fileHandleForWriting.write(payload)
    // DO NOT close stdin yet.
    //
    // The server exits on stdin EOF. Closing immediately after writing raced its own reply:
    // measured, it answered `initialize` (id=0, 196 bytes) and then shut down before ever
    // handling the `tools/list` on the next line — exit 0, no error, nothing to indicate the
    // request had been dropped. A real MCP client holds the pipe open until it has its
    // answer, which is also what makes the transport a session rather than a one-shot.

    let sem = DispatchSemaphore(value: 0)
    let lock = NSLock()
    nonisolated(unsafe) var out = Data()
    nonisolated(unsafe) var result: [String: Any]?

    let outFH = stdout.fileHandleForReading
    let errFH = stderr.fileHandleForReading
    // stderr must be drained: a child that fills a 64 KB stderr pipe with nobody reading
    // blocks forever, and this upstream is chatty at startup.
    DispatchQueue.global(qos: .utility).async { _ = errFH.readDataToEndOfFile() }

    outFH.readabilityHandler = { h in
        let chunk = h.availableData
        // An EMPTY chunk is not necessarily EOF here — it also arrives while the child is
        // still starting. Ignoring it and letting the timeout be the only backstop is what
        // an earlier version got wrong, reporting a working server unreachable in 295 ms.
        guard !chunk.isEmpty else { return }
        lock.lock()
        out.append(chunk)
        for lineData in out.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else { continue }
            guard let rid = o["id"] as? Int, rid == 1 else { continue }
            if o["result"] != nil || o["error"] != nil { result = o }
        }
        let done = result != nil
        lock.unlock()
        if done { sem.signal() }
    }

    let timedOut = sem.wait(timeout: .now() + up.effectiveTimeout) == .timedOut
    outFH.readabilityHandler = nil
    try? stdin.fileHandleForWriting.close()

    if result == nil {
        FileHandle.standardError.write(
            "[mcp] upstream \(up.name): no id=1 response — timedOut=\(timedOut) bytes=\(out.count) handshake=\(handshake)\n"
                .data(using: .utf8)!)
    }

    if p.isRunning { p.terminate() }
    _ = try? stderr.fileHandleForReading.close()

    if result == nil {
        // Say WHICH failure this was. The first version reported "no response within Ns"
        // for every empty result, including ones that returned in 225 ms — a message that
        // sent the reader looking for a timeout that never happened.
        FileHandle.standardError.write(
            "[mcp] upstream \(up.name): no id=1 response — timedOut=\(timedOut) bytes=\(out.count) exit=\(p.isRunning ? -1 : Int(p.terminationStatus)) handshake=\(handshake)\n"
                .data(using: .utf8)!)
        if out.count > 0, let head = String(data: out.prefix(240), encoding: .utf8) {
            FileHandle.standardError.write("[mcp]   stdout head: \(head.replacingOccurrences(of: "\n", with: " ⏎ "))\n".data(using: .utf8)!)
        }
    }
    if let err = result?["error"] as? [String: Any] {
        FileHandle.standardError.write("[mcp] upstream \(up.name) error: \(err)\n".data(using: .utf8)!)
        return nil
    }
    return result?["result"] as? [String: Any]
}

/// http upstream: one POST. `URLSession` is Foundation, not a third-party dependency, so
/// this does not breach the zero-dependency rule — unlike pulling in an HTTP client library.
func upstreamHTTP(_ up: Upstream, body: Data) -> [String: Any]? {
    guard let urlString = up.url, let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    req.timeoutInterval = up.effectiveTimeout

    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any]?
    URLSession.shared.dataTask(with: req) { data, _, error in
        defer { sem.signal() }
        if let error {
            FileHandle.standardError.write("[mcp] upstream \(up.name): \(error.localizedDescription)\n".data(using: .utf8)!)
            return
        }
        guard let data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let err = o["error"] as? [String: Any] {
            FileHandle.standardError.write("[mcp] upstream \(up.name) error: \(err)\n".data(using: .utf8)!)
            return
        }
        out = o["result"] as? [String: Any]
    }.resume()
    _ = sem.wait(timeout: .now() + up.effectiveTimeout + 2)
    return out
}

/// Upstream tools, renamed into our namespace.
///
/// Prefixed `<upstream>__<tool>` so two upstreams exposing `search` stay distinct and
/// neither can shadow one of ours. A double underscore because single ones are common
/// INSIDE tool names and would make the split ambiguous.
func upstreamTools(dbPath: String) -> [MCPTool] {
    var out: [MCPTool] = []
    for up in loadUpstreams(dbPath: dbPath) where up.isExposed {
        guard let r = upstreamCall(up, method: "tools/list", params: nil),
              let tools = r["tools"] as? [[String: Any]] else { continue }
        for t in tools {
            guard let n = t["name"] as? String else { continue }
            out.append(MCPTool(
                name: "\(up.name)__\(n)",
                title: (t["title"] as? String) ?? n,
                description: "[via \(up.name)] " + ((t["description"] as? String) ?? ""),
                schema: (t["inputSchema"] as? [String: Any]) ?? ["type": "object"]))
        }
    }
    return out
}

/// Forward a call to the upstream that owns it. Returns nil when the name is not ours.
func callUpstreamTool(name: String, args: [String: Any], dbPath: String) -> [String: Any]? {
    guard let sep = name.range(of: "__") else { return nil }
    let upName = String(name[..<sep.lowerBound])
    let toolName = String(name[sep.upperBound...])
    guard let up = loadUpstreams(dbPath: dbPath).first(where: { $0.name == upName }) else { return nil }

    guard let r = upstreamCall(up, method: "tools/call",
                               params: ["name": toolName, "arguments": args]) else {
        // A failed upstream is a RESULT the model should see, not a transport error — it
        // may well be able to answer another way.
        return ["content": [["type": "text",
                             "text": "upstream \(upName) did not answer (see stderr for why)"]],
                "isError": true]
    }
    return r
}

/// `session-viewer upstreams` — what is wrapped, and whether it answers.
public func runUpstreamsCLI(dbPath: String) {
    let ups = loadUpstreams(dbPath: dbPath)
    let dir = (dbPath as NSString).deletingLastPathComponent
    guard !ups.isEmpty else {
        print("No upstreams configured.")
        print("Create \(dir)/upstreams.json, e.g.")
        print("""
          [
            {"name":"oracle","transport":"stdio","command":"/path/to/bun","args":["/path/to/server.ts"]},
            {"name":"memory","transport":"http","url":"https://example.workers.dev/mcp"}
          ]
        """)
        return
    }
    for up in ups {
        let target = up.url ?? ([up.command ?? ""] + (up.args ?? [])).joined(separator: " ")
        let t0 = Date()
        let r = upstreamCall(up, method: "tools/list", params: nil)
        let ms = Date().timeIntervalSince(t0) * 1000
        let tools = (r?["tools"] as? [[String: Any]])?.count ?? 0
        let state = r == nil ? "UNREACHABLE" : "\(tools) tools"
        print("  \(padR(up.name, 14)) \(padR(up.transport, 7)) \(padL(String(format: "%.0f ms", ms), 9))  \(padR(state, 14)) \(target.prefix(60))")
    }
}

/// Turn an upstream tool's text result into hits.
///
/// Upstream results are usually JSON, and the first version split the blob on newlines and
/// kept any line over 30 characters — which produced "hits" like `"source_file": "..."` and
/// `"matched by keyword search",`. Fragments of a serialisation are not results. Parse
/// first; fall back to lines only for genuinely unstructured prose.
func upstreamHits(text: String, upstream: String, limit: Int) -> [SearchHit] {
    func hit(_ snippet: String) -> SearchHit {
        SearchHit(sessionId: 0, uuid: upstream, role: "upstream", ts: nil,
                  snippet: String(snippet.prefix(300)), score: 0, seq: 0)
    }

    if let d = text.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) {
        var rows: [[String: Any]] = []
        if let arr = obj as? [[String: Any]] {
            rows = arr
        } else if let o = obj as? [String: Any] {
            // Servers name their result array differently; try the common ones rather than
            // assuming one shape.
            for key in ["results", "items", "matches", "data", "memories", "entries"] {
                if let arr = o[key] as? [[String: Any]] { rows = arr; break }
            }
        }
        if !rows.isEmpty {
            return rows.prefix(limit).map { row in
                for key in ["content", "text", "snippet", "summary", "body", "title", "name"] {
                    if let v = row[key] as? String, !v.isEmpty {
                        let label = (row["type"] as? String).map { "[\($0)] " } ?? ""
                        return hit(label + v.replacingOccurrences(of: "\n", with: " "))
                    }
                }
                // Unrecognised schema: keep the row rather than drop the result.
                return hit(String(describing: row))
            }
        }
    }

    return text.split(separator: "\n")
        .filter { $0.count > 30 }
        .prefix(limit)
        .map { hit(String($0)) }
}
