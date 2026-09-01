// Tail.swift — incremental follow of LIVE session .jsonl files.
//
// The load-bearing measured fact this file exists to exploit: session .jsonl files are
// APPEND-ONLY. Verified on this machine 2026-08-24 — the md5 of a file's first 1 MB
// stayed bda4e46c5b650d5e302f61b4959e8d19 while the file itself grew 3825889 → 3850991
// bytes. Nothing rewrites earlier bytes. So a changed file does NOT need re-reading:
// seek(lastKnownOffset), read only the delta, done.
//
// What that buys, concretely: the p99 file here is 39.6 MB, and Store.parseSessionFile
// re-reads from byte 0 on every change (it takes no offset parameter). During a live
// session that file is touched every turn. Tailing turns a repeated 39.6 MB read into a
// repeated ~25 KB read.
//
// THE CRITICAL CORRECTNESS POINT — a trailing PARTIAL line is held back, never parsed.
// Writes are bursty (a file sits still for seconds, then jumps 25 KB at a turn boundary),
// and 6 sessions were observed writing concurrently, so reading while a writer is
// mid-append is the normal case, not an edge case. If the last byte read is not a
// newline, those bytes are NOT consumed and the offset does not advance past them; they
// are re-read next tick when the rest has landed. Note the deliberate contrast with
// Store.parseSessionFile, which DOES parse its trailing newline-less remainder
// (Store.swift:134) — that is right for a one-shot import of a file nobody is appending
// to right now, and wrong here.

import Foundation
import SQLite3

// MARK: - One appended line

/// One complete line that appeared after the last known offset.
/// `byteOffset` is absolute within the file, so a caller can jump straight back to it.
struct TailEvent {
    let path: String
    let byteOffset: Int
    let byteLength: Int      // bytes of the line, excluding its newline
    let parsedOK: Bool       // false = malformed JSON; kept and surfaced, never silently dropped
    let lineType: String?    // "user" | "assistant" | "system" | mode | attachment | … (~14 real values)
    let timestamp: String?
    let text: String         // extracted conversational text; "" for non-conversational types
    let raw: String
}

/// Result of one incremental read. `newOffset` is what to persist; anything the writer
/// had not finished is reported as `heldBackBytes` and is NOT included in `newOffset`.
struct TailRead {
    var events: [TailEvent] = []
    var fromOffset: Int = 0
    var newOffset: Int = 0
    var heldBackBytes: Int = 0
    var truncated: Bool = false      // file shrank ⇒ replaced, not appended to; restarted from 0
    var moreAvailable: Bool = false  // hit the per-read cap; call read() again immediately
    var bytesConsumed: Int { newOffset - fromOffset }
    var isEmpty: Bool { events.isEmpty && bytesConsumed == 0 }
}

enum TailError: Error, CustomStringConvertible {
    case missing(String)
    case unreadable(String)
    var description: String {
        switch self {
        case .missing(let p):    return "file disappeared: \(p)"
        case .unreadable(let p): return "cannot open for reading: \(p)"
        }
    }
}

// MARK: - The tailer

/// Follows ONE file from a byte offset. Stateful (remembers `offset`), cheap to create,
/// and deliberately unaware of SQLite or the UI — `TailWatcher` owns policy, this owns
/// the byte-exact "what is new since offset N" question.
final class SessionTailer {

    /// Per-read cap. A live turn appends ~25 KB, so 4 MB is ~150 turns of slack; it exists
    /// only to bound memory when resuming a long-idle file, never to bound a normal tick.
    /// Never load a whole file: the p99 here is 39.6 MB.
    static let defaultMaxBytes = 4 << 20

    /// A single JSON line longer than this is not something this corpus produces; the read
    /// window doubles up to here looking for a newline, then gives up and holds the bytes
    /// back rather than guessing at a line boundary.
    static let hardMaxLineBytes = 64 << 20

    let path: String
    private(set) var offset: Int
    private(set) var linesSeen: Int
    private(set) var lastLineAt: String?

    init(path: String, offset: Int = 0, linesSeen: Int = 0) {
        self.path = path
        self.offset = max(0, offset)
        self.linesSeen = linesSeen
    }

    /// Reads only the bytes after `offset`, parses the COMPLETE lines among them, and
    /// returns them with the new offset. A trailing partial line is held back.
    func read(maxBytes: Int = SessionTailer.defaultMaxBytes) throws -> TailRead {
        guard let st = statFile(path) else { throw TailError.missing(path) }

        var out = TailRead()
        var from = offset

        if st.size < from {
            // Append-only is an empirical property, not a guarantee. If size ever goes
            // BACKWARD the file was replaced or rotated — seeking to the old offset would
            // land past EOF or mid-line of unrelated bytes. Restart from 0 and say so.
            from = 0
            out.truncated = true
        }

        out.fromOffset = from
        out.newOffset = from

        if st.size == from { offset = from; return out }

        guard let fh = FileHandle(forReadingAtPath: path) else { throw TailError.unreadable(path) }
        defer { try? fh.close() }

        let available = st.size - from
        var window = min(available, maxBytes)
        var chunk = Data()
        var lastNL: Data.Index? = nil

        while true {
            try fh.seek(toOffset: UInt64(from))
            chunk = fh.readData(ofLength: window)
            if chunk.isEmpty { break }
            lastNL = chunk.lastIndex(of: 0x0A)
            if lastNL != nil { break }
            // No newline anywhere in the window: either the writer is mid-line (normal —
            // hold back) or this line is genuinely enormous (grow the window and retry).
            if window >= available || window >= SessionTailer.hardMaxLineBytes { break }
            window = min(available, min(window &* 2, SessionTailer.hardMaxLineBytes))
        }

        out.moreAvailable = available > window

        guard let nl = lastNL else {
            // Everything read so far is one unterminated line. Consume nothing.
            out.heldBackBytes = chunk.count
            offset = from
            return out
        }

        let completeEnd = chunk.index(after: nl)   // exclusive: one past the last newline
        let consumed = chunk.distance(from: chunk.startIndex, to: completeEnd)

        var lineStart = chunk.startIndex
        while lineStart < completeEnd {
            guard let nlIdx = chunk[lineStart..<completeEnd].firstIndex(of: 0x0A) else { break }
            let lineBytes = chunk[lineStart..<nlIdx]
            let absOffset = from + chunk.distance(from: chunk.startIndex, to: lineStart)
            if !lineBytes.isEmpty {
                let ev = makeEvent(lineBytes, at: absOffset)
                out.events.append(ev)
                linesSeen += 1
                if let ts = ev.timestamp { lastLineAt = ts }
            }
            lineStart = chunk.index(after: nlIdx)
        }

        out.heldBackBytes = chunk.count - consumed
        out.newOffset = from + consumed
        offset = out.newOffset
        return out
    }

    private func makeEvent(_ bytes: Data, at absOffset: Int) -> TailEvent {
        let copy = Data(bytes)   // JSONSerialization wants a 0-based contiguous buffer
        let raw = String(data: copy, encoding: .utf8) ?? "<non-utf8 \(copy.count) bytes>"
        guard let obj = try? JSONSerialization.jsonObject(with: copy) as? [String: Any] else {
            // Malformed lines happen (truncated mid-write, then the writer moved on).
            // Surfaced as parsedOK=false rather than dropped — same policy as the importer.
            return TailEvent(path: path, byteOffset: absOffset, byteLength: copy.count,
                             parsedOK: false, lineType: nil, timestamp: nil, text: "", raw: raw)
        }
        let t = obj["type"] as? String

        // TWO TRANSCRIPT FORMATS REACH THIS FUNCTION. A Claude line carries its text at
        // `message.content` under a conversational `type`; a Codex rollout line has
        // type="response_item" with the text nested under `payload`, and nothing at
        // `message` at all. Extracting only the Claude shape made every Codex line render
        // as "no content" — the tail was following the file correctly and reporting an
        // empty conversation, which is the same silent-empty-result failure as returning
        // no rows for a query that could not prepare.
        //
        // `codexLineText` is the SAME function the Codex importer uses, so what the live
        // pane shows and what the index stores cannot disagree.
        if let claudeText = t.map({ CONVERSATIONAL_TYPES.contains($0) }), claudeText {
            return TailEvent(path: path, byteOffset: absOffset, byteLength: copy.count,
                             parsedOK: true, lineType: t, timestamp: obj["timestamp"] as? String,
                             text: extractText(from: obj), raw: raw)
        }
        if let (role, codexText) = codexLineText(obj) {
            // Label it by ROLE, not by "response_item" — the wrapper type is the same on
            // every line and so carries no information; the role is what a reader wants.
            return TailEvent(path: path, byteOffset: absOffset, byteLength: copy.count,
                             parsedOK: true, lineType: role, timestamp: obj["timestamp"] as? String,
                             text: codexText, raw: raw)
        }
        // Still nothing readable: name the payload sub-type where there is one, so a
        // Codex line reads "reasoning" or "token_count" rather than a uniform
        // "response_item" that says nothing about which lines were skipped and why.
        let sub = (obj["payload"] as? [String: Any])?["type"] as? String
        return TailEvent(path: path, byteOffset: absOffset, byteLength: copy.count,
                         parsedOK: true, lineType: sub.map { "\(t ?? "?") · \($0)" } ?? t,
                         timestamp: obj["timestamp"] as? String,
                         text: "", raw: raw)
    }

    /// Resolve a starting offset that is guaranteed to sit on a line boundary.
    /// Starting mid-line would emit the leading fragment as a malformed event — the
    /// hold-back rule only protects the TRAILING edge, so the leading edge is handled here.
    static func alignedOffset(path: String, approx: Int, scanLimit: Int = 1 << 20) -> Int {
        guard let st = statFile(path) else { return 0 }
        if approx <= 0 { return 0 }
        if approx >= st.size { return st.size }
        guard let fh = FileHandle(forReadingAtPath: path) else { return st.size }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: UInt64(approx))) != nil else { return st.size }
        let probe = fh.readData(ofLength: min(scanLimit, st.size - approx))
        guard let nl = probe.firstIndex(of: 0x0A) else { return st.size }
        return approx + probe.distance(from: probe.startIndex, to: nl) + 1
    }
}

// MARK: - Which sessions are live right now

/// Files whose mtime is within the last `withinSeconds`. Pure FileManager (statFile →
/// attributesOfItem), no shell — a `find -newermt` would silently return 0 rows on BSD
/// find anyway, and shelling out per tick is exactly the cost this design avoids.
///
/// Reuses discoverFiles() unchanged: liveness is a FILTER over the verified 975-file
/// three-tier discovery, never a second, divergent walk.
func liveFiles(root: String, withinSeconds: Int = 300, now: Date = Date()) -> [DiscoveredFile] {
    let cutoff = Int(now.timeIntervalSince1970) - withinSeconds
    return discoverFiles(root: root).filter { $0.mtime >= cutoff }
}

// MARK: - Persisted offsets

/// Per-file tail offset, so a restart resumes instead of re-reading.
///
/// MIGRATION: this is a NEW TABLE, not a new column on `sessions`, for three reasons —
///   1. SQLite has no `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, so a column would make
///      re-running schema.sql against the existing .data/sessions.db fail with
///      "duplicate column name". `CREATE TABLE IF NOT EXISTS` is idempotent, so the
///      existing 45 MB db picks this up with a plain `just init-db` — no db rebuild.
///   2. The tailer legitimately sees files with no `sessions` row (a workflow agent
///      transcript created 3 seconds ago has never been imported). A column would force
///      inventing a half-empty sessions row just to remember a number.
///   3. Tail offset is follow-bookkeeping, not import state. `reimport` should be able to
///      wipe the index without necessarily wiping where a live follower had got to.
/// ensureSchema() below runs the same DDL at open time, so `session-viewer tail` also
/// self-heals an old db that has not had schema.sql re-applied.
final class TailOffsetStore {
    private let db: DB

    init(dbPath: String) {
        db = DB(path: dbPath)
        // Concurrent writers are the normal case here (6 sessions observed at once, plus
        // this process's own import). Without a busy timeout a contended step() returns
        // SQLITE_BUSY and a `while step() == SQLITE_ROW` loop reads it as "end of rows" —
        // a silently truncated result. 5s of retry costs nothing and removes that class.
        sqlite3_busy_timeout(db.handle, 5000)
        db.exec(SQL.createTailState)
    }

    func load(path: String) -> (offset: Int, size: Int, linesSeen: Int)? {
        let stmt = db.prepare(SQL.selectTailState)
        db.bindText(stmt, 1, path)
        var out: (Int, Int, Int)? = nil
        if sqlite3_step(stmt) == SQLITE_ROW {
            out = (Int(sqlite3_column_int64(stmt, 0)),
                   Int(sqlite3_column_int64(stmt, 1)),
                   Int(sqlite3_column_int64(stmt, 2)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func save(path: String, offset: Int, size: Int, mtime: Int, linesSeen: Int, lastLineAt: String?) {
        let stmt = db.prepare(SQL.upsertTailState)
        db.bindText(stmt, 1, path)
        db.bindInt(stmt, 2, offset)
        db.bindInt(stmt, 3, size)
        db.bindInt(stmt, 4, mtime)
        db.bindInt(stmt, 5, linesSeen)
        db.bindText(stmt, 6, lastLineAt)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
}

// MARK: - The watcher

struct TailStats {
    var ticks = 0
    var rescans = 0
    var filesFollowed = 0
    var bytesConsumed = 0
    var linesEmitted = 0
    var linesMalformed = 0
    var holdBacks = 0        // times a partial trailing line was held back — the point of this file
    var truncations = 0
}

/// Polling follower over the live set.
///
/// ── WHY A TIMER POLL AND NOT DispatchSource.makeFileSystemObjectSource(vnode) ──────
/// Both were on the table; poll wins here on four measured properties of THIS corpus,
/// not on general preference:
///
///  1. The watch set is not a fixed set of files. A vnode source watches an already-open
///     fd — it cannot tell you about a file that does not exist yet. In a 6-minute sample
///     26 files were touched, and workflow runs create brand-new agent-*.jsonl mid-run.
///     Catching creation with vnode means also arming a vnode source on every directory
///     (hundreds of them, nested three deep), then diffing the directory anyway. The poll
///     does creation, modification, deletion and pruning in one uniform rescan.
///  2. vnode tells you THAT something changed, never HOW MUCH. Every wakeup still ends in
///     stat + seek + read-the-delta — the identical work the poll does. vnode saves only
///     the stat, and a stat is ~microseconds; 26 of them per tick is not a cost worth
///     buying complexity to avoid.
///  3. Writes are bursty at turn boundaries, not character-streamed — a file sits idle for
///     seconds then jumps 25 KB. A 1 s poll is already far below the natural inter-write
///     gap, so sub-second wakeup latency buys nothing a human or the UI can perceive.
///  4. Files get PRUNED from disk while being watched (cleanupPeriodDays=30, SPEC.md).
///     vnode requires explicit .delete/.rename handling and re-arming to survive that; for
///     the poll, a vanished file is just a file that stopped appearing in the rescan.
///
/// (fd exhaustion is the usual fifth argument and it does NOT apply on this shell —
/// measured `ulimit -n` = 1048576. It would apply to an app bundle launched from Finder
/// under the launchd default, but that is not a number this task verified, so it is not
/// leaned on.)
///
/// The timer lives on its own serial DispatchQueue, so the same class is usable unchanged
/// from the SwiftUI app without blocking the main thread.
final class TailWatcher {
    let root: String
    let windowSeconds: Int
    let interval: TimeInterval
    let rescanEvery: TimeInterval
    let rewindBytes: Int
    let store: TailOffsetStore?

    var onBatch: ((DiscoveredFile, TailRead) -> Void)?
    var onEnter: ((DiscoveredFile, Int, Bool) -> Void)?   // file, start offset, resumedFromDB
    var onLeave: ((DiscoveredFile) -> Void)?
    var onRescan: ((Int) -> Void)?                        // live file count
    var onError: ((String, Error) -> Void)?

    private(set) var stats = TailStats()

    private let queue = DispatchQueue(label: "session-viewer.tail")
    private var timer: DispatchSourceTimer?
    private var tailers: [String: SessionTailer] = [:]
    private var meta: [String: DiscoveredFile] = [:]
    private var lastRescan = Date.distantPast

    /// Max read() rounds per file per tick — bounds a single tick at 16 × 4 MB when
    /// catching up a long-idle file, so one huge backlog cannot stall every other file.
    private let catchupRounds = 16

    init(root: String, windowSeconds: Int = 300, interval: TimeInterval = 1.0,
         rescanEvery: TimeInterval = 10.0, rewindBytes: Int = 0, store: TailOffsetStore? = nil) {
        self.root = root
        self.windowSeconds = windowSeconds
        self.interval = interval
        self.rescanEvery = rescanEvery
        self.rewindBytes = rewindBytes
        self.store = store
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One pass, synchronously, on the caller's thread — used by `tail --once` and tests.
    func runOnce() { tick() }

    private func tick() {
        stats.ticks += 1
        if Date().timeIntervalSince(lastRescan) >= rescanEvery { rescan() }

        for (path, tailer) in tailers {
            guard let file = meta[path] else { continue }
            var rounds = 0
            while rounds < catchupRounds {
                rounds += 1
                do {
                    let r = try tailer.read()
                    if r.truncated { stats.truncations += 1 }
                    if r.heldBackBytes > 0 { stats.holdBacks += 1 }
                    if !r.isEmpty {
                        stats.bytesConsumed += r.bytesConsumed
                        stats.linesEmitted += r.events.count
                        stats.linesMalformed += r.events.filter { !$0.parsedOK }.count
                        onBatch?(file, r)
                        persist(file: file, tailer: tailer)
                    }
                    if !r.moreAvailable { break }
                } catch {
                    // A file vanishing mid-follow is expected (pruning), not an error state.
                    onError?(path, error)
                    tailers.removeValue(forKey: path)
                    meta.removeValue(forKey: path)
                    break
                }
            }
        }
    }

    private func persist(file: DiscoveredFile, tailer: SessionTailer) {
        guard let store else { return }
        let size = statFile(file.path)?.size ?? tailer.offset
        store.save(path: file.path, offset: tailer.offset, size: size,
                   mtime: statFile(file.path)?.mtime ?? file.mtime,
                   linesSeen: tailer.linesSeen, lastLineAt: tailer.lastLineAt)
    }

    private func rescan() {
        lastRescan = Date()
        stats.rescans += 1
        let live = liveFiles(root: root, withinSeconds: windowSeconds)
        onRescan?(live.count)

        var seen = Set<String>()
        for f in live {
            seen.insert(f.path)
            meta[f.path] = f
            if tailers[f.path] != nil { continue }

            // Start offset policy:
            //   persisted   → resume exactly where we stopped (the whole point of the table)
            //   --rewind N  → N bytes before EOF, snapped FORWARD to a line boundary
            //   default     → EOF, i.e. true follow semantics; do not replay 39.6 MB of history
            var start: Int
            var resumed = false
            if let saved = store?.load(path: f.path), saved.offset <= f.size {
                start = saved.offset
                resumed = true
            } else if rewindBytes > 0 {
                start = SessionTailer.alignedOffset(path: f.path, approx: max(0, f.size - rewindBytes))
            } else {
                start = f.size
            }
            if start > f.size { start = 0 }   // file shrank since the offset was saved

            let t = SessionTailer(path: f.path, offset: start,
                                  linesSeen: store?.load(path: f.path)?.linesSeen ?? 0)
            tailers[f.path] = t
            stats.filesFollowed += 1
            onEnter?(f, start, resumed)
        }

        for (path, _) in tailers where !seen.contains(path) {
            if let f = meta[path] { onLeave?(f) }
            tailers.removeValue(forKey: path)
            meta.removeValue(forKey: path)
        }
    }
}

// MARK: - CLI: `session-viewer tail`

public struct TailOptions {
    var root: String
    var dbPath: String
    var window: Int = 300
    var interval: TimeInterval = 1.0
    var rescan: TimeInterval = 10.0
    var forSeconds: Double = 0     // 0 = run forever
    var rewind: Int = 0
    var raw = false
    var once = false
    var noDB = false
    var selfTest = false

    public static func parse(_ args: [String], defaultRoot: String, defaultDB: String) -> TailOptions {
        func val(_ n: String) -> String? {
            guard let i = args.firstIndex(of: "--\(n)"), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func has(_ n: String) -> Bool { args.contains("--\(n)") }

        // Reject unknown flags instead of ignoring them. Silently dropping an unrecognized
        // `--flag` is not a harmless no-op here: every flag this parser knows is a MODIFIER,
        // so a typo doesn't disable a feature, it falls through to the unmodified default —
        // and `tail`'s default is FOLLOW FOREVER. Measured: `tail --self-test` (the real flag
        // is `--selftest`) sat blocked for 94 minutes at 0.0% CPU looking exactly like a hung
        // app, because it was correctly tailing. Same family as the debug/release and no-op
        // `swift build` traps in SPEC.md: the tool succeeds at something other than what
        // was asked, so the failure is invisible at the point it happens.
        let takesValue: Set<String> = ["root", "db", "window", "interval", "rescan", "for", "rewind"]
        let boolean: Set<String> = ["raw", "once", "no-db", "selftest"]
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let name = String(a.dropFirst(2))
            if takesValue.contains(name) { i += 2; continue }
            if boolean.contains(name) { i += 1; continue }
            let known = takesValue.union(boolean).sorted().map { "--\($0)" }.joined(separator: " ")
            err("unknown flag: \(a)\nknown tail flags: \(known)")
            exit(2)
        }

        var o = TailOptions(root: val("root") ?? defaultRoot, dbPath: val("db") ?? defaultDB)
        if let v = val("window"), let n = Int(v) { o.window = n }
        if let v = val("interval"), let n = Double(v) { o.interval = n }
        if let v = val("rescan"), let n = Double(v) { o.rescan = n }
        if let v = val("for"), let n = Double(v) { o.forSeconds = n }
        if let v = val("rewind"), let n = Int(v) { o.rewind = n }
        o.raw = has("raw")
        o.once = has("once")
        o.noDB = has("no-db")
        o.selfTest = has("selftest")
        return o
    }
}

private let tailClock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
}()

private func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

private func shortPath(_ f: DiscoveredFile) -> String {
    let proj = f.projectDirName.split(separator: "-").suffix(2).joined(separator: "-")
    switch f.tier {
    case "session":        return "\(proj)/\(f.sessionUUID.prefix(8))"
    case "subagent":       return "\(proj)/\(f.sessionUUID.prefix(8))/\(f.agentId?.prefix(10) ?? "?")"
    default:               return "\(proj)/\(f.workflowRunId ?? "?")/\(f.agentId?.prefix(10) ?? "?")"
    }
}

private func oneLine(_ s: String, _ n: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: "⏎ ")
    return flat.count > n ? String(flat.prefix(n)) + "…" : flat
}

public func runTail(options o: TailOptions) {
    if o.selfTest { runTailSelfTest(); return }

    let store = o.noDB ? nil : TailOffsetStore(dbPath: o.dbPath)
    let w = TailWatcher(root: o.root, windowSeconds: o.window, interval: o.interval,
                        rescanEvery: o.rescan, rewindBytes: o.rewind, store: store)

    err("tail: root=\(o.root)")
    err("tail: live window=\(o.window)s  poll=\(o.interval)s  rescan=\(o.rescan)s  " +
        "offsets=\(o.noDB ? "not persisted" : o.dbPath)")

    w.onRescan = { n in err("tail: rescan — \(n) live file(s)") }
    w.onEnter = { f, start, resumed in
        err("tail: + \(shortPath(f))  [\(f.tier)] @\(start)\(resumed ? " (resumed)" : "") of \(f.size)B")
    }
    w.onLeave = { f in err("tail: - \(shortPath(f)) (went idle)") }
    w.onError = { p, e in err("tail: ! \(p): \(e)") }

    w.onBatch = { f, r in
        let stamp = tailClock.string(from: Date())
        var head = "\(stamp)  +\(r.bytesConsumed)B  \(r.events.count) line(s)  \(shortPath(f))"
        if r.heldBackBytes > 0 { head += "  [held back \(r.heldBackBytes)B partial]" }
        if r.truncated { head += "  [TRUNCATED — restarted at 0]" }
        print(head)
        for e in r.events {
            if o.raw {
                print("    @\(e.byteOffset) \(e.raw)")
            } else {
                let ty = e.parsedOK ? (e.lineType ?? "(no type)") : "MALFORMED"
                // Same summarizer the window uses (LiveEventRow.summarizeBlocks), so what
                // this CLI prints is literally what the UI renders — one code path, and
                // running `tail` is a real test of the GUI's transcript rendering.
                // Without it, every tool call prints as a blank line: the most common
                // line in a real transcript, showing nothing.
                let body: String
                if !e.text.isEmpty {
                    body = "  " + oneLine(e.text, 110)
                } else if let tool = LiveEventRow.summarizeBlocks(raw: e.raw) {
                    body = "  " + oneLine(tool, 110)
                } else {
                    body = ""
                }
                print("    @\(e.byteOffset) \(e.byteLength)B  \(ty.padding(toLength: max(ty.count, 12), withPad: " ", startingAt: 0))\(body)")
            }
        }
        fflush(stdout)
    }

    if o.once {
        w.runOnce()
        report(w)
        return
    }

    w.start()
    if o.forSeconds > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + o.forSeconds) {
            w.stop()
            report(w)
            exit(0)
        }
    }
    dispatchMain()
}

private func report(_ w: TailWatcher) {
    let s = w.stats
    err("""
        tail: stopped — ticks=\(s.ticks) rescans=\(s.rescans) files=\(s.filesFollowed) \
        bytes=\(s.bytesConsumed) lines=\(s.linesEmitted) malformed=\(s.linesMalformed) \
        partial-holdbacks=\(s.holdBacks) truncations=\(s.truncations)
        """)
}

// MARK: - Self test (no test target exists in Package.swift — this is the substitute)

/// Proves the properties that matter, against a file WE control so the assertions are
/// exact: partial trailing line held back, resumption at the exact byte, no-trailing-
/// newline behaviour, malformed-line survival, and truncation reset.
func runTailSelfTest() {
    var failures = 0
    func check(_ label: String, _ cond: Bool, _ detail: String = "") {
        if cond { print("  PASS  \(label)\(detail.isEmpty ? "" : "  — \(detail)")") }
        else { print("  FAIL  \(label)\(detail.isEmpty ? "" : "  — \(detail)")"); failures += 1 }
    }

    let dir = NSTemporaryDirectory() + "session-viewer-tailtest-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/live.jsonl"

    func write(_ s: String) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(s.data(using: .utf8)!); try? fh.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: s.data(using: .utf8))
        }
    }

    print("tail selftest — \(path)")

    let l1 = #"{"type":"user","timestamp":"2026-08-24T21:00:00Z","message":{"content":"hello one"}}"# + "\n"
    let l2 = #"{"type":"assistant","timestamp":"2026-08-24T21:00:01Z","message":{"content":[{"type":"text","text":"hi two"}]}}"# + "\n"
    let partialHead = #"{"type":"user","timestamp":"2026-08-24T21:00:02Z","messa"#
    let partialTail = #"ge":{"content":"third line, finished late"}}"# + "\n"

    write(l1); write(l2); write(partialHead)

    let t = SessionTailer(path: path, offset: 0)
    let r1 = try! t.read()

    check("complete lines parsed", r1.events.count == 2, "got \(r1.events.count)")
    check("PARTIAL LINE HELD BACK — not parsed",
          r1.heldBackBytes == partialHead.utf8.count,
          "held \(r1.heldBackBytes)B, partial is \(partialHead.utf8.count)B")
    check("offset stops at last newline",
          r1.newOffset == l1.utf8.count + l2.utf8.count,
          "newOffset=\(r1.newOffset) expected \(l1.utf8.count + l2.utf8.count)")
    check("no malformed event emitted for the partial",
          r1.events.allSatisfy { $0.parsedOK }, "")
    check("text extracted from both content shapes",
          r1.events.first?.text == "hello one" && r1.events.last?.text == "hi two",
          "[\(r1.events.first?.text ?? "")] [\(r1.events.last?.text ?? "")]")
    check("byte offsets are absolute and contiguous",
          r1.events.first?.byteOffset == 0 && r1.events.last?.byteOffset == l1.utf8.count, "")

    // Nothing new yet — a second read must be a no-op, and must still hold the partial.
    let r1b = try! t.read()
    check("re-read with no new bytes yields nothing",
          r1b.events.isEmpty && r1b.bytesConsumed == 0 && r1b.heldBackBytes == partialHead.utf8.count,
          "events=\(r1b.events.count) consumed=\(r1b.bytesConsumed) held=\(r1b.heldBackBytes)")

    // The writer finishes the line.
    write(partialTail)
    let r2 = try! t.read()
    check("the completed line arrives exactly once", r2.events.count == 1, "got \(r2.events.count)")
    check("it parses correctly once complete",
          r2.events.first?.parsedOK == true && r2.events.first?.text == "third line, finished late",
          "text=[\(r2.events.first?.text ?? "")]")
    check("it resumes at the held-back byte offset",
          r2.events.first?.byteOffset == l1.utf8.count + l2.utf8.count,
          "offset=\(r2.events.first?.byteOffset ?? -1)")

    // A genuinely malformed complete line is surfaced, not dropped, and does not stall.
    write("{ this is not json }\n")
    let r3 = try! t.read()
    check("malformed complete line surfaced as parsedOK=false",
          r3.events.count == 1 && r3.events.first?.parsedOK == false, "got \(r3.events.count)")

    // Truncation / replacement: size goes backward ⇒ restart at 0.
    try? "only-one\n".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    let r4 = try! t.read()
    check("shrunk file detected and restarted from 0",
          r4.truncated && r4.fromOffset == 0 && r4.events.count == 1,
          "truncated=\(r4.truncated) from=\(r4.fromOffset) events=\(r4.events.count)")

    // Leading-edge alignment.
    let aligned = SessionTailer.alignedOffset(path: path, approx: 3)
    check("alignedOffset snaps forward past the newline", aligned == "only-one\n".utf8.count,
          "aligned=\(aligned)")

    print(failures == 0 ? "tail selftest: ALL PASS" : "tail selftest: \(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
