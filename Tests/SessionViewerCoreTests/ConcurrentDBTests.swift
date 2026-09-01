// ConcurrentDBTests.swift
//
// The app crashed (EXC_BREAKPOINT, 2026-08-25 00:38) with two of its own background queues
// reading the same SQLite file:
//
//   Thread 1: DBView.refresh() -> readDBStatus -> DB.prepare -> fatalError
//   Thread 3: DBView.scan()    -> scanProjects -> loadKnownFiles -> sqlite3_step
//
// Three defects, each independently sufficient to be worth a test:
//   1. DB.prepare called fatalError on a RUNTIME condition (SQLITE_BUSY), killing the app.
//   2. readDBStatus/scanProjects never set a busy timeout — the only two of ten DB call
//      sites that forgot, because it was the caller's job to remember.
//   3. DBView.refresh() and DBView.scan() ran on the concurrent global queue, and
//      chooseFolder() invokes both back to back.
//
// These tests cover 1 and 2 directly. 3 is structural (a private serial queue in a SwiftUI
// view) and is covered by making 1 and 2 impossible to hit.

import Testing
import Foundation
import SQLite3
@testable import SessionViewerCore

private func tempDBPath(_ name: String) -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sv-conc-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("test.db").path
}

@Suite("crash regression · a failed prepare must not kill the process")
struct PrepareFailureTests {

    @Test("preparing invalid SQL returns nil instead of trapping")
    func invalidSQLReturnsNil() {
        let db = DB(path: tempDBPath("badsql"))
        // Before the fix this line terminated the test runner via fatalError.
        let stmt = db.prepare("SELECT * FROM a_table_that_does_not_exist")
        #expect(stmt == nil)
    }

    @Test("preparing against a table the db does not have yet returns nil")
    func missingTableReturnsNil() {
        // The realistic shape: a db created before `events_fts_tri` existed. A schema
        // addition must degrade to an empty result, never to an abort.
        let db = DB(path: tempDBPath("missingtable"))
        #expect(db.prepare(SQL.searchEventsTri) == nil)
    }

    @Test("a nil statement is safe to step and finalize — the empty-result contract")
    func nilStatementIsSafe() {
        let db = DB(path: tempDBPath("nilstmt"))
        let stmt = db.prepare("SELECT * FROM nope")
        #expect(stmt == nil)
        // This is what every read loop in the codebase does with the result. If nil were
        // not safe here, returning nil would have traded a crash for a different crash.
        #expect(sqlite3_step(stmt) != SQLITE_ROW)
        sqlite3_finalize(stmt)
    }
}

@Suite("crash regression · every DB carries a busy timeout")
struct BusyTimeoutTests {

    @Test("a busy timeout is applied at construction, not left to the caller")
    func timeoutSetInInit() {
        let path = tempDBPath("busy")
        let db = DB(path: path)
        db.exec("CREATE TABLE t (x)")

        // Prove the handle actually has a busy handler: a second connection holds an
        // EXCLUSIVE lock, and a write from the first must WAIT rather than fail instantly.
        let holder = DB(path: path)
        holder.exec("BEGIN EXCLUSIVE")

        let started = Date()
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.handle, "INSERT INTO t VALUES (1)", -1, &stmt, nil)
        #expect(rc == SQLITE_OK)
        let step = sqlite3_step(stmt)
        let waited = Date().timeIntervalSince(started)
        sqlite3_finalize(stmt)

        // It should have blocked for a meaningful fraction of the 5 s timeout rather than
        // returning SQLITE_BUSY immediately. Without a busy handler this returns in ~0 s.
        #expect(step == SQLITE_BUSY)
        #expect(waited > 1.0, "returned after \(waited)s — the busy timeout is not applied")

        holder.exec("ROLLBACK")
    }
}

@Suite("crash regression · concurrent readers on one file")
struct ConcurrentReadTests {

    /// The actual crash shape, in-process: many threads opening their own DB on the same
    /// file and reading at once, which is what `refresh()` and `scan()` were doing.
    @Test("16 concurrent readers on one db file all complete", .timeLimit(.minutes(1)))
    func concurrentReaders() {
        let path = tempDBPath("readers")
        let seed = DB(path: path)
        seed.exec("CREATE TABLE sessions (id INTEGER PRIMARY KEY, file_path TEXT UNIQUE, file_mtime INT, file_size INT, import_status TEXT)")
        for i in 0..<400 {
            seed.exec("INSERT INTO sessions (file_path, file_mtime, file_size, import_status) VALUES ('/p/\(i)', \(i), \(i * 10), 'imported')")
        }

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var counts: [Int] = []

        for _ in 0..<16 {
            DispatchQueue.global(qos: .userInitiated).async {
                // Each thread opens its OWN handle, exactly as readDBStatus and
                // scanProjects do — this is not a shared-handle misuse test.
                let db = DB(path: path)
                let known = loadKnownFiles(db: db)
                lock.lock(); counts.append(known.count); lock.unlock()
                done.signal()
            }
        }
        for _ in 0..<16 { done.wait() }

        #expect(counts.count == 16)
        // Every reader must see the FULL set. A short read here would mean an error was
        // being misread as "no more rows" — the silent-truncation bug this repo has hit.
        let short = counts.filter { $0 != 400 }
        #expect(short.isEmpty, "readers saw truncated result sets: \(short)")
    }
}

@Suite("crash regression · upsertProject never returns an unverified id")
struct UpsertProjectTests {

    /// The latent data-corruption bug: the old implementation discarded its INSERT's step
    /// result and returned `db.lastInsertId`, which is the last SUCCESSFUL insert on the
    /// connection. When the INSERT did not happen, it handed back ANOTHER row's id and the
    /// importer filed that project's sessions under it — reporting success. Foreign keys
    /// could not catch it: they are off on these connections, and a valid-but-wrong id
    /// satisfies the constraint anyway.
    @Test("a second call for the same dirname returns the SAME id, not a new rowid")
    func idempotentUpsert() {
        let path = tempDBPath("upsert")
        let db = DB(path: path)
        db.exec("CREATE TABLE projects (id INTEGER PRIMARY KEY, dir_name TEXT UNIQUE NOT NULL, cwd TEXT, first_seen_at TEXT DEFAULT (datetime('now')), last_seen_at TEXT DEFAULT (datetime('now')))")

        let a = upsertProject(db: db, dirName: "-opt-Code-alpha", cwd: nil)
        let b = upsertProject(db: db, dirName: "-opt-Code-alpha", cwd: "/opt/Code/alpha")
        #expect(a != nil)
        #expect(a == b, "the same project resolved to two different ids: \(String(describing: a)) vs \(String(describing: b))")
    }

    @Test("an unrelated insert between calls cannot leak its rowid into the result")
    func noLastInsertRowidLeak() {
        let path = tempDBPath("leak")
        let db = DB(path: path)
        db.exec("CREATE TABLE projects (id INTEGER PRIMARY KEY, dir_name TEXT UNIQUE NOT NULL, cwd TEXT, first_seen_at TEXT DEFAULT (datetime('now')), last_seen_at TEXT DEFAULT (datetime('now')))")
        db.exec("CREATE TABLE noise (id INTEGER PRIMARY KEY, x TEXT)")

        let first = upsertProject(db: db, dirName: "-opt-Code-alpha", cwd: nil)

        // Push last_insert_rowid() far away from any projects rowid. The old code read that
        // counter, so this is the exact shape that produced a wrong id.
        for i in 0..<50 { db.exec("INSERT INTO noise (x) VALUES ('n\(i)')") }

        let again = upsertProject(db: db, dirName: "-opt-Code-alpha", cwd: nil)
        #expect(again == first, "upsertProject returned a foreign rowid: \(String(describing: again)) — expected \(String(describing: first))")

        // And the id it returns must genuinely be this project's row.
        let stmt = db.prepare("SELECT dir_name FROM projects WHERE id = ?")
        db.bindInt(stmt, 1, again ?? -1)
        var name = ""
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) { name = String(cString: c) }
        sqlite3_finalize(stmt)
        #expect(name == "-opt-Code-alpha")
    }

    @Test("cwd is filled once known and never overwritten back to nil")
    func cwdCoalesce() {
        let path = tempDBPath("cwd")
        let db = DB(path: path)
        db.exec("CREATE TABLE projects (id INTEGER PRIMARY KEY, dir_name TEXT UNIQUE NOT NULL, cwd TEXT, first_seen_at TEXT DEFAULT (datetime('now')), last_seen_at TEXT DEFAULT (datetime('now')))")

        _ = upsertProject(db: db, dirName: "-p", cwd: nil)
        _ = upsertProject(db: db, dirName: "-p", cwd: "/real/path")
        // A subagent file lacking cwd must NOT wipe the real path a session file supplied.
        _ = upsertProject(db: db, dirName: "-p", cwd: nil)

        let stmt = db.prepare("SELECT cwd FROM projects WHERE dir_name='-p'")
        var cwd: String? = nil
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) { cwd = String(cString: c) }
        sqlite3_finalize(stmt)
        #expect(cwd == "/real/path")
    }
}
