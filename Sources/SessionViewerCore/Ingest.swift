// Ingest.swift — the CLI core: list / diff / import against schema.sql.
//
// This is deliberately the SAME code path the future GUI app will call — the design
// review's Integrator lens flagged file-discovery as the hard, easy-to-get-wrong part
// (dig.py's own one-tier-too-shallow glob bug), so it lives here once, not duplicated
// between a CLI and an app target.
//
// Zero third-party deps: SQLite3 is a system library on macOS (import SQLite3), JSON
// parsing is Foundation's JSONSerialization rather than Codable — the schema is 14+
// line types and evolving (confirmed live, ψ/ralph/jsonl-of-neo-oracle...md sibling
// finding), so a strict Codable struct would break on the next field Anthropic adds.

import Foundation
import SQLite3

let CONVERSATIONAL_TYPES: Set<String> = ["user", "assistant", "system"]

struct DiscoveredFile {
    let path: String
    let projectDirName: String
    let tier: String            // "session" | "subagent" | "workflow_agent"
    let sessionUUID: String
    let agentId: String?
    let workflowRunId: String?
    let mtime: Int
    let size: Int
}

// MARK: - Discovery (the part the design review said matters most)

func discoverFiles(root: String) -> [DiscoveredFile] {
    let fm = FileManager.default
    var results: [DiscoveredFile] = []
    guard let projectDirs = try? fm.contentsOfDirectory(atPath: root) else { return results }

    for projectDirName in projectDirs {
        let projectPath = "\(root)/\(projectDirName)"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }

        guard let entries = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

        for entry in entries {
            let entryPath = "\(projectPath)/\(entry)"
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: entryPath, isDirectory: &entryIsDir)

            if !entryIsDir.boolValue, entry.hasSuffix(".jsonl") {
                // Tier 1: top-level session — <project>/<uuid>.jsonl
                let uuid = String(entry.dropLast(".jsonl".count))
                if let stat = statFile(entryPath) {
                    results.append(DiscoveredFile(
                        path: entryPath, projectDirName: projectDirName, tier: "session",
                        sessionUUID: uuid, agentId: nil, workflowRunId: nil,
                        mtime: stat.mtime, size: stat.size))
                }
                continue
            }

            guard entryIsDir.boolValue else { continue }
            let sessionUUID = entry
            let subagentsDir = "\(entryPath)/subagents"
            guard let subEntries = try? fm.contentsOfDirectory(atPath: subagentsDir) else { continue }

            for subEntry in subEntries {
                let subPath = "\(subagentsDir)/\(subEntry)"
                var subIsDir: ObjCBool = false
                fm.fileExists(atPath: subPath, isDirectory: &subIsDir)

                if !subIsDir.boolValue, subEntry.hasSuffix(".jsonl") {
                    // Tier 2: plain subagent — <project>/<uuid>/subagents/<agent>.jsonl
                    let agentId = String(subEntry.dropLast(".jsonl".count))
                    if let stat = statFile(subPath) {
                        results.append(DiscoveredFile(
                            path: subPath, projectDirName: projectDirName, tier: "subagent",
                            sessionUUID: sessionUUID, agentId: agentId, workflowRunId: nil,
                            mtime: stat.mtime, size: stat.size))
                    }
                } else if subIsDir.boolValue, subEntry == "workflows" {
                    // Tier 3: workflow-run agents — the dig.py blind spot this schema exists to not repeat
                    guard let runDirs = try? fm.contentsOfDirectory(atPath: subPath) else { continue }
                    for runDir in runDirs {
                        guard runDir.hasPrefix("wf_") else { continue }
                        let runPath = "\(subPath)/\(runDir)"
                        guard let runEntries = try? fm.contentsOfDirectory(atPath: runPath) else { continue }
                        for f in runEntries {
                            guard f.hasSuffix(".jsonl"), f != "journal.jsonl" else { continue }
                            // journal.jsonl is the run's event log, not a per-agent transcript —
                            // it doesn't fit this table's shape; skipped explicitly, not silently.
                            let fPath = "\(runPath)/\(f)"
                            let agentId = String(f.dropFirst("agent-".count).dropLast(".jsonl".count))
                            if let stat = statFile(fPath) {
                                results.append(DiscoveredFile(
                                    path: fPath, projectDirName: projectDirName, tier: "workflow_agent",
                                    sessionUUID: sessionUUID, agentId: agentId, workflowRunId: runDir,
                                    mtime: stat.mtime, size: stat.size))
                            }
                        }
                    }
                }
            }
        }
    }
    return results
}

func statFile(_ path: String) -> (mtime: Int, size: Int)? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    guard let date = attrs[.modificationDate] as? Date, let size = attrs[.size] as? Int else { return nil }
    return (Int(date.timeIntervalSince1970), size)
}

// MARK: - SQLite helpers (thin — no ORM, matches this fleet's zero-dep preference)

final class DB {
    var handle: OpaquePointer?

    /// Every DB this app opens is opened while ANOTHER thread may be reading or writing the
    /// same file — the live poll, the tailer, the server, an import, and the Database tab's
    /// own status read all touch it. Without a busy timeout a contended access returns
    /// SQLITE_BUSY immediately.
    ///
    /// Applying it in `init` rather than leaving it to callers, because leaving it to
    /// callers is exactly what crashed the app: eight call sites remembered
    /// `setBusyTimeout()` and the two newest (`readDBStatus`, `scanProjects`) did not, so
    /// pressing Choose-folder — which starts a status read and a scan on two background
    /// queues at once — produced SQLITE_BUSY inside `DB.prepare`, which called
    /// `fatalError`. A safety property that each new caller must remember is one that will
    /// eventually be forgotten; this one now cannot be.
    static let defaultBusyTimeoutMs: Int32 = 5_000

    init(path: String) {
        if sqlite3_open(path, &handle) != SQLITE_OK {
            fatalError("cannot open db at \(path): \(String(cString: sqlite3_errmsg(handle)))")
        }
        sqlite3_busy_timeout(handle, DB.defaultBusyTimeoutMs)
        // schema.sql declares `PRAGMA foreign_keys = ON`, but that pragma is PER-CONNECTION
        // and non-persistent, and schema.sql is applied only by `initSchema` — which nothing
        // under Sources/ calls. Measured on the real index: `PRAGMA foreign_keys` = 0. So the
        // `project_id INTEGER NOT NULL REFERENCES projects(id)` constraint has never actually
        // been enforced in the app. Enabling it here makes the declaration true.
        // (Checked before switching it on: 0 orphaned sessions and a clean
        // `PRAGMA foreign_key_check` on the live 1039-session db.)
        sqlite3_exec(handle, "PRAGMA foreign_keys = ON", nil, nil, nil)
    }

    /// Run a statement for its effect. Returns whether it succeeded.
    ///
    /// Same correction as `DB.prepare`: this used to `fatalError` on any non-SQLITE_OK,
    /// which is right for a malformed constant and wrong for SQLITE_BUSY — and BUSY is what
    /// this app actually produces, since BEGIN/COMMIT go through here while the live poll,
    /// the tailer and the server are reading the same file. Hardening `prepare` alone left
    /// this path able to abort the process for the identical reason.
    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(handle))
            // "duplicate column name" is the EXPECTED steady state of an idempotent
            // ALTER TABLE migration — SQLite has no ADD COLUMN IF NOT EXISTS, so the only
            // way to write one is to run it and ignore that specific failure. Logging it
            // every run would train the reader to ignore this channel, which is the last
            // thing a stderr diagnostic should do.
            if msg.hasPrefix("duplicate column name") { return false }
            let first = sql.split(whereSeparator: \.isNewline).first.map(String.init) ?? sql
            FileHandle.standardError.write(
                "sqlite exec failed: \(msg)\n  statement: \(first.prefix(120))\n"
                    .data(using: .utf8)!)
            return false
        }
        return true
    }

    deinit { sqlite3_close(handle) }
}

func initSchema(db: DB, schemaPath: String) {
    guard let sql = try? String(contentsOfFile: schemaPath, encoding: .utf8) else {
        fatalError("cannot read schema at \(schemaPath)")
    }
    db.exec(sql)
}

// MARK: - Diff (identity = path, mtime, size — no content hashing over 541MB, per design note)

struct KnownFile { let mtime: Int; let size: Int; let status: String }

func loadKnownFiles(db: DB) -> [String: KnownFile] {
    var known: [String: KnownFile] = [:]
    // Through `db.prepare`, not a raw `sqlite3_prepare_v2` whose return code was discarded.
    // This was the ONLY SQLite read in Sources/ that bypassed the hardened wrapper, so a
    // failure here produced neither a diagnostic nor a signal — it just looked like an
    // empty index, which would make every file report as "new" and be re-imported.
    guard let stmt = db.prepare(SQL.selectKnownFiles) else { return known }
    while sqlite3_step(stmt) == SQLITE_ROW {
        let path = String(cString: sqlite3_column_text(stmt, 0))
        let mtime = Int(sqlite3_column_int64(stmt, 1))
        let size = Int(sqlite3_column_int64(stmt, 2))
        let status = String(cString: sqlite3_column_text(stmt, 3))
        known[path] = KnownFile(mtime: mtime, size: size, status: status)
    }
    sqlite3_finalize(stmt)
    return known
}

enum DiffState { case new, changed, unchanged }

func diffState(file: DiscoveredFile, known: [String: KnownFile]) -> DiffState {
    guard let k = known[file.path] else { return .new }
    if k.mtime != file.mtime || k.size != file.size { return .changed }
    if k.status != "imported" { return .changed }   // previously failed/pending — retry
    return .unchanged
}
