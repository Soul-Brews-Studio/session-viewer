// CLI.swift — the headless subcommand bodies: `diff` / `list` / `import` / `search`.
//
// These used to live in main.swift. They moved here unchanged when the package was split
// into a library (SessionViewerCore) + a thin executable, because an executableTarget
// cannot be imported by a test target — so anything a test needs to reach has to live in
// a library. main.swift now holds ONLY argument dispatch; every line of behaviour below
// is byte-identical to what it ran before the split.
//
// `public` here is exactly "what the executable calls". Everything else in this module
// stays internal and is reached by tests via `@testable import SessionViewerCore`.

import Foundation
import SQLite3

// MARK: - diff

public func runDiff(dbPath: String, root: String) {
    let db = DB(path: dbPath)
    let files = discoverFiles(root: root)
    let known = loadKnownFiles(db: db)

    var new = 0, changed = 0, unchanged = 0
    var newBytes = 0, changedBytes = 0

    for f in files {
        switch diffState(file: f, known: known) {
        case .new:       new += 1; newBytes += f.size
        case .changed:   changed += 1; changedBytes += f.size
        case .unchanged: unchanged += 1
        }
    }

    let missing = known.keys.filter { path in !files.contains { $0.path == path } }

    print("scanned   \(files.count) files under \(root)")
    print("new       \(new)  (\(newBytes / 1_000_000) MB)")
    print("changed   \(changed)  (\(changedBytes / 1_000_000) MB)")
    print("unchanged \(unchanged)")
    if !missing.isEmpty {
        // Not an error: sessions DO get pruned from disk while the index keeps the row.
        // Surfaced rather than hidden, because "the index has more than disk" is a real
        // and expected state here, not corruption.
        print("in db but no longer on disk: \(missing.count)")
    }
}

// MARK: - list (sorted)

/// Print the indexed sessions in the requested order. Reads only — the same
/// `fetchSessions` the app calls, so a sort proven here is the sort the UI gets.
public func runList(dbPath: String, tier: String?, sort: SessionSort, direction: SortDirection, limit: Int) {
    let db = DB(path: dbPath)
    let rows = fetchSessions(db: db, tier: tier, sort: sort, direction: direction, limit: limit)

    // Pad by Character count, not utf8 count — the ▲/▼ sort marker is multi-byte.
    // Overlong cells are trimmed to n-1 so there is always at least one space before the
    // next column: a full-width path ran straight into the events number without it.
    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count)
    }
    /// Paths are distinctive at the END (…/Soul-Brews-Studio/digger-oracle); a head-trim
    /// leaves every fleet repo showing the same "…/github.com/Soul-Brews-St".
    func padTail(_ s: String, _ n: Int) -> String {
        guard s.count >= n else { return pad(s, n) }
        return "…" + String(s.suffix(n - 2)) + " "
    }
    /// Descriptions are the first user message verbatim, and real ones contain newlines
    /// (`<command-message>recap</command-message>\n<command-name>…`). Unflattened, one row
    /// wraps onto several lines and the whole table stops lining up.
    func oneLine(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
        return String(flat.prefix(n))
    }
    func title(_ key: SessionSort) -> String {
        key == sort ? "\(key.label)\(direction.arrow)" : key.label
    }

    print(pad(title(.tier), 15) + pad(title(.project), 34)
        + pad(title(.events), 8) + pad(title(.lines), 8) + pad(title(.size), 9)
        + pad(title(.started) + " utc", 18) + pad(title(.mtime) + " utc", 18) + title(.description))

    for r in rows {
        let started = (r.startedAt.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") }) ?? "—"
        print(pad(r.tier, 15) + padTail(r.project, 34)
            + pad("\(r.eventCount)", 8) + pad("\(r.lineCount)", 8) + pad("\(r.size / 1000)", 9)
            + pad(started, 18) + pad(utcStamp(epoch: r.mtime, format: "yyyy-MM-dd HH:mm"), 18)
            + oneLine(r.description ?? r.uuid, 60))
    }
    print("\(rows.count) rows · sort \(sort.rawValue) \(direction.rawValue) · tier \(tier ?? "all") · limit \(limit)")
}

// MARK: - import

/// Summary of one import run — returned so callers (CLI print, or the app's status
/// line) can report results without re-querying import_runs.
public struct ImportSummary {
    public let runId: Int
    public let new: Int
    public let changed: Int
    public let skipped: Int
    public let failed: Int
}

/// The one import code path — used by both the CLI `import` subcommand and the app's
/// Import button (on a background queue). `onProgress`, when given, is called once per
/// file scanned (after) with (filesDone, filesTotal) so a caller can show progress
/// without duplicating this loop.
/// `only`, when non-nil, restricts the run to those project directory names. It filters
/// AFTER discovery rather than by walking a subset of directories, so a selective import
/// and a full one see the identical three-tier file set and cannot disagree about what
/// exists — the selection narrows what is written, never what is found.
@discardableResult
/// `force` re-parses every file even when `(path, mtime, size)` says it is unchanged.
///
/// Needed because the import diff is, correctly, about the FILE — so when the SCHEMA gains
/// something (the trigram index did exactly this), an ordinary import skips all 1031
/// unchanged files and the new index stays empty forever while every status line reports
/// success. A diff that tracks source freshness cannot also track index completeness;
/// this flag is the seam between them.
public func runImport(dbPath: String, root: String,
                      only: Set<String>? = nil,
                      force: Bool = false,
                      sinceCutoff: Int? = nil,
                      onProgress: ((Int, Int) -> Void)? = nil) -> ImportSummary {
    let db = DB(path: dbPath)
    var files = discoverFiles(root: root)
    if let only { files = files.filter { only.contains($0.projectDirName) } }
    // A since-window bounds which files are even CONSIDERED (by mtime), so "sync the last
    // 7 days" on a 30k-file corpus doesn't re-diff 30k rows. The (path, mtime, size) diff
    // below still decides new/changed/unchanged within the window.
    if let sinceCutoff { files = files.filter { $0.mtime >= sinceCutoff } }
    let known = loadKnownFiles(db: db)

    let runIns = db.prepare(SQL.insertImportRun)
    db.bindInt(runIns, 1, files.count)
    sqlite3_step(runIns); sqlite3_finalize(runIns)
    let runId = db.lastInsertId

    var new = 0, changed = 0, skipped = 0, failed = 0
    db.exec(SQL.begin)

    for (i, f) in files.enumerated() {
        defer { onProgress?(i + 1, files.count) }
        let state = diffState(file: f, known: known)
        if state == .unchanged && !force { skipped += 1; continue }

        // A project id that could not be established is a FAILED file, not a file to write
        // under whatever id happened to be lying around.
        guard let projectId = upsertProject(db: db, dirName: f.projectDirName, cwd: nil) else {
            failed += 1
            continue
        }
        let existing = existingSessionId(db: db, path: f.path)

        if importFile(db: db, file: f, projectId: projectId, existingId: existing) {
            if state == .new { new += 1 } else { changed += 1 }
        } else {
            failed += 1
        }

        if (i + 1) % 50 == 0 {
            db.exec(SQL.commit); db.exec(SQL.begin)
            FileHandle.standardError.write("  … \(i + 1)/\(files.count)\n".data(using: .utf8)!)
        }
    }

    db.exec(SQL.commit)

    // LINK tier-2/3 rows to their owning session. The parent's identity is not a guess —
    // a subagent or workflow-agent file lives under <project>/<uuid>/subagents/…, so it
    // CARRIES the parent's uuid, and both rows are in this table. The column sat NULL for
    // 1,232 rows (241 subagent + 991 workflow_agent, measured) purely because nothing
    // joined them. Scoped by project_id as well as uuid: one uuid can appear under two
    // projects when a repo is worked on from two checkouts, and cross-linking those would
    // be silently wrong in exactly the way nothing would ever surface.
    //
    // Runs after every import, not as a one-time migration, so newly imported workers are
    // linked in the same pass that indexed them. A worker whose parent transcript is not
    // in the index stays NULL — an honest unknown, not an error.
    // The count is BEFORE-minus-AFTER on the unparented set, not sqlite3_changes():
    // changes() counts every row the WHERE matched, INCLUDING rows whose subquery
    // returned NULL and which remain unparented — so a corpus with orphans would print
    // the same "linked N" lie on every import, forever. ORDER BY p.id makes the pick
    // deterministic if two tier-1 rows ever share (uuid, project): today none do, but
    // that is a property of this corpus, not of the schema, and an arbitrary pick that
    // varies between runs would be wrong in a way nothing surfaces.
    func unparented() -> Int {
        guard let st = db.prepare("""
            SELECT count(*) FROM sessions
            WHERE source='claude' AND file_tier != 'session' AND parent_session_id IS NULL
            """) else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }
    let orphansBefore = unparented()
    db.exec("""
        UPDATE sessions SET parent_session_id = (
            SELECT p.id FROM sessions p
            WHERE p.session_uuid = sessions.session_uuid
              AND p.project_id = sessions.project_id
              AND p.file_tier = 'session'
              AND p.source = 'claude'
            ORDER BY p.id LIMIT 1)
        WHERE source = 'claude' AND file_tier != 'session' AND parent_session_id IS NULL
        """)
    let orphansAfter = unparented()
    let linked = orphansBefore - orphansAfter
    if linked > 0 {
        print("linked     \(linked) subagent/workflow row(s) to their parent session")
    }
    if orphansAfter > 0 {
        print("unlinked   \(orphansAfter) row(s) whose parent transcript is not indexed")
    }

    let upd = db.prepare(SQL.updateImportRun)
    db.bindInt(upd, 1, new); db.bindInt(upd, 2, changed)
    db.bindInt(upd, 3, skipped); db.bindInt(upd, 4, failed); db.bindInt(upd, 5, runId)
    sqlite3_step(upd); sqlite3_finalize(upd)

    print("import run \(runId): \(new) new, \(changed) changed, \(skipped) skipped, \(failed) failed")
    return ImportSummary(runId: runId, new: new, changed: changed, skipped: skipped, failed: failed)
}

// MARK: - search (CLI twin of the app's search box)

public func runSearchCLI(dbPath: String, query: String, limit: Int) {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
        FileHandle.standardError.write("search: need a query\nusage: session-viewer search <text> [--limit N]\n".data(using: .utf8)!)
        exit(2)
    }
    let db = DB(path: dbPath)
    db.setBusyTimeout()
    let t0 = Date()
    let hits = searchEvents(db: db, query: query, limit: limit)
    // The CLI writes to the SAME log the Search tab reads — one history, not two.
    logSearch(dbPath: dbPath, query: query,
              engine: usesTrigram(query) ? "trigram" : "unicode61",
              model: nil, hits: hits, ms: Date().timeIntervalSince(t0) * 1000)
    // Name the index that actually answered. This line printed `ftsQuery(query)`
    // unconditionally, so a Thai query routed to trigram still displayed the unicode61
    // form complete with a `*` it never used — the debug output contradicted the code.
    let tri = usesTrigram(query)
    print("query \(query.debugDescription) → \(tri ? "trigram" : "unicode61") \(tri ? trigramQuery(query) : ftsQuery(query))")
    for h in hits {
        let ts = h.ts.map { String($0.prefix(19)) } ?? "—"
        let flat = h.snippet.replacingOccurrences(of: "\n", with: "⏎ ")
        let snip = flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
        let sc = String(format: "%7.2f", h.score)
        print("  \(sc)  \(h.role.padding(toLength: 10, withPad: " ", startingAt: 0)) \(ts)  \(snip)")
    }
    print("\(hits.count) hit(s)")
}
