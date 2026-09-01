import Foundation

// MCP.swift — session-viewer as an MCP server, protocol 2026-07-28 ("modern" era).
//
// WHY 2026-07-28 AND WHY STDIO — both answered from this fleet's own session history
// (vpskeeper-oracle, 2026-08-23), retrieved with this app's own search rather than guessed:
//
//   * `2026-07-28` is a STRUCTURAL BREAK, not a point release. The spec splits
//     implementations into LEGACY (`2025-11-25` and earlier — establish a session via an
//     `initialize` handshake) and MODERN (`2026-07-28`+ — stateless, no handshake). Every
//     request carries its own protocol version and the server accepts or rejects it
//     independently. Released versions: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25,
//     2026-07-28. Python `mcp` 2.0.0 shipped the same day as the revision.
//
//   * STDIO, not Streamable HTTP. Streamable HTTP means a new listening socket, `Origin`
//     validation (a spec MUST, against DNS rebinding), and auth you have to build. The
//     fleet's own recorded verdict was that "one more port" is the decision to avoid on a
//     host with no packet filtering. stdio has no port, no origin, and no auth surface —
//     and this binary is already a CLI, so a subcommand is the whole transport.
//
// The modern era removed the standalone GET SSE stream, protocol-level sessions
// (`Mcp-Session-Id`) and `Last-Event-ID` resumability. None of that applies to stdio, which
// is a second reason it is the cheaper binding here.
//
// ⚠️ UNVERIFIED, and deliberately permissive because of it: the exact `_meta` key names for
// protocol version and client identity are recorded in our notes only as the namespace
// `_meta.io.modelcontextprotocol/*`. This reader therefore ACCEPTS several plausible
// spellings and treats an absent version as "modern", rather than rejecting traffic on a
// guess. What it EMITS is pinned. Re-check against schema/2026-07-28/schema.ts before
// trusting the strict path.

public let MCP_PROTOCOL_VERSION = "2026-07-28"

/// Every version this server will answer for — BOTH ERAS.
///
/// A modern-only server is unusable by most clients today. Claude Code itself opens with
/// `initialize`, and a server that knows only `server/discover` answers it with -32601, which
/// the client surfaces as `Failed to reconnect to session-viewer: -32601` and nothing else.
/// That is the same dual-era trap that made wrapping arra-oracle fail, inverted: there we
/// spoke modern AT a legacy server, here we spoke modern AT a legacy client.
///
/// Python `mcp` 2.0.0 handles this by carrying two sets — MODERN_PROTOCOL_VERSIONS and
/// HANDSHAKE_PROTOCOL_VERSIONS — and so does this.
public let MCP_MODERN_VERSIONS = ["2026-07-28"]
public let MCP_HANDSHAKE_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
public let MCP_SUPPORTED_VERSIONS = MCP_MODERN_VERSIONS + MCP_HANDSHAKE_VERSIONS

/// JSON-RPC error codes. `-32022` is MCP's own `UnsupportedProtocolVersionError`, and it
/// must list what IS supported — a bare rejection leaves the client no way forward.
enum MCPError: Int {
    case parse = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case unsupportedProtocolVersion = -32022
}

/// One tool this server exposes.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    let schema: [String: Any]
}

/// THE tool surface — every transport and every introspection path derives from this one
/// call. Three sites used to concatenate the three sources by hand, and one of them
/// (Serve's tools/list) forgot two of the three for weeks: HTTP clients could not see
/// promoted topics while `mcpCall` happily dispatched them. A list that exists once cannot
/// be three different lists.
func fullMCPToolList(dbPath: String) -> [MCPTool] {
    mcpTools() + registryTools() + topicTools(dbPath: dbPath) + upstreamTools(dbPath: dbPath)
}

/// The tools, and the reasoning for the set: expose what this app KNOWS that a plain `rg`
/// over the corpus does not. Keyword search is deliberately included even though `rg` could
/// do it, because the trigram index is the only thing here that finds Thai inside words —
/// measured 100% recall against unicode61's 0-40%.
func mcpTools() -> [MCPTool] {
    [
        MCPTool(
            name: "search_sessions",
            title: "Search session transcripts",
            description: """
                Full-text search over every indexed Claude Code session on this machine, \
                ranked by bm25. Queries of 3+ characters use a trigram index that matches \
                INSIDE words — the only way to find Thai terms, which whitespace tokenizing \
                misses entirely. Shorter queries fall back to prefix matching.
                """,
            schema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to search for. English or Thai."],
                    "project": ["type": "string", "description": "Narrow to one project — substring of its path, e.g. 'digger-oracle'."],
                    "tier": ["type": "string", "description": "session | subagent | workflow_agent. Workflow-agent transcripts are 73% of this corpus."],
                    "since": ["type": "string", "description": "ISO date/time lower bound, e.g. 2026-08-20."],
                    "until": ["type": "string", "description": "ISO date/time upper bound."],
                    "limit": ["type": "integer", "description": "Max results (default 20).", "default": 20],
                ],
                "required": ["query"],
            ]),
        MCPTool(
            name: "read_session",
            title: "Read a session transcript",
            description: """
                Read a session's actual messages, in order. This is what turns a search hit                 into an answer — a snippet tells you a session mentioned something, and only                 reading around it tells you what was decided. Accepts a uuid PREFIX (the 8                 characters search prints).
                """,
            schema: [
                "type": "object",
                "properties": [
                    "session": ["type": "string", "description": "Session uuid or an 8-char prefix of one."],
                    "from": ["type": "integer", "description": "First line number to read (default 0).", "default": 0],
                    "limit": ["type": "integer", "description": "How many messages (default 30).", "default": 30],
                ],
                "required": ["session"],
            ]),
        MCPTool(
            name: "read_context",
            title: "Read around a search hit",
            description: """
                The messages either side of one line in a session. Use this directly after                 search_sessions: every hit carries its session and line number, and this                 turns that into the surrounding exchange.
                """,
            schema: [
                "type": "object",
                "properties": [
                    "session": ["type": "string", "description": "Session uuid or 8-char prefix."],
                    "seq": ["type": "integer", "description": "Line number, as reported by search_sessions."],
                    "before": ["type": "integer", "description": "Messages before (default 4).", "default": 4],
                    "after": ["type": "integer", "description": "Messages after (default 6).", "default": 6],
                ],
                "required": ["session", "seq"],
            ]),
        MCPTool(
            name: "semantic_search",
            title: "Semantic search over session transcripts",
            description: """
                Vector search over embedded session text. Use this for PARAPHRASE queries \
                whose literal words do not appear in the text — measured 19% recall@50 \
                (apple-nlce, labeled set) against keyword search's 4% on such queries. \
                For queries whose words DO appear, prefer search_sessions: it scores 100% \
                where this scores 60%. Only covers events that have been embedded.
                """,
            schema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "A description or paraphrase of what you are looking for."],
                    "limit": ["type": "integer", "description": "Max results (default 20).", "default": 20],
                ],
                "required": ["query"],
            ]),
        // list_sessions is REGISTRY-OWNED now (CommandRegistry.swift) — declared once,
        // serving both `session-viewer list` and this tool, with the time-window `since`
        // param and a real JSON-Schema enum for sorts. Its literal was deleted from here;
        // a second copy is how drift starts.
        MCPTool(
            name: "index_status",
            title: "Index status",
            description: """
                What the index holds and what it is missing: file counts by tier, event and \
                line totals, which embedding models are present, and how many files on disk \
                are new or changed since the last import.
                """,
            // `additionalProperties: false` is the spec's RECOMMENDED shape for a no-arg
            // tool — it accepts only an empty object. A bare `{"type":"object"}` accepts
            // any object, so a model passing stray arguments would be silently tolerated.
            schema: ["type": "object", "properties": [:], "additionalProperties": false]),
        MCPTool(
            name: "trace_topic",
            title: "Start or refresh a traced topic",
            description: """
                Remember an investigation under a name. The query is run and its results are                 memoized, and from then on this server ADVERTISES a new tool `dig_<name>`                 that replays and refreshes it. Use this when you expect to return to the                 same question — the saved topic accumulates what it finds across runs, which                 a one-shot search cannot do.
                """,
            schema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Short topic name. Reduced to [a-z0-9_]; the tool becomes dig_<name>."],
                    "query": ["type": "string", "description": "The search this topic stands for."],
                    "engine": ["type": "string", "description": "keyword (default) or semantic.", "default": "keyword"],
                    "description": ["type": "string", "description": "Optional: what this topic is for. Shown to models choosing between tools."],
                    "sources": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "COMPOSE across sources. Omit for local search only. Forms: 'local:keyword', 'local:semantic', 'upstream:<server>/<tool>' (e.g. 'upstream:oracle/oracle_search'). A source that fails is skipped and reported, never fatal — an upstream being down must not cost you the local answer.",
                    ],
                ],
                "required": ["name", "query"],
            ]),
        MCPTool(
            name: "dig_topic",
            title: "Run a traced topic",
            description: """
                Replay any saved topic by name — fresh results plus everything it has                 captured across previous runs. This ONE tool reaches every topic, promoted                 or not, so a topic is usable the moment it is traced without waiting for                 the client to re-read the tool list. Use list_topics to see what exists.
                """,
            schema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Topic name, as shown by list_topics."],
                    "refresh": ["type": "boolean", "description": "Re-run the query first (default true).", "default": true],
                    "limit": ["type": "integer", "default": 20],
                ],
                "required": ["name"],
            ]),
        MCPTool(
            name: "promote_topic",
            title: "Give a topic its own tool",
            description: """
                Add a dedicated `dig_<name>` tool for this topic. A specifically-named tool                 helps a model choose correctly, but every tool is charged against a budget                 shared with every other connected server — so promote the few topics you                 reach for often, not all of them. Unpromoted topics remain fully usable via                 dig_topic.
                """,
            schema: [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ]),
        MCPTool(
            name: "demote_topic",
            title: "Take back a topic's tool",
            description: "Remove the dedicated dig_<name> tool. The topic itself and everything it captured are kept, and stay reachable through dig_topic.",
            schema: [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ]),
        MCPTool(
            name: "describe_tool",
            title: "Show what a tool actually is",
            description: """
                The full definition of any tool this server exposes — its schema, and for a                 generated `dig_<topic>` tool the saved query, engine, run history and the                 code path that runs it. Use it when a tool's one-line description is not                 enough to know what calling it will do.
                """,
            schema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Tool name, e.g. dig_esp32 or search_sessions."],
                ],
                "required": ["name"],
            ]),
        MCPTool(
            name: "list_topics",
            title: "List traced topics",
            description: "Every saved topic, its query, how often it has run and what it last found. A topic that once found things and now finds none means the corpus moved or the query rotted.",
            // `additionalProperties: false` is the spec's RECOMMENDED shape for a no-arg
            // tool — it accepts only an empty object. A bare `{"type":"object"}` accepts
            // any object, so a model passing stray arguments would be silently tolerated.
            schema: ["type": "object", "properties": [:], "additionalProperties": false]),
        MCPTool(
            name: "forget_topic",
            title: "Forget a traced topic",
            description: "Remove a saved topic and its captured hits. Its dig_<name> tool disappears from tools/list.",
            schema: [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ]),
        MCPTool(
            name: "session_graph",
            title: "Knowledge graph for one session",
            description: """
                Beats (human turns), the tools each used, and the files/URLs they touched, \
                for one session file. Reports which targets more than one beat came back to \
                — the cross-links a linear read of the transcript cannot show.
                """,
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to a session .jsonl file."],
                ],
                "required": ["path"],
            ]),
    ]
}

// MARK: - JSON helpers

private func jsonData(_ o: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
}

private func writeLine(_ o: Any) {
    var d = jsonData(o)
    d.append(0x0A)
    FileHandle.standardOutput.write(d)
}

private func errorResponse(id: Any?, code: MCPError, message: String, data: Any? = nil) -> [String: Any] {
    var err: [String: Any] = ["code": code.rawValue, "message": message]
    if let data { err["data"] = data }
    var r: [String: Any] = ["jsonrpc": "2.0", "error": err]
    r["id"] = id ?? NSNull()
    return r
}

private func result(id: Any?, _ value: [String: Any]) -> [String: Any] {
    var payload = value
    // `resultType` is on EVERY result in the 2026-07-28 schema — `"complete"` for a
    // finished call, `"input_required"` for the multi-round-trip path we do not implement.
    // We were omitting it entirely. Clients that switch on it would see a result with no
    // type rather than a completed one; adding it costs nothing and is what the wire
    // examples show.
    if payload["resultType"] == nil { payload["resultType"] = "complete" }
    var r: [String: Any] = ["jsonrpc": "2.0", "result": payload]
    r["id"] = id ?? NSNull()
    return r
}

/// Announce that `tools/list` has changed.
///
/// `listChanged: true` is a PROMISE to send this, and we were declaring it without ever
/// sending one — clients only saw a new `dig_*` tool if they happened to re-list. A
/// capability you advertise and do not honour is worse than not advertising it, because the
/// client stops polling on your word.
///
/// stdio only. Notifying over Streamable HTTP needs a server-initiated stream, and the
/// modern era removed the standalone GET SSE channel — a notification would have to ride an
/// open request-scoped stream, which a one-shot POST does not have. So the HTTP transport
/// still requires the client to re-list, and that is a real limitation rather than an
/// oversight.
private func notifyToolsChanged() {
    writeLine(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"] as [String: Any])
}

/// Tool results are content blocks. Text-only here: every answer this server gives is text,
/// and returning a richer type nothing consumes would be decoration.
private func textContent(_ s: String) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": false]
}

private func errorContent(_ s: String) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": true]
}

/// Pull the protocol version out of `_meta`, accepting the spellings we cannot confirm
/// between. Absent means modern — rejecting unlabelled traffic on an unverified key name
/// would break clients over our own uncertainty.
func mcpRequestVersion(_ req: [String: Any]) -> String? {
    guard let meta = (req["_meta"] as? [String: Any])
            ?? ((req["params"] as? [String: Any])?["_meta"] as? [String: Any]) else { return nil }
    for key in ["io.modelcontextprotocol/protocol-version",
                "io.modelcontextprotocol/protocolVersion",
                "protocolVersion", "protocol-version"] {
        if let v = meta[key] as? String { return v }
    }
    return nil
}

// MARK: - the server

/// `session-viewer mcp` — newline-delimited JSON-RPC on stdin/stdout.
///
/// No dependency: stdio framing for MCP is one JSON object per line, which Foundation
/// already does. This is the same reason `Serve.swift` could stand up a WebSocket with
/// nothing but Network.framework.
public func runMCPServer(dbPath: String, root: String) {
    // stdout is the PROTOCOL CHANNEL. Anything printed to it that is not a JSON-RPC message
    // corrupts the stream, so every diagnostic in this path must go to stderr. This is the
    // classic way a stdio MCP server fails, and it fails as "client sees garbage", not as
    // an error here.
    func log(_ s: String) {
        FileHandle.standardError.write("[mcp] \(s)\n".data(using: .utf8)!)
    }
    log("session-viewer MCP server · protocol \(MCP_PROTOCOL_VERSION) · stdio · db=\(dbPath)")

    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        guard let d = trimmed.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            writeLine(errorResponse(id: nil, code: .parse, message: "invalid JSON"))
            continue
        }

        let id = req["id"]
        guard let method = req["method"] as? String else {
            writeLine(errorResponse(id: id, code: .invalidRequest, message: "missing method"))
            continue
        }

        // Version is checked PER REQUEST, which is the whole point of the modern era: there
        // is no handshake to have agreed at, so every message stands or falls alone.
        // Only MODERN requests carry a per-request version; a legacy client never does, and
        // its version was agreed at `initialize` instead.
        if let v = mcpRequestVersion(req), !MCP_SUPPORTED_VERSIONS.contains(v) {
            writeLine(errorResponse(id: id, code: .unsupportedProtocolVersion,
                                    message: "unsupported protocol version \(v)",
                                    data: ["supported": MCP_SUPPORTED_VERSIONS]))
            continue
        }

        // A notification has no id and MUST NOT be answered.
        let isNotification = (id == nil)

        switch method {
        case "initialize":
            // LEGACY ERA. The client establishes a session, so we echo back a version it
            // asked for when we support it, and otherwise offer our newest handshake-era
            // one — never our modern version, which a handshake client cannot speak.
            let params = req["params"] as? [String: Any] ?? [:]
            let asked = params["protocolVersion"] as? String
            let agreed: String
            if let asked, MCP_SUPPORTED_VERSIONS.contains(asked) { agreed = asked }
            else { agreed = MCP_HANDSHAKE_VERSIONS[0] }
            writeLine(result(id: id, [
                "protocolVersion": agreed,
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "session-viewer", "version": "1.0.0"],
                "instructions": """
                    Searches every Claude Code session on this machine, across all three file \
                    tiers including workflow-agent transcripts that a plain glob misses. Use \
                    search_sessions for words that appear in the text (the only index that \
                    finds Thai inside words), then read_context to see the exchange around a \
                    hit — a snippet alone rarely answers anything.
                    """,
            ]))

        case "notifications/initialized", "initialized":
            // A notification completing the legacy handshake. It carries no id and MUST NOT
            // be answered — replying to a notification is itself a protocol violation.
            continue

        case "server/discover":
            // MUST be implemented in the modern era. It replaces `initialize` — the client
            // asks what this server is instead of negotiating a session with it.
            writeLine(result(id: id, [
                // MODERN versions only. `server/discover` is itself a modern-era method, so
                // listing handshake-era versions here would tell a modern client we speak
                // 2024-11-05 statelessly, which we do not — those are reachable only through
                // `initialize`.
                "protocolVersions": MCP_MODERN_VERSIONS,
                "serverInfo": [
                    "name": "session-viewer",
                    "title": "Claude Code session index",
                    "version": "1.0.0",
                ],
                // listChanged is TRUE because saved topics generate tools at runtime.
                // Declaring false while doing that would be a lie to any client that
                // caches the first tools/list — which is most of them.
                "capabilities": ["tools": ["listChanged": true]],
                "instructions": """
                    Searches every Claude Code session on this machine, across all three file \
                    tiers including workflow-agent transcripts that a plain glob misses. \
                    Use search_sessions for words that appear in the text (it is the only \
                    index that finds Thai inside words); use semantic_search for paraphrases \
                    whose literal words do not appear.
                    """,
            ]))

        case "tools/list":
            // Built-ins PLUS one generated tool per saved topic. This is the reason
            // `listChanged` is true in server/discover: the set genuinely changes at
            // runtime, and a client that cached the first answer would be wrong.
            let tools = fullMCPToolList(dbPath: dbPath).map { t -> [String: Any] in
                ["name": t.name, "title": t.title, "description": t.description, "inputSchema": t.schema]
            }
            writeLine(result(id: id, ["tools": tools]))

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let callResult = mcpCall(name: name, args: args, dbPath: dbPath, root: root)
            writeLine(result(id: id, callResult))
            // Announce AFTER the response, so the client has the result in hand before it
            // is told to re-list.
            if toolSetChanged { toolSetChanged = false; notifyToolsChanged() }

        case "ping":
            writeLine(result(id: id, [:]))

        default:
            if isNotification { continue }   // unknown notifications are ignored, not errors
            writeLine(errorResponse(id: id, code: .methodNotFound, message: "unknown method \(method)"))
        }
    }
    log("stdin closed — exiting")
}

/// Dispatch one tool call. Every branch returns content rather than throwing, because a
/// tool failure is a RESULT the model should see and reason about, not a transport error.
/// Set by any tool that changes the TOOL SET. Drained by the stdio loop, which is the only
/// transport that can push a notification. Kept as a flag rather than having `mcpCall` write
/// to stdout directly, so the dispatcher stays transport-agnostic — it is shared with HTTP.
nonisolated(unsafe) var toolSetChanged = false

func mcpCall(name: String, args: [String: Any], dbPath: String, root: String) -> [String: Any] {
    // Generated topic tools are checked FIRST, but they can only match `dig_*`, and
    // `traceTopic` refuses to create a topic whose tool name collides with a built-in — so
    // the ordering here cannot shadow anything.
    if let r = callTopicTool(name: name, args: args, dbPath: dbPath, root: root) { return r }
    // Upstream tools are `<upstream>__<tool>`; ours never contain a double underscore.
    if let r = callUpstreamTool(name: name, args: args, dbPath: dbPath) { return r }
    // Registry-owned commands (one declaration serving CLI verb + MCP tool). Checked
    // before the built-in switch for the same reason topic tools are: the name space is
    // guarded at declaration, so ordering cannot shadow anything.
    if let out = callRegistryTool(name: name, args: args, dbPath: dbPath, root: root) {
        var content: [String: Any] = ["content": [["type": "text", "text": out.text]]]
        if let st = out.structured { content["structuredContent"] = st }
        // Without this, a validation refusal was indistinguishable from a successful
        // result — the model read "error: …" as data and kept going.
        if out.isError { content["isError"] = true }
        return content
    }

    switch name {
    case "search_sessions":
        guard let q = args["query"] as? String, !q.isEmpty else {
            return errorContent("search_sessions needs a non-empty `query`")
        }
        let limit = (args["limit"] as? Int) ?? 20
        let db = DB(path: dbPath)
        let t0 = Date()
        let hits = searchEventsFiltered(db: db, query: q,
                                        project: args["project"] as? String,
                                        tier: args["tier"] as? String,
                                        since: args["since"] as? String,
                                        until: args["until"] as? String,
                                        limit: limit)
        // ONE search history, not two. The CLI (CLI.swift) and the Search tab
        // (SearchView.swift) both write here; MCP did not, so every search a MODEL ran was
        // invisible to `session-viewer searches` and to the Search tab's history — which is
        // backwards, since agent traffic is the majority of queries against this index and
        // the log exists precisely to show which queries stopped finding things.
        logSearch(dbPath: dbPath, query: q,
                  engine: usesTrigram(q) ? "trigram" : "unicode61",
                  model: nil, hits: hits, ms: Date().timeIntervalSince(t0) * 1000)
        guard !hits.isEmpty else {
            return textContent("No matches for \(q.debugDescription)\(args["project"] != nil || args["tier"] != nil || args["since"] != nil ? " with those filters" : "").")
        }
        let engine = usesTrigram(q) ? "trigram" : "unicode61"
        var out = "\(hits.count) match(es) for \(q.debugDescription) · \(engine) index\n"
        out += "Each line ends with the session and seq to pass to read_context.\n\n"
        for h in hits {
            let ts = h.ts.map { String($0.prefix(19)) } ?? "—"
            out += "[\(String(format: "%.2f", h.score))] \(h.role) \(ts)\n  \(h.snippet)\n"
            out += "  → read_context{session:\"\(h.uuid.prefix(8))\", seq:\(h.seq)}\n"
        }
        return textContent(out)

    case "read_session":
        guard let sref = args["session"] as? String, !sref.isEmpty else {
            return errorContent("read_session needs `session` (a uuid or 8-char prefix)")
        }
        let matches = resolveDistinctSessions(dbPath: dbPath, uuidPrefix: sref)
        guard let s0 = matches.first else { return errorContent("no session matching \(sref.debugDescription)") }
        if matches.count > 1 {
            return errorContent("prefix \(sref.debugDescription) matches \(matches.count) distinct sessions: "
                                + matches.map { String($0.uuid.prefix(12)) }.joined(separator: ", "))
        }
        let from = (args["from"] as? Int) ?? 0
        let limit = (args["limit"] as? Int) ?? 30
        let evs = readSessionEvents(dbPath: dbPath, sessionId: s0.id, from: from, limit: limit)
        guard !evs.isEmpty else { return textContent("No messages at or after line \(from) in \(s0.uuid.prefix(8)).") }
        var out = "session  \(s0.uuid)\ntier     \(s0.tier)\nproject  \(s0.project)\n"
        out += "events   \(s0.events) total, showing \(evs.count) from line \(evs.first?.seq ?? from)\n\n"
        out += renderEvents(evs)
        if let last = evs.last, last.seq < s0.events {
            out += "→ more: read_session{session:\"\(s0.uuid.prefix(8))\", from:\(last.seq + 1)}\n"
        }
        return textContent(out)

    case "read_context":
        guard let sref = args["session"] as? String, let seq = args["seq"] as? Int else {
            return errorContent("read_context needs `session` and `seq`")
        }
        guard let s0 = resolveDistinctSessions(dbPath: dbPath, uuidPrefix: sref).first else {
            return errorContent("no session matching \(sref.debugDescription)")
        }
        let evs = readEventContext(dbPath: dbPath, sessionId: s0.id, seq: seq,
                                   before: (args["before"] as? Int) ?? 4,
                                   after: (args["after"] as? Int) ?? 6)
        guard !evs.isEmpty else { return textContent("No messages around line \(seq).") }
        return textContent("session \(s0.uuid.prefix(8)) · \(s0.project)\n\n" + renderEvents(evs))

    case "semantic_search":
        guard let q = args["query"] as? String, !q.isEmpty else {
            return errorContent("semantic_search needs a non-empty `query`")
        }
        let limit = (args["limit"] as? Int) ?? 20
        let t0 = Date()
        let hits = semanticSearch(dbPath: dbPath, query: q, limit: limit)
        // Same one-search-history rule as search_sessions above: without this line every
        // vector query an agent ran was invisible to `searches` — the GPU-embedding spend
        // had zero usage data behind it (measured 2026-08-26: 95 keyword rows, 0 vector).
        logSearch(dbPath: dbPath, query: q, engine: "vector", model: nil,
                  hits: hits, ms: Date().timeIntervalSince(t0) * 1000)
        guard !hits.isEmpty else {
            let cov = readEmbedCoverage(dbPath: dbPath)
            return textContent("""
                No semantic matches for \(q.debugDescription).
                Index coverage: \(cov.embeddedEvents)/\(cov.totalEvents) events embedded. \
                If that is low, the answer may simply not be indexed yet rather than absent.
                """)
        }
        var out = "\(hits.count) semantic match(es) for \(q.debugDescription)\n\n"
        for h in hits {
            out += "session \(h.uuid.prefix(8))  \(h.snippet)\n"
        }
        return textContent(out)


    case "index_status":
        let s = readDBStatus(dbPath: dbPath, root: root)
        let cov = readEmbedCoverage(dbPath: dbPath)
        // Freshness, answered directly: the last import run IS "how current is this
        // index". Without it a reader must infer staleness from pending counts alone,
        // and a count of 0 pending is ambiguous between "fresh" and "roots not walked".
        let lastRun = lastImportRunLine(dbPath: dbPath)
        var out = """
            database   \(s.dbPath)
            on disk    \(s.onDisk) files · indexed \(s.imported) · projects \(s.projects) · failed \(s.failed)
            content    \(s.events) events · \(s.lines) lines · \(humanBytes(s.sourceBytes)) source
            last import \(lastRun)
            pending    \(s.pendingNew) new · \(s.pendingChanged) changed
            semantic   \(cov.embeddedEvents)/\(cov.totalEvents) events · \(cov.vectors) vectors

            """
        for t in s.tiers { out += "  \(t.tier)  \(t.files) files  \(humanBytes(t.bytes))\n" }
        if !cov.remoteProviders.isEmpty {
            out += "\n⚠️ remote providers in this index: \(cov.remoteProviders.joined(separator: ", "))\n"
        }
        return textContent(out)

    case "trace_topic":
        guard let n = args["name"] as? String, let q = args["query"] as? String,
              !n.isEmpty, !q.isEmpty else {
            return errorContent("trace_topic needs `name` and `query`")
        }
        do {
            let (t, hits) = try traceTopic(dbPath: dbPath, root: root, name: n, query: q,
                                           engine: (args["engine"] as? String) ?? "keyword",
                                           description: args["description"] as? String,
                                           sources: (args["sources"] as? [String]) ?? [])
            // No tool appears, so no notification. Creating a topic is deliberately
            // separate from spending a tool slot on it.
            return textContent("""
                Traced \(t.name.debugDescription) — \(hits) hit(s) captured.
                Run it with dig_topic{name:"\(t.name)"}. If you will reach for it often,
                promote_topic{name:"\(t.name)"} gives it its own `\(t.toolName)` tool.
                """)
        } catch {
            return errorContent("\(error)")
        }

    case "dig_topic":
        guard let n = args["name"] as? String, !n.isEmpty else {
            return errorContent("dig_topic needs `name` — see list_topics")
        }
        let key = sanitizeTopicName(n) ?? n
        guard let r = callTopicTool(name: "dig_\(key)", args: args, dbPath: dbPath, root: root) else {
            let known = loadTopics(dbPath: dbPath).map(\.name)
            return errorContent("no topic named \(n.debugDescription)"
                + (known.isEmpty ? ". Use trace_topic to create one."
                                 : ". Known: \(known.joined(separator: ", "))"))
        }
        return r

    case "promote_topic", "demote_topic":
        guard let n = args["name"] as? String, !n.isEmpty else {
            return errorContent("\(name) needs `name`")
        }
        let key = sanitizeTopicName(n) ?? n
        let want = (name == "promote_topic")
        guard let ok = setTopicPromoted(dbPath: dbPath, name: key, promoted: want), ok else {
            return errorContent("no topic named \(n.debugDescription)")
        }
        toolSetChanged = true
        return textContent(want
            ? "Promoted \(key.debugDescription) — it now has its own `dig_\(key)` tool."
            : "Demoted \(key.debugDescription) — its dedicated tool is gone; still reachable via dig_topic.")

    case "describe_tool":
        guard let n = args["name"] as? String, !n.isEmpty else {
            return errorContent("describe_tool needs `name`")
        }
        // ONE introspection tool rather than a `<tool>_description` per tool. A per-tool
        // variant would double the tool count for every topic — 10 topics becoming 20
        // tools — which is the budget problem promotion exists to avoid.
        let all = fullMCPToolList(dbPath: dbPath)
        guard let t = all.first(where: { $0.name == n }) else {
            return errorContent("no tool named \(n.debugDescription). Known: "
                + all.map(\.name).joined(separator: ", "))
        }

        var out = "name         \(t.name)\ntitle        \(t.title)\n\n"
        out += "description\n  \(t.description)\n\n"
        if let d = try? JSONSerialization.data(withJSONObject: t.schema,
                                               options: [.prettyPrinted, .sortedKeys]),
           let js = String(data: d, encoding: .utf8) {
            out += "inputSchema\n" + js.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n\n"
        }

        // For a generated tool, the definition alone is not the answer — what it DOES is
        // the saved query plus the memoized history, and both are data.
        if n.hasPrefix("dig_"), let topic = loadTopics(dbPath: dbPath)
                .first(where: { $0.name == String(n.dropFirst(4)) }) {
            out += """
                topic (this tool is generated from a row, not hand-written)
                  name        \(topic.name)
                  query       \(topic.query.debugDescription)
                  engine      \(topic.engine)
                  promoted    \(topic.promoted)   (false = reachable only via dig_topic)
                  runs        \(topic.runs)
                  last found  \(topic.lastHits < 0 ? "never run" : String(topic.lastHits))
                  created     \(topic.createdAt)
                  last run    \(topic.lastRunAt.isEmpty ? "—" : topic.lastRunAt)

                what a call does
                  1. traceTopic(query: \(topic.query.debugDescription), engine: \(topic.engine))
                     → \(topic.engine == "semantic" ? "semanticSearch()" : "searchEvents()")   [Topics.swift]
                  2. captures new hits into topic_hits (memoized, never replaced)
                  3. returns fresh hits + everything captured across all \(topic.runs) run(s)
                  refresh:false skips step 1 and answers from the capture alone.

                """
            let captured = loadTopicHits(dbPath: dbPath, topic: topic.name, limit: 3)
            if !captured.isEmpty {
                out += "sample of what it has captured\n"
                for h in captured { out += "  [\(String(format: "%.2f", h.score))] \(String(h.snippet.prefix(88)))\n" }
            }
        } else if n.contains("__") {
            out += "origin\n  proxied from upstream \(String(n.split(separator: "_").first ?? "?")) — the schema above is the upstream's own.\n"
        } else {
            out += "origin\n  built-in, implemented in mcpCall() [MCP.swift]\n"
        }
        return textContent(out)

    case "list_topics":
        let ts = loadTopics(dbPath: dbPath)
        guard !ts.isEmpty else {
            return textContent("No topics traced yet. Use trace_topic to create one.")
        }
        let promoted = ts.filter(\.promoted).count
        var out = "\(ts.count) topic(s) · \(promoted) promoted to their own tool\n"
        out += "Every topic is runnable via dig_topic{name}; promoted ones also have dig_<name>.\n\n"
        for t in ts {
            out += "\(t.promoted ? "★" : "·") \(t.name)\(t.promoted ? "  → \(t.toolName)" : "")\n"
            out += "  query \(t.query.debugDescription) · \(t.engine)\n"
            out += "  runs \(t.runs)\(t.lastHits >= 0 ? ", last found \(t.lastHits)" : ", never run")"
            out += t.lastRunAt.isEmpty ? "\n" : " at \(t.lastRunAt)\n"
        }
        return textContent(out)

    case "forget_topic":
        guard let n = args["name"] as? String, !n.isEmpty else {
            return errorContent("forget_topic needs `name`")
        }
        let gone = forgetTopic(dbPath: dbPath, name: sanitizeTopicName(n) ?? n)
        if gone { toolSetChanged = true }
        return textContent(gone ? "Forgot topic \(n.debugDescription); its dig_ tool is gone."
                                : "No topic named \(n.debugDescription).")

    case "session_graph":
        guard let path = args["path"] as? String, !path.isEmpty else {
            return errorContent("session_graph needs a `path` to a .jsonl file")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return errorContent("no such file: \(path)")
        }
        let g = buildSessionGraph(path: path)
        var out = """
            \(g.nodes.count) nodes — \(g.beats) beats · \(g.tools) tools · \(g.targets) targets
            \(g.edges.count) edges · \(g.recurring) targets revisited by more than one beat
            \(g.truncated ? "(tail only — file exceeded the graph read cap)\n" : "")

            """
        for n in g.nodes where n.kind == .beat {
            out += "beat @\(n.byteOffset)  \(n.label)\n"
        }
        for n in g.nodes.filter({ $0.kind == .tool }).sorted(by: { $0.weight > $1.weight }) {
            out += "tool ×\(n.weight)  \(n.label)\n"
        }
        return textContent(out)

    default:
        return errorContent("unknown tool \(name.debugDescription)")
    }
}
