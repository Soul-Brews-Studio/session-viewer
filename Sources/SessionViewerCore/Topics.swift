import Foundation
import SQLite3

// Topics.swift — remembered investigations that become MCP tools.
//
// The idea is higher-order: `tools/list` is not a fixed set. You start a trace on a topic,
// the server memoizes what it found, and from then on it ADVERTISES `dig_<topic>` next to
// the built-in tools. A model can then call the investigation by name instead of
// re-deriving the query — and the tool carries its own provenance (the query, the engine
// that answered it, when it last ran, what it last found) rather than being an opaque alias.
//
// Two consequences that are easy to get wrong and are handled explicitly:
//
//   1. `capabilities.tools.listChanged` MUST become true. A server that advertises a fixed
//      tool list and then changes it is lying to clients that cached the first answer, and
//      the spec's whole mechanism for this is the listChanged flag plus a
//      `notifications/tools/list_changed` notification. Declaring `false` while generating
//      tools at runtime is the bug this file exists to avoid.
//
//   2. Tool names are a NAMESPACE, and topics are user input. A topic called
//      `search_sessions` would shadow a built-in and silently change what that name does.
//      Names are therefore sanitized and prefixed (`dig_`), and a topic that still collides
//      after that is rejected at creation rather than at call time.

public struct Topic: Identifiable, Equatable {
    public let name: String
    public let query: String
    public let engine: String        // "keyword" | "semantic"
    public let description: String
    public let createdAt: String
    public let lastRunAt: String
    public let runs: Int
    /// -1 means never run. A topic that once found things and now finds none is the
    /// interesting case — the corpus moved, or the query rotted.
    public let lastHits: Int
    /// True when this topic has its own entry in tools/list.
    public let promoted: Bool
    /// Where this topic looks. Empty = local keyword only (the pre-composition default).
    public let sources: [String]

    /// The sources actually used, with the default made explicit.
    public var effectiveSources: [String] {
        sources.isEmpty ? ["local:\(engine)"] : sources
    }
    public var isComposed: Bool { effectiveSources.count > 1 }
    public var id: String { name }

    public var toolName: String { "dig_\(name)" }
}

public struct TopicHit {
    public let uuid: String
    public let role: String
    public let ts: String
    public let score: Double
    public let snippet: String
    /// Which source produced this hit — the only way to tell whether a composed topic's
    /// upstream is contributing or just adding latency.
    public let source: String
}

/// Tool names must be stable identifiers, so a topic name is reduced to
/// `[a-z0-9_]`. Returns nil when nothing usable survives, rather than inventing a name.
public func sanitizeTopicName(_ raw: String) -> String? {
    let lowered = raw.lowercased()
    var out = ""
    var lastWasSep = false
    for ch in lowered {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            lastWasSep = false
        } else if !lastWasSep && !out.isEmpty {
            out.append("_")
            lastWasSep = true
        }
    }
    while out.hasSuffix("_") { out.removeLast() }
    guard !out.isEmpty, out.count <= 48 else { return nil }
    // A name that starts with a digit is a poor identifier in most clients.
    return out.first!.isNumber ? "t_\(out)" : out
}

/// Names a topic may not take, because `dig_<name>` would otherwise be able to collide with
/// something already meaningful. Checked at CREATION so the failure is where the mistake is.
let RESERVED_TOPIC_NAMES: Set<String> = ["sessions", "topic", "topics", "list", "status"]

public func loadTopics(dbPath: String) -> [Topic] {
    guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
    let db = DB(path: dbPath)
    db.exec(SQL.createTopics)
    db.exec(SQL.createTopicHits)
    // Self-heal a db created before promotion existed. `exec` returns false and logs on
    // "duplicate column name", which is the expected outcome on every run after the first.
    _ = db.exec(SQL.addTopicPromotedColumn)
    _ = db.exec(SQL.addTopicSourcesColumn)
    _ = db.exec(SQL.addTopicHitSourceColumn)
    guard let s = db.prepare(SQL.selectTopics) else { return [] }
    var out: [Topic] = []
    while sqlite3_step(s) == SQLITE_ROW {
        func txt(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        out.append(Topic(name: txt(0), query: txt(1), engine: txt(2), description: txt(3),
                         createdAt: txt(4), lastRunAt: txt(5),
                         runs: Int(sqlite3_column_int64(s, 6)),
                         lastHits: Int(sqlite3_column_int64(s, 7)),
                         promoted: sqlite3_column_int64(s, 8) != 0,
                         sources: txt(9).split(separator: ",").map {
                             $0.trimmingCharacters(in: .whitespaces)
                         }.filter { !$0.isEmpty }))
    }
    sqlite3_finalize(s)
    return out
}

public func loadTopicHits(dbPath: String, topic: String, limit: Int = 40) -> [TopicHit] {
    let db = DB(path: dbPath)
    db.exec(SQL.createTopicHits)
    guard let s = db.prepare(SQL.selectTopicHits) else { return [] }
    db.bindText(s, 1, topic)
    db.bindInt(s, 2, limit)
    var out: [TopicHit] = []
    while sqlite3_step(s) == SQLITE_ROW {
        func txt(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        out.append(TopicHit(uuid: txt(0), role: txt(1), ts: txt(2),
                            score: sqlite3_column_double(s, 3), snippet: txt(4),
                            source: txt(5)))
    }
    sqlite3_finalize(s)
    return out
}

public enum TopicError: Error, CustomStringConvertible {
    case badName(String)
    case reserved(String)
    case collides(String)

    public var description: String {
        switch self {
        case .badName(let n):  return "topic name \(n.debugDescription) reduces to nothing usable"
        case .reserved(let n): return "topic name \(n.debugDescription) is reserved"
        case .collides(let n): return "\(n.debugDescription) is already a built-in tool — pick another topic name"
        }
    }
}

/// Start (or refresh) a trace on a topic: run the query, memoize the hits, and from this
/// point on advertise `dig_<name>` in `tools/list`.
@discardableResult
public func traceTopic(dbPath: String, root: String, name rawName: String, query: String,
                       engine: String = "keyword", description: String? = nil,
                       sources: [String] = [], limit: Int = 40) throws -> (topic: Topic, hits: Int) {
    guard let name = sanitizeTopicName(rawName) else { throw TopicError.badName(rawName) }
    guard !RESERVED_TOPIC_NAMES.contains(name) else { throw TopicError.reserved(name) }
    // Built-in tool names are the other half of the namespace.
    // Name the ACTUAL collision, not the tool we were about to create. The first version
    // reported `dig_search_sessions already exists` when the real problem was that
    // `search_sessions` is a built-in — an error that sends the reader looking for a tool
    // that does not exist.
    let builtIn = Set((mcpTools() + registryTools()).map(\.name))
    if builtIn.contains("dig_\(name)") { throw TopicError.collides("dig_\(name)") }
    if builtIn.contains(name) { throw TopicError.collides(name) }

    let db = DB(path: dbPath)
    db.exec(SQL.createTopics)
    db.exec(SQL.createTopicHits)
    // Run the migrations HERE, not only in loadTopics. Relying on a read path to migrate
    // meant the very first trace on an existing db wrote `sources` to a column that did not
    // exist yet — the UPDATE failed, the topic looked uncomposed, and the next read then
    // added the column so nothing pointed at the cause.
    _ = db.exec(SQL.addTopicPromotedColumn)
    _ = db.exec(SQL.addTopicSourcesColumn)
    _ = db.exec(SQL.addTopicHitSourceColumn)

    if let ins = db.prepare(SQL.upsertTopic) {
        db.bindText(ins, 1, name)
        db.bindText(ins, 2, query)
        db.bindText(ins, 3, engine)
        db.bindText(ins, 4, description)
        sqlite3_step(ins)
        sqlite3_finalize(ins)
    }

    // FAN OUT ACROSS SOURCES — this is the composition.
    //
    // MCP has no composition primitive: no server-to-server RPC, no tool calling another
    // tool. SEP-1610 excludes server-side macro tools; SEP-1686 (Tasks) says it is not
    // composition. The spec leaves three options — do it inside one tool, let the model
    // chain calls, or use code execution. This is the first, made durable: one topic asks
    // several sources the same question and keeps all the answers together over time.
    //
    // PARTIAL RESULTS ARE THE POINT. A source that fails is recorded and skipped, not
    // fatal. An upstream being down must not cost you the local answer — that would make
    // composing strictly worse than not composing, which is how these things get abandoned.
    let wanted = sources.isEmpty ? ["local:\(engine)"] : sources
    var perSource: [(source: String, hits: [SearchHit], error: String?)] = []

    for src in wanted {
        if src.hasPrefix("local:") {
            let mode = String(src.dropFirst("local:".count))
            let hits = mode == "semantic"
                ? semanticSearch(dbPath: dbPath, query: query, limit: limit)
                : searchEvents(db: db, query: query, limit: limit)
            perSource.append((src, hits, nil))

        } else if src.hasPrefix("upstream:") {
            // "upstream:oracle/oracle_search" -> server `oracle`, tool `oracle_search`.
            let spec = String(src.dropFirst("upstream:".count))
            let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let up = loadUpstreams(dbPath: dbPath).first(where: { $0.name == parts[0] }) else {
                perSource.append((src, [], "no upstream named \(parts.first ?? spec)"))
                continue
            }
            guard let r = upstreamCall(up, method: "tools/call",
                                       params: ["name": parts[1], "arguments": ["query": query]]) else {
                perSource.append((src, [], "upstream did not answer"))
                continue
            }
            // An upstream returns content blocks, not SearchHits. Flatten its text into
            // hits so one merged, comparably-shaped result set comes back — the caller
            // should not have to know which source a row came from to read it.
            var hits: [SearchHit] = []
            if let content = r["content"] as? [[String: Any]] {
                for block in content {
                    guard let text = block["text"] as? String, !text.isEmpty else { continue }
                    hits.append(contentsOf: upstreamHits(text: text, upstream: parts[0], limit: limit))
                }
            }
            perSource.append((src, hits, hits.isEmpty ? "upstream returned nothing usable" : nil))

        } else {
            perSource.append((src, [], "unknown source form \(src.debugDescription)"))
        }
    }

    let hits = perSource.flatMap(\.hits)

    // Memoized, not replaced: earlier captures stay. A topic is a record of what this
    // question has found OVER TIME, which is the thing a one-shot search cannot give you.
    if let h = db.prepare(SQL.insertTopicHit) {
        for entry in perSource {
            for hit in entry.hits {
                sqlite3_reset(h)
                db.bindText(h, 1, name)
                db.bindInt(h, 2, hit.sessionId)
                db.bindText(h, 3, hit.uuid)
                db.bindText(h, 4, hit.role)
                db.bindText(h, 5, hit.ts)
                sqlite3_bind_double(h, 6, hit.score)
                db.bindText(h, 7, hit.snippet)
                db.bindText(h, 8, entry.source)
                sqlite3_step(h)
            }
        }
        sqlite3_finalize(h)
    }

    for e in perSource where e.error != nil {
        FileHandle.standardError.write(
            "[topic \(name)] source \(e.source): \(e.error!)\n".data(using: .utf8)!)
    }

    if !sources.isEmpty, let sq = db.prepare(SQL.setTopicSources) {
        db.bindText(sq, 1, sources.joined(separator: ","))
        db.bindText(sq, 2, name)
        sqlite3_step(sq)
        sqlite3_finalize(sq)
    }

    if let f = db.prepare(SQL.finishTopicRun) {
        db.bindInt(f, 1, hits.count)
        db.bindText(f, 2, name)
        sqlite3_step(f)
        sqlite3_finalize(f)
    }

    let topic = Topic(name: name, query: query, engine: engine,
                      description: description ?? "", createdAt: "", lastRunAt: "",
                      runs: 0, lastHits: hits.count, promoted: false, sources: sources)
    return (topic, hits.count)
}

/// Give a topic its own tool, or take it away. Returns nil when there is no such topic.
///
/// Separate from creation on purpose. Creating a topic is cheap and reversible; spending a
/// tool slot is neither, because the slot is charged against a budget shared with every
/// other MCP server the client has connected.
@discardableResult
public func setTopicPromoted(dbPath: String, name: String, promoted: Bool) -> Bool? {
    let db = DB(path: dbPath)
    db.exec(SQL.createTopics)
    _ = db.exec(SQL.addTopicPromotedColumn)
    guard loadTopics(dbPath: dbPath).contains(where: { $0.name == name }) else { return nil }
    guard let s = db.prepare(SQL.setTopicPromoted) else { return nil }
    db.bindInt(s, 1, promoted ? 1 : 0)
    db.bindText(s, 2, name)
    let ok = sqlite3_step(s) == SQLITE_DONE
    sqlite3_finalize(s)
    return ok
}

public func forgetTopic(dbPath: String, name: String) -> Bool {
    let db = DB(path: dbPath)
    db.exec(SQL.createTopics)
    var removed = false
    if let s = db.prepare(SQL.deleteTopic) {
        db.bindText(s, 1, name)
        removed = sqlite3_step(s) == SQLITE_DONE && sqlite3_changes(db.handle) > 0
        sqlite3_finalize(s)
    }
    if let s = db.prepare(SQL.deleteTopicHits) {
        db.bindText(s, 1, name)
        sqlite3_step(s)
        sqlite3_finalize(s)
    }
    return removed
}

/// The generated half of `tools/list`. One tool per saved topic, each carrying its own
/// query and last result count in the description — so a model choosing between them sees
/// what they actually are, not just their names.
/// Tools for PROMOTED topics only.
///
/// An unpromoted topic is not hidden — it is reachable through the built-in `dig_topic`,
/// which needs no tool slot and works on clients that never re-read tools/list. Promotion
/// buys the naming benefit for the few topics that deserve it.
func topicTools(dbPath: String) -> [MCPTool] {
    loadTopics(dbPath: dbPath).filter(\.promoted).map { t in
        var desc = t.description.isEmpty
            ? "Saved investigation. Runs the \(t.engine) query \(t.query.debugDescription) and returns both the fresh results and everything this topic has captured before."
            : t.description
        desc += " · query: \(t.query.debugDescription) · engine: \(t.engine)"
        if t.runs > 0 { desc += " · run \(t.runs)x, last found \(t.lastHits)" }
        return MCPTool(
            name: t.toolName,
            title: "Dig: \(t.name)",
            description: desc,
            schema: [
                "type": "object",
                "properties": [
                    "refresh": ["type": "boolean",
                                "description": "Re-run the query against the index before answering (default true). False returns only what was captured previously.",
                                "default": true],
                    "limit": ["type": "integer", "default": 20],
                ],
            ])
    }
}

/// Handle a call to a generated `dig_<topic>` tool. Returns nil when the name is not one.
public func callTopicTool(name: String, args: [String: Any], dbPath: String, root: String) -> [String: Any]? {
    guard name.hasPrefix("dig_") else { return nil }
    let topicName = String(name.dropFirst(4))
    guard let t = loadTopics(dbPath: dbPath).first(where: { $0.name == topicName }) else { return nil }

    let refresh = (args["refresh"] as? Bool) ?? true
    let limit = (args["limit"] as? Int) ?? 20
    var fresh = 0
    if refresh {
        // Pass the topic's STORED sources. Omitting them made a refresh silently run
        // local-only, so a composed topic quietly stopped being composed the moment anyone
        // ran it — the upstream count froze and nothing said why.
        fresh = (try? traceTopic(dbPath: dbPath, root: root, name: t.name, query: t.query,
                                 engine: t.engine, sources: t.sources, limit: limit).hits) ?? 0
    }

    // INTERLEAVE across sources for a composed topic.
    //
    // Ordering by (source, score) fills the whole limit from whichever source sorts first —
    // 39 local rows before the upstream is reached, so the upstream never appears and the
    // composition looks broken. Scores are not comparable across sources, so there is no
    // honest global ranking; a fair share from each is the truthful presentation.
    let captured: [TopicHit]
    if t.isComposed {
        let all = loadTopicHits(dbPath: dbPath, topic: t.name, limit: limit * 8)
        var bySource: [String: [TopicHit]] = [:]
        for h in all { bySource[h.source, default: []].append(h) }
        var interleaved: [TopicHit] = []
        var i = 0
        let order = bySource.keys.sorted()
        while interleaved.count < limit {
            var addedAny = false
            for src in order where i < (bySource[src]?.count ?? 0) {
                interleaved.append(bySource[src]![i])
                addedAny = true
                if interleaved.count >= limit { break }
            }
            if !addedAny { break }
            i += 1
        }
        captured = interleaved
    } else {
        captured = loadTopicHits(dbPath: dbPath, topic: t.name, limit: limit)
    }
    var out = """
        topic    \(t.name)
        query    \(t.query.debugDescription)
        sources  \(t.effectiveSources.joined(separator: " + "))\(t.isComposed ? "   ← composed" : "")
        \(refresh ? "fresh    \(fresh) hit(s) this run\n" : "")captured \(captured.count) memoized hit(s) across \(t.runs) run(s)

        """
    // Per-source counts. For a composed topic this is the only number that answers "is the
    // upstream earning its latency" — without it a merged pile looks the same either way.
    if t.isComposed {
        let db = DB(path: dbPath)
        if let s = db.prepare(SQL.selectTopicSourceCounts) {
            db.bindText(s, 1, t.name)
            out += "by source\n"
            while sqlite3_step(s) == SQLITE_ROW {
                let src = sqlite3_column_text(s, 0).map { String(cString: $0) } ?? "?"
                out += "  \(src)  \(sqlite3_column_int64(s, 1))\n"
            }
            sqlite3_finalize(s)
            out += "\n"
        }
    }
    for h in captured {
        let tag = h.source.hasPrefix("upstream:") ? "⇗ " : ""
        out += "\(tag)[\(String(format: "%.2f", h.score))] \(h.role) \(h.ts.prefix(19)) \(h.uuid.prefix(8))\n  \(h.snippet)\n"
    }
    if captured.isEmpty {
        out += "Nothing captured yet. If this topic has run before and now finds nothing, the corpus moved or the query rotted.\n"
    }
    return ["content": [["type": "text", "text": out]], "isError": false]
}

// MARK: - reading sessions (the dig path)

public struct SessionEvent {
    public let seq: Int
    public let role: String
    public let ts: String
    public let text: String
}

public struct SessionRef {
    public let id: Int
    public let uuid: String
    public let tier: String
    public let path: String
    public let project: String
    public let startedAt: String
    public let events: Int
}

/// Resolve a uuid PREFIX. Search results print 8 characters, so 8 is what people paste;
/// requiring the full uuid would make every read a two-step lookup.
///
/// ONE UUID CAN HAVE MANY ROWS. That is the three-tier structure, not duplication: a
/// session's own transcript, its subagent transcripts, and its workflow-agent transcripts
/// all carry the SAME session uuid and differ by `file_tier` and `file_path`. Measured on
/// one uuid here: 1 session + 8 subagent + 37 workflow_agent rows. A caller that treats row
/// count as ambiguity reports "matches 5 sessions" and prints the same uuid five times.
/// Distinct SESSIONS matching a prefix — one entry per uuid, preferring the tier-1 file.
///
/// Tier 1 is the parent transcript and is what "read this session" means; the subagent and
/// workflow files are its children and are reachable by their own paths.
public func resolveDistinctSessions(dbPath: String, uuidPrefix: String) -> [SessionRef] {
    let all = resolveSession(dbPath: dbPath, uuidPrefix: uuidPrefix, limit: 200)
    var byUUID: [String: SessionRef] = [:]
    for r in all {
        guard let existing = byUUID[r.uuid] else { byUUID[r.uuid] = r; continue }
        // Prefer session > subagent > workflow_agent, then the larger event count.
        func rank(_ t: String) -> Int { t == "session" ? 0 : (t == "subagent" ? 1 : 2) }
        if rank(r.tier) < rank(existing.tier) || (r.tier == existing.tier && r.events > existing.events) {
            byUUID[r.uuid] = r
        }
    }
    return byUUID.values.sorted { $0.uuid < $1.uuid }
}

public func resolveSession(dbPath: String, uuidPrefix: String, limit: Int = 5) -> [SessionRef] {
    let db = DB(path: dbPath)
    guard let s = db.prepare(SQL.selectSessionByUUIDPrefix) else { return [] }
    db.bindText(s, 1, uuidPrefix)
    _ = limit
    var out: [SessionRef] = []
    while sqlite3_step(s) == SQLITE_ROW {
        func txt(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        out.append(SessionRef(id: Int(sqlite3_column_int64(s, 0)), uuid: txt(1), tier: txt(2),
                              path: txt(3), project: txt(4), startedAt: txt(5),
                              events: Int(sqlite3_column_int64(s, 6))))
    }
    sqlite3_finalize(s)
    return out
}

public func readSessionEvents(dbPath: String, sessionId: Int, from: Int, limit: Int) -> [SessionEvent] {
    let db = DB(path: dbPath)
    guard let s = db.prepare(SQL.selectSessionEvents) else { return [] }
    db.bindInt(s, 1, sessionId); db.bindInt(s, 2, from); db.bindInt(s, 3, limit)
    return drainEvents(s)
}

public func readEventContext(dbPath: String, sessionId: Int, seq: Int,
                             before: Int, after: Int) -> [SessionEvent] {
    let db = DB(path: dbPath)
    guard let s = db.prepare(SQL.selectEventContext) else { return [] }
    db.bindInt(s, 1, sessionId)
    db.bindInt(s, 2, max(0, seq - before))
    db.bindInt(s, 3, seq + after)
    return drainEvents(s)
}

private func drainEvents(_ s: OpaquePointer?) -> [SessionEvent] {
    var out: [SessionEvent] = []
    while sqlite3_step(s) == SQLITE_ROW {
        func txt(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        out.append(SessionEvent(seq: Int(sqlite3_column_int64(s, 0)), role: txt(1),
                                ts: txt(2), text: txt(3)))
    }
    sqlite3_finalize(s)
    return out
}

/// Render events for a model to read.
///
/// Per-message truncation, not whole-response: cutting the LAST message off a 40-message
/// read loses the end of the exchange, which is usually the part that answers the question.
/// Trimming each message instead keeps the shape of the conversation intact.
public func renderEvents(_ events: [SessionEvent], perMessage: Int = 1200) -> String {
    var out = ""
    for e in events {
        let t = e.text.count > perMessage
            ? String(e.text.prefix(perMessage)) + "\n  […\(e.text.count - perMessage) more chars]"
            : e.text
        out += "#\(e.seq) \(e.role)\(e.ts.isEmpty ? "" : " " + String(e.ts.prefix(19)))\n\(t)\n\n"
    }
    return out
}
