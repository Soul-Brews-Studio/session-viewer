import Foundation
import SQLite3

// The Database tab's model.
//
// It exists because the app could import but never told you WHERE it imported TO, whether
// the file it was writing was brand new or one with 1000 sessions already in it, or what
// the last run actually did. `import_runs` has recorded every run since the first commit
// and was displayed nowhere — this reads it back.
//
// Everything here is derived from two sources and NOTHING else: the db file's own stat,
// and queries against that db. Disk-vs-index drift reuses `discoverFiles` + `loadKnownFiles`
// — the same pair `runImport` itself diffs on — so the "N new / N changed" this tab shows
// is by construction the number the Import button will act on, not a second estimate.

/// Whether this db has ever been imported into. The distinction the user asked for
/// ("new db or old db"), made explicit rather than left to be inferred from a zero.
public enum DBAge: Equatable {
    case missing        // no file on disk at all — first run, nothing created yet
    case empty          // file exists (schema applied) but zero sessions
    case populated(Int) // N sessions already indexed
}

public struct TierStat: Identifiable, Equatable {
    public let tier: String
    public let files: Int
    public let bytes: Int
    public var id: String { tier }
}

public struct ImportRun: Identifiable, Equatable {
    public let id: Int
    public let startedAt: String
    public let finishedAt: String?
    public let scanned: Int
    public let new: Int
    public let changed: Int
    public let skipped: Int
    public let failed: Int

    /// A run with no `finished_at` did not complete. Surfaced, not hidden.
    public var interrupted: Bool { finishedAt == nil }
}

/// Everything the Database tab shows, gathered in one background pass.
public struct DBStatus: Equatable {
    public var dbPath: String = ""
    public var dbExists: Bool = false
    public var dbBytes: Int = 0
    public var dbModified: Date?
    public var age: DBAge = .missing

    public var projects: Int = 0
    public var imported: Int = 0
    public var failed: Int = 0
    public var sourceBytes: Int = 0
    public var events: Int = 0
    public var lines: Int = 0
    public var firstSeen: String?

    public var tiers: [TierStat] = []
    /// Per-source breakdown. Empty on a db that predates multi-source import.
    public var sources: [SourceStat] = []
    public var runs: [ImportRun] = []

    // Disk-vs-index drift — what pressing Import right now would actually do.
    public var onDisk: Int = 0
    public var pendingNew: Int = 0
    public var pendingChanged: Int = 0
    public var goneFromDisk: Int = 0

    public var pendingTotal: Int { pendingNew + pendingChanged }
    public var upToDate: Bool { pendingTotal == 0 && failed == 0 }
}

/// Read the whole status in one background pass. Opens the db read-only-ish through the
/// same `DB` wrapper the rest of the app uses; if the file does not exist yet, returns a
/// `.missing` status instead of creating one — a status read must never have the side
/// effect of creating the thing it reports on.
public func readDBStatus(dbPath: String, root: String, codexRoot: String = defaultCodexRoot) -> DBStatus {
    var s = DBStatus()
    s.dbPath = dbPath

    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: dbPath) {
        s.dbExists = true
        s.dbBytes = (attrs[.size] as? Int) ?? 0
        s.dbModified = attrs[.modificationDate] as? Date
    }

    // Disk side is independent of the db and is worth showing even when there is no db.
    let files = discoverFiles(root: root)
    s.onDisk = files.count

    guard s.dbExists else {
        s.age = .missing
        // Both corpora here too — this branch previously counted Claude only, so
        // "on disk" meant a different population on a fresh db than on an existing one.
        let codexCount = codexFilePaths(root: codexRoot).count
        s.onDisk += codexCount
        s.pendingNew = files.count + codexCount
        return s
    }

    let db = DB(path: dbPath)

    let stmt = db.prepare(SQL.selectDBOverview)
    var sessions = 0
    if sqlite3_step(stmt) == SQLITE_ROW {
        sessions      = Int(sqlite3_column_int64(stmt, 0))
        s.projects    = Int(sqlite3_column_int64(stmt, 1))
        s.imported    = Int(sqlite3_column_int64(stmt, 2))
        s.failed      = Int(sqlite3_column_int64(stmt, 3))
        s.sourceBytes = Int(sqlite3_column_int64(stmt, 4))
        s.events      = Int(sqlite3_column_int64(stmt, 5))
        s.lines       = Int(sqlite3_column_int64(stmt, 6))
        s.firstSeen   = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
    }
    sqlite3_finalize(stmt)
    s.age = sessions == 0 ? .empty : .populated(sessions)

    // Per-source counts. The column is added idempotently so a pre-Codex db reads as all
    // 'claude' rather than failing — which is the honest answer for one.
    _ = db.exec(SQL.addSessionSourceColumn)
    if let ss = db.prepare(SQL.selectSourceCounts) {
        while sqlite3_step(ss) == SQLITE_ROW {
            func txt(_ i: Int32) -> String { sqlite3_column_text(ss, i).map { String(cString: $0) } ?? "" }
            s.sources.append(SourceStat(source: txt(0), tier: txt(1),
                                        files: Int(sqlite3_column_int64(ss, 2)),
                                        bytes: Int(sqlite3_column_int64(ss, 3)),
                                        events: Int(sqlite3_column_int64(ss, 4))))
        }
        sqlite3_finalize(ss)
    }

    let tierStmt = db.prepare(SQL.selectTierCounts)
    while sqlite3_step(tierStmt) == SQLITE_ROW {
        guard let t = sqlite3_column_text(tierStmt, 0) else { continue }
        s.tiers.append(TierStat(tier: String(cString: t),
                                files: Int(sqlite3_column_int64(tierStmt, 1)),
                                bytes: Int(sqlite3_column_int64(tierStmt, 2))))
    }
    sqlite3_finalize(tierStmt)

    let runStmt = db.prepare(SQL.selectImportRuns)
    db.bindInt(runStmt, 1, 12)
    while sqlite3_step(runStmt) == SQLITE_ROW {
        func txt(_ i: Int32) -> String? { sqlite3_column_text(runStmt, i).map { String(cString: $0) } }
        s.runs.append(ImportRun(
            id: Int(sqlite3_column_int64(runStmt, 0)),
            startedAt: txt(1) ?? "",
            finishedAt: txt(2),
            scanned: Int(sqlite3_column_int64(runStmt, 3)),
            new: Int(sqlite3_column_int64(runStmt, 4)),
            changed: Int(sqlite3_column_int64(runStmt, 5)),
            skipped: Int(sqlite3_column_int64(runStmt, 6)),
            failed: Int(sqlite3_column_int64(runStmt, 7))))
    }
    sqlite3_finalize(runStmt)

    // The same diff `runImport` performs, so this number and the button agree.
    let known = loadKnownFiles(db: db)
    var seen = Set<String>()
    for f in files {
        seen.insert(f.path)
        guard let k = known[f.path] else { s.pendingNew += 1; continue }
        if k.mtime != f.mtime || k.size != f.size { s.pendingChanged += 1 }
    }
    // CODEX FILES GO THROUGH THE SAME DIFF, not just into `seen`. Half-covering them made
    // the panel self-contradictory: "on disk 1357" printed beside "indexed 1966", and a
    // new rollout raised neither pending count. The diff needs only (path, mtime, size) —
    // a stat per file, no header probes — so the status read stays cheap.
    for path in codexFilePaths(root: codexRoot) {
        seen.insert(path)
        guard let st = statFile(path) else { continue }
        s.onDisk += 1
        guard let k = known[path] else { s.pendingNew += 1; continue }
        if k.mtime != st.mtime || k.size != st.size { s.pendingChanged += 1 }
    }
    // Rows whose file is gone. Per SPEC this is expected (sessions get pruned at 30 days),
    // so it is reported as information, never as corruption.
    //
    // BOTH ROOTS. This diff walked only ~/.claude/projects, so all 627 Codex rollouts —
    // alive on disk in ~/.codex/sessions — were counted as "pruned from disk". A chip
    // asserting files are gone when they exist is worse than no chip: it teaches the
    // reader to ignore the one number that would matter if pruning ever really bit.
    s.goneFromDisk = known.keys.filter { !seen.contains($0) }.count

    return s
}

/// One project as seen ON DISK by a scan, with how much of it the index already has.
/// Distinct from the `projects` table: this row can exist for a project that has never
/// been imported, which is exactly the case the "scan and choose" flow is for.
public struct ProjectScan: Identifiable, Equatable {
    public let dirName: String
    /// Real path when a session file inside it declares one; the encoded dirname otherwise.
    /// SPEC is explicit that the dirname is lossy and must never be decoded back to a path.
    public let cwd: String?
    public let files: Int
    public let bytes: Int
    public let newFiles: Int
    public let changedFiles: Int
    public var id: String { dirName }

    public var pending: Int { newFiles + changedFiles }
    public var display: String { cwd ?? dirName }
}

/// Scan a root and group what is there by project, marking what the index is missing.
///
/// `cwd` is recovered by reading the FIRST LINE of one session file per project rather
/// than decoding the directory name — the dirname replaces both `/` and `.` with `-` and
/// is ambiguous in both directions (SPEC.md). One line per project, not per file.
public func scanProjects(root: String, dbPath: String) -> [ProjectScan] {
    let files = discoverFiles(root: root)
    guard !files.isEmpty else { return [] }

    var known: [String: KnownFile] = [:]
    if FileManager.default.fileExists(atPath: dbPath) {
        known = loadKnownFiles(db: DB(path: dbPath))
    }

    var byProject: [String: (files: Int, bytes: Int, new: Int, changed: Int, sample: String, sampleIsTier1: Bool)] = [:]
    for f in files {
        var e = byProject[f.projectDirName] ?? (0, 0, 0, 0, f.path, false)
        e.files += 1
        e.bytes += f.size
        if let k = known[f.path] {
            if k.mtime != f.mtime || k.size != f.size { e.changed += 1 }
        } else {
            e.new += 1
        }
        // Prefer a TIER-1 file for the cwd probe. Workflow-agent and subagent transcripts
        // do not reliably carry `cwd` in their opening lines, so probing whichever file
        // happened to be walked first left real projects displaying their lossy encoded
        // dirname. (First version guarded on `sample.isEmpty`, which was never true — the
        // tuple is seeded with a path — so the preference never applied.)
        if f.tier == "session" && !e.sampleIsTier1 {
            e.sample = f.path
            e.sampleIsTier1 = true
        }
        byProject[f.projectDirName] = e
    }

    return byProject.map { name, e in
        ProjectScan(dirName: name, cwd: firstLineCwd(path: e.sample), files: e.files,
                    bytes: e.bytes, newFiles: e.new, changedFiles: e.changed)
    }
    .sorted { $0.files > $1.files }
}

/// Read just enough of a file to find its `cwd`. Bounded read — the p99 file is 39.6 MB and
/// this is called once per project during a scan.
func firstLineCwd(path: String, probeBytes: Int = 64 * 1024) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let data = try? fh.read(upToCount: probeBytes), !data.isEmpty else { return nil }
    for slice in data.split(separator: 0x0A).prefix(4) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any],
              let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
        return cwd
    }
    return nil
}

/// `session-viewer scan --root DIR` — the project list the Database tab's Scan button
/// produces, as text. Same `scanProjects`; lets a chosen folder be checked before importing.
public func runScanCLI(root: String, dbPath: String) {
    let ps = scanProjects(root: root, dbPath: dbPath)
    guard !ps.isEmpty else {
        print("no session files found under \(root)")
        return
    }
    let files = ps.reduce(0) { $0 + $1.files }
    let bytes = ps.reduce(0) { $0 + $1.bytes }
    let pending = ps.reduce(0) { $0 + $1.pending }
    print("root       \(root)")
    print("projects   \(ps.count)   files \(files)   \(humanBytes(bytes))   pending \(pending)")
    print("")
    print("  " + padL("files", 6) + " " + padL("size", 9) + " " + padL("new", 6)
              + " " + padL("changed", 8) + "  project")
    for p in ps {
        print("  " + padL(String(p.files), 6)
                  + " " + padL(humanBytes(p.bytes), 9)
                  + " " + padL(p.newFiles == 0 ? "-" : String(p.newFiles), 6)
                  + " " + padL(p.changedFiles == 0 ? "-" : String(p.changedFiles), 8)
                  + "  " + p.display)
    }
}

/// One (source, tier) pair — the breakdown that answers "which tool produced this".
public struct SourceStat: Identifiable, Equatable {
    public let source: String        // "claude" | "codex"
    public let tier: String
    public let files: Int
    public let bytes: Int
    public let events: Int
    public var id: String { "\(source)/\(tier)" }
}

/// One row of a tier drill-down.
public struct TierSession: Identifiable, Equatable {
    public let path: String
    public let uuid: String
    public let agentId: String?
    public let bytes: Int
    public let events: Int
    public let project: String
    public var id: String { path }

    /// Agent name when the filename encodes one, else the uuid head — same recovery rule
    /// the Live tab uses, so a session is called the same thing in both places.
    public var label: String {
        agentDisplayName(agentId: agentId) ?? String(uuid.prefix(8))
    }
}

/// The sessions behind one tier count, biggest first. Read on demand when a tier row is
/// opened — there is no reason to hold 754 workflow-agent rows for a panel showing three.
public func tierSessions(dbPath: String, tier: String, limit: Int = 25) -> [TierSession] {
    guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
    let db = DB(path: dbPath)
    let stmt = db.prepare(SQL.selectSessionsInTier)
    db.bindText(stmt, 1, tier)
    db.bindInt(stmt, 2, limit)
    var out: [TierSession] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func txt(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        out.append(TierSession(path: txt(0) ?? "",
                               uuid: txt(1) ?? "",
                               agentId: txt(2),
                               bytes: Int(sqlite3_column_int64(stmt, 3)),
                               events: Int(sqlite3_column_int64(stmt, 4)),
                               project: txt(5) ?? ""))
    }
    sqlite3_finalize(stmt)
    return out
}

/// Fixed-width padding for the CLI tables.
///
/// Replaces `String(format:"%s", (swift as NSString).utf8String!)`, which SEGFAULTED
/// (`exit=139`): `utf8String` returns a pointer owned by a TEMPORARY NSString that is
/// already released by the time `%s` reads it. The same pattern sat in the status and
/// graph printers and happened not to crash there, which is the worst outcome — a
/// use-after-free that usually looks fine. There is no reason to reach for C formatting
/// here at all.
func padL(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

func padR(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}

/// Byte formatter shared by the Database tab. `.file` so a 40 MB db reads as "40 MB".
public func humanBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

/// `session-viewer status` — prints exactly what the Database tab renders, so the tab's
/// claims are checkable from a terminal. Same `readDBStatus`; no second implementation.
public func runStatusCLI(dbPath: String, root: String,
                         codexRoot: String = defaultCodexRoot) {
    let s = readDBStatus(dbPath: dbPath, root: root, codexRoot: codexRoot)

    let age: String
    switch s.age {
    case .missing:          age = "NEW — no database file yet (Import will create it)"
    case .empty:            age = "EMPTY — schema present, zero sessions"
    case .populated(let n): age = "EXISTING — \(n) sessions already indexed"
    }

    print("database   \(s.dbPath)")
    print("state      \(age)")
    print("size       \(s.dbExists ? humanBytes(s.dbBytes) : "—")")
    print("")
    print("on disk    \(s.onDisk) files")
    print("indexed    \(s.imported)   projects \(s.projects)   failed \(s.failed)")
    print("events     \(s.events)   lines \(s.lines)   source \(humanBytes(s.sourceBytes))")
    print("")
    if s.upToDate {
        print("pending    none — index matches disk")
    } else {
        print("pending    \(s.pendingNew) new · \(s.pendingChanged) changed · \(s.failed) failed")
    }
    if s.goneFromDisk > 0 {
        print("pruned     \(s.goneFromDisk) indexed rows whose file is gone (expected — 30d cleanup)")
    }
    if !s.sources.isEmpty {
        print("")
        print("  BY SOURCE")
        for x in s.sources {
            print("  " + padR(x.source, 8) + padR(x.tier, 16) + padL(String(x.files), 6)
                      + padL(humanBytes(x.bytes), 11) + padL(x.events.formatted(), 10) + " events")
        }
    }
    if !s.tiers.isEmpty {
        print("")
        for t in s.tiers {
            print("  " + padR(t.tier, 16) + " " + padL(String(t.files), 6) + "  " + humanBytes(t.bytes))
        }
    }
    if !s.runs.isEmpty {
        print("")
        print("  run  started              scanned    new  changed  failed")
        for r in s.runs.prefix(8) {
            print("  #" + padR(String(r.id), 3) + " " + padR(r.startedAt, 20)
                      + " " + padL(String(r.scanned), 7) + " " + padL(String(r.new), 6)
                      + " " + padL(String(r.changed), 8) + " " + padL(String(r.failed), 7)
                      + (r.interrupted ? "  interrupted" : ""))
        }
    }
}

/// One line answering "how current is this index" — the most recent import run.
/// Lives here rather than MCP.swift so the sqlite symbols stay where the imports are.
public func lastImportRunLine(dbPath: String) -> String {
    let db = DB(path: dbPath)
    guard let q = db.prepare(SQL.selectImportRuns) else { return "never" }
    defer { sqlite3_finalize(q) }
    db.bindInt(q, 1, 1)
    guard sqlite3_step(q) == SQLITE_ROW else { return "never" }
    let id = sqlite3_column_int64(q, 0)
    let fin = sqlite3_column_text(q, 2).map { String(cString: $0) } ?? "unfinished"
    let new = sqlite3_column_int64(q, 4)
    let chg = sqlite3_column_int64(q, 5)
    return "run \(id) · finished \(fin) UTC · \(new) new, \(chg) changed"
}
