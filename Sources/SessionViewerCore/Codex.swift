import Foundation
import SQLite3

// Codex.swift — reading Codex CLI transcripts alongside Claude Code's.
//
// Measured on this machine, 2026-08-25: 615 rollout files, 2.5 GB — comparable to the
// Claude Code corpus (1,275 files, 741 MB) and completely invisible to it.
//
//   ~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<uuid>.jsonl
//
// THE FORMAT IS GENUINELY DIFFERENT, not a dialect. Every line is
// `{ordinal, payload, timestamp, type}` and the content lives in `payload`, so none of
// Claude Code's shape applies — no top-level `message`, no `cwd` on every line, no
// `sessionId`. Types seen in a real file:
//
//   response_item   message · custom_tool_call · custom_tool_call_output · reasoning
//   event_msg       item_completed · token_count · task_started · task_complete
//   session_meta    session_id, id, cwd, agent_nickname, agent_role, cli_version, …
//   turn_context · world_state · inter_agent_communication_metadata
//
// ONE THING CODEX HAS THAT WE DO NOT: `parent_thread_id` and `forked_from_id` in
// session_meta. Claude Code's tier-3 workflow transcripts carry no link back to their owning
// session — `parent_session_id` is a standing NULL in this schema and an open TODO. Codex
// states it outright, so for Codex rows we can populate what we cannot for our own.

/// Where Codex keeps transcripts. Overridable because a second machine's copy is a normal
/// thing to point at, exactly as with `~/.claude/projects`.
public let defaultCodexRoot = "\(NSHomeDirectory())/.codex/sessions"

/// One Codex rollout file, after the cheap header read.
struct CodexFile {
    let path: String
    let sessionUUID: String
    let cwd: String?
    let agentNickname: String?
    let agentRole: String?
    let parentThreadID: String?
    /// thread_source == "subagent" (or a parent_thread_id present): a worker spawned by a
    /// session, as opposed to a top-level session or a fork of one.
    let isSubagent: Bool
    let mtime: Int
    let size: Int
}

/// Walk the date-partitioned tree. Only `rollout-*.jsonl` — the same directory also holds
/// `session_index.jsonl` and `history.jsonl` at the root, which are indexes over these
/// files rather than transcripts, and importing an index as a transcript would double-count
/// every session under a second identity.
func discoverCodexFiles(root: String) -> [CodexFile] {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: root) else { return [] }
    var out: [CodexFile] = []
    for case let rel as String in en {
        let name = (rel as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
        let full = root + "/" + rel
        guard let st = statFile(full) else { continue }
        let head = codexHeader(path: full)
        // The uuid is in session_meta, but a file whose header is unreadable (truncated
        // mid-write, which happens on live sessions) still has it in the FILENAME:
        // rollout-<ISO8601>-<uuid>.jsonl. Fall back rather than skip the file.
        let uuid = head?.uuid ?? uuidFromCodexFilename(name) ?? name
        out.append(CodexFile(path: full, sessionUUID: uuid, cwd: head?.cwd,
                             agentNickname: head?.nickname, agentRole: head?.role,
                             parentThreadID: head?.parent,
                             isSubagent: head?.isSubagent ?? false,
                             mtime: st.mtime, size: st.size))
    }
    return out
}

/// Paths only — no header probes. For consumers that need to know WHICH files exist
/// (the pruned-file diff) rather than what is in them: 627 bounded header reads to
/// compute a count would make a status read cost as much as an import scan.
func codexFilePaths(root: String) -> [String] {
    guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
    var out: [String] = []
    for case let rel as String in en {
        let name = (rel as NSString).lastPathComponent
        if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") { out.append(root + "/" + rel) }
    }
    return out
}

/// The live-poll variant: filter by mtime BEFORE reading any header.
///
/// `discoverCodexFiles` reads a bounded header probe for every file it finds, which is the
/// right trade for an import that runs once over 617 files. The Live tab re-scans every
/// two seconds, and paying 617 file opens per tick to display the two or three sessions
/// that are actually being written would make the poll itself the most expensive thing on
/// the machine — the same class of stall as the freeze this tab already had once.
///
/// `stat` is cheap and `mtime` alone decides liveness, so the header cost is paid only for
/// files that survive the cutoff.
func liveCodexFiles(root: String, withinSeconds: Int = 300, now: Date = Date()) -> [CodexFile] {
    let cutoff = Int(now.timeIntervalSince1970) - withinSeconds
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: root) else { return [] }
    var out: [CodexFile] = []
    for case let rel as String in en {
        let name = (rel as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
        let full = root + "/" + rel
        guard let st = statFile(full), st.mtime >= cutoff else { continue }
        let head = codexHeader(path: full)
        let uuid = head?.uuid ?? uuidFromCodexFilename(name) ?? name
        out.append(CodexFile(path: full, sessionUUID: uuid, cwd: head?.cwd,
                             agentNickname: head?.nickname, agentRole: head?.role,
                             parentThreadID: head?.parent,
                             isSubagent: head?.isSubagent ?? false,
                             mtime: st.mtime, size: st.size))
    }
    return out
}

/// `rollout-2026-08-20T16-20-05-01a01e78-7197-7f42-a6fe-9a83f787e1ff.jsonl` → the uuid.
/// The timestamp uses `-` as its own separator, so splitting on `-` cannot work; take the
/// last five hyphen-groups, which is what a uuid is.
func uuidFromCodexFilename(_ name: String) -> String? {
    let base = name.replacingOccurrences(of: "rollout-", with: "")
        .replacingOccurrences(of: ".jsonl", with: "")
    let parts = base.split(separator: "-")
    guard parts.count >= 5 else { return nil }
    return parts.suffix(5).joined(separator: "-")
}

/// Read only as far as the first `session_meta`. These files run to hundreds of KB and the
/// header is in the first line or two; reading the whole file to learn its cwd would make
/// discovery cost as much as import.
func codexHeader(path: String, probeBytes: Int = 128 * 1024)
    -> (uuid: String, cwd: String?, nickname: String?, role: String?, parent: String?,
        isSubagent: Bool)? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let data = try? fh.read(upToCount: probeBytes), !data.isEmpty else { return nil }

    for slice in data.split(separator: 0x0A).prefix(8) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any],
              (o["type"] as? String) == "session_meta",
              let p = o["payload"] as? [String: Any] else { continue }
        let uuid = (p["id"] as? String) ?? (p["session_id"] as? String) ?? ""
        guard !uuid.isEmpty else { continue }
        // SUBAGENT IS DECIDED BY thread_source, not by having a parent. A rollout can
        // carry `forked_from_id` (a compact/fork continuation of a top-level session)
        // without being anyone's worker — classifying by "has a parent" would demote those
        // to subagents. `parent_thread_id` alone is accepted as a fallback signal because
        // headers that carry it have been subagents in every observed case.
        let threadSource = p["thread_source"] as? String
        let parentThread = p["parent_thread_id"] as? String
        return (uuid,
                p["cwd"] as? String,
                p["agent_nickname"] as? String,
                p["agent_role"] as? String,
                parentThread ?? (p["forked_from_id"] as? String),
                threadSource == "subagent" || parentThread != nil)
    }
    return nil
}

/// Searchable text out of one Codex line, or nil.
///
/// SCOPE IS SET BY PARITY WITH THE CLAUDE PATH, not by what looks conversational. Claude
/// tool results arrive as `user`-type lines and ARE indexed, because a command's output is
/// usually the thing you are searching for. The first cut here took only
/// `response_item/message` and indexed 9,421 items out of ~32,500 — searching Codex would
/// have been materially worse than searching Claude for no principled reason.
///
/// Indexed: message · custom_tool_call (name + input) · custom_tool_call_output ·
///          function_call · function_call_output.
/// NOT indexed: `reasoning`, whose payload is `summary: []` plus `encrypted_content` — there
/// is no readable text in it, exactly as Claude's `thinking` blocks are stripped at write
/// time. Counted in session_type_counts either way, so the omission is visible.
func codexLineText(_ obj: [String: Any]) -> (role: String, text: String)? {
    guard (obj["type"] as? String) == "response_item",
          let p = obj["payload"] as? [String: Any],
          let sub = p["type"] as? String else { return nil }

    /// Codex nests text as [{type: input_text|output_text, text: …}] in several places.
    func flatten(_ any: Any?) -> String {
        if let str = any as? String { return str }
        if let blocks = any as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return ""
    }

    switch sub {
    case "message":
        let role = (p["role"] as? String) ?? "assistant"
        let text = flatten(p["content"])
        return text.isEmpty ? nil : (role, text)

    case "custom_tool_call", "function_call":
        // Name AND input — the equivalent of Claude's tool_use, where dropping the name
        // threw away the most useful field on the most common line in the file.
        let name = (p["name"] as? String) ?? "tool"
        let input = flatten(p["input"]) + flatten(p["arguments"])
        return ("tool_use", input.isEmpty ? name : "\(name) · \(input)")

    case "custom_tool_call_output", "function_call_output":
        let text = flatten(p["output"])
        return text.isEmpty ? nil : ("tool_result", text)

    default:
        return nil
    }
}

/// The per-line type, for the type-count table. Nested so a `response_item/message` is
/// distinguishable from a `response_item/reasoning` — collapsing them would repeat the
/// mistake this project exists to avoid, where ~14 real Claude line types were read as 3.
func codexLineType(_ obj: [String: Any]) -> String {
    let t = (obj["type"] as? String) ?? "(no type)"
    guard let p = obj["payload"] as? [String: Any] else { return t }
    if let sub = p["type"] as? String { return "\(t)/\(sub)" }
    return t
}

/// `session-viewer codex` — what is there, without importing anything.
public func runCodexScanCLI(root: String) {
    let files = discoverCodexFiles(root: root)
    guard !files.isEmpty else {
        print("no Codex rollouts under \(root)")
        return
    }
    let bytes = files.reduce(0) { $0 + $1.size }
    let withCwd = files.filter { $0.cwd != nil }.count
    let withParent = files.filter { $0.parentThreadID != nil }.count

    print("root       \(root)")
    print("rollouts   \(files.count) files · \(humanBytes(bytes))")
    print("cwd known  \(withCwd)/\(files.count)")
    print("parented   \(withParent)/\(files.count)   ← Codex states this; Claude Code tier-3 does not")

    var byProject: [String: Int] = [:]
    for f in files { byProject[f.cwd ?? "(unknown)", default: 0] += 1 }
    print("")
    for (proj, n) in byProject.sorted(by: { $0.value > $1.value }).prefix(10) {
        print("  " + padL(String(n), 5) + "  " + proj)
    }
}

// MARK: - import

/// Parse one rollout into the same shape the Claude importer produces.
///
/// Line-streamed and failure-tolerant, for the same reason as `parseSessionFile`: these run
/// to hundreds of KB (2.64 GB across 615 files) and a live one is truncated mid-write.
func parseCodexFile(path: String) -> ParsedSession? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }

    var typeCounts: [String: Int] = [:]
    var events: [(seq: Int, role: String, ts: String?, text: String)] = []
    var lineCount = 0
    var cwd: String?
    var startedAt: String?
    var endedAt: String?
    var description: String?
    var seq = 0

    var buffer = Data()
    while true {
        let chunk = fh.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = buffer[buffer.index(after: nl)...]
            lineCount += 1
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { typeCounts["(malformed)", default: 0] += 1; continue }

            typeCounts[codexLineType(obj), default: 0] += 1
            if let ts = obj["timestamp"] as? String {
                if startedAt == nil { startedAt = ts }
                endedAt = ts
            }
            if (obj["type"] as? String) == "session_meta",
               let p = obj["payload"] as? [String: Any] {
                cwd = cwd ?? (p["cwd"] as? String)
            }
            if let (role, text) = codexLineText(obj) {
                seq += 1
                events.append((seq: seq, role: role,
                               ts: obj["timestamp"] as? String, text: text))
                // First non-developer message is the closest thing to a human prompt —
                // `developer` lines are the system identity block, not what was asked.
                if description == nil, role != "developer" {
                    description = String(text.split(whereSeparator: \.isNewline)
                                             .first.map(String.init)?.prefix(200) ?? "")
                }
            }
        }
    }
    // A file with no trailing newline leaves its last line in the buffer.
    if !buffer.isEmpty,
       let obj = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] {
        lineCount += 1
        typeCounts[codexLineType(obj), default: 0] += 1
        if let (role, text) = codexLineText(obj) {
            seq += 1
            events.append((seq: seq, role: role,
                           ts: obj["timestamp"] as? String, text: text))
        }
    }

    var out = ParsedSession()
    out.lineCount = lineCount
    out.eventCount = events.count
    out.startedAt = startedAt
    out.endedAt = endedAt
    out.cwd = cwd
    out.description = description
    out.typeCounts = typeCounts
    out.events = events
    return out
}

public struct CodexImportSummary {
    public let files: Int
    public let new: Int
    public let changed: Int
    public let skipped: Int
    public let failed: Int
    public let parented: Int
    public let seconds: Double
}

/// Import Codex rollouts into the same index, tagged `source='codex'`.
@discardableResult
public func runCodexImport(dbPath: String, codexRoot: String,
                           onProgress: ((Int, Int) -> Void)? = nil) -> CodexImportSummary {
    let t0 = Date()
    let db = DB(path: dbPath)
    _ = db.exec(SQL.addSessionSourceColumn)

    let files = discoverCodexFiles(root: codexRoot)
    let known = loadKnownFiles(db: db)
    var new = 0, changed = 0, skipped = 0, failed = 0

    // RETIER rows imported before tier-from-header existed. The (path, mtime, size) diff
    // below skips unchanged files, so a finished worker's row would keep tier='session'
    // forever without this pass. Discovery already probed every header, so this costs one
    // UPDATE per misfiled row and is idempotent.
    var retiered = 0
    if let up = db.prepare("UPDATE sessions SET file_tier='subagent' WHERE file_path=? AND file_tier='session'") {
        for f in files where f.isSubagent {
            sqlite3_reset(up)
            db.bindText(up, 1, f.path)
            if sqlite3_step(up) == SQLITE_DONE, sqlite3_changes(db.handle) > 0 { retiered += 1 }
        }
        sqlite3_finalize(up)
    }
    if retiered > 0 {
        FileHandle.standardError.write("codex: retiered \(retiered) existing row(s) session → subagent\n".data(using: .utf8)!)
    }

    db.exec(SQL.begin)
    for (i, f) in files.enumerated() {
        defer { onProgress?(i + 1, files.count) }
        if let k = known[f.path], k.mtime == f.mtime, k.size == f.size { skipped += 1; continue }
        let isNew = known[f.path] == nil

        guard let parsed = parseCodexFile(path: f.path) else { failed += 1; continue }

        // A Codex rollout's "project" is its cwd. Claude Code's dirname is an encoded,
        // lossy thing we must never decode; Codex hands us the real path, so the dirName
        // and cwd are simply the same string here.
        let proj = parsed.cwd ?? f.cwd ?? "(unknown)"
        guard let projectId = upsertProject(db: db, dirName: proj, cwd: proj) else {
            failed += 1; continue
        }

        let existing = existingSessionId(db: db, path: f.path)
        // Tier from the header: a rollout is a top-level session UNLESS its thread_source
        // says subagent — Codex has the same two-level structure Claude does, and for two
        // days the index flattened it (617 rows all 'session') while the Live view nested
        // correctly, so the All tab and `--tier subagent` disagreed with Live about the
        // same files. `source` still tells codex from claude; tier is the same axis it is
        // for Claude files.
        let file = DiscoveredFile(path: f.path, projectDirName: proj,
                                  tier: f.isSubagent ? "subagent" : "session",
                                  sessionUUID: f.sessionUUID,
                                  agentId: f.agentNickname ?? f.agentRole,
                                  workflowRunId: nil, mtime: f.mtime, size: f.size)

        if importParsed(db: db, file: file, parsed: parsed,
                        projectId: projectId, existingId: existing) {
            if isNew { new += 1 } else { changed += 1 }
        } else {
            failed += 1
        }
        if (i + 1) % 25 == 0 { db.exec(SQL.commit); db.exec(SQL.begin) }
    }
    db.exec(SQL.commit)

    // Tag every row we just wrote, then resolve parents. Codex states parent_thread_id, so
    // this link is available here even though it is a standing NULL for Claude tier-3.
    var parented = 0
    if let s = db.prepare("UPDATE sessions SET source='codex' WHERE file_path LIKE ? || '%'") {
        db.bindText(s, 1, codexRoot)
        sqlite3_step(s); sqlite3_finalize(s)
    }
    for f in files {
        guard let parent = f.parentThreadID else { continue }
        guard let child = existingSessionId(db: db, path: f.path) else { continue }
        if let s = db.prepare(SQL.updateSessionParentThread) {
            db.bindText(s, 1, parent)
            db.bindInt(s, 2, child)
            if sqlite3_step(s) == SQLITE_DONE && sqlite3_changes(db.handle) > 0 { parented += 1 }
            sqlite3_finalize(s)
        }
    }

    return CodexImportSummary(files: files.count, new: new, changed: changed,
                              skipped: skipped, failed: failed, parented: parented,
                              seconds: Date().timeIntervalSince(t0))
}
