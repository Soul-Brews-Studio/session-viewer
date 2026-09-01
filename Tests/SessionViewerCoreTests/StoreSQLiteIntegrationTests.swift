// StoreSQLiteIntegrationTests.swift — DB integration tests against a real SQLite file.
//
// EVERY test here builds its own SQLite file under FileManager.default.temporaryDirectory
// and deletes it afterwards. The real index at `.data/sessions.db` is USER DATA (1000+
// imported transcripts, ~10 min to rebuild) and is never opened, read, or written by this
// file — `makeTempDB` asserts the path it was handed actually lives under the temp dir, so
// a future edit that points a test at the real db fails loudly instead of mutating it.
//
// These are integration tests on purpose: the bugs this file exists to catch (a silent
// zero-row FTS5 answer, an import that reports success on an unreadable file, an ORDER BY
// that silently sorts nothing) are all invisible to a unit test of the Swift function —
// they only appear once real SQLite is on the other end.

import Foundation
import SQLite3
import Testing

@testable import SessionViewerCore

// MARK: - temp sandbox

/// `sqlite3_bind_text` needs SQLITE_TRANSIENT (sqlite copies the bytes). Defined locally
/// rather than reusing the module's so these helpers stand alone if the app's moves.
private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The package root, derived from this file's own location — no bundle resources, no cwd
/// assumption. `swift test` runs with an unspecified working directory, so a relative
/// "schema.sql" would be a coin flip.
private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)          // …/Tests/SessionViewerCoreTests/<this file>
        .deletingLastPathComponent()          // …/Tests/SessionViewerCoreTests
        .deletingLastPathComponent()          // …/Tests
        .deletingLastPathComponent()          // package root
}

private var schemaPath: String { packageRoot.appendingPathComponent("schema.sql").path }

/// One disposable directory per test. `cleanup()` is called from a `defer` in every test.
///
/// A CLASS, not a struct, because it owns the SQLite connections opened inside it and has
/// to close them before deleting the directory. That ordering is not a nicety — it was a
/// real defect found by counting what the suite left behind:
///
///   a lone `defer` calling cleanup runs at scope exit while the test's `DB` is still
///   alive (ARC has not released it yet, so `DB.deinit`'s `sqlite3_close` has not run).
///   `removeItem` then unlinks `test.db` out from under a live connection, that connection
///   immediately writes a `test.db-journal` back into the directory, and the final `rmdir`
///   fails with ENOTEMPTY. The call is `try?`, so the failure is silent — the suite passes
///   green while leaving a directory per test behind. 43 of them had accumulated in the
///   system temp dir before anyone looked.
///
/// Closing first makes the delete unambiguous. `verifyCleanupHappened` then asserts it,
/// because "cleanup is written" and "cleanup works" are the same distinction this whole
/// suite exists to police.
private final class TempDir {
    let url: URL
    private var openDBs: [DB] = []

    init(_ label: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-viewer-tests-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ component: String) -> String {
        url.appendingPathComponent(component).path
    }

    /// Hands a connection to the sandbox so `cleanup()` can close it at the right moment.
    @discardableResult
    func adopt(_ db: DB) -> DB {
        openDBs.append(db)
        return db
    }

    func cleanup() {
        // 1. Close every connection this sandbox handed out, BEFORE touching the files.
        //    `handle` is set to nil so `DB.deinit`'s own `sqlite3_close` becomes a no-op
        //    (sqlite3_close(nil) is defined to return SQLITE_OK) rather than a double close.
        for db in openDBs {
            sqlite3_close(db.handle)
            db.handle = nil
        }
        openDBs.removeAll()

        // 2. A test may have chmod'ed a fixture to 000; restore so the delete can proceed.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for i in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: url.appendingPathComponent(i).path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Asserts the directory is actually gone. Called from a second `defer` so it runs
    /// AFTER `cleanup()` (defers unwind in reverse order of registration).
    func verifyCleanupHappened() {
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "temp dir survived cleanup: \(url.path)")
    }
}

/// Opens a fresh db in `dir` and applies schema.sql through the PRODUCTION `initSchema`
/// path, after asserting the file really is disposable.
private func makeTempDB(_ dir: TempDir, _ name: String = "test.db") -> DB {
    let dbPath = dir.path(name)
    let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    // The guard that keeps a test from ever touching .data/sessions.db.
    #expect(URL(fileURLWithPath: dbPath).resolvingSymlinksInPath().path.hasPrefix(tempRoot),
            "refusing to run against a db outside the temp dir: \(dbPath)")
    #expect(!dbPath.contains(".data"), "refusing to run against the real index")

    let db = DB(path: dbPath)
    initSchema(db: db, schemaPath: schemaPath)
    return dir.adopt(db)
}

// MARK: - raw SQLite probes
//
// Deliberately NOT `db.prepare` — that calls fatalError on a bad statement, which would
// abort the whole test process instead of failing one test. These return errors as values
// so "did this statement fail?" is itself assertable.

private func queryStrings(_ db: DB, _ sql: String) -> [String] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var out: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
    }
    return out
}

private func scalarInt(_ db: DB, _ sql: String) -> Int? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(stmt, 0))
}

private func tableNames(_ db: DB) -> Set<String> {
    Set(queryStrings(db, "SELECT name FROM sqlite_master WHERE type='table'"))
}

/// Applies schema.sql WITHOUT fatalError, so "no such module: fts5" becomes a readable
/// test failure rather than a process abort. Returns the sqlite error message, or nil.
private func applySchemaSafely(_ db: DB, _ path: String) -> String? {
    guard let sql = try? String(contentsOfFile: path, encoding: .utf8) else {
        return "cannot read schema at \(path)"
    }
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db.handle, sql, nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown error"
        sqlite3_free(err)
        return msg
    }
    return nil
}

/// Runs a MATCH expression straight against events_fts and reports BOTH the row count and
/// any sqlite error. This is the probe that makes the "silent zero" bug visible: the app's
/// row loop treats a step error as end-of-rows, so without capturing the error a failed
/// query and an empty result are indistinguishable — which is exactly how `append-only`
/// shipped looking like "no matches".
private func rawMatch(_ db: DB, _ expr: String) -> (rows: Int, error: String?) {
    var stmt: OpaquePointer?
    let sql = "SELECT count(*) FROM events_fts WHERE events_fts MATCH ?"
    guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else {
        return (0, String(cString: sqlite3_errmsg(db.handle)))
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, expr, -1, TRANSIENT)
    if sqlite3_step(stmt) == SQLITE_ROW { return (Int(sqlite3_column_int64(stmt, 0)), nil) }
    return (0, String(cString: sqlite3_errmsg(db.handle)))
}

// MARK: - jsonl fixtures

private func jsonLine(_ obj: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
    return String(data: data, encoding: .utf8)!
}

/// `message.content` as a plain STRING — one of the two real shapes in the corpus.
private func userLine(_ text: String, ts: String, cwd: String? = nil) -> String {
    var obj: [String: Any] = ["type": "user", "timestamp": ts,
                              "message": ["role": "user", "content": text]]
    if let cwd { obj["cwd"] = cwd }
    return jsonLine(obj)
}

/// `message.content` as an ARRAY of typed blocks — the other real shape.
private func assistantLine(_ text: String, ts: String) -> String {
    jsonLine(["type": "assistant", "timestamp": ts,
              "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}

/// A non-conversational line — counted in session_type_counts, never indexed in FTS.
private func stateLine(_ type: String, ts: String) -> String {
    jsonLine(["type": type, "timestamp": ts])
}

/// Writes raw bytes so a test can control the FINAL byte — whether the file ends in a
/// newline is the whole point of one of the tests below, so `joined(separator:)` plus an
/// explicit flag, never a helper that appends one for you.
private func writeRaw(_ path: String, _ contents: String) throws {
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

private func writeJSONL(_ path: String, _ lines: [String], trailingNewline: Bool = true) throws {
    try writeRaw(path, lines.joined(separator: "\n") + (trailingNewline ? "\n" : ""))
}

private func discovered(path: String,
                        uuid: String,
                        tier: String = "session",
                        projectDir: String = "-tmp-session-viewer-test") -> DiscoveredFile {
    let st = statFile(path) ?? (mtime: 0, size: 0)
    return DiscoveredFile(path: path, projectDirName: projectDir, tier: tier,
                          sessionUUID: uuid, agentId: nil, workflowRunId: nil,
                          mtime: st.mtime, size: st.size)
}

/// Import one on-disk file through the real code path (upsertProject → importFile).
@discardableResult
private func importOne(_ db: DB, _ file: DiscoveredFile) -> Bool {
    let projectId = upsertProject(db: db, dirName: file.projectDirName, cwd: nil)!
    let existing = existingSessionId(db: db, path: file.path)
    return importFile(db: db, file: file, projectId: projectId, existingId: existing)
}

// MARK: - sort fixtures

/// One row's worth of controlled values. Every sortable column gets a DISTINCT value
/// (except `tier`, where duplicates are the point — they exercise the `s.id DESC`
/// tiebreaker), so a sort that silently did nothing cannot pass by accident.
private struct SortFixture {
    let id: Int
    let projectDir: String
    let projectCwd: String
    let uuid: String
    let tier: String
    let description: String
    let events: Int
    let lines: Int
    let size: Int
    let started: String
    let mtime: Int
}

private let sortFixtures: [SortFixture] = [
    SortFixture(id: 1, projectDir: "-a-alpha", projectCwd: "/a/alpha", uuid: "uuid-1",
                tier: "session",        description: "b second description",
                events: 30, lines: 300, size: 3_000, started: "2026-08-24t03:00:00z", mtime: 1_700_000_300),
    SortFixture(id: 2, projectDir: "-b-bravo", projectCwd: "/b/bravo", uuid: "uuid-2",
                tier: "workflow_agent", description: "f sixth description",
                events: 60, lines: 600, size: 6_000, started: "2026-08-24t06:00:00z", mtime: 1_700_000_600),
    SortFixture(id: 3, projectDir: "-c-charlie", projectCwd: "/c/charlie", uuid: "uuid-3",
                tier: "subagent",       description: "a first description",
                events: 10, lines: 100, size: 1_000, started: "2026-08-24t01:00:00z", mtime: 1_700_000_100),
    SortFixture(id: 4, projectDir: "-d-delta", projectCwd: "/d/delta", uuid: "uuid-4",
                tier: "workflow_agent", description: "e fifth description",
                events: 50, lines: 500, size: 5_000, started: "2026-08-24t05:00:00z", mtime: 1_700_000_500),
    SortFixture(id: 5, projectDir: "-e-echo", projectCwd: "/e/echo", uuid: "uuid-5",
                tier: "session",        description: "c third description",
                events: 20, lines: 200, size: 2_000, started: "2026-08-24t02:00:00z", mtime: 1_700_000_200),
    SortFixture(id: 6, projectDir: "-f-foxtrot", projectCwd: "/f/foxtrot", uuid: "uuid-6",
                tier: "subagent",       description: "d fourth description",
                events: 40, lines: 400, size: 4_000, started: "2026-08-24t04:00:00z", mtime: 1_700_000_400),
]

private func seedSortFixtures(_ db: DB) {
    let insertSQL = """
        INSERT INTO sessions (id, project_id, session_uuid, file_path, file_tier,
          file_mtime, file_size, imported_at, import_status, line_count, event_count,
          started_at, description)
        VALUES (?,?,?,?,?,?,?,datetime('now'),'imported',?,?,?,?)
        """
    for f in sortFixtures {
        let projectId = upsertProject(db: db, dirName: f.projectDir, cwd: f.projectCwd)!
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db.handle, insertSQL, -1, &stmt, nil) == SQLITE_OK)
        sqlite3_bind_int64(stmt, 1, Int64(f.id))
        sqlite3_bind_int64(stmt, 2, Int64(projectId))
        sqlite3_bind_text(stmt, 3, f.uuid, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 4, "/tmp/fixture/\(f.id).jsonl", -1, TRANSIENT)
        sqlite3_bind_text(stmt, 5, f.tier, -1, TRANSIENT)
        sqlite3_bind_int64(stmt, 6, Int64(f.mtime))
        sqlite3_bind_int64(stmt, 7, Int64(f.size))
        sqlite3_bind_int64(stmt, 8, Int64(f.lines))
        sqlite3_bind_int64(stmt, 9, Int64(f.events))
        sqlite3_bind_text(stmt, 10, f.started, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 11, f.description, -1, TRANSIENT)
        #expect(sqlite3_step(stmt) == SQLITE_DONE, "fixture insert failed: \(db.lastErrorMessage)")
        sqlite3_finalize(stmt)
    }
}

/// Mirrors `SessionSort.sqlExpression` in Swift so the expected order is computed
/// independently of the SQL that produced it. All fixture values are ASCII lowercase, so
/// SQLite's BINARY/NOCASE collation and Swift's `<` agree.
private func compareFixtures(_ key: SessionSort, _ a: SortFixture, _ b: SortFixture) -> Int {
    func cmp<T: Comparable>(_ x: T, _ y: T) -> Int { x == y ? 0 : (x < y ? -1 : 1) }
    switch key {
    case .description: return cmp(a.description, b.description)
    case .tier:        return cmp(a.tier, b.tier)
    case .project:     return cmp(a.projectCwd, b.projectCwd)
    case .events:      return cmp(a.events, b.events)
    case .lines:       return cmp(a.lines, b.lines)
    case .size:        return cmp(a.size, b.size)
    case .started:     return cmp(a.started, b.started)
    case .mtime:       return cmp(a.mtime, b.mtime)
    }
}

private func expectedOrder(_ key: SessionSort, _ direction: SortDirection) -> [Int] {
    sortFixtures.sorted { a, b in
        let c = compareFixtures(key, a, b)
        if c != 0 { return direction == .asc ? c < 0 : c > 0 }
        return a.id > b.id      // SQL.selectSessionsOrderLimit's `, s.id DESC` tiebreaker
    }.map(\.id)
}

// MARK: - tests

@Suite("Store · SQLite integration (temp db file)")
struct StoreSQLiteIntegrationTests {

    // MARK: schema

    /// Guards the toolchain trap recorded in SPEC.md: on this machine a bare `sqlite3`
    /// resolves to the Android SDK build, which has NO FTS5, and schema.sql dies there with
    /// `no such module: fts5`. The same failure would hit the app if it were ever linked
    /// against such a build. Asserting the shadow tables (not just "CREATE VIRTUAL TABLE
    /// parsed") is what proves fts5 actually instantiated.
    @Test("schema.sql applies cleanly and really creates an FTS5 table")
    func schemaAppliesAndCreatesFTS5() throws {
        let dir = try TempDir("schema"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = dir.adopt(DB(path: dir.path("schema.db")))

        let error = applySchemaSafely(db, schemaPath)
        #expect(error == nil, "schema.sql failed: \(error ?? "")")

        let tables = tableNames(db)
        for expected in ["projects", "sessions", "session_type_counts", "events_fts",
                         "session_tail_state", "import_runs"] {
            #expect(tables.contains(expected), "schema.sql did not create \(expected)")
        }

        let ddl = queryStrings(db, "SELECT sql FROM sqlite_master WHERE name='events_fts'").first ?? ""
        #expect(ddl.lowercased().contains("fts5"), "events_fts is not an fts5 table: \(ddl)")

        // FTS5 shadow tables only exist if the module actually loaded and built the vtab.
        #expect(tables.contains("events_fts_data"))
        #expect(tables.contains("events_fts_idx"))
        #expect(tables.contains("events_fts_docsize"))
        #expect(tables.contains("events_fts_config"))

        // …and it has to be queryable, not merely present.
        #expect(scalarInt(db, "SELECT count(*) FROM events_fts") == 0)
        #expect(rawMatch(db, "\"anything\"*").error == nil)
    }

    /// schema.sql is re-run by `just init-db` against an existing db, so every statement
    /// in it must be idempotent — that is the stated reason session_tail_state is a TABLE
    /// rather than an ALTER TABLE ADD COLUMN (SQLite has no ADD COLUMN IF NOT EXISTS).
    @Test("schema.sql is idempotent — re-applying it does not fail")
    func schemaIsIdempotent() throws {
        let dir = try TempDir("schema-idem"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = dir.adopt(DB(path: dir.path("idem.db")))
        #expect(applySchemaSafely(db, schemaPath) == nil)
        #expect(applySchemaSafely(db, schemaPath) == nil, "schema.sql is not re-runnable")
        #expect(tableNames(db).contains("session_tail_state"))
    }

    // MARK: import → search round trip

    @Test("import a session file, then searchEvents finds its text")
    func importThenSearchFindsEvents() throws {
        let dir = try TempDir("import-search"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("9cda6f37-0000-4000-8000-000000000001.jsonl")
        try writeJSONL(file, [
            userLine("please index the quokkaphrase marker", ts: "2026-08-24T10:00:00.000Z",
                     cwd: "/workspace/digger-oracle"),
            assistantLine("acknowledged, quokkaphrase recorded", ts: "2026-08-24T10:00:01.000Z"),
            stateLine("file-history-snapshot", ts: "2026-08-24T10:00:02.000Z"),
        ])

        let f = discovered(path: file, uuid: "9cda6f37-0000-4000-8000-000000000001")
        #expect(importOne(db, f), "importFile reported failure on a readable file")

        // Session row landed, with the counts the parser measured.
        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == 1)
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["imported"])
        #expect(scalarInt(db, "SELECT line_count FROM sessions") == 3)
        #expect(scalarInt(db, "SELECT event_count FROM sessions") == 2)   // the state line is not an event

        // SPEC.md: the project's real path comes from the file's own `cwd`, never the dirname.
        #expect(queryStrings(db, "SELECT cwd FROM projects")
                == ["/workspace/digger-oracle"])

        // All ~14 line types are counted; only the conversational ones are indexed.
        #expect(scalarInt(db, "SELECT count(*) FROM session_type_counts") == 3)
        #expect(scalarInt(db, "SELECT count(*) FROM events_fts") == 2)

        let hits = searchEvents(db: db, query: "quokkaphrase", limit: 50)
        #expect(hits.count == 2, "expected both conversational lines, got \(hits.count)")
        #expect(Set(hits.map(\.role)) == ["user", "assistant"])
        #expect(hits.allSatisfy { $0.uuid == "9cda6f37-0000-4000-8000-000000000001" })
        // The snippet is checked with the HIGHLIGHT MARKERS STRIPPED. Queries of 3+ chars
        // are answered by the trigram index, whose snippet() brackets the matched TRIGRAM
        // span rather than the whole word — measured: `workflow` highlights as «Workflo»,
        // clipping the final letter. A raw `contains("quokkaphrase")` therefore fails on a
        // snippet that does contain the phrase, just with a `»` inside it.
        #expect(hits.allSatisfy {
            $0.snippet.replacingOccurrences(of: "«", with: "")
                      .replacingOccurrences(of: "»", with: "")
                      .contains("quokkaphrase")
        })

        // A term that is not in the corpus must return zero — otherwise "found rows" proves
        // nothing about the query actually matching.
        #expect(searchEvents(db: db, query: "wombatphrase", limit: 50).isEmpty)
    }

    // MARK: the two search regressions

    /// REGRESSION — the silent wrong answer. A bare `-` is an FTS5 OPERATOR, so an
    /// unquoted `append-only` parsed as a column reference and failed at sqlite3_step.
    /// The row loop reads a step error as "no more rows", so the search box returned zero
    /// hits with no error and looked like "nothing matched".
    @Test("searchEvents with a HYPHENATED term returns rows (silent-zero regression)")
    func searchWithHyphenatedTermReturnsRows() throws {
        let dir = try TempDir("hyphen"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("hyphen.jsonl")
        try writeJSONL(file, [
            userLine("session files are append-only in practice", ts: "2026-08-24T11:00:00.000Z",
                     cwd: "/tmp/hyphen"),
            assistantLine("noted: append-only, so a tailer only reads the delta",
                          ts: "2026-08-24T11:00:01.000Z"),
        ])
        #expect(importOne(db, discovered(path: file, uuid: "hyphen-uuid")))

        let hits = searchEvents(db: db, query: "append-only", limit: 50)
        #expect(hits.count == 2, "hyphenated search returned \(hits.count) rows — the bug is back")

        // The guard is load-bearing: prove the RAW term is genuinely invalid FTS5, so the
        // quoting in ftsQuery is what makes the query work rather than a coincidence.
        let raw = rawMatch(db, "append-only")
        #expect(raw.error != nil, "expected raw `append-only` to be an FTS5 error; it was not")
        #expect(raw.rows == 0)

        // And what ftsQuery actually produces is a quoted, prefixed phrase.
        #expect(ftsQuery("append-only") == "\"append-only\"*")
        #expect(rawMatch(db, ftsQuery("append-only")).error == nil)

        // Other punctuation from the same family must not resurrect the bug.
        for query in ["append-only", "wal-mode", "byte_offset", "c++", "a:b", "foo*", "(paren"] {
            #expect(rawMatch(db, ftsQuery(query)).error == nil,
                    "ftsQuery produced invalid FTS5 for \(query.debugDescription)")
        }
    }

    /// REGRESSION — typing `9c` to find session `9cda6f37` returned nothing, because a
    /// quoted FTS5 phrase only matches a WHOLE token. The last token is now a prefix.
    @Test("searchEvents with a PREFIX returns rows")
    func searchWithPrefixReturnsRows() throws {
        let dir = try TempDir("prefix"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("prefix.jsonl")
        try writeJSONL(file, [
            userLine("resume session 9cda6f37 please", ts: "2026-08-24T12:00:00.000Z", cwd: "/tmp/prefix"),
            assistantLine("byte offset held back on partial lines", ts: "2026-08-24T12:00:01.000Z"),
        ])
        #expect(importOne(db, discovered(path: file, uuid: "prefix-uuid")))

        #expect(ftsQuery("9c") == "\"9c\"*")
        let hits = searchEvents(db: db, query: "9c", limit: 50)
        #expect(hits.count == 1, "prefix search for `9c` returned \(hits.count) rows — the bug is back")
        #expect(hits.first?.snippet.contains("9cda6f37") == true)

        // Control: the same phrase WITHOUT the `*` is what used to run, and it finds nothing.
        // This is the proof that the `*` is doing the work, not the quoting.
        let whole = rawMatch(db, "\"9c\"")
        #expect(whole.error == nil)
        #expect(whole.rows == 0, "a whole-token phrase should NOT match 9cda6f37")

        // Only the LAST token is a prefix: `byte off` means "byte AND off*", not "byte*".
        #expect(ftsQuery("byte off") == "\"byte\" \"off\"*")
        #expect(searchEvents(db: db, query: "byte off", limit: 50).count == 1)
        // …so an earlier token still has to match whole ON THE UNICODE61 PATH.
        #expect(rawMatch(db, ftsQuery("byt off")).rows == 0)

        // But `searchEvents("byt off")` is 7 characters, so it is answered by the TRIGRAM
        // index, where substring matching is the default and `byt` reaches `byte` with no
        // wildcard at all. This assertion used to require zero rows, which encoded the old
        // engine's limitation as if it were the desired behaviour — finding the row is the
        // improvement, not a regression.
        #expect(searchEvents(db: db, query: "byt off", limit: 50).count == 1)

        // The routing boundary itself, stated: below 3 characters there is no trigram to
        // match, so those queries MUST keep going to unicode61-with-prefix.
        #expect(usesTrigram("9c") == false)
        #expect(usesTrigram("9cd") == true)

        // Incremental typing: every prefix of a token the user is part-way through must
        // keep finding it. This is what makes the search box feel like a search box —
        // before the fix, only the very last keystroke produced a result.
        for typed in ["9", "9c", "9cd", "9cda", "9cda6f3", "9cda6f37"] {
            #expect(searchEvents(db: db, query: typed, limit: 50).count == 1,
                    "prefix \(typed.debugDescription) lost the hit")
        }

        // Empty / whitespace-only input must be a safe no-op, not an FTS5 syntax error.
        #expect(rawMatch(db, ftsQuery("")).error == nil)
        #expect(rawMatch(db, ftsQuery("   ")).error == nil)
        #expect(searchEvents(db: db, query: "", limit: 50).isEmpty)
    }

    // MARK: sorting

    @Test("fetchSessions honours every SessionSort key in both directions")
    func fetchSessionsHonoursEverySortKeyBothDirections() throws {
        let dir = try TempDir("sort"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)
        seedSortFixtures(db)
        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == sortFixtures.count)

        // Pin the size of the allow-list, so "all 8 keys are covered" is a fact this test
        // asserts rather than a claim its loop quietly stops making if a case is removed.
        #expect(SessionSort.allCases.count == 8)
        #expect(SortDirection.allCases.count == 2)

        // The enum is the allow-list, so iterating allCases means a NEW sort key added
        // later is covered by this test the moment it exists.
        for key in SessionSort.allCases {
            for direction in SortDirection.allCases {
                let rows = fetchSessions(db: db, sort: key, direction: direction, limit: 100)
                #expect(rows.count == sortFixtures.count,
                        "\(key.rawValue) \(direction.rawValue): got \(rows.count) rows")
                // One string LITERAL, not a `+` concatenation: swift-testing's second
                // parameter is a `Comment`, which is ExpressibleByStringInterpolation —
                // a literal converts, the result of `String + String` does not
                // ("cannot convert value of type 'String' to expected argument type
                // 'Comment?'"). Same text, expressed so it compiles.
                #expect(rows.map(\.id) == expectedOrder(key, direction),
                        "\(key.rawValue) \(direction.rawValue) order wrong: got \(rows.map(\.id)), want \(expectedOrder(key, direction))")
            }
        }

        // asc and desc must genuinely differ — `ORDER BY ?` (the bug the enum exists to
        // prevent) returns the SAME arbitrary order for every input without erroring, and
        // would sail through a "rows are ordered" check.
        for key in SessionSort.allCases {
            let asc = fetchSessions(db: db, sort: key, direction: .asc, limit: 100).map(\.id)
            let desc = fetchSessions(db: db, sort: key, direction: .desc, limit: 100).map(\.id)
            #expect(asc != desc, "\(key.rawValue): asc and desc returned identical order")
            // For a key whose values are all distinct, asc is the EXACT reverse of desc.
            // `tier` is excluded: its duplicates are resolved by `s.id DESC` in BOTH
            // directions, so it is deliberately not symmetric.
            if key != .tier {
                #expect(asc == desc.reversed(), "\(key.rawValue): asc is not the reverse of desc")
            }
        }

        // The `s.id DESC` tiebreaker, spelled out rather than left implicit: equal tiers
        // fall back to descending id, which is what stops the list from reshuffling
        // between reloads (a whole workflow fan-out shares one tier and one mtime second).
        let byTier = fetchSessions(db: db, sort: .tier, direction: .asc, limit: 100)
        #expect(byTier.map(\.tier) == ["session", "session", "subagent", "subagent",
                                       "workflow_agent", "workflow_agent"])
        #expect(byTier.map(\.id) == [5, 1, 6, 3, 4, 2])

        // The tier filter and limit are ordinary bound params and must still compose.
        let subagents = fetchSessions(db: db, tier: "subagent", sort: .mtime, direction: .desc, limit: 100)
        #expect(subagents.map(\.id) == [6, 3])
        #expect(fetchSessions(db: db, sort: .mtime, direction: .desc, limit: 2).map(\.id) == [2, 4])
        #expect(fetchSessions(db: db, tier: "workflow_agent", sort: .size,
                              direction: .desc, limit: 100).map(\.id) == [2, 4])
        #expect(fetchSessions(db: db, tier: "no-such-tier", sort: .mtime,
                              direction: .desc, limit: 100).isEmpty)
    }

    // MARK: the SQL-injection guard

    /// The ORDER BY column is the ONE thing in this app interpolated into SQL text
    /// (SQLite cannot bind an identifier). `SessionSort(rawValue:)` is the entire defence,
    /// so it gets a test: untrusted input must fail the init and never reach the SQL.
    @Test("SessionSort(rawValue:) rejects an injection string and the table survives")
    func sortEnumRejectsInjection() throws {
        let dir = try TempDir("injection"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)
        seedSortFixtures(db)
        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == 6)

        let injection = ";DROP TABLE sessions;--"
        #expect(SessionSort(rawValue: injection) == nil)
        #expect(SortDirection(rawValue: injection) == nil)

        // Neighbouring shapes: a real column name, an ordinal, a trailing statement, and a
        // case variant. None of them is a case of the enum, so none can be interpolated.
        for hostile in ["s.file_mtime", "file_mtime", "1", "mtime; DROP TABLE sessions",
                        "mtime--", "mtime) --", "MTIME", "", " mtime", "mtime "] {
            #expect(SessionSort(rawValue: hostile) == nil,
                    "SessionSort accepted \(hostile.debugDescription)")
        }
        for hostile in ["ASC", "asc; DROP TABLE sessions", "desc--", "descending", "1"] {
            #expect(SortDirection(rawValue: hostile) == nil,
                    "SortDirection accepted \(hostile.debugDescription)")
        }

        // The table — and every row in it, and the FTS index — is still there.
        #expect(tableNames(db).contains("sessions"))
        #expect(tableNames(db).contains("events_fts"))
        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == 6)
        #expect(fetchSessions(db: db, sort: .mtime, direction: .desc, limit: 100).count == 6)

        // Belt and braces: no case of the allow-list can itself smuggle a statement
        // terminator or comment into the interpolated ORDER BY text, and every fragment is
        // a plain column expression rather than anything caller-shaped.
        for key in SessionSort.allCases {
            let fragment = key.sqlExpression
            #expect(!fragment.contains(";"), "\(key.rawValue) sqlExpression contains ';'")
            #expect(!fragment.contains("--"), "\(key.rawValue) sqlExpression contains '--'")
            #expect(!fragment.contains("/*"), "\(key.rawValue) sqlExpression contains '/*'")
            #expect(fragment.hasPrefix("s.") || fragment.hasPrefix("COALESCE("),
                    "\(key.rawValue) sqlExpression is not a plain column expression: \(fragment)")
        }
        for direction in SortDirection.allCases {
            #expect(["ASC", "DESC"].contains(direction.sqlKeyword))
        }

        // The one interpolation in the app, pinned as text — so a change to how ORDER BY
        // is assembled has to be a deliberate edit to this expectation.
        #expect(SQL.selectSessionsOrderLimit(.mtime, .desc)
                == " ORDER BY s.file_mtime DESC, s.id DESC LIMIT ?")
        #expect(SQL.selectSessionsOrderLimit(.project, .asc)
                == " ORDER BY COALESCE(p.cwd, p.dir_name) COLLATE NOCASE ASC, s.id DESC LIMIT ?")

        // The CLI's usage text is generated from the allow-list itself, so it cannot drift
        // from what is actually accepted — that string is what an injection attempt sees.
        #expect(SessionSort.usage == "description|tier|project|events|lines|size|started|mtime")
        #expect(SortDirection.usage == "asc|desc")
    }

    // MARK: import failure recording

    /// `importFile` used to return `true` unconditionally — a file that could not be read
    /// was reported as a successful import. The failure must be RECORDED, not swallowed.
    @Test("importFile records a failure for an unreadable file instead of returning true")
    func importFileRecordsFailureForUnreadableFile() throws {
        let dir = try TempDir("unreadable"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("locked.jsonl")
        try writeJSONL(file, [userLine("secret", ts: "2026-08-24T13:00:00.000Z", cwd: "/tmp/locked")])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        // If this process could still read it (e.g. running as root) the test would be
        // vacuous, so assert the precondition rather than assuming it.
        #expect(FileHandle(forReadingAtPath: file) == nil, "fixture is still readable — test is vacuous")

        let f = discovered(path: file, uuid: "locked-uuid")
        #expect(importOne(db, f) == false, "importFile returned true for an unreadable file")

        // A brand-new file that failed before its row existed still gets a `failed` row —
        // otherwise the failure vanishes and the file looks "new" again on every diff.
        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == 1)
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["failed"])
        let recorded = queryStrings(db, "SELECT import_error FROM sessions").first ?? ""
        #expect(recorded.contains("cannot open file for reading"), "import_error was \(recorded.debugDescription)")
        #expect(recorded.contains("locked.jsonl"))
        // Nothing half-written was left behind.
        #expect(scalarInt(db, "SELECT count(*) FROM events_fts") == 0)
        #expect(scalarInt(db, "SELECT count(*) FROM session_type_counts") == 0)

        // diffState must see the failed row as work to retry, not as "unchanged".
        let known = loadKnownFiles(db: db)
        #expect(diffState(file: f, known: known) == .changed)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
    }

    @Test("importFile records a failure for a file that does not exist")
    func importFileRecordsFailureForMissingFile() throws {
        let dir = try TempDir("missing"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let ghost = DiscoveredFile(path: dir.path("does-not-exist.jsonl"),
                                   projectDirName: "-tmp-ghost", tier: "workflow_agent",
                                   sessionUUID: "ghost-uuid", agentId: "agent-1",
                                   workflowRunId: "wf_deadbeef", mtime: 1_700_000_000, size: 123)
        #expect(importOne(db, ghost) == false)
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["failed"])
        #expect((queryStrings(db, "SELECT import_error FROM sessions").first ?? "")
                    .contains("cannot open file for reading"))
    }

    /// The other half of the failure path: a file that imported cleanly and LATER became
    /// unreadable must have its existing row flipped to `failed` rather than left showing
    /// stale success data.
    @Test("a previously-imported file that becomes unreadable flips its row to failed")
    func reimportOfNowUnreadableFileFlipsRowToFailed() throws {
        let dir = try TempDir("flip"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("flip.jsonl")
        try writeJSONL(file, [
            userLine("first import works", ts: "2026-08-24T14:00:00.000Z", cwd: "/tmp/flip"),
        ])
        let f1 = discovered(path: file, uuid: "flip-uuid")
        #expect(importOne(db, f1))
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["imported"])
        #expect(scalarInt(db, "SELECT count(*) FROM events_fts") == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        #expect(FileHandle(forReadingAtPath: file) == nil, "fixture is still readable — test is vacuous")

        #expect(importOne(db, discovered(path: file, uuid: "flip-uuid")) == false)
        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == 1, "a second row was created")
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["failed"])
        #expect((queryStrings(db, "SELECT import_error FROM sessions").first ?? "")
                    .contains("cannot open file for reading"))

        // The ON CONFLICT branch of insertSessionFailed: a row already exists at this
        // file_path, but the caller took the "new file" path and passed existingId: nil.
        // `file_path` is UNIQUE, so a plain INSERT would violate the constraint — and
        // db.prepare's fatalError-on-bad-SQL would take the whole import down with it.
        // It must still record the failure, in place, without duplicating the row.
        let projectId = upsertProject(db: db, dirName: f1.projectDirName, cwd: nil)!
        #expect(importFile(db: db, file: f1, projectId: projectId, existingId: nil) == false)
        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == 1)
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["failed"])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
    }

    // MARK: parser edge cases

    /// A live session file is being appended to right now, so the last line very often has
    /// no trailing newline yet. Dropping it would silently lose the newest message.
    @Test("a jsonl line with NO trailing newline is still parsed")
    func fileWithoutTrailingNewlineIsFullyParsed() throws {
        let dir = try TempDir("no-newline"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }

        let lines = [
            userLine("alpha marker", ts: "2026-08-24T15:00:00.000Z", cwd: "/tmp/nonl"),
            assistantLine("bravo marker", ts: "2026-08-24T15:00:01.000Z"),
            userLine("charlie marker", ts: "2026-08-24T15:00:02.000Z"),
        ]

        let noNewline = dir.path("no-newline.jsonl")
        try writeJSONL(noNewline, lines, trailingNewline: false)
        let raw = try String(contentsOfFile: noNewline, encoding: .utf8)
        #expect(raw.hasSuffix("}"), "fixture ends in a newline — the test would be vacuous")

        let parsed = try parseSessionFile(path: noNewline)
        #expect(parsed.lineCount == 3)
        #expect(parsed.eventCount == 3)
        #expect(parsed.events.map(\.text) == ["alpha marker", "bravo marker", "charlie marker"])
        #expect(parsed.startedAt == "2026-08-24T15:00:00.000Z")
        #expect(parsed.endedAt == "2026-08-24T15:00:02.000Z")
        #expect(parsed.cwd == "/tmp/nonl")
        #expect(parsed.description == "alpha marker")

        // The same content WITH a trailing newline must parse identically — the newline is
        // a terminator, not a record.
        let withNewline = dir.path("with-newline.jsonl")
        try writeJSONL(withNewline, lines, trailingNewline: true)
        let parsed2 = try parseSessionFile(path: withNewline)
        #expect(parsed2.lineCount == parsed.lineCount)
        #expect(parsed2.eventCount == parsed.eventCount)
        #expect(parsed2.events.map(\.text) == parsed.events.map(\.text))
        #expect(parsed2.typeCounts == parsed.typeCounts)

        // …and end to end: the last line is searchable, and the counted lines reach the db.
        let db = makeTempDB(dir)
        #expect(importOne(db, discovered(path: noNewline, uuid: "no-newline-uuid")))
        #expect(scalarInt(db, "SELECT line_count FROM sessions") == 3)
        #expect(searchEvents(db: db, query: "charlie", limit: 50).count == 1)
    }

    /// Real session files get truncated mid-write. One bad line must not cost the file.
    @Test("a truncated final line is skipped, not fatal, and earlier valid lines survive")
    func truncatedFinalLineIsSkippedWithoutLosingEarlierLines() throws {
        let dir = try TempDir("truncated"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let good = [
            userLine("alpha truncmarker", ts: "2026-08-24T16:00:00.000Z", cwd: "/tmp/trunc"),
            assistantLine("bravo truncmarker", ts: "2026-08-24T16:00:01.000Z"),
            userLine("charlie truncmarker", ts: "2026-08-24T16:00:02.000Z"),
        ]
        // A genuinely half-written line: valid JSON prefix, cut off mid-string, no newline.
        let truncated = "{\"type\":\"assistant\",\"timestamp\":\"2026-08-24T16:00:03.000Z\",\"messa"

        let file = dir.path("truncated.jsonl")
        try writeRaw(file, good.joined(separator: "\n") + "\n" + truncated)

        let parsed = try parseSessionFile(path: file)
        #expect(parsed.lineCount == 4, "the truncated line should still be counted as a line")
        #expect(parsed.eventCount == 3, "the truncated line must not become an event")
        #expect(parsed.events.map(\.text) == ["alpha truncmarker", "bravo truncmarker", "charlie truncmarker"])
        #expect(parsed.typeCounts == ["user": 2, "assistant": 1])
        #expect(parsed.startedAt == "2026-08-24T16:00:00.000Z")
        #expect(parsed.endedAt == "2026-08-24T16:00:02.000Z", "a timestamp was taken from the unparseable line")

        // The import itself SUCCEEDS — a bad line is data, not an import failure.
        #expect(importOne(db, discovered(path: file, uuid: "trunc-uuid")))
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["imported"])
        #expect(scalarInt(db, "SELECT count(*) FROM events_fts") == 3)
        #expect(searchEvents(db: db, query: "truncmarker", limit: 50).count == 3)

        // A file that is nothing BUT garbage still imports as an empty session: "the file
        // is readable" and "the file has content we understand" are different questions,
        // and only the first one is an import failure.
        let junk = dir.path("junk.jsonl")
        try writeRaw(junk, "not json\nalso not json\n")
        let junkParsed = try parseSessionFile(path: junk)
        #expect(junkParsed.lineCount == 2)
        #expect(junkParsed.eventCount == 0)
        #expect(junkParsed.events.isEmpty)
        #expect(importOne(db, discovered(path: junk, uuid: "junk-uuid")))
        #expect(scalarInt(db, "SELECT count(*) FROM sessions WHERE import_status='failed'") == 0)
    }

    /// The same tolerance, but with the damage in the MIDDLE — a corrupt line must not
    /// truncate the parse at that point and lose everything after it.
    @Test("malformed and blank lines in the middle are skipped, not fatal")
    func malformedMiddleLinesAreSkipped() throws {
        let dir = try TempDir("malformed-middle"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("malformed.jsonl")
        try writeRaw(file, [
            userLine("before midmarker", ts: "2026-08-24T17:00:00.000Z", cwd: "/tmp/mid"),
            "not json at all",
            "",                                  // blank line — must not count as a line
            "{\"type\":\"user\",\"message\":",    // valid JSON prefix, invalid JSON
            "[1,2,3]",                           // valid JSON, wrong shape (array, not object)
            "{\"no_type\":true}",                // object with no `type`
            assistantLine("after midmarker", ts: "2026-08-24T17:00:05.000Z"),
        ].joined(separator: "\n") + "\n")

        let parsed = try parseSessionFile(path: file)
        #expect(parsed.lineCount == 6, "blank lines must not be counted; got \(parsed.lineCount)")
        #expect(parsed.eventCount == 2)
        #expect(parsed.events.map(\.text) == ["before midmarker", "after midmarker"])
        #expect(parsed.startedAt == "2026-08-24T17:00:00.000Z")
        #expect(parsed.endedAt == "2026-08-24T17:00:05.000Z")

        #expect(importOne(db, discovered(path: file, uuid: "mid-uuid")))
        #expect(searchEvents(db: db, query: "midmarker", limit: 50).count == 2)
    }

    /// An entirely empty file must import as an empty session rather than as a failure —
    /// a session file exists on disk the moment a session starts, before any line is written.
    @Test("an empty file imports as an empty session, not a failure")
    func emptyFileImportsAsEmptySession() throws {
        let dir = try TempDir("empty"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("empty.jsonl")
        try writeRaw(file, "")

        let parsed = try parseSessionFile(path: file)
        #expect(parsed.lineCount == 0)
        #expect(parsed.eventCount == 0)

        #expect(importOne(db, discovered(path: file, uuid: "empty-uuid")))
        #expect(queryStrings(db, "SELECT import_status FROM sessions") == ["imported"])
        #expect(scalarInt(db, "SELECT count(*) FROM events_fts") == 0)
    }

    /// Re-importing a changed file must REPLACE its FTS rows and type counts, not add a
    /// second copy — the delete-then-insert branch of importFile.
    @Test("re-importing a grown file replaces its events instead of duplicating them")
    func reimportReplacesEventsRatherThanDuplicating() throws {
        let dir = try TempDir("reimport"); defer { dir.verifyCleanupHappened() }; defer { dir.cleanup() }
        let db = makeTempDB(dir)

        let file = dir.path("grow.jsonl")
        try writeJSONL(file, [
            userLine("first growmarker", ts: "2026-08-24T18:00:00.000Z", cwd: "/tmp/grow"),
        ])
        #expect(importOne(db, discovered(path: file, uuid: "grow-uuid")))
        #expect(searchEvents(db: db, query: "growmarker", limit: 50).count == 1)

        try writeJSONL(file, [
            userLine("first growmarker", ts: "2026-08-24T18:00:00.000Z", cwd: "/tmp/grow"),
            assistantLine("second growmarker", ts: "2026-08-24T18:00:01.000Z"),
        ])
        #expect(importOne(db, discovered(path: file, uuid: "grow-uuid")))

        #expect(scalarInt(db, "SELECT count(*) FROM sessions") == 1)
        #expect(scalarInt(db, "SELECT count(*) FROM events_fts") == 2)
        #expect(searchEvents(db: db, query: "growmarker", limit: 50).count == 2,
                "re-import duplicated or dropped FTS rows")
        #expect(scalarInt(db, "SELECT line_count FROM sessions") == 2)
    }
}
