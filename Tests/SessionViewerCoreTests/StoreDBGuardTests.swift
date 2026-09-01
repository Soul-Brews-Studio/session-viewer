// StoreDBGuardTests.swift — the DB-layer gaps NOT covered by StoreDBIntegrationTests.
//
// That file owns the main integration story (schema + FTS5, the two ftsQuery regressions,
// all 8 sort keys, the injection guard, import failure recording, parser edge cases). This
// one deliberately does not repeat any of it. It covers four things that survive a green
// run of that suite:
//
//   1. THE INTERPOLATED TEXT ITSELF. `SessionSort` is tested through the row order it
//      produces; the string that actually gets concatenated into the SQL is never
//      asserted. Row order cannot see a LIMIT that quietly became literal text, and it
//      cannot see a column expression that parses but is not the one intended.
//   2. THE ALLOW-LIST'S PUBLISHED TEXT. `SessionSort.usage` is what main.swift prints when
//      it rejects `--sort ';DROP TABLE sessions;--'`. It is generated from `allCases`, so
//      adding a case silently changes the contract the CLI advertises.
//   3. `insertSessionFailed`'s ON CONFLICT branch — reached when a row already exists at a
//      UNIQUE file_path but the caller passed `existingId: nil`. Nothing else reaches it,
//      and `DB.prepare` calls `fatalError`, so a regression there aborts the whole import
//      process rather than failing one file.
//   4. THE READ SIDE the app's detail pane uses: `fetchSession(db:id:)` and
//      `fetchTypeCounts(db:sessionId:)`. `SQL.selectSessionById` duplicates
//      `selectSessionsBase`'s column list and its own comment says the two must stay
//      identical — a duplicated column list with no test is a silent field-shift waiting
//      to happen.
//
// Same rule as its sibling: every database here is a throwaway file under
// FileManager.default.temporaryDirectory. `.data/sessions.db` is user data and is never
// opened.

import Foundation
import SQLite3
import Testing
@testable import SessionViewerCore

// MARK: - sandbox (private; the sibling suite keeps its own copies)

private var guardPackageRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // …/Tests/SessionViewerCoreTests
        .deletingLastPathComponent()      // …/Tests
        .deletingLastPathComponent()      // package root
}

private var guardSchemaPath: String { guardPackageRoot.appendingPathComponent("schema.sql").path }

private struct GuardSandbox {
    let url: URL

    init(_ label: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-guard-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ component: String) -> String { url.appendingPathComponent(component).path }

    func cleanup() {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for i in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: url.appendingPathComponent(i).path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func makeDB() -> DB {
        let p = path("guard.db")
        #expect(p.hasPrefix(FileManager.default.temporaryDirectory.path),
                "test db escaped the temp directory: \(p)")
        #expect(!p.hasSuffix(".data/sessions.db"), "a test must never open the real index")
        let db = DB(path: p)
        initSchema(db: db, schemaPath: guardSchemaPath)
        return db
    }
}

// MARK: - raw probes (bypass DB.prepare, which fatalErrors on bad SQL)

private func guardStrings(_ db: DB, _ sql: String) -> [String] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var out: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
    }
    return out
}

private func guardInt(_ db: DB, _ sql: String) -> Int? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(stmt, 0))
}

// MARK: - jsonl fixtures

private func guardJSON(_ obj: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj, options: []), encoding: .utf8)!
}

private func guardUser(_ text: String, ts: String, cwd: String? = nil) -> String {
    var obj: [String: Any] = ["type": "user", "timestamp": ts,
                              "message": ["role": "user", "content": text]]
    if let cwd { obj["cwd"] = cwd }
    return guardJSON(obj)
}

private func guardAssistant(_ text: String, ts: String) -> String {
    guardJSON(["type": "assistant", "timestamp": ts,
               "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}

private func guardState(_ type: String, ts: String) -> String {
    guardJSON(["type": type, "timestamp": ts])
}

private func guardWrite(_ lines: [String], to path: String) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
}

private func guardDiscovered(path: String, uuid: String) -> DiscoveredFile {
    let st = statFile(path) ?? (mtime: 0, size: 0)
    return DiscoveredFile(path: path, projectDirName: "-tmp-sv-guard", tier: "session",
                          sessionUUID: uuid, agentId: nil, workflowRunId: nil,
                          mtime: st.mtime, size: st.size)
}

@discardableResult
private func guardImport(_ db: DB, _ file: DiscoveredFile) -> Bool {
    let projectId = upsertProject(db: db, dirName: file.projectDirName, cwd: nil)!
    return importFile(db: db, file: file, projectId: projectId,
                      existingId: existingSessionId(db: db, path: file.path))
}

// MARK: - suite

@Suite("Store · DB guards (interpolated SQL, ON CONFLICT, read side)")
struct StoreDBGuardTests {

    /// The one interpolation in the app, pinned as TEXT. Asserting row order proves the
    /// sort works; asserting the string proves it works *for the intended reason*, and it
    /// is the only way to see the two failures order cannot show:
    ///   * `LIMIT ?` degrading back into concatenated literal text (it already did once,
    ///     for `SQL.searchEvents`, and contradicted this file's own header claim),
    ///   * a column expression that still parses but no longer matches the select list, so
    ///     the list sorts by something it does not display.
    @Test("selectSessionsOrderLimit emits exactly the expected SQL for every key/direction")
    func orderByTextIsPinnedForEveryKey() throws {
        // Written out by hand rather than derived from the enum: a table generated from the
        // thing under test agrees with it even when it is wrong.
        let expectedFragment: [SessionSort: String] = [
            .description: "COALESCE(s.description, s.session_uuid) COLLATE NOCASE",
            .tier:        "s.file_tier",
            .project:     "COALESCE(p.cwd, p.dir_name) COLLATE NOCASE",
            .events:      "COALESCE(s.event_count,0)",
            .lines:       "COALESCE(s.line_count,0)",
            .size:        "s.file_size",
            .started:     "s.started_at",
            .mtime:       "s.file_mtime",
        ]

        for key in SessionSort.allCases {
            guard let fragment = expectedFragment[key] else {
                Issue.record("new sort key \(key.rawValue) has no pinned SQL fragment here")
                continue
            }
            #expect(key.sqlExpression == fragment,
                    "\(key.rawValue).sqlExpression drifted: \(key.sqlExpression)")

            #expect(SQL.selectSessionsOrderLimit(key, .asc)
                    == " ORDER BY \(fragment) ASC, s.id DESC LIMIT ?")
            #expect(SQL.selectSessionsOrderLimit(key, .desc)
                    == " ORDER BY \(fragment) DESC, s.id DESC LIMIT ?")
        }

        // LIMIT must be a placeholder, never a number baked into the text.
        for key in SessionSort.allCases {
            for direction in SortDirection.allCases {
                let clause = SQL.selectSessionsOrderLimit(key, direction)
                #expect(clause.hasSuffix("LIMIT ?"), "LIMIT is not a bound parameter: \(clause)")
                #expect(clause.contains(", s.id DESC"), "lost the stable-order tiebreaker: \(clause)")
            }
        }
    }

    /// Every composed statement must actually PARSE, and must expose exactly the bind
    /// parameters the caller supplies — one for `limit`, two once the tier filter is on.
    /// A column expression that silently stops being valid SQL would surface in production
    /// as `DB.prepare`'s fatalError, i.e. a crash, not a failed query.
    @Test("every composed session query prepares and binds the expected parameter count")
    func composedQueriesPrepareCleanly() throws {
        let tmp = try GuardSandbox("compose"); defer { tmp.cleanup() }
        let db = tmp.makeDB()

        func bindParameterCount(_ sql: String) -> Int32? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_bind_parameter_count(stmt)
        }

        for key in SessionSort.allCases {
            for direction in SortDirection.allCases {
                let plain = SQL.selectSessionsBase + SQL.selectSessionsOrderLimit(key, direction)
                #expect(bindParameterCount(plain) == 1,
                        "\(key.rawValue)/\(direction.rawValue) unfiltered: expected 1 bound param")

                let filtered = SQL.selectSessionsBase + SQL.selectSessionsTierFilter
                             + SQL.selectSessionsOrderLimit(key, direction)
                #expect(bindParameterCount(filtered) == 2,
                        "\(key.rawValue)/\(direction.rawValue) tier-filtered: expected 2 bound params")
            }
        }

        // The single-session query duplicates the same column list; it must parse too.
        #expect(bindParameterCount(SQL.selectSessionById) == 1)
        // And the search statement's LIMIT is a `?` as well — the last statement to lose it.
        #expect(bindParameterCount(SQL.searchEvents) == 2)
    }

    /// `SessionSort.usage` is the text main.swift prints when it REJECTS hostile input:
    /// `unknown --sort: ';DROP TABLE sessions;--' (want: description|tier|…)`. It is derived
    /// from `allCases`, so it is the one part of the guard that changes itself when the
    /// allow-list grows. Pinning it makes that change deliberate.
    @Test("the allow-list's advertised usage text and SQL fragments cannot drift silently")
    func allowListTextIsPinned() throws {
        #expect(SessionSort.usage == "description|tier|project|events|lines|size|started|mtime")
        #expect(SortDirection.usage == "asc|desc")
        #expect(SessionSort.allCases.map(\.rawValue)
                == ["description", "tier", "project", "events", "lines", "size", "started", "mtime"])

        // Whatever the cases are, each interpolated fragment must stay a plain column
        // expression: no statement terminator, no comment introducer of either style, no
        // nested statement. This is the shape check that fails if the enum is ever widened
        // to carry caller text.
        for key in SessionSort.allCases {
            let fragment = key.sqlExpression
            #expect(!fragment.contains(";"), "\(key.rawValue) fragment contains ';': \(fragment)")
            #expect(!fragment.contains("--"), "\(key.rawValue) fragment contains '--': \(fragment)")
            #expect(!fragment.contains("/*"), "\(key.rawValue) fragment contains '/*': \(fragment)")
            #expect(!fragment.lowercased().contains("select"),
                    "\(key.rawValue) fragment contains a nested SELECT: \(fragment)")
            #expect(fragment.hasPrefix("s.") || fragment.hasPrefix("COALESCE("),
                    "\(key.rawValue) fragment is not a plain column expression: \(fragment)")
        }

        // Each label is used as a CLI/table header, and `defaultDirection` decides what the
        // first click on a header does. Both are part of the same closed enum.
        #expect(SessionSort.mtime.label == "modified")
        #expect(SessionSort.size.label == "KB")
        #expect(SessionSort.description.defaultDirection == .asc)
        #expect(SessionSort.mtime.defaultDirection == .desc)
        #expect(SortDirection.asc.toggled == .desc)
        #expect(SortDirection.desc.toggled == .asc)
        #expect(SortDirection.asc.sqlKeyword == "ASC")
        #expect(SortDirection.desc.sqlKeyword == "DESC")
    }

    /// `recordImportFailure`'s "brand-new file" branch runs `SQL.insertSessionFailed`, whose
    /// ON CONFLICT clause exists for exactly one situation: a row already exists at this
    /// UNIQUE `file_path`, but the caller passed `existingId: nil`. Without the clause this
    /// is a UNIQUE constraint violation — and because the failure recorder ignores the step
    /// result, the row would keep its stale `imported` status while the file is unreadable.
    /// Nothing else in the suite reaches this branch.
    @Test("a failure recorded via the new-file branch on an existing path updates, not duplicates")
    func failureRecordingHitsOnConflictBranch() throws {
        let tmp = try GuardSandbox("conflict"); defer { tmp.cleanup() }
        let db = tmp.makeDB()

        let file = tmp.path("conflict.jsonl")
        try guardWrite([guardUser("imports fine the first time", ts: "2026-08-24T19:00:00.000Z",
                                  cwd: "/tmp/conflict")], to: file)
        let f = guardDiscovered(path: file, uuid: "conflict-uuid")
        let projectId = upsertProject(db: db, dirName: f.projectDirName, cwd: nil)!

        #expect(importFile(db: db, file: f, projectId: projectId, existingId: nil))
        #expect(guardInt(db, "SELECT count(*) FROM sessions") == 1)
        #expect(guardStrings(db, "SELECT import_status FROM sessions") == ["imported"])

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        #expect(FileHandle(forReadingAtPath: file) == nil, "fixture is still readable — test is vacuous")

        // The "new file" branch again, deliberately: existingId nil while the row exists.
        #expect(importFile(db: db, file: f, projectId: projectId, existingId: nil) == false)

        #expect(guardInt(db, "SELECT count(*) FROM sessions") == 1, "ON CONFLICT inserted a duplicate row")
        #expect(guardStrings(db, "SELECT import_status FROM sessions") == ["failed"],
                "the conflicting insert was swallowed and the row kept its stale status")
        #expect((guardStrings(db, "SELECT import_error FROM sessions").first ?? "")
                    .contains("cannot open file for reading"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
    }

    /// SPEC.md's "line types are modeled, not collapsed" decision, asserted at the VALUE
    /// level: not just "three rows exist" but which types and which counts, and that the
    /// non-conversational ones are counted yet never indexed for search.
    @Test("session_type_counts records every line type, and only conversational ones are indexed")
    func typeCountsRecordEveryLineTypeAndOnlyConversationalAreIndexed() throws {
        let tmp = try GuardSandbox("typecounts"); defer { tmp.cleanup() }
        let db = tmp.makeDB()

        let file = tmp.path("types.jsonl")
        try guardWrite([
            guardUser("one typemarker", ts: "2026-08-24T20:00:00.000Z", cwd: "/tmp/types"),
            guardState("mode", ts: "2026-08-24T20:00:01.000Z"),
            guardUser("two typemarker", ts: "2026-08-24T20:00:02.000Z"),
            guardAssistant("three typemarker", ts: "2026-08-24T20:00:03.000Z"),
            guardState("mode", ts: "2026-08-24T20:00:04.000Z"),
            guardUser("four typemarker", ts: "2026-08-24T20:00:05.000Z"),
            guardState("file-history-snapshot", ts: "2026-08-24T20:00:06.000Z"),
        ], to: file)

        #expect(guardImport(db, guardDiscovered(path: file, uuid: "types-uuid")))

        let sessionId = guardInt(db, "SELECT id FROM sessions")
        #expect(sessionId != nil)
        let counts = fetchTypeCounts(db: db, sessionId: sessionId ?? -1)

        // Every distinct type present, conversational or not.
        #expect(Dictionary(uniqueKeysWithValues: counts.map { ($0.lineType, $0.count) })
                == ["user": 3, "assistant": 1, "mode": 2, "file-history-snapshot": 1])

        // fetchTypeCounts orders by count DESC — the detail pane shows the biggest first.
        #expect(counts.map(\.count) == counts.map(\.count).sorted(by: >))
        #expect(counts.first?.lineType == "user")
        #expect(counts.first?.count == 3)

        // 7 lines total, but only the 4 conversational ones are events…
        #expect(guardInt(db, "SELECT line_count FROM sessions") == 7)
        #expect(guardInt(db, "SELECT event_count FROM sessions") == 4)
        // …and only those 4 are searchable. A state line must never reach the FTS index.
        #expect(guardInt(db, "SELECT count(*) FROM events_fts") == 4)
        #expect(searchEvents(db: db, query: "typemarker", limit: 50).count == 4)
        #expect(searchEvents(db: db, query: "file-history-snapshot", limit: 50).isEmpty)
        #expect(searchEvents(db: db, query: "mode", limit: 50).isEmpty)
    }

    /// `SQL.selectSessionById` duplicates `selectSessionsBase`'s column list, and its own
    /// comment says the two must stay identical because both build a `SessionRow`. Nothing
    /// enforced that. A reordered or dropped column there shows up as a search hit opening
    /// the detail pane with another session's numbers — a wrong answer, not a crash.
    ///
    /// Note the comparison is FIELD BY FIELD on purpose: `SessionRow`'s `Hashable`
    /// conformance defines `==` as `a.id == b.id`, so `#expect(a == b)` would pass no
    /// matter how badly the other ten columns were shuffled.
    @Test("fetchSession returns the same row fetchSessions does, field for field")
    func fetchSessionMatchesFetchSessionsFieldForField() throws {
        let tmp = try GuardSandbox("byid"); defer { tmp.cleanup() }
        let db = tmp.makeDB()

        let file = tmp.path("byid.jsonl")
        try guardWrite([
            guardUser("detail pane marker", ts: "2026-08-24T21:00:00.000Z",
                      cwd: "/workspace/example/by-id"),
            guardAssistant("second line", ts: "2026-08-24T21:00:01.000Z"),
            guardState("mode", ts: "2026-08-24T21:00:02.000Z"),
        ], to: file)
        #expect(guardImport(db, guardDiscovered(path: file, uuid: "byid-uuid")))

        let listed = fetchSessions(db: db, sort: .mtime, direction: .desc, limit: 10)
        #expect(listed.count == 1)
        guard let fromList = listed.first else { return }
        guard let fromId = fetchSession(db: db, id: fromList.id) else {
            Issue.record("fetchSession returned nil for an existing id")
            return
        }

        #expect(fromId.id == fromList.id)
        #expect(fromId.uuid == fromList.uuid)
        #expect(fromId.tier == fromList.tier)
        #expect(fromId.project == fromList.project)
        #expect(fromId.path == fromList.path)
        #expect(fromId.size == fromList.size)
        #expect(fromId.lineCount == fromList.lineCount)
        #expect(fromId.eventCount == fromList.eventCount)
        #expect(fromId.startedAt == fromList.startedAt)
        #expect(fromId.description == fromList.description)
        #expect(fromId.mtime == fromList.mtime)

        // And the values are the real ones, not merely equal to each other.
        #expect(fromId.uuid == "byid-uuid")
        #expect(fromId.tier == "session")
        #expect(fromId.project == "/workspace/example/by-id")
        #expect(fromId.path == file)
        #expect(fromId.lineCount == 3)
        #expect(fromId.eventCount == 2)
        #expect(fromId.startedAt == "2026-08-24T21:00:00.000Z")
        #expect(fromId.description == "detail pane marker")

        // A search hit whose tier is filtered out of the sidebar must still resolve — the
        // stated reason this query ignores the tier filter.
        #expect(fetchSessions(db: db, tier: "workflow_agent", sort: .mtime,
                              direction: .desc, limit: 10).isEmpty)
        #expect(fetchSession(db: db, id: fromList.id) != nil)

        // A missing id is nil, not a crash and not row zero.
        #expect(fetchSession(db: db, id: 999_999) == nil)
    }
}
