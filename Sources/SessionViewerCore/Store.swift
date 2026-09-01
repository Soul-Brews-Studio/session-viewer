// Store.swift — all SQLite writes/reads. Kept separate from Ingest.swift (discovery)
// and the UI, so the future Bun/Drizzle ingest path can replace the WRITE side without
// touching discovery logic or the app.

import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension DB {
    /// Prepare a statement, returning nil rather than terminating the process on failure.
    ///
    /// This used to `fatalError`, on the reasoning that every SQL string here is a compiled
    /// constant so a prepare failure could only mean a typo — a programmer error worth
    /// crashing on. That reasoning was wrong about WHEN prepare fails. `sqlite3_prepare_v2`
    /// also fails for reasons that have nothing to do with the SQL text: SQLITE_BUSY under
    /// concurrent access, a schema that changed under an open handle, a table this db does
    /// not have yet. All three are RUNTIME conditions, all three are recoverable, and the
    /// app killed itself over one of them — a status read raced a project scan, prepare saw
    /// SQLITE_BUSY, and a window the user was using vanished.
    ///
    /// Now: log to stderr and return nil. Every `sqlite3_step`/`sqlite3_finalize` in this
    /// file already accepts an optional and treats nil as "no rows", so a failed prepare
    /// degrades to an empty result instead of a crash.
    ///
    /// The tradeoff is real and is accepted deliberately: an actual SQL typo now surfaces as
    /// an empty result plus a stderr line instead of an immediate abort. That is the same
    /// silent-empty-result shape this project has been bitten by before, which is why the
    /// message is loud and names the statement. Losing a result set is recoverable; losing
    /// the user's window is not.
    func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(handle))
            let firstLine = sql.split(whereSeparator: \.isNewline).first.map(String.init) ?? sql
            FileHandle.standardError.write(
                "sqlite prepare failed: \(msg)\n  statement: \(firstLine.prefix(120))\n"
                    .data(using: .utf8)!)
            return nil
        }
        return stmt
    }

    func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let v = value { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let v = value { sqlite3_bind_int64(stmt, idx, Int64(v)) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    var lastInsertId: Int { Int(sqlite3_last_insert_rowid(handle)) }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

// MARK: - Project upsert

/// Returns the project row's id, or nil when the database could not give one.
///
/// Optional is the point. This used to return `Int`, and when its INSERT failed it returned
/// `db.lastInsertId` — the id of the last insert that DID succeed, i.e. a different row.
/// The importer then wrote that project's sessions under it and counted them as imported.
/// Nothing detected it: foreign keys are OFF on these connections (schema.sql's
/// `PRAGMA foreign_keys = ON` is applied by `initSchema`, which nothing under Sources/
/// calls — measured `PRAGMA foreign_keys` = 0 on the real db), and a valid-but-wrong id
/// satisfies the constraint even when it is on.
///
/// Checked on the live 1039-session index before the fix: 0 orphans and 0 path/dirname
/// mismatches, so the bug was latent rather than triggered.
func upsertProject(db: DB, dirName: String, cwd: String?) -> Int? {
    guard let stmt = db.prepare(SQL.upsertProjectReturning) else { return nil }
    defer { sqlite3_finalize(stmt) }
    db.bindText(stmt, 1, dirName)
    db.bindText(stmt, 2, cwd)
    guard sqlite3_step(stmt) == SQLITE_ROW else {
        FileHandle.standardError.write(
            "upsertProject(\(dirName)) failed: \(db.lastErrorMessage)\n".data(using: .utf8)!)
        return nil
    }
    return Int(sqlite3_column_int64(stmt, 0))
}



// MARK: - Parsed session summary

struct ParsedSession {
    var lineCount = 0
    var eventCount = 0
    var startedAt: String?
    var endedAt: String?
    var cwd: String?
    var description: String?
    var typeCounts: [String: Int] = [:]
    var events: [(seq: Int, role: String, ts: String?, text: String)] = []
}

/// Thrown only for "the file itself couldn't be read" (missing, permission denied, …).
/// A malformed *line* inside a readable file is NOT this — see handleLine below, which
/// skips bad JSON per-line rather than failing the whole parse.
struct FileReadError: Error, CustomStringConvertible {
    let path: String
    var description: String { "cannot open file for reading: \(path)" }
}

/// Streams one .jsonl file line-by-line. Never loads the whole file — the p99 session
/// here is 39.6 MB and the max observed is the same, so a read-it-all approach would
/// stall the UI and balloon memory during a full import.
func parseSessionFile(path: String) throws -> ParsedSession {
    var out = ParsedSession()
    guard let fh = FileHandle(forReadingAtPath: path) else { throw FileReadError(path: path) }
    defer { try? fh.close() }

    var buffer = Data()
    let chunkSize = 1 << 20
    var seq = 0

    func handleLine(_ line: Data) {
        guard !line.isEmpty else { return }
        seq += 1
        out.lineCount += 1
        // A corrupt line is skipped, not fatal — real session files DO get truncated
        // mid-write. Fleet tooling treats "the tail parses" as something to check.
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        if let t = obj["type"] as? String {
            out.typeCounts[t, default: 0] += 1

            if let ts = obj["timestamp"] as? String {
                if out.startedAt == nil { out.startedAt = ts }
                out.endedAt = ts
            }
            if out.cwd == nil, let cwd = obj["cwd"] as? String { out.cwd = cwd }

            if CONVERSATIONAL_TYPES.contains(t) {
                out.eventCount += 1
                let text = extractText(from: obj)
                if !text.isEmpty {
                    out.events.append((seq: seq, role: t, ts: obj["timestamp"] as? String, text: text))
                    if out.description == nil, t == "user" {
                        out.description = String(text.prefix(200))
                    }
                }
            }
        }
    }

    while true {
        let chunk = fh.readData(ofLength: chunkSize)
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            handleLine(buffer[buffer.startIndex..<nl])
            buffer = buffer[buffer.index(after: nl)...]
        }
    }
    handleLine(buffer)   // trailing line with no newline
    return out
}

/// Message content is either a plain string or an array of typed blocks — both shapes
/// occur in real files, so handle both rather than assuming one.
func extractText(from obj: [String: Any]) -> String {
    guard let message = obj["message"] as? [String: Any] else { return "" }
    if let s = message["content"] as? String { return s }
    guard let blocks = message["content"] as? [[String: Any]] else { return "" }
    return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
}

// MARK: - Import one file

/// Attempts the real import; returns false on the two failure modes the caller cares
/// about: the file couldn't be read, or a write to the db was rejected (constraint
/// violation, disk full, …). Every prepared statement below is finalized on every exit
/// path, success or failure — this is written to a `failure` flag rather than
/// early-returning mid-transaction so the tail (finalize + failure recording) always runs.
///
/// It is NOT crash-free, and an earlier version of this comment claimed it was. `db.prepare`
/// calls `fatalError` on a bad statement (Store.swift:13) and is called several times below,
/// so malformed SQL still aborts the process. That is deliberate — SQL text here is a
/// compile-time constant, so a prepare failure is a programming error that should be loud,
/// not a runtime condition to recover from. Bad *data* returns false; bad *code* crashes.
/// Parse a Claude Code file, then write it. Split so a second SOURCE can reuse the writer:
/// Codex rollouts have an entirely different line shape but produce the same ParsedSession,
/// and duplicating the write half would give the two sources two chances to disagree about
/// what a stored session is.
func importFile(db: DB, file: DiscoveredFile, projectId: Int, existingId: Int?) -> Bool {
    let parsed: ParsedSession
    do {
        parsed = try parseSessionFile(path: file.path)
    } catch {
        recordImportFailure(db: db, file: file, projectId: projectId, existingId: existingId,
                             error: "\(error)")
        return false
    }
    return importParsed(db: db, file: file, parsed: parsed,
                        projectId: projectId, existingId: existingId)
}

/// Write an already-parsed session. Source-agnostic.
func importParsed(db: DB, file: DiscoveredFile, parsed: ParsedSession,
                  projectId: Int, existingId: Int?) -> Bool {

    // SPEC.md: a project's real path comes from the file's own `cwd` field, never from
    // decoding the directory name (that encoding maps both `/` and `.` to `-`, so it is
    // lossy and ambiguous in both directions). It can only be filled HERE, not at
    // upsertProject time, because cwd is not known until the file is parsed. The SQL uses
    // COALESCE, so the first file to report a cwd wins and later files that lack the field
    // (subagent transcripts often do) cannot clobber a known-good path back to NULL.
    if let cwd = parsed.cwd {
        let upd = db.prepare(SQL.updateProjectCwd)
        db.bindText(upd, 1, cwd)
        db.bindInt(upd, 2, projectId)
        sqlite3_step(upd)
        sqlite3_finalize(upd)
    }

    var sessionId = existingId ?? -1
    var failure: String? = nil

    if let id = existingId {
        let upd = db.prepare(SQL.updateSession)
        db.bindInt(upd, 1, file.mtime); db.bindInt(upd, 2, file.size)
        db.bindInt(upd, 3, parsed.lineCount); db.bindInt(upd, 4, parsed.eventCount)
        db.bindText(upd, 5, parsed.startedAt); db.bindText(upd, 6, parsed.endedAt)
        db.bindText(upd, 7, parsed.description); db.bindInt(upd, 8, id)
        if sqlite3_step(upd) != SQLITE_DONE {
            failure = "session update failed: \(db.lastErrorMessage)"
        }
        sqlite3_finalize(upd)
    } else {
        let ins = db.prepare(SQL.insertSession)
        db.bindInt(ins, 1, projectId); db.bindText(ins, 2, file.sessionUUID)
        db.bindText(ins, 3, file.path); db.bindText(ins, 4, file.tier)
        db.bindText(ins, 5, file.workflowRunId); db.bindText(ins, 6, file.agentId)
        db.bindInt(ins, 7, file.mtime); db.bindInt(ins, 8, file.size)
        db.bindInt(ins, 9, parsed.lineCount); db.bindInt(ins, 10, parsed.eventCount)
        db.bindText(ins, 11, parsed.startedAt); db.bindText(ins, 12, parsed.endedAt)
        db.bindText(ins, 13, parsed.description)
        if sqlite3_step(ins) != SQLITE_DONE {
            failure = "session insert failed: \(db.lastErrorMessage)"
        } else {
            sessionId = db.lastInsertId
        }
        sqlite3_finalize(ins)
    }

    if let failure {
        recordImportFailure(db: db, file: file, projectId: projectId, existingId: existingId,
                             error: failure)
        return false
    }

    if existingId != nil {
        let delTC = db.prepare(SQL.deleteTypeCountsForSession)
        db.bindInt(delTC, 1, sessionId)
        if sqlite3_step(delTC) != SQLITE_DONE {
            failure = "session_type_counts delete failed: \(db.lastErrorMessage)"
        }
        sqlite3_finalize(delTC)

        if failure == nil {
            let delFTS = db.prepare(SQL.deleteEventsFtsForSession)
            db.bindInt(delFTS, 1, sessionId)
            if sqlite3_step(delFTS) != SQLITE_DONE {
                failure = "events_fts delete failed: \(db.lastErrorMessage)"
            }
            sqlite3_finalize(delFTS)

            // The trigram twin is cleared in the SAME branch. Clearing one index and not
            // the other would leave a re-imported session double-counted in whichever
            // survived — and the two would then disagree about what the file contains,
            // which is the failure mode this project exists to avoid.
            let delTri = db.prepare(SQL.deleteEventsFtsTriForSession)
            db.bindInt(delTri, 1, sessionId)
            if sqlite3_step(delTri) != SQLITE_DONE {
                failure = "events_fts_tri delete failed: \(db.lastErrorMessage)"
            }
            sqlite3_finalize(delTri)
        }

        if let failure {
            recordImportFailure(db: db, file: file, projectId: projectId, existingId: existingId,
                                 error: failure)
            return false
        }
    }

    let tc = db.prepare(SQL.insertTypeCount)
    for (type, count) in parsed.typeCounts {
        sqlite3_reset(tc)
        db.bindInt(tc, 1, sessionId); db.bindText(tc, 2, type); db.bindInt(tc, 3, count)
        if sqlite3_step(tc) != SQLITE_DONE {
            failure = "session_type_counts insert failed (type=\(type)): \(db.lastErrorMessage)"
            break
        }
    }
    sqlite3_finalize(tc)

    if failure == nil {
        // Both indexes written in ONE pass over the events. Two passes would double the
        // walk for no benefit, and — more importantly — could not fail atomically together.
        let fts = db.prepare(SQL.insertEventFts)
        let tri = db.prepare(SQL.insertEventFtsTri)
        for e in parsed.events {
            sqlite3_reset(fts)
            db.bindInt(fts, 1, sessionId); db.bindInt(fts, 2, e.seq)
            db.bindText(fts, 3, e.role); db.bindText(fts, 4, e.ts); db.bindText(fts, 5, e.text)
            if sqlite3_step(fts) != SQLITE_DONE {
                failure = "events_fts insert failed (seq=\(e.seq)): \(db.lastErrorMessage)"
                break
            }
            sqlite3_reset(tri)
            db.bindInt(tri, 1, sessionId); db.bindInt(tri, 2, e.seq)
            db.bindText(tri, 3, e.role); db.bindText(tri, 4, e.ts); db.bindText(tri, 5, e.text)
            if sqlite3_step(tri) != SQLITE_DONE {
                failure = "events_fts_tri insert failed (seq=\(e.seq)): \(db.lastErrorMessage)"
                break
            }
        }
        sqlite3_finalize(fts)
        sqlite3_finalize(tri)
    }

    if let failure {
        recordImportFailure(db: db, file: file, projectId: projectId, existingId: existingId,
                             error: failure)
        return false
    }

    return true
}

/// Marks a file's import as failed instead of leaving stale or half-written data behind.
/// Two shapes: an existing row is updated in place; a brand-new file that failed before
/// its `sessions` row could even be created gets a minimal failed row so the failure is
/// visible in `import_status`/`import_error` rather than silently vanishing (the file
/// would otherwise look "new" again on the next diff and fail identically forever).
/// ON CONFLICT guards the same race the original code didn't: `file_path` is UNIQUE, so
/// if a row already exists there under the "new" branch, this still records the failure
/// instead of crashing the whole import via db.prepare's fatalError-on-bad-SQL path.
func recordImportFailure(db: DB, file: DiscoveredFile, projectId: Int, existingId: Int?, error: String) {
    if let id = existingId {
        let upd = db.prepare(SQL.updateSessionFailed)
        db.bindInt(upd, 1, file.mtime); db.bindInt(upd, 2, file.size)
        db.bindText(upd, 3, error); db.bindInt(upd, 4, id)
        sqlite3_step(upd)
        sqlite3_finalize(upd)
    } else {
        let ins = db.prepare(SQL.insertSessionFailed)
        db.bindInt(ins, 1, projectId); db.bindText(ins, 2, file.sessionUUID)
        db.bindText(ins, 3, file.path); db.bindText(ins, 4, file.tier)
        db.bindText(ins, 5, file.workflowRunId); db.bindText(ins, 6, file.agentId)
        db.bindInt(ins, 7, file.mtime); db.bindInt(ins, 8, file.size)
        db.bindText(ins, 9, error)
        sqlite3_step(ins)
        sqlite3_finalize(ins)
    }
}

func existingSessionId(db: DB, path: String) -> Int? {
    let sel = db.prepare(SQL.selectSessionIdByPath)
    db.bindText(sel, 1, path)
    var id: Int? = nil
    if sqlite3_step(sel) == SQLITE_ROW { id = Int(sqlite3_column_int64(sel, 0)) }
    sqlite3_finalize(sel)
    return id
}

// MARK: - Read side (used by the SwiftUI app)

struct SessionRow: Identifiable {
    let id: Int
    let uuid: String
    let tier: String
    let project: String
    let path: String
    let size: Int
    let lineCount: Int
    let eventCount: Int
    let startedAt: String?
    let description: String?
    /// Which tool wrote this transcript — 'claude' or 'codex'. Carried into the list
    /// because with both sources imported, a row's tier no longer identifies it: a Codex
    /// rollout and a Claude session are both `file_tier = 'session'`.
    let source: String

    /// file mtime, unix epoch — the DEFAULT sort key, so the UI can actually show the
    /// column it is sorted by (it previously sorted on this and displayed startedAt).
    let mtime: Int
}

/// The sorted session list.
///
/// `sort`/`direction` are enums, NOT strings, and that is a correctness requirement, not
/// a style choice: SQLite cannot bind an ORDER BY column, so the column name is
/// interpolated into the SQL text by `SQL.selectSessionsOrderLimit`. The closed
/// `SessionSort`/`SortDirection` allow-list is the only thing standing between that
/// interpolation and a SQL injection — see the big comment in SQL.swift. Do not widen
/// these parameters to `String`.
///
/// `tier` and `limit` are ordinary bound parameters (`?`) — only the sort is special.
/// Add `sessions.source` to a database created before that column existed.
///
/// `schema.sql` declares it now, but `CREATE TABLE IF NOT EXISTS` does NOT alter a table
/// that already exists — so re-running the schema over an older `.data/sessions.db` leaves
/// it without the column, and every session query selects `s.source`. The failure is the
/// nasty kind: `prepare` returns nil, `fetchSessions` returns `[]`, and the All tab renders
/// an empty list that looks exactly like an empty index rather than a broken query.
///
/// SQLite has no `ADD COLUMN IF NOT EXISTS`, so the duplicate-column error on an
/// already-migrated db is the expected path and is discarded. Guarded to once per process
/// because it is a write, and the common case is that there is nothing to do.
private var didEnsureSessionSource = false
private let ensureSourceLock = NSLock()
func ensureSessionSource(db: DB) {
    ensureSourceLock.lock()
    defer { ensureSourceLock.unlock() }
    guard !didEnsureSessionSource else { return }
    didEnsureSessionSource = true
    _ = db.exec(SQL.addSessionSourceColumn)
}

/// Total rows in `sessions`, ignoring every filter and LIMIT.
///
/// This exists so a paged list can say "showing 500 of 1,891" instead of "500 sessions" —
/// the latter states a total it does not have, which is the same silent under-reporting
/// this tool was built to expose in other people's session tooling.
func countSessions(db: DB) -> Int? {
    guard let st = db.prepare(SQL.countSessions) else { return nil }
    defer { sqlite3_finalize(st) }
    guard sqlite3_step(st) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(st, 0))
}

/// `since` is an epoch lower bound on file mtime — "active in the last N" — parsed from
/// the user's window by `parseSinceWindow`. Mtime, not started_at: a session that started
/// yesterday and is still being written IS active now, and started_at would hide it.
func fetchSessions(db: DB,
                   tier: String? = nil,
                   sort: SessionSort = .mtime,
                   direction: SortDirection = .desc,
                   since: Int? = nil,
                   limit: Int = 500) -> [SessionRow] {
    ensureSessionSource(db: db)
    var sql = SQL.selectSessionsBase
    var filters: [String] = []
    if tier != nil { filters.append(SQL.sessionsTierFragment) }
    if since != nil { filters.append(SQL.sessionsSinceFragment) }
    if !filters.isEmpty { sql += " WHERE " + filters.joined(separator: " AND ") }
    sql += SQL.selectSessionsOrderLimit(sort, direction)

    let stmt = db.prepare(sql)
    var idx: Int32 = 1
    if let tier { db.bindText(stmt, idx, tier); idx += 1 }
    if let since { db.bindInt(stmt, idx, since); idx += 1 }
    db.bindInt(stmt, idx, limit)

    var rows: [SessionRow] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func str(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        rows.append(SessionRow(
            id: Int(sqlite3_column_int64(stmt, 0)),
            uuid: str(1) ?? "",
            tier: str(2) ?? "",
            project: str(3) ?? "",
            path: str(4) ?? "",
            size: Int(sqlite3_column_int64(stmt, 5)),
            lineCount: Int(sqlite3_column_int64(stmt, 6)),
            eventCount: Int(sqlite3_column_int64(stmt, 7)),
            startedAt: str(8),
            description: str(9),
            source: str(11) ?? "claude",
            mtime: Int(sqlite3_column_int64(stmt, 10))))
    }
    sqlite3_finalize(stmt)
    return rows
}

/// Per-line-type counts for one session, from session_type_counts — the ~14-types
/// breakdown (SPEC.md), not the 3 conversational roles events_fts indexes.
struct TypeCount: Identifiable {
    let lineType: String
    let count: Int
    var id: String { lineType }
}

func fetchTypeCounts(db: DB, sessionId: Int) -> [TypeCount] {
    let stmt = db.prepare(SQL.selectTypeCountsForSession)
    db.bindInt(stmt, 1, sessionId)

    var rows: [TypeCount] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let c = sqlite3_column_text(stmt, 0) else { continue }
        rows.append(TypeCount(lineType: String(cString: c), count: Int(sqlite3_column_int64(stmt, 1))))
    }
    sqlite3_finalize(stmt)
    return rows
}

/// Fetch a single session by id, independent of the current tier filter — used when a
/// search hit (which may belong to a tier the sidebar list isn't currently showing) is
/// clicked, so selecting it can still populate the detail pane.
func fetchSession(db: DB, id: Int) -> SessionRow? {
    ensureSessionSource(db: db)
    let stmt = db.prepare(SQL.selectSessionById)
    db.bindInt(stmt, 1, id)

    var row: SessionRow? = nil
    if sqlite3_step(stmt) == SQLITE_ROW {
        func str(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        row = SessionRow(
            id: Int(sqlite3_column_int64(stmt, 0)),
            uuid: str(1) ?? "",
            tier: str(2) ?? "",
            project: str(3) ?? "",
            path: str(4) ?? "",
            size: Int(sqlite3_column_int64(stmt, 5)),
            lineCount: Int(sqlite3_column_int64(stmt, 6)),
            eventCount: Int(sqlite3_column_int64(stmt, 7)),
            startedAt: str(8),
            description: str(9),
            source: str(11) ?? "claude",
            mtime: Int(sqlite3_column_int64(stmt, 10)))
    }
    sqlite3_finalize(stmt)
    return row
}

struct SearchHit: Identifiable {
    let id = UUID()
    let sessionId: Int
    let uuid: String
    let role: String
    let ts: String?
    let snippet: String

    /// Relevance. bm25 for keyword hits, cosine for semantic ones.
    ///
    /// Carried because the SPREAD of these numbers is diagnostic, not decorative: a flat
    /// spread means the query is not discriminating and the order on screen is close to
    /// arbitrary. That is exactly the signal that exposed the semantic index's failure
    /// (top-8 spanning 0.01) and it is why `the` — which scores 0.0 flat — is visibly
    /// different from `crash`, which spans -9.0 to -7.9.
    var score: Double = 0

    /// Line number within its session. Carried so a hit can be READ IN CONTEXT — without it
    /// a search result is a dead end, and reading around a hit was the single biggest thing
    /// this index could not do.
    var seq: Int = 0

    /// bm25 returns MORE NEGATIVE for a better match, cosine returns higher-is-better.
    /// One accessor so the UI never has to remember which engine produced a row.
    var strength: Double { score < 0 ? -score : score }
}

/// Turn arbitrary human input into a valid FTS5 MATCH expression.
///
/// FTS5's MATCH argument is its own query LANGUAGE, not a search string: bare `-`, `:`,
/// `*`, `^`, `AND/OR/NOT` and parentheses are operators. Typing `append-only` in the
/// search box parsed as a column reference and failed with `no such column: only`.
/// That failure was INVISIBLE — the error surfaces at `sqlite3_step`, which the loop below
/// reads as "no more rows", so the user saw an empty result set and concluded nothing
/// matched. A silent wrong answer, not an error.
///
/// Fix: quote every whitespace-separated token, so each is a literal phrase and the whole
/// thing is an implicit AND. `"` is the only character that needs escaping inside an FTS5
/// string, by doubling. This deliberately gives up operator support from the box — a
/// literal search that always works beats a query language that fails silently.
/// The LAST token is a PREFIX match, earlier tokens are exact phrases.
///
/// Why: a quoted FTS5 phrase only matches a WHOLE token, so typing `9c` looking for
/// session `9cda6f37` returned "no matches" — the search looked broken while working
/// exactly as written. Every incremental search UI (Spotlight, fuzzy finders, browser
/// address bars) treats what you are still typing as a prefix, because you have not
/// finished the word yet. `9c` → `"9c"*` now finds `9cda6f37`.
///
/// Only the last token gets `*`: `byte off` should mean "the word byte, and something
/// starting with off", not "anything starting with byte".
func ftsQuery(_ raw: String) -> String {
    let tokens = raw.split(whereSeparator: { $0.isWhitespace })
    guard !tokens.isEmpty else { return "\"\"" }
    let quoted = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    return (quoted.dropLast() + [quoted[quoted.count - 1] + "*"]).joined(separator: " ")
}

/// FTS5 query text for the TRIGRAM index.
///
/// Same quoting discipline as `ftsQuery` — every token wrapped so that `-`, `.`, `/` and
/// friends are data rather than FTS5 operators (the `append-only` bug: an unquoted hyphen
/// parsed as NOT, failed at `sqlite3_step`, and the row loop read the error as "no rows",
/// so search silently returned nothing).
///
/// The ONE difference from `ftsQuery` is the deliberate absence of a trailing `*`. On a
/// token index a prefix wildcard is what lets `9c` reach `9cda6f37`; on a trigram index
/// substring matching is already the default, and the wildcard instead matches any document
/// containing a trigram with that prefix — measured `"work"*` = 4527 rows against a truth
/// of 771. Adding it here would trade a recall problem for a precision problem.
func trigramQuery(_ raw: String) -> String {
    let tokens = raw.split(whereSeparator: { $0.isWhitespace })
    guard !tokens.isEmpty else { return "\"\"" }
    return tokens
        .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        .joined(separator: " ")
}

/// Shortest query the trigram index can answer. FTS5's trigram tokenizer indexes 3-char
/// sequences, so a 1- or 2-character needle has no trigram to match and returns ZERO —
/// measured: `9c` against trigram = 0 rows, against unicode61-with-prefix = 3.
let TRIGRAM_MIN_CHARS = 3

/// Which index answers a query.
///
/// Trigram wherever it can (measured 100% recall on both Thai and English, against 1–97%
/// for unicode61), unicode61 for needles too short for a trigram to exist. This is not a
/// hedge: each index is genuinely unable to serve the other's case.
///
/// Note that the `*` prefix wildcard is applied ONLY on the unicode61 path. It exists to
/// make token-based matching find `9cda6f37` from `9c`; trigram already matches substrings
/// natively, and adding the wildcard there over-matches badly — `"work"*` returned 4527
/// rows against a ground truth of 771.
func usesTrigram(_ query: String) -> Bool {
    query.trimmingCharacters(in: .whitespaces).count >= TRIGRAM_MIN_CHARS
}

/// Search with the narrowing a real dig needs: project, tier, and a time window.
///
/// Over 1039 sessions an unfiltered query is often the wrong tool — "when did we discuss X
/// in THIS repo, last week" is the actual question, and without filters the answer is a
/// hundred hits across every project on the machine.
func searchEventsFiltered(db: DB, query: String, project: String?, tier: String?,
                          since: String?, until: String?, limit: Int) -> [SearchHit] {
    let trigram = usesTrigram(query)
    var sql = trigram ? SQL.searchEventsTriBase : SQL.searchEventsBase
    // Fragments are fixed literals selected by a Bool; every VALUE is bound below.
    if project != nil { sql += " AND (p.cwd LIKE ? OR p.dir_name LIKE ?)" }
    if tier != nil    { sql += " AND s.file_tier = ?" }
    if since != nil   { sql += " AND s.started_at >= ?" }
    if until != nil   { sql += " AND s.started_at <= ?" }
    sql += trigram ? " ORDER BY bm25(events_fts_tri) LIMIT ?" : " ORDER BY bm25(events_fts) LIMIT ?"

    guard let stmt = db.prepare(sql) else { return [] }
    var i: Int32 = 1
    db.bindText(stmt, i, trigram ? trigramQuery(query) : ftsQuery(query)); i += 1
    if let project { db.bindText(stmt, i, "%\(project)%"); i += 1
                     db.bindText(stmt, i, "%\(project)%"); i += 1 }
    if let tier    { db.bindText(stmt, i, tier); i += 1 }
    if let since   { db.bindText(stmt, i, since); i += 1 }
    if let until   { db.bindText(stmt, i, until); i += 1 }
    db.bindInt(stmt, i, limit)

    var hits: [SearchHit] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func str(_ n: Int32) -> String? {
            sqlite3_column_text(stmt, n).map { String(cString: $0) }
        }
        hits.append(SearchHit(sessionId: Int(sqlite3_column_int64(stmt, 0)),
                              uuid: str(1) ?? "", role: str(2) ?? "", ts: str(3),
                              snippet: str(4) ?? "",
                              score: sqlite3_column_double(stmt, 5),
                              seq: Int(sqlite3_column_int64(stmt, 6))))
    }
    sqlite3_finalize(stmt)
    return hits
}

func searchEvents(db: DB, query: String, limit: Int = 200) -> [SearchHit] {
    let trigram = usesTrigram(query)
    let stmt = db.prepare(trigram ? SQL.searchEventsTri : SQL.searchEvents)
    db.bindText(stmt, 1, trigram ? trigramQuery(query) : ftsQuery(query))
    db.bindInt(stmt, 2, limit)

    var hits: [SearchHit] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func str(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        hits.append(SearchHit(
            sessionId: Int(sqlite3_column_int64(stmt, 0)),
            uuid: str(1) ?? "", role: str(2) ?? "",
            ts: str(3), snippet: str(4) ?? "",
            score: sqlite3_column_double(stmt, 5)))
    }
    sqlite3_finalize(stmt)
    return hits
}

// MARK: - search log

public struct SearchLogRow: Identifiable {
    public let id: Int
    public let ts: String
    public let query: String
    public let engine: String
    public let model: String
    public let hits: Int
    public let ms: Double
    public let topScore: Double
    public let spread: Double

    /// A result set whose scores are all within a hair of each other could not rank what it
    /// returned. Recorded so the condition is reviewable later, not only noticed live.
    public var flat: Bool { hits > 1 && abs(topScore) > 0 && (spread / abs(topScore)) < 0.05 }
}

/// Record one search. Failure here must never break the search itself — a log is an
/// observation, not a dependency, so every step is best-effort and errors are dropped.
func logSearch(dbPath: String, query: String, engine: String, model: String?,
               hits: [SearchHit], ms: Double) {
    let db = DB(path: dbPath)
    db.exec(SQL.createSearchLog)
    guard let s = db.prepare(SQL.insertSearchLog) else { return }
    defer { sqlite3_finalize(s) }

    let strengths = hits.map(\.strength)
    let top = strengths.max() ?? 0
    let spread = (strengths.max() ?? 0) - (strengths.min() ?? 0)

    db.bindText(s, 1, query)
    db.bindText(s, 2, engine)
    db.bindText(s, 3, model)
    db.bindInt(s, 4, hits.count)
    sqlite3_bind_double(s, 5, ms)
    sqlite3_bind_double(s, 6, top)
    sqlite3_bind_double(s, 7, spread)
    sqlite3_step(s)
}

public func readSearchLog(dbPath: String, limit: Int = 50) -> [SearchLogRow] {
    guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
    let db = DB(path: dbPath)
    db.exec(SQL.createSearchLog)
    guard let s = db.prepare(SQL.selectSearchLog) else { return [] }
    db.bindInt(s, 1, limit)
    var out: [SearchLogRow] = []
    while sqlite3_step(s) == SQLITE_ROW {
        func txt(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        out.append(SearchLogRow(id: Int(sqlite3_column_int64(s, 0)), ts: txt(1), query: txt(2),
                                engine: txt(3), model: txt(4),
                                hits: Int(sqlite3_column_int64(s, 5)),
                                ms: sqlite3_column_double(s, 6),
                                topScore: sqlite3_column_double(s, 7),
                                spread: sqlite3_column_double(s, 8)))
    }
    sqlite3_finalize(s)
    return out
}

/// `session-viewer searches` — the log as text.
public func runSearchLogCLI(dbPath: String, limit: Int) {
    let rows = readSearchLog(dbPath: dbPath, limit: limit)
    guard !rows.isEmpty else { print("no searches logged yet"); return }
    print("  " + padR("when", 21) + padR("query", 34) + padR("engine", 11)
          + padL("hits", 6) + padL("ms", 8) + "  flags")
    for r in rows {
        print("  " + padR(r.ts, 21)
                  + padR(String(r.query.prefix(32)), 34)
                  + padR(r.engine, 11)
                  + padL(String(r.hits), 6)
                  + padL(String(format: "%.0f", r.ms), 8)
                  + (r.hits == 0 ? "  EMPTY" : "") + (r.flat ? "  FLAT" : ""))
    }
    let empties = rows.filter { $0.hits == 0 }.count
    let flats = rows.filter { $0.flat }.count
    print("")
    print("  \(rows.count) searches · \(empties) returned nothing · \(flats) could not rank what they returned")
}
