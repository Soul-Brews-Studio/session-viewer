// Serve.swift — the app as a server: HTTP for a web UI, WebSocket for the live stream.
//
// WHY A SERVER AND NOT A WEBVIEW. The earlier question was "do we need a webview toggler?"
// A WebView would have replaced the native renderer to gain CSS. This is the better shape:
// the Mac app keeps its native list, and the web UI becomes a SECOND CLIENT of the same
// data. Nothing is replaced, the browser gets full CSS, and the stream can reach another
// machine (a phone, a second display, a tunnelled host) which a WebView never could.
//
// ZERO DEPENDENCIES, verified before writing this. Network.framework ships
// `NWProtocolWebSocket`, and it works on the LISTENER side, not just as a client — checked
// by standing up an NWListener with a websocket options stack on a real port before
// committing to the design. So no Vapor, no swift-nio, nothing added to Package.swift.
//
// WHAT IT REUSES. Everything. `liveFiles`/`discoverFiles` decide what is live (one
// definition, Ingest.swift), `SessionTailer` does the byte-offset incremental read (one
// tailer, Tail.swift), `LiveEventRow.summarizeBlocks` names the tool calls (one summarizer,
// shared with the window and the CLI). The server adds transport and nothing else — if it
// disagreed with the app about what "live" means, that would be a second source of truth.

import Foundation
import Network

// MARK: - Wire format

/// One frame on the wire. Deliberately a tagged union with a `kind` string rather than
/// bare arrays: a browser client has to switch on something, and adding a case later must
/// not break a client that does not know it yet.
struct WireFrame: Encodable {
    let kind: String              // "fleet" | "events" | "attached" | "error"
    var fleet: [WireSession]?
    var events: [WireEvent]?
    var path: String?
    var message: String?
    /// history frames only: the byte offset this page STARTS at. The client sends it back
    /// as `before` to page further, and when it reaches 0 there is nothing older left.
    var fromOffset: Int?
    var atTop: Bool?
    var stamp: String
}

struct WireSession: Encodable {
    let path: String
    let project: String
    let tier: String
    let sessionUUID: String
    let agentId: String?
    let agentName: String?        // parsed from the filename; nil when unnamed
    let workflowRunId: String?
    let size: Int
    let secondsSinceWrite: Int
    let heat: String              // "hot" | "warm" | "cool"
}

struct WireEvent: Encodable {
    let seq: Int
    let lineType: String
    let ts: String?
    let text: String              // conversational text, "" when none
    let summary: String?          // tool/thinking summary when text is empty
    let byteOffset: Int
}

private func wireHeat(_ h: LiveHeat) -> String {
    switch h {
    case .hot: return "hot"
    case .warm: return "warm"
    case .cool: return "cool"
    }
}

private func isoNow() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")   // never the machine's Buddhist calendar
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f.string(from: Date())
}

// MARK: - Server

final class SessionServer {
    private let root: String
    private let dbPath: String
    private let port: NWEndpoint.Port
    private let windowSeconds: Int

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "session-viewer.serve")

    /// One tailer per connection, keyed by the path that connection asked to follow.
    /// Per-connection rather than shared because two browsers may watch different sessions,
    /// and a shared tailer would have to arbitrate offsets between them.
    private var clients: [ObjectIdentifier: ClientState] = [:]

    private final class ClientState {
        let conn: NWConnection
        var tailer: SessionTailer?
        var attachedPath: String?
        var seq = 0
        init(conn: NWConnection) { self.conn = conn }
    }

    init(root: String, dbPath: String, port: UInt16, windowSeconds: Int) {
        self.root = root
        self.dbPath = dbPath
        self.port = NWEndpoint.Port(rawValue: port)!
        self.windowSeconds = windowSeconds
    }

    func run() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true                       // browsers ping; answer without waking us
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true          // restart without waiting for TIME_WAIT
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // BIND TO LOOPBACK — the same fix the HTTP listener below already carries.
        //
        // It was applied there and NOT here, and the gap was invisible from the code because
        // this function PRINTS "ws://127.0.0.1:<port>" either way. `lsof` told the truth:
        //     TCP 127.0.0.1:8793 (LISTEN)   ← http/mcp, correct
        //     TCP *:8792        (LISTEN)   ← this one, every interface
        // So the transport that streams live session content — the whole corpus, as it is
        // written — was reachable by anything that could route to this machine, while the
        // more obviously sensitive MCP endpoint next to it was not. Same argument, same
        // audit finding ("⚠️ NO PACKET FILTERING — everything on 0.0.0.0 is reachable"),
        // and `requiredLocalEndpoint` replaces `on:` here for the same POSIX 22 reason.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

        do {
            let l = try NWListener(using: params)
            listener = l
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] (st: NWListener.State) in
                guard let self else { return }
                switch st {
                case .ready:
                    print("serve: ws://127.0.0.1:\(self.port.rawValue)  (root=\(self.root))")
                    print("serve: open the web UI, or connect a WebSocket client directly")
                case .failed(let e):
                    FileHandle.standardError.write("serve: listener failed: \(e)\n".data(using: .utf8)!)
                    exit(1)
                default: break
                }
            }
            l.start(queue: queue)
        } catch {
            FileHandle.standardError.write("serve: cannot listen on \(port): \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        startFleetTimer()
        dispatchMain()
    }

    private func accept(_ c: NWConnection) {
        let state = ClientState(conn: c)
        clients[ObjectIdentifier(c)] = state

        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            if case .cancelled = st { self.clients[ObjectIdentifier(c)] = nil }
            if case .failed = st { self.clients[ObjectIdentifier(c)] = nil }
        }
        c.start(queue: queue)
        receive(on: c)

        // Send the current fleet immediately — a client that connects between ticks should
        // not stare at an empty page for two seconds. Reuses the same builder as the timer
        // so a newly-connected client cannot see a different shape than a ticking one.
        send(currentFleetFrame(), to: state)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, ctx, _, err in
            guard let self else { return }
            if err != nil { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                self.handle(command: text, from: c)
            }
            _ = ctx
            self.receive(on: c)
        }
    }

    /// Commands are one-line JSON: {"cmd":"attach","path":"…"} / {"cmd":"detach"}.
    private func handle(command: String, from c: NWConnection) {
        guard let state = clients[ObjectIdentifier(c)],
              let d = command.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cmd = obj["cmd"] as? String
        else { return }

        switch cmd {
        case "attach":
            guard let path = obj["path"] as? String else { return }
            attach(state: state, to: path)
        case "history":
            // Scroll-up paging. The live tail only ever moves FORWARD from its offset, so
            // older lines need a separate bounded read that never touches the follow
            // tailer's position — otherwise paging back would rewind the live view.
            guard let path = obj["path"] as? String,
                  let before = obj["before"] as? Int else { return }
            sendHistory(to: state, path: path, before: before)
        case "detach":
            state.tailer = nil
            state.attachedPath = nil
        default:
            break
        }
    }

    /// How far back from EOF to start, so an attach shows recent context immediately.
    ///
    /// Attaching exactly AT eof was correct in the "don't replay 39 MB down a socket"
    /// sense and wrong in the way that matters: the pane stayed completely blank until the
    /// session happened to write again, which on a thinking session is a minute or more of
    /// staring at nothing. `tail -f` behaves the same way and nobody uses it bare — they
    /// use `tail -n 40 -f`. This is that -n.
    ///
    /// Bytes rather than lines because the offset must be a byte offset anyway, and lines
    /// here run from ~80 B to ~30 KB. 256 KB is a few dozen real events: enough to see what
    /// the session is doing, far short of the 39.6 MB p99 file.
    static let backfillBytes = 256 * 1024

    /// Attach slightly BEFORE the end of the file, then follow. See `backfillBytes`.
    private func attach(state: ClientState, to path: String) {
        state.attachedPath = path
        state.seq = 0
        guard let st = statFile(path) else {
            send(WireFrame(kind: "error", fleet: nil, events: nil, path: path,
                           message: "cannot stat file", fromOffset: nil, atTop: nil, stamp: isoNow()), to: state)
            return
        }
        let from = max(0, st.size - SessionServer.backfillBytes)
        let start = SessionTailer.alignedOffset(path: path, approx: from)
        state.tailer = SessionTailer(path: path, offset: start)
        send(WireFrame(kind: "attached", fleet: nil, events: nil, path: path,
                       message: "following from byte \(start) of \(st.size)", fromOffset: start, atTop: nil, stamp: isoNow()), to: state)
        // Push the backfill immediately rather than waiting for the next 2s tick — the
        // whole point is that the pane is not blank when you arrive.
        drainTail(state)
    }

    /// One page of OLDER lines, ending just before `before`.
    ///
    /// Reads forward from an aligned offset one page back, then keeps only what falls
    /// before the requested boundary — a jsonl file cannot be read backwards, so "the
    /// previous page" is "read forward from earlier and stop". Uses its OWN tailer, never
    /// `state.tailer`, so paging history cannot move the live follow position.
    private func sendHistory(to state: ClientState, path: String, before: Int) {
        if before <= 0 {
            send(WireFrame(kind: "history", fleet: nil, events: [], path: path,
                           message: nil, fromOffset: 0, atTop: true, stamp: isoNow()), to: state)
            return
        }
        let want = max(0, before - SessionServer.backfillBytes)
        let from = SessionTailer.alignedOffset(path: path, approx: want)
        let pager = SessionTailer(path: path, offset: from)
        guard let read = try? pager.read(maxBytes: SessionServer.backfillBytes * 2) else { return }

        var out: [WireEvent] = []
        var seq = -1                      // negative ids: older than anything already shown
        for e in read.events where e.byteOffset < before {
            let summary = e.text.isEmpty ? LiveEventRow.summarizeBlocks(raw: e.raw) : nil
            out.append(WireEvent(seq: seq,
                                 lineType: e.parsedOK ? (e.lineType ?? "(no type)") : "malformed",
                                 ts: e.timestamp, text: e.text, summary: summary,
                                 byteOffset: e.byteOffset))
            seq -= 1
        }
        send(WireFrame(kind: "history", fleet: nil, events: out, path: path, message: nil,
                       fromOffset: from, atTop: from <= 0, stamp: isoNow()), to: state)
    }

    // MARK: fleet + tail ticks

    private func startFleetTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 2.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        fleetTimer = t
    }
    private var fleetTimer: DispatchSourceTimer?

    /// One definition of the fleet frame, used by both the 2s tick and the on-connect
    /// send — otherwise a client's first frame could disagree with its second.
    private func currentFleetFrame() -> WireFrame {
        let db = DB(path: dbPath)
        db.setBusyTimeout()
        let names = loadProjectNames(db: db)
        let live = scanLiveSessions(root: root, windowSeconds: windowSeconds, projectNames: names)
        let wire = live.map { s in
            WireSession(path: s.path, project: s.project, tier: s.tier,
                        sessionUUID: s.sessionUUID, agentId: s.agentId,
                        agentName: agentDisplayName(agentId: s.agentId),
                        workflowRunId: s.workflowRunId, size: s.size,
                        secondsSinceWrite: s.secondsSinceWrite, heat: wireHeat(s.heat))
        }
        return WireFrame(kind: "fleet", fleet: wire, events: nil, path: nil,
                         message: nil, fromOffset: nil, atTop: nil, stamp: isoNow())
    }

    private func tick() {
        guard !clients.isEmpty else { return }
        let frame = currentFleetFrame()
        for (_, state) in clients {
            send(frame, to: state)
            drainTail(state)
        }
    }

    /// Read only the delta, exactly as the window does — the append-only property is what
    /// makes streaming a 39 MB file to a browser cost the bytes that were just written
    /// rather than the whole file.
    private func drainTail(_ state: ClientState) {
        guard let tailer = state.tailer else { return }
        guard let read = try? tailer.read(), !read.events.isEmpty else { return }

        var out: [WireEvent] = []
        for e in read.events {
            state.seq += 1
            let summary = e.text.isEmpty ? LiveEventRow.summarizeBlocks(raw: e.raw) : nil
            out.append(WireEvent(seq: state.seq,
                                 lineType: e.parsedOK ? (e.lineType ?? "(no type)") : "malformed",
                                 ts: e.timestamp, text: e.text, summary: summary,
                                 byteOffset: e.byteOffset))
        }
        send(WireFrame(kind: "events", fleet: nil, events: out, path: state.attachedPath,
                       message: nil, fromOffset: nil, atTop: nil, stamp: isoNow()), to: state)
    }

    private func send(_ frame: WireFrame, to state: ClientState) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        state.conn.send(content: data, contentContext: ctx, isComplete: true,
                        completion: .contentProcessed { _ in })
    }
}

// MARK: - CLI entry

public func runServe(root: String, dbPath: String, port: UInt16, windowSeconds: Int, webRoot: String) {
    // HTTP on port+1 so the page has a real origin; websocket on `port`.
    let http = StaticFileServer(port: port &+ 1, webRoot: webRoot)
    // Same listener serves the web UI and MCP. One port, two things, because the MCP
    // binding is a route rather than a service — and "one more port" is the decision this
    // fleet's own notes argue against on a host with no packet filtering.
    http.mcpDBPath = dbPath
    http.mcpRoot = root
    http.start()
    print("serve: http://127.0.0.1:\(port &+ 1)/       ← web UI")
    print("serve: http://127.0.0.1:\(port &+ 1)/mcp    ← MCP (POST only, protocol \(MCP_PROTOCOL_VERSION))")
    let s = SessionServer(root: root, dbPath: dbPath, port: port, windowSeconds: windowSeconds)
    s.run()
}

// MARK: - HTTP for the web UI

/// A deliberately tiny HTTP/1.1 server whose only job is to hand the browser index.html
/// from an http:// origin.
///
/// WHY IT EXISTS: opening the file directly gives the page a `file://` origin, and browsers
/// treat every `file:` URL as a UNIQUE, opaque security origin — so the page cannot open a
/// WebSocket at all. The observed error is exactly that:
///   "Unsafe attempt to load URL file://… from frame with URL file://…
///    'file:' URLs are treated as unique security origins."
/// Nothing is wrong with the socket; the page simply is not allowed to use it. Serving the
/// same bytes over http://127.0.0.1 gives it a real origin and the connection is permitted.
///
/// A SEPARATE listener on its own port, not the websocket one: that listener has
/// `NWProtocolWebSocket` in its protocol stack and therefore expects an upgrade handshake,
/// so a plain GET on it is not a supported shape.
/// One parsed HTTP request. This type exists because the server previously read a single
/// 8 KB chunk and pulled the path out of it with `split(separator: " ")` — no method, no
/// headers, and no body at all. That was adequate for handing a browser one page and is not
/// adequate for MCP, whose Streamable HTTP binding is POST-only with a JSON body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]     // lowercased keys
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

final class StaticFileServer {
    private let port: NWEndpoint.Port
    private let webRoot: String
    private let queue = DispatchQueue(label: "session-viewer.http")
    private var listener: NWListener?

    /// Set to serve MCP at `/mcp`. Nil leaves the server exactly as it was — a static file
    /// server — so the MCP binding is additive and can be left off.
    var mcpDBPath: String?
    var mcpRoot: String?

    /// Largest request body accepted. A JSON-RPC call is small; anything near this is either
    /// a mistake or an attempt to make the process hold memory it cannot use.
    static let maxBody = 4 << 20

    init(port: UInt16, webRoot: String) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.webRoot = webRoot
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // BIND TO LOOPBACK, not 0.0.0.0.
        //
        // NWListener(on:) binds every interface by default. This fleet's own host audit
        // prints "⚠️ NO PACKET FILTERING — everything on 0.0.0.0 is reachable", so a
        // default bind would put the entire session corpus — and now an MCP tool surface —
        // on the network for anyone who can route to this machine.
        // `requiredLocalEndpoint` carries BOTH host and port, so the listener must NOT also
        // be given `on:` — supplying both fails at start with POSIX 22 (Invalid argument),
        // which surfaces only as a log line while the process keeps running and serves
        // nothing. Found by starting it, not by reading it.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        do {
            let l = try NWListener(using: params)
            listener = l
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: queue)
        } catch {
            FileHandle.standardError.write("serve: http listener failed: \(error)\n".data(using: .utf8)!)
        }
    }

    /// Read a whole request: head, then exactly `Content-Length` bytes of body.
    ///
    /// The body must be read across MULTIPLE receives. A single 8 KB read happens to work
    /// for a GET and silently truncates any POST larger than one TCP segment — which would
    /// present as malformed JSON from the client, not as a server error.
    private func readRequest(_ c: NWConnection, accumulated: Data = Data(),
                             _ done: @escaping (HTTPRequest?) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, _ in
            guard let self else { return done(nil) }
            var buf = accumulated
            if let chunk { buf.append(chunk) }

            // Find the head/body boundary.
            guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || buf.count > 64 * 1024 { return done(nil) }
                return self.readRequest(c, accumulated: buf, done)
            }

            let head = String(data: buf[..<sep.lowerBound], encoding: .utf8) ?? ""
            var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { return done(nil) }
            let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
            guard requestLine.count >= 2 else { return done(nil) }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }

            let want = Int(headers["content-length"] ?? "0") ?? 0
            guard want <= StaticFileServer.maxBody else { return done(nil) }
            var body = buf[sep.upperBound...]
            if body.count < want {
                if isComplete { return done(nil) }
                return self.readRequest(c, accumulated: buf, done)
            }
            if body.count > want { body = body.prefix(want) }

            done(HTTPRequest(method: requestLine[0], path: requestLine[1],
                             headers: headers, body: Data(body)))
        }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        readRequest(c) { [weak self] req in
            guard let self else { return }
            guard let req else { return c.cancel() }

            // ---- MCP Streamable HTTP, protocol 2026-07-28 ----------------------------
            if req.path == "/mcp" || req.path.hasPrefix("/mcp?") {
                return self.serveMCP(c, req)
            }
            // ---- the surface, as JSON. GET, because it is a read.
            //
            // Separate from /mcp on purpose: /mcp is the PROTOCOL and answers only POST.
            // This is an observation endpoint about that protocol surface, and wanting to
            // curl it should not require composing a JSON-RPC envelope.
            if req.path == "/mcp/surface" || req.path.hasPrefix("/mcp/surface?") {
                let probe = !req.path.contains("probe=0")
                let surface = readMCPSurface(dbPath: self.mcpDBPath ?? "", probeUpstreams: probe)
                let body = (try? JSONEncoder().encode(surface)) ?? Data("{}".utf8)
                var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var out = Data(head.utf8); out.append(body)
                return c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
            }

            let path = req.path
            let file = (path == "/" || path.hasPrefix("/?")) ? "index.html"
                     : String(path.dropFirst()).replacingOccurrences(of: "..", with: "")
            let full = self.webRoot + "/" + file

            let body = FileManager.default.contents(atPath: full)
            let status = body == nil ? "404 Not Found" : "200 OK"
            let payload = body ?? Data("not found: \(file)".utf8)
            // MIME MATTERS, it is not cosmetic. A browser REFUSES to execute a module
            // script served as text/plain ("Failed to load module script: expected a
            // JavaScript MIME type") — the page loads and renders nothing, with the only
            // clue in the console. Caught here by checking the served header rather than
            // by opening the page and seeing white.
            let type: String
            switch (file as NSString).pathExtension.lowercased() {
            case "html": type = "text/html; charset=utf-8"
            case "js", "mjs": type = "text/javascript; charset=utf-8"
            case "css": type = "text/css; charset=utf-8"
            case "json": type = "application/json; charset=utf-8"
            case "svg": type = "image/svg+xml"
            case "woff2": type = "font/woff2"
            case "png": type = "image/png"
            default: type = "application/octet-stream"
            }
            var head = "HTTP/1.1 \(status)\r\n"
            head += "Content-Type: \(type)\r\n"
            head += "Content-Length: \(payload.count)\r\n"
            head += "Cache-Control: no-store\r\n"     // always serve the file as it is on disk
            head += "Connection: close\r\n\r\n"

            c.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                c.cancel()
            })
        }
    }
}

// MARK: - MCP over Streamable HTTP

extension StaticFileServer {

    /// Serve one MCP request on the SAME listener that serves the web UI.
    ///
    /// Streamable HTTP (protocol 2026-07-28) is one endpoint, POST only. The modern era
    /// removed the standalone GET SSE stream, protocol-level sessions (`Mcp-Session-Id`)
    /// and `Last-Event-ID` resumability — so a modern-only server answers GET and DELETE on
    /// this endpoint with 405 and ignores those headers entirely. That is what this does.
    ///
    /// The shape is taken from `Soul-Brews-Studio/arra-memory-cloudflare-template`, which
    /// runs the same binding on Cloudflare Workers: a single `apiRoute: "/mcp"`, stateless,
    /// with the SDK owning the transport. We cannot use that SDK from Swift, so the binding
    /// is hand-rolled here — but the endpoint shape and the statelessness are theirs.
    ///
    /// One thing deliberately NOT copied: their OAuth. They are on the public internet and
    /// need it. This listener is bound to LOOPBACK, so the trust boundary is the machine,
    /// and adding an auth flow to a socket only this host can reach would be ceremony.
    /// That is a consequence of the bind, so it stops being true the moment the bind changes
    /// — which is why the bind is pinned in `start()` rather than left to a flag.
    func serveMCP(_ c: NWConnection, _ req: HTTPRequest) {
        func send(_ status: String, _ body: Data, contentType: String = "application/json") {
            var head = "HTTP/1.1 \(status)\r\n"
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            var out = Data(head.utf8)
            out.append(body)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
        func rpcError(_ id: Any?, _ code: Int, _ message: String, _ data: Any? = nil) -> Data {
            var err: [String: Any] = ["code": code, "message": message]
            if let data { err["data"] = data }
            let o: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": err]
            return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        }

        // ORIGIN VALIDATION — a spec MUST, and the reason is specific: without it any web
        // page the user visits can POST to 127.0.0.1 from their browser and read this
        // machine's entire session history. Binding to loopback does NOT prevent that; the
        // browser IS on loopback. DNS rebinding is exactly this attack.
        //
        // A missing Origin is allowed: that is a non-browser client (curl, an MCP client),
        // which is the normal case here. A PRESENT Origin must be local.
        if let origin = req.header("Origin") {
            let ok = origin.hasPrefix("http://localhost")
                  || origin.hasPrefix("http://127.0.0.1")
                  || origin.hasPrefix("https://localhost")
                  || origin.hasPrefix("https://127.0.0.1")
                  || origin == "null"
            if !ok {
                return send("403 Forbidden",
                            Data(#"{"error":"origin not allowed"}"#.utf8))
            }
        }

        // Modern-only: this endpoint takes POST and nothing else.
        guard req.method == "POST" else {
            var head = "HTTP/1.1 405 Method Not Allowed\r\nAllow: POST\r\n"
            head += "Content-Length: 0\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in c.cancel() })
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return send("400 Bad Request", rpcError(nil, -32700, "invalid JSON"))
        }
        let id = obj["id"]
        guard let method = obj["method"] as? String else {
            return send("400 Bad Request", rpcError(id, -32600, "missing method"))
        }

        // Version is checked per request — there is no handshake to have agreed at.
        if let v = mcpRequestVersion(obj), !MCP_SUPPORTED_VERSIONS.contains(v) {
            return send("200 OK", rpcError(id, -32022, "unsupported protocol version \(v)",
                                           ["supported": MCP_SUPPORTED_VERSIONS]))
        }

        let db = mcpDBPath ?? ""
        let root = mcpRoot ?? defaultRoot
        var result: [String: Any]

        switch method {
        case "initialize":
            // The HTTP binding must be dual-era for the same reason stdio is: Claude Code
            // opens with `initialize` on both transports, and a modern-only endpoint answers
            // it -32601 and never connects.
            let ps = obj["params"] as? [String: Any] ?? [:]
            let asked = ps["protocolVersion"] as? String
            let agreed = (asked.flatMap { MCP_SUPPORTED_VERSIONS.contains($0) ? $0 : nil })
                ?? MCP_HANDSHAKE_VERSIONS[0]
            result = [
                "protocolVersion": agreed,
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "session-viewer", "version": "1.0.0"],
            ]
        case "notifications/initialized", "initialized":
            // Notification: no id, no response body. Answer 202 with an empty payload.
            return send("202 Accepted", Data())
        case "server/discover":
            result = [
                // MODERN versions only. `server/discover` is itself a modern-era method, so
                // listing handshake-era versions here would tell a modern client we speak
                // 2024-11-05 statelessly, which we do not — those are reachable only through
                // `initialize`.
                "protocolVersions": MCP_MODERN_VERSIONS,
                "serverInfo": ["name": "session-viewer", "title": "Claude Code session index",
                               "version": "1.0.0"],
                // Must match what `initialize` says on this same transport — the two
                // disagreed (true here, false there), which is worse than either answer:
                // a client learns one thing at handshake and the opposite at discovery.
                "capabilities": ["tools": ["listChanged": true]],
                "instructions": "Searches every Claude Code session on this machine, across all three file tiers.",
            ]
        case "tools/list":
            // ALL THREE SOURCES, matching the stdio transport (MCP.swift). This listed
            // only `mcpTools()` while sharing `mcpCall` with stdio — and `mcpCall`
            // dispatches promoted `dig_*` topics and wrapped upstream tools perfectly
            // well. So the HTTP transport advertised FEWER tools than it would answer:
            // a client connected over HTTP could not see a promoted topic, and promoting
            // one — the entire point of `promote_topic` — did nothing it could observe.
            // Two transports disagreeing about the same server's tool set is the exact
            // drift this project keeps finding in other people's tooling.
            result = ["tools": fullMCPToolList(dbPath: db)
                .map { t -> [String: Any] in
                    ["name": t.name, "title": t.title, "description": t.description,
                     "inputSchema": t.schema]
                }]
        case "tools/call":
            let params = obj["params"] as? [String: Any] ?? [:]
            result = mcpCall(name: params["name"] as? String ?? "",
                             args: params["arguments"] as? [String: Any] ?? [:],
                             dbPath: db, root: root)
        case "ping":
            result = [:]
        default:
            return send("200 OK", rpcError(id, -32601, "unknown method \(method)"))
        }

        // Same `resultType` the stdio path adds — the two transports must not disagree
        // about the shape of a result.
        if result["resultType"] == nil { result["resultType"] = "complete" }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
        send("200 OK", data)
    }
}
