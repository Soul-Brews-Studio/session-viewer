// VectorStoreTests.swift — the per-class vector split: routing, paths, and the union.
//
// The split exists because of two measured facts (VectorStore.swift carries the numbers):
// conversation is 16.8% of this corpus by characters, and `semanticSearch` is a brute-force
// scan whose cost is the bytes it reads. A wrong ROUTE here is the silent kind of failure —
// a vector written to the wrong class file still searches fine today and simply makes the
// chat file grow toward the size the split exists to avoid.

import Testing
import Foundation
import SQLite3
@testable import SessionViewerCore

@Suite("vector store · roles route to the right class, paths derive from the index")
struct VectorStoreTests {

    /// Every role observed in the real corpus (the five from the by-source measurement,
    /// plus `system`, which Claude emits). If a NEW role ever appears, `of(role:)` sends it
    /// to `.tools` — the safe side, since chat is the small curated class.
    @Test("the five measured corpus roles all route, chat keeps only conversation")
    func corpusRolesRoute() {
        #expect(VectorClass.of(role: "user") == .chat)
        #expect(VectorClass.of(role: "assistant") == .chat)
        #expect(VectorClass.of(role: "tool_use") == .tools)
        #expect(VectorClass.of(role: "tool_result") == .tools)
        #expect(VectorClass.of(role: "developer") == .tools)
        #expect(VectorClass.of(role: "system") == .tools)
    }

    @Test("an unknown future role lands in tools, never in chat")
    func unknownRoleGoesToTools() {
        #expect(VectorClass.of(role: "some_future_role") == .tools,
                "chat is the curated class; anything unrecognised must not dilute it")
    }

    /// No role may be claimed by both classes, and between them the two must cover every
    /// role either one names — otherwise an event could be embedded twice or never.
    @Test("class role sets are disjoint")
    func roleSetsDisjoint() {
        let overlap = VectorClass.chat.roles.intersection(VectorClass.tools.roles)
        #expect(overlap.isEmpty, "role(s) claimed by both classes: \(overlap)")
    }

    @Test("class db paths are siblings of the index, one per class, never colliding")
    func pathsDeriveFromIndex() {
        let idx = "/tmp/some/dir/sessions.db"
        #expect(VectorClass.chat.path(besideIndex: idx) == "/tmp/some/dir/sessions.chat.vec.db")
        #expect(VectorClass.tools.path(besideIndex: idx) == "/tmp/some/dir/sessions.tools.vec.db")
        let all = Set(VectorClass.allCases.map { $0.path(besideIndex: idx) })
        #expect(all.count == VectorClass.allCases.count, "two classes must never share a file")
    }

    /// Pointing the app at a different index must move the vector files WITH it — a class
    /// file resolved from anywhere but the index path would silently mix two corpora.
    @Test("a different index yields different class files")
    func differentIndexDifferentFiles() {
        let a = VectorClass.chat.path(besideIndex: "/tmp/a/sessions.db")
        let b = VectorClass.chat.path(besideIndex: "/tmp/b/sessions.db")
        #expect(a != b)
    }

    @Test("attaching skips class files that do not exist, and reports what it attached")
    func attachSkipsMissing() throws {
        let dir = NSTemporaryDirectory() + "vecstore-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let idx = dir + "/sessions.db"

        // Nothing exists: nothing attaches, and that is a report, not an error.
        let db = DB(path: idx)
        #expect(attachVectorDBs(db, classes: VectorClass.allCases, besideIndex: idx).isEmpty)

        // Create only chat; only chat attaches.
        _ = openVectorDB(class: .chat, besideIndex: idx)
        let db2 = DB(path: idx)
        let attached = attachVectorDBs(db2, classes: VectorClass.allCases, besideIndex: idx)
        #expect(attached == ["vec_chat"])
    }

    /// End to end at the SQL level: insert through the attached schema, read back through
    /// the union statement — the exact statements the builder and the search execute.
    @Test("a vector inserted via the attached schema is found by the union scan")
    func insertAndUnionRoundTrip() throws {
        let dir = NSTemporaryDirectory() + "vecstore-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let idx = dir + "/sessions.db"

        // A minimal main db: the union JOINs main.sessions, so it must exist.
        let main = DB(path: idx)
        main.exec("CREATE TABLE sessions (id INTEGER PRIMARY KEY, session_uuid TEXT)")
        main.exec("INSERT INTO sessions (id, session_uuid) VALUES (7, 'abc-uuid')")

        _ = openVectorDB(class: .chat, besideIndex: idx)
        let attached = attachVectorDBs(main, classes: [.chat], besideIndex: idx)
        #expect(attached == ["vec_chat"])

        let ins = main.prepare(SQL.insertEventVector(schema: "vec_chat"))
        #expect(ins != nil)
        main.bindInt(ins, 1, 7); main.bindInt(ins, 2, 3); main.bindInt(ins, 3, 0)
        main.bindText(ins, 4, "test-model"); main.bindInt(ins, 5, 4)
        let blob = Data([1, 2, 3, 4])
        _ = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(ins, 6, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
        }
        main.bindText(ins, 7, "hello")
        #expect(sqlite3_step(ins) == SQLITE_DONE)
        sqlite3_finalize(ins)

        let scan = main.prepare(SQL.selectVectorsForSearch(schema: "vec_chat"))
        #expect(scan != nil)
        main.bindText(scan, 1, "test-model")
        var rows = 0
        var uuid = ""
        while sqlite3_step(scan) == SQLITE_ROW {
            rows += 1
            uuid = sqlite3_column_text(scan, 1).map { String(cString: $0) } ?? ""
        }
        sqlite3_finalize(scan)
        #expect(rows == 1)
        #expect(uuid == "abc-uuid", "the cross-schema JOIN to main.sessions must resolve")

        // And the class stats read the same truth from the file alone.
        let stats = readVectorClassStats(besideIndex: idx, models: ["test-model"])
        let chat = stats.first { $0.cls == .chat }
        #expect(chat?.vectors == 1)
        #expect(chat?.events == 1)
        let tools = stats.first { $0.cls == .tools }
        #expect(tools?.exists == false)
    }
}
