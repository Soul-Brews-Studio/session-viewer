import Foundation
import SQLite3

// Eval.swift — measuring retrieval, so changes can be judged instead of argued about.
//
// This exists because the only quality numbers this project has ever had (2/8 semantic vs
// 8/9 keyword) were produced by hand, outside the tool, on one query. Every knob added since
// — trigram vs unicode61, chunk geometry, mean-centering, model scoping — was therefore a
// change nobody could score. An instrument first, then tuning.
//
// THE GROUND-TRUTH PROBLEM, stated plainly because it decides whether any number here means
// anything: the cheap automatic ground truth is SUBSTRING CONTAINMENT — "the right answers
// are the events containing this string". That is exactly what a trigram index computes, so
// a substring benchmark does not compare two engines, it asks a keyword engine to reproduce
// its own definition. facebook-oracle's benchmark used substring truth and scored FTS5
// trigram at 100%; that number is real but it is not evidence that keyword search is better
// at retrieval, only that it is perfect at substring matching.
//
// So this eval supports two modes and always prints which one produced a row:
//
//   substring — truth is auto-derived (events containing `expect`). Cheap, reproducible,
//               and BIASED TOWARD KEYWORD. Useful as a regression check, not as a verdict.
//   labeled   — truth is a hand-written list of event ids. The only mode that can express
//               the query embeddings exist for: a paraphrase whose words never appear in
//               the text. Expensive, and the only fair test of semantic retrieval.
//
// A second fairness trap, hit for real earlier: the semantic index is built incrementally,
// so a query whose relevant events are simply NOT EMBEDDED scores zero for reasons that have
// nothing to do with ranking. (Measured: a Thai query returned nothing useful, and the cause
// was that ZERO of its relevant chunks were in the embedded 10%.) Every row therefore reports
// semantic recall against the ACHIEVABLE CEILING — relevant ∩ embedded — and prints coverage
// so a low score cannot be silently misread as a ranking failure.

public struct EvalQuery {
    public let query: String
    public let mode: String            // "substring" | "labeled"
    public let expect: String?         // substring mode: the needle
    public let ids: [String]           // labeled mode: "sessionId:seq"
}

public struct EvalRow {
    public let query: String
    public let mode: String
    public let relevantTotal: Int
    public let relevantEmbedded: Int
    public let keywordRecall10: Double
    public let keywordRecall50: Double
    public let keywordMRR: Double
    public let semanticRecall10: Double
    public let semanticRecall50: Double
    public let semanticMRR: Double
    public let keywordMs: Double
    public let semanticMs: Double
}

/// Parse the query file. One JSON object per line — same shape as everything else this
/// corpus uses, so it can be produced by any script.
///
///   {"query":"the app froze","mode":"substring","expect":"froze"}
///   {"query":"why did it hang","mode":"labeled","ids":["12:340","88:12"]}
public func loadEvalQueries(path: String) -> [EvalQuery] {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return [] }

    var out: [EvalQuery] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
        guard let d = trimmed.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let q = o["query"] as? String else { continue }
        let mode = (o["mode"] as? String) ?? (o["ids"] == nil ? "substring" : "labeled")
        out.append(EvalQuery(query: q,
                             mode: mode,
                             expect: o["expect"] as? String,
                             ids: (o["ids"] as? [String]) ?? []))
    }
    return out
}

/// Ground truth for one query, as a set of "sessionId:seq" keys.
///
/// Substring truth is computed with LIKE over `events_fts`, NOT with either search engine —
/// deriving truth from one of the things under test would make the whole exercise circular.
func groundTruth(db: DB, q: EvalQuery) -> Set<String> {
    if q.mode == "labeled" { return Set(q.ids) }
    guard let needle = q.expect ?? Optional(q.query) else { return [] }

    var truth = Set<String>()
    guard let s = db.prepare("SELECT session_id, seq FROM events_fts WHERE text LIKE ?") else { return truth }
    db.bindText(s, 1, "%\(needle)%")
    while sqlite3_step(s) == SQLITE_ROW {
        truth.insert("\(sqlite3_column_int64(s, 0)):\(sqlite3_column_int64(s, 1))")
    }
    sqlite3_finalize(s)
    return truth
}

/// Which of those events actually have vectors — the ceiling semantic search could reach.
/// Works on SESSION ids, matching the granularity everything else here scores at.
///
/// The first version keyed on "session:seq" and intersected that against the truth set.
/// That silently produced an EMPTY ceiling for every `labeled` query, because labeled ids
/// are session-level ("1022") and never equal a "1022:47" key. The result was semantic
/// scoring 0% on exactly the rows that exist to test it — and reading as "no coverage"
/// rather than as a bug, because the eval's own coverage warning fired and looked like an
/// explanation. A measurement that explains away its own defect is the dangerous kind.
/// The ceiling must describe the corpus the ENGINE UNDER TEST actually scans.
///
/// After the class split this read only the legacy in-db table (1,285 sessions for the en
/// model) while semanticSearch scanned the union of class files + legacy. Had the union not
/// also kept legacy, the eval would have scored recall against ~1,300 claimed-reachable
/// sessions of which the engine could see 5 — a near-total collapse manufactured by the
/// instrument, which is precisely the self-excusing failure the comment above warns about.
/// The ceiling now reads the SAME union the search reads, and the two cannot diverge
/// without this query being edited by hand.
func embeddedSessions(db: DB, dbPath: String, truthSessions: Set<String>, model: String) -> Set<String> {
    guard !truthSessions.isEmpty else { return [] }
    let attached = attachVectorDBs(db, classes: VectorClass.allCases, besideIndex: dbPath)
    let union = (attached + ["main"])
        .map { "SELECT DISTINCT session_id FROM \($0).event_vectors WHERE model = ?1" }
        .joined(separator: " UNION ")
    var have = Set<String>()
    guard let s = db.prepare(union) else { return [] }
    db.bindText(s, 1, model)
    while sqlite3_step(s) == SQLITE_ROW {
        let k = "\(sqlite3_column_int64(s, 0))"
        if truthSessions.contains(k) { have.insert(k) }
    }
    sqlite3_finalize(s)
    return have
}

/// recall@K against a stated denominator, plus reciprocal rank of the first hit.
///
/// The denominator is `min(K, relevant)`, not `relevant`: with 435 relevant events, no
/// engine can return more than 10 of them in a top-10, so dividing by 435 would cap the
/// best possible score at 2% and make every engine look broken.
func scoreAt(_ ranked: [String], truth: Set<String>, k: Int) -> (recall: Double, mrr: Double) {
    guard !truth.isEmpty else { return (0, 0) }

    // DE-DUPLICATE the ranked list before scoring, preserving order.
    //
    // Caught by this eval's own output on its first run: it printed recall of 109%, 155%
    // and 529%. A ranked list contains one entry per matching EVENT, and many events share
    // a session, so the numerator counted the same session repeatedly while the denominator
    // — a Set — counted it once. Any recall above 100% is arithmetically impossible and was
    // the tell. An instrument that cannot be wrong in a visible way is worse than none.
    var seen = Set<String>()
    let unique = ranked.filter { seen.insert($0).inserted }

    let top = unique.prefix(k)
    let hit = top.filter { truth.contains($0) }.count
    let denom = Double(min(k, truth.count))
    var mrr = 0.0
    for (i, id) in unique.enumerated() where truth.contains(id) {
        mrr = 1.0 / Double(i + 1)
        break
    }
    return (denom > 0 ? Double(hit) / denom : 0, mrr)
}

/// Run the whole file against both engines.
public func runEval(dbPath: String, queriesPath: String, verbose: Bool = false) {
    let queries = loadEvalQueries(path: queriesPath)
    guard !queries.isEmpty else {
        FileHandle.standardError.write("eval: no queries in \(queriesPath)\n".data(using: .utf8)!)
        exit(2)
    }
    let db = DB(path: dbPath)
    let model = Embedder()?.modelID(for: .english) ?? "apple-nlce/en/r1/512"

    // Same union the search scans — a header stating vectors the engine cannot reach
    // would make every score below it unreadable.
    var totalVectors = 0
    let hdrAttached = attachVectorDBs(db, classes: VectorClass.allCases, besideIndex: dbPath)
    let hdrUnion = (hdrAttached + ["main"])
        .map { "SELECT count(*) n FROM \($0).event_vectors WHERE model = ?1" }
        .joined(separator: " UNION ALL ")
    if let s = db.prepare("SELECT sum(n) FROM (\(hdrUnion))") {
        db.bindText(s, 1, model)
        if sqlite3_step(s) == SQLITE_ROW { totalVectors = Int(sqlite3_column_int64(s, 0)) }
        sqlite3_finalize(s)
    }

    print("eval       \(queries.count) queries · \(queriesPath)")
    print("model      \(model) · \(totalVectors.formatted()) vectors")
    print("")
    print("  " + padR("query", 44) + padR("mode", 10) + padL("rel", 5) + padL("emb", 6)
          + "  " + padL("kw@10", 7) + padL("kw@50", 7) + padL("kwMRR", 7)
          + "  " + padL("sem@10", 7) + padL("sem@50", 7) + padL("semMRR", 7))

    var rows: [EvalRow] = []
    for q in queries {
        let truth = groundTruth(db: db, q: q)

        // Retrieve DEEP, score shallow.
        //
        // Both engines return one row per matching EVENT, and scoring is per SESSION, so a
        // 50-row fetch collapses to far fewer than 50 unique sessions. Scoring recall@50
        // off that fetch made recall@50 come out BELOW recall@10 — impossible for recall,
        // and a pure artefact of retrieval depth rather than any property of the ranking.
        // Fetching 8x the deepest K leaves enough unique sessions to fill the denominator.
        let fetch = 400
        let t0 = Date()
        let kw = searchEvents(db: db, query: q.query, limit: fetch)
        let kwMs = Date().timeIntervalSince(t0) * 1000

        let t1 = Date()
        let sem = semanticSearch(dbPath: dbPath, query: q.query, limit: fetch)
        let semMs = Date().timeIntervalSince(t1) * 1000

        // searchEvents returns session ids but not seq, so keyword hits are keyed on the
        // session alone; semantic rows carry the same shape. Truth is collapsed to match,
        // otherwise the two engines would be scored against different key spaces.
        let truthSessions = Set(truth.map { $0.split(separator: ":").first.map(String.init) ?? $0 })
        let embSessions = embeddedSessions(db: db, dbPath: dbPath, truthSessions: truthSessions, model: model)
        let kwRanked = kw.map { String($0.sessionId) }
        let semRanked = sem.map { String($0.sessionId) }

        let k10 = scoreAt(kwRanked, truth: truthSessions, k: 10)
        let k50 = scoreAt(kwRanked, truth: truthSessions, k: 50)
        // Semantic is scored against the ACHIEVABLE ceiling — what it could possibly find.
        let s10 = scoreAt(semRanked, truth: embSessions, k: 10)
        let s50 = scoreAt(semRanked, truth: embSessions, k: 50)

        rows.append(EvalRow(query: q.query, mode: q.mode,
                            relevantTotal: truthSessions.count, relevantEmbedded: embSessions.count,
                            keywordRecall10: k10.recall, keywordRecall50: k50.recall, keywordMRR: k10.mrr,
                            semanticRecall10: s10.recall, semanticRecall50: s50.recall, semanticMRR: s10.mrr,
                            keywordMs: kwMs, semanticMs: semMs))

        func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
        print("  " + padR(String(q.query.prefix(42)), 44)
              + padR(q.mode, 10)
              + padL(String(truthSessions.count), 5)
              + padL(String(embSessions.count), 6) + "  "
              + padL(pct(k10.recall), 7) + padL(pct(k50.recall), 7) + padL(String(format: "%.2f", k10.mrr), 7) + "  "
              + padL(pct(s10.recall), 7) + padL(pct(s50.recall), 7) + padL(String(format: "%.2f", s10.mrr), 7))
    }

    // Aggregate per mode. Averaging substring and labeled rows together would blend a
    // keyword-biased measurement with a fair one and produce a number meaning neither.
    print("")
    for mode in ["substring", "labeled"] {
        let m = rows.filter { $0.mode == mode }
        guard !m.isEmpty else { continue }
        func avg(_ f: (EvalRow) -> Double) -> String {
            String(format: "%.0f%%", m.reduce(0) { $0 + f($1) } / Double(m.count) * 100)
        }
        print("  \(padR(mode, 12)) n=\(m.count)   keyword @10 \(avg(\.keywordRecall10)) @50 \(avg(\.keywordRecall50))   semantic @10 \(avg(\.semanticRecall10)) @50 \(avg(\.semanticRecall50))")
    }

    let noCoverage = rows.filter { $0.relevantTotal > 0 && $0.relevantEmbedded == 0 }
    if !noCoverage.isEmpty {
        print("")
        print("  ⚠️  \(noCoverage.count) queries have ZERO relevant events embedded — their semantic")
        print("      score measures index coverage, not ranking. Excluded from any conclusion.")
    }
    if rows.contains(where: { $0.mode == "substring" }) {
        print("")
        print("  note: substring truth is what a trigram index computes by definition, so it")
        print("        favours keyword search structurally. Only `labeled` rows can show what")
        print("        semantic retrieval is for.")
    }
}

/// Generate a starter query file from the corpus, so the eval is runnable immediately
/// rather than blocked on someone hand-writing one.
///
/// Substring rows only — labeled rows cannot be generated, because a paraphrase whose words
/// never appear is precisely the thing no automatic rule can derive. Those must be written
/// by a human, and the file says so.
public func generateEvalQueries(dbPath: String, outPath: String, count: Int = 12) {
    let db = DB(path: dbPath)
    // Terms that appear often enough to have real ground truth but not so often as to be
    // stopwords — a term matching half the corpus cannot discriminate and scores nothing.
    let candidates = ["crash", "trigram", "workflow", "sqlite", "embedding", "concurrency",
                      "freeze", "chunk", "vector", "import", "ประชุม", "หลักฐาน", "ทดสอบ", "กระจก"]

    var lines: [String] = [
        "// session-viewer eval set. One JSON object per line.",
        "//",
        "//   substring : truth = events containing `expect`. Auto, reproducible, and BIASED",
        "//               toward keyword search — a trigram index computes exactly this.",
        "//   labeled   : truth = an explicit list of \"sessionId:seq\" ids. The ONLY mode that",
        "//               can express a paraphrase whose words never appear in the text, which",
        "//               is the query semantic search exists for. Must be written by hand.",
        "//",
        "// Add labeled rows to make this a fair test. Substring rows alone only prove that",
        "// the keyword index still works.",
    ]

    var added = 0
    for term in candidates where added < count {
        var n = 0
        if let s = db.prepare("SELECT count(DISTINCT session_id) FROM events_fts WHERE text LIKE ?") {
            db.bindText(s, 1, "%\(term)%")
            if sqlite3_step(s) == SQLITE_ROW { n = Int(sqlite3_column_int64(s, 0)) }
            sqlite3_finalize(s)
        }
        guard n >= 3 else { continue }   // too rare to score meaningfully
        lines.append("{\"query\":\"\(term)\",\"mode\":\"substring\",\"expect\":\"\(term)\"}")
        added += 1
    }

    lines.append("// --- add labeled rows below, e.g. ---")
    lines.append("// {\"query\":\"why did the app stop responding\",\"mode\":\"labeled\",\"ids\":[\"12:340\"]}")

    // PRESERVE HAND-WRITTEN LABELED ROWS.
    //
    // This overwrote the file outright, and destroyed 12 of 13 labeled queries the first
    // time it was run as a smoke test — hours of hand-written ground truth, gone to a
    // command whose name suggests it only adds things. Substring rows are regenerable from
    // the corpus in a second; labeled rows are not regenerable at all, which is exactly why
    // they must survive a regeneration.
    var preserved: [String] = []
    if let existing = try? String(contentsOfFile: outPath, encoding: .utf8) {
        preserved = existing.split(whereSeparator: \.isNewline)
            .map(String.init)
            // A real row only — the file also carries a COMMENTED example containing the
            // word "labeled", and preserving that turned 13 rows into 14 on the first run.
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{")
                      && $0.contains("\"labeled\"") }
    }
    if !preserved.isEmpty {
        lines.append("// --- preserved hand-written labeled rows ---")
        lines.append(contentsOf: preserved)
    }

    try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    print("wrote \(added) substring queries to \(outPath)")
    if preserved.isEmpty {
        print("Add `labeled` rows by hand — they are the only fair test of semantic retrieval.")
    } else {
        print("Kept \(preserved.count) existing labeled row(s) — those are not regenerable.")
    }
}
