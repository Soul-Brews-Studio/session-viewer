// VectorStore.swift — vectors split across per-class databases, queried together.
//
// WHY SPLIT AT ALL. Measured on this corpus, by character count:
//
//   tool_result  205.4 M  68.4%     user       36.9 M  12.3%
//   tool_use      27.0 M   9.0%     assistant  13.5 M   4.5%
//   developer     17.6 M   5.9%
//
// Conversation is 16.8% of the text. The other 83% is tool traffic, and tool traffic is
// exactly where keyword search already scores 100% recall on this corpus — nobody
// paraphrases a build log. So embedding all of it costs ~6× more for the queries semantic
// search is worst at.
//
// WHY SEPARATE FILES RATHER THAN A `role` COLUMN. Because of how the search actually runs:
// `semanticSearch` has no index to seek with — it is a brute-force cosine scan that loads
// EVERY vector for the model into memory (measured: 193,246 vectors, 395.8 MB of blobs)
// and compares them one at a time. There is no query plan to improve; the cost is the
// bytes read. A predicate would still read them. A separate file is not read at all.
//
// So the speed-up is proportional to what is left out, and searching chat only touches
// ~1/6 of the corpus. That is a property of a linear scan, not of SQLite — with an indexed
// lookup a column and a WHERE would have been the better answer.
//
// The classes are queried TOGETHER when that is what is wanted: SQLite ATTACHes the other
// databases and the reads UNION across them, so "search everything" is still one statement
// and one pass.

import Foundation
import SQLite3

/// Which corpus a vector belongs to. The split is by ROLE, because role is what predicts
/// both the size of the text and whether a paraphrase query could ever want it.
public enum VectorClass: String, CaseIterable, Sendable {
    /// What people and the model said to each other. Small, and the only place a paraphrase
    /// query has any hope — "what did we decide about the Thai tokenizer" is answered here.
    case chat
    /// Tool calls, their output, and injected system/developer text. 83% of the corpus by
    /// characters, and the part keyword search already answers perfectly.
    case tools

    /// The roles that land in this class. `developer` is grouped with tools deliberately:
    /// measured, it is 2,123 rows carrying only 37 DISTINCT texts — the same AGENTS.md
    /// injected ~57 times over. Embedding it is duplication that crowds the top-K, not
    /// conversation.
    public var roles: Set<String> {
        switch self {
        case .chat:  return ["user", "assistant"]
        case .tools: return ["tool_use", "tool_result", "developer", "system"]
        }
    }

    public static func of(role: String) -> VectorClass {
        VectorClass.chat.roles.contains(role) ? .chat : .tools
    }

    /// Sibling file of the index it belongs to: `.data/sessions.db` → `.data/sessions.chat.vec.db`.
    ///
    /// Derived rather than configured so that pointing the app at a different index cannot
    /// leave it reading another index's vectors — the failure would be silent and the
    /// results would look plausible.
    public func path(besideIndex indexPath: String) -> String {
        let base = (indexPath as NSString).deletingPathExtension
        return "\(base).\(rawValue).vec.db"
    }
}

/// Open (creating if needed) the vector database for one class.
func openVectorDB(class cls: VectorClass, besideIndex indexPath: String) -> DB {
    let db = DB(path: cls.path(besideIndex: indexPath))
    // WAL, matching the main index. Left at the DELETE default, committing the build's
    // transaction needs an EXCLUSIVE lock on this file — so a concurrent semanticSearch
    // holding SHARED while it loads blobs could make COMMIT return SQLITE_BUSY, which is
    // the opening move of the silent-rollback failure the commit path now guards against.
    // WAL lets the reader and the committer coexist, removing the common trigger.
    db.exec("PRAGMA journal_mode=WAL")
    db.exec(SQL.createEventVectors)
    return db
}

/// ATTACH every requested class onto `db` under a stable schema name, returning the names
/// that actually attached.
///
/// A class whose file does not exist yet is skipped rather than created: a read should not
/// bring a database into being as a side effect, and a missing file legitimately means
/// "nothing of that kind has been embedded".
@discardableResult
func attachVectorDBs(_ db: DB, classes: [VectorClass], besideIndex indexPath: String) -> [String] {
    // IDEMPOTENT, because callers legitimately attach twice on one connection (runEval
    // attaches for its header and again per query). A second `ATTACH … AS vec_chat` fails
    // with "already in use" — and with the failure correctly not appended, the union would
    // silently shrink to legacy-only on every call after the first. Already-attached
    // schemas are therefore read off `database_list` and reported as attached, which is
    // what they are.
    var already = Set<String>()
    if let s = db.prepare("PRAGMA database_list") {
        while sqlite3_step(s) == SQLITE_ROW {
            if let n = sqlite3_column_text(s, 1) { already.insert(String(cString: n)) }
        }
        sqlite3_finalize(s)
    }

    var attached: [String] = []
    for cls in classes {
        let p = cls.path(besideIndex: indexPath)
        let schemaName = "vec_\(cls.rawValue)"
        if already.contains(schemaName) { attached.append(schemaName); continue }
        guard FileManager.default.fileExists(atPath: p) else { continue }
        // The schema name is a fixed identifier derived from a closed enum, never from
        // caller input — SQLite cannot bind an identifier, so this is the same discipline
        // SessionSort follows for ORDER BY.
        let schema = "vec_\(cls.rawValue)"
        let escaped = p.replacingOccurrences(of: "'", with: "''")
        // Append ONLY on success. The first version discarded exec's Bool (it is
        // @discardableResult, so not even a warning) and reported the schema as attached
        // regardless — and a phantom schema poisons every statement built from this list:
        // the coverage union failed to PREPARE, wiping even the legacy counts to zero, and
        // the search union failed the same way while the legacy fallback stayed off
        // because this list was non-empty. Verified by the adversarial pass, not guessed.
        if db.exec("ATTACH DATABASE '\(escaped)' AS \(schema)") {
            attached.append(schema)
        }
    }
    return attached
}

/// One SELECT over the attached class databases, UNIONed.
///
/// Returns nil when nothing is attached — the caller must treat that as "no vectors", which
/// is different from "no matches" and is why this is an Optional rather than a query that
/// returns zero rows.
public func vectorUnionSQL(schemas: [String], columns: String, whereClause: String) -> String? {
    guard !schemas.isEmpty else { return nil }
    return schemas
        .map { "SELECT \(columns) FROM \($0).event_vectors v \(whereClause)" }
        .joined(separator: "\nUNION ALL\n")
}

/// Vector count and byte size per class — what the UI needs to say where the index actually
/// lives, and the CLI to prove the split happened.
public struct VectorClassStats {
    public let cls: VectorClass
    public let vectors: Int
    public let events: Int
    public let bytes: Int
    public let exists: Bool
}

/// `models` is every space this embedder writes (en + th here). Binding en alone showed
/// "28,089 events" for a class file that held 31,611 — the 3,522 Thai-routed events were
/// embedded, searchable, and reported as absent, the same hole the coverage counts had.
public func readVectorClassStats(besideIndex indexPath: String, models: [String]) -> [VectorClassStats] {
    let list = Array(repeating: "?", count: max(1, models.count)).joined(separator: ",")
    return VectorClass.allCases.map { cls in
        let p = cls.path(besideIndex: indexPath)
        guard FileManager.default.fileExists(atPath: p) else {
            return VectorClassStats(cls: cls, vectors: 0, events: 0, bytes: 0, exists: false)
        }
        let db = DB(path: p)
        guard let s = db.prepare("""
            SELECT count(*), count(DISTINCT session_id || ':' || seq),
                   coalesce(sum(length(vector)), 0)
              FROM event_vectors WHERE model IN (\(list))
            """) else {
            return VectorClassStats(cls: cls, vectors: 0, events: 0, bytes: 0, exists: true)
        }
        defer { sqlite3_finalize(s) }
        for (i, m) in models.enumerated() { db.bindText(s, Int32(i + 1), m) }
        guard sqlite3_step(s) == SQLITE_ROW else {
            return VectorClassStats(cls: cls, vectors: 0, events: 0, bytes: 0, exists: true)
        }
        return VectorClassStats(cls: cls,
                                vectors: Int(sqlite3_column_int64(s, 0)),
                                events: Int(sqlite3_column_int64(s, 1)),
                                bytes: Int(sqlite3_column_int64(s, 2)),
                                exists: true)
    }
}
