import Foundation
import NaturalLanguage
import SQLite3

// Embed.swift — the SECOND index: on-device semantic vectors.
//
// Step 1 (trigram FTS) already shipped and is the better keyword engine. This is not its
// replacement, and the measurements say so plainly. From laris-co/facebook-oracle's
// benchmark on 5,000 real vault messages, 73% Thai, substring ground truth:
//
//     FTS5 trigram (keyword)      recall@10 100%   build 0.19s     ~10 MB   no deps
//     e5-small        C=20 S=10             88%    build 16.2s      27 MB   PyTorch+HF
//     Apple NLCE      C=20 S=10             60%    build 136.9s    196 MB   no deps
//
// Read that honestly: on a benchmark whose ground truth is SUBSTRING CONTAINMENT, trigram
// wins because substring matching is exactly what it does. That benchmark cannot express
// the query embeddings exist for — a paraphrase, a synonym, a description of a thing whose
// words never appear. So this index is not here to beat trigram at trigram's job; it is
// here to answer the queries trigram structurally cannot, and the UI says so rather than
// implying "newer is better".
//
// Two findings from that research are load-bearing here:
//
//   UNIFORM CHUNKING IS THE BIGGEST LEVER. Larger than the vector database, larger than
//   exact-vs-ANN, larger than which model: chunking took e5 55%→88% and Apple NLCE
//   30%→60%. So chunking is not a tuning knob here, it is the design.
//
//   `maximumSequenceLength` IS 256 TOKENS (probed on this machine). A chunk that overruns
//   the window cannot influence its own vector's tail, so every long chunk drifts toward
//   the same centroid. Chunks are sized well inside it.

/// Chunking parameters. `C=20 S=10` — 20-word window, 10-word stride — is the
/// configuration that produced the near-doubling above, not a guess.
/// Chunk geometry.
///
/// DEFAULTS CHANGED 2026-08-25, from the borrowed C=20/S=10 to C=100/S=50, for two measured
/// reasons:
///
///  1. C=20/S=10 came from facebook-oracle's benchmark on 12-400 character chat messages.
///     Our events are median 149 chars but p90 2,276 and max 218,955, so the same window
///     produced ~23 chunks per event — 44,387 vectors from 1,930 events, extrapolating to
///     ~918 MB for the corpus.
///  2. There is a hard ceiling the other way. `maximumSequenceLength` is 256 tokens, and
///     overrunning it is SILENT: two 200-word chunks sharing a head but with completely
///     different tails embed to cosine **1.000000** — identical, because the tails were
///     truncated away before reaching the model. At 60 words the same pair differs
///     (0.998397). Measured 120 words -> 241 tokens, so 100 words leaves real headroom for
///     text that tokenizes less kindly than the probe did.
///
/// So the window is bounded above by the model and below by chunk count, and 100/50 sits
/// between them. It is not a tuned optimum — no eval exists yet to tune against.
public struct ChunkPlan {
    public var words: Int = 100
    public var stride: Int = 50

    /// Hard ceiling on chunks produced from ONE event. 0 disables it.
    ///
    /// This is the single biggest lever on build cost, and the corpus says so. Measured over
    /// 24,461 already-embedded events:
    ///
    ///   chunks/event   events            vectors    share of all work
    ///   1–4            19,839  (81%)      24,804     14%
    ///   33–64             573              25,972     15%
    ///   65+               453  (1.9%)      81,804     47%     ← largest single event: 1,497
    ///
    /// So 1.9% of events generate 47% of the embedding, and the worst one alone costs ~50
    /// seconds of model time. Those are giant tool results — a build log, a file dump — cut
    /// into hundreds of 50%-overlapping windows.
    ///
    /// Capping is not only a speed argument. Those windows are near-duplicates of each
    /// other, so a query that matches one matches dozens, and they crowd the top-K with many
    /// slices of a single event. Bounding them should improve precision as well as cost.
    ///
    /// The kept chunks are the FIRST N: a tool result leads with the command and the start
    /// of its output, which is the part that identifies it. The tail of a 40 KB log is the
    /// least retrievable text in the corpus.
    public var maxChunks: Int = 32

    /// DEFAULTS MUST MATCH THE PROPERTY INITIALIZERS ABOVE.
    ///
    /// They did not. The properties declared 100/50 with a doc comment explaining the
    /// measured change from 20/10, but this init's parameter defaults were left at 20/10
    /// and unconditionally overwrite them — so `ChunkPlan()` produced 20/10 and the
    /// property initializers were dead code. The CLI passes words/stride explicitly and was
    /// unaffected; the app never passed a plan, so EVERY build launched from the window ran
    /// at the old geometry. `vector_runs` recorded it the whole time:
    ///
    ///     run 1 | 20|10   run 2 | 100|50   run 4 | 20|10   run 6 | 20|10   run 7 | 100|50
    ///           (UI)            (CLI)            (UI)            (UI)            (CLI)
    ///
    /// It matters more now that chunks are capped: at 20/10 a 32-chunk cap stops at word
    /// 330, where at 100/50 it reaches word 1,650. The wrong default made the cap five
    /// times more aggressive than the measurements behind it assumed.
    public init(words: Int = 100, stride: Int = 50, maxChunks: Int = 32) {
        self.words = max(1, words)
        self.stride = max(1, min(stride, self.words))
        self.maxChunks = max(0, maxChunks)
    }
}

/// Split text into overlapping word windows. Overlap is the point: a phrase that straddles
/// a boundary is lost by disjoint chunking, and that loss is what the stride recovers.
///
/// Thai has no spaces, so splitting on whitespace would make one enormous "word" out of a
/// whole sentence. `NLTokenizer` segments Thai correctly (verified on this corpus), so
/// tokenization goes through it rather than through `split(separator: " ")`.
public func chunkText(_ text: String, plan: ChunkPlan = ChunkPlan()) -> [String] {
    // COLLAPSE WHITESPACE RUNS before anything else. Measured on tool-heavy samples,
    // whitespace is ~14% of characters; runs of it carry no meaning the embedding can use,
    // and collapsing is the one "strip special chars" idea that costs nothing semantically
    // — unlike stripping punctuation, which would destroy Thai combining marks and
    // identifiers. EMBED PATH ONLY: FTS never sees this, so keyword search is unchanged.
    let collapsed = text.replacingOccurrences(of: "\\s+", with: " ",
                                              options: .regularExpression)
    let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let tok = NLTokenizer(unit: .word)
    tok.string = trimmed
    var words: [Range<String.Index>] = []
    tok.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { r, _ in
        words.append(r); return true
    }
    guard words.count > plan.words else { return [trimmed] }

    var out: [String] = []
    var i = 0
    while i < words.count {
        let end = min(i + plan.words, words.count)
        let lo = words[i].lowerBound
        let hi = words[end - 1].upperBound
        out.append(String(trimmed[lo..<hi]))
        if end == words.count { break }
        // Stop at the ceiling rather than trimming afterwards, so the windows never get
        // built in the first place — the cost being avoided is downstream (one model call
        // per chunk), but building 1,497 substrings of a 40 KB string is not free either.
        if plan.maxChunks > 0 && out.count >= plan.maxChunks { break }
        i += plan.stride
    }
    return out
}

/// Loads and caches the per-language embedding models.
///
/// Loading is expensive and the model is per SCRIPT, not per language — probed on this
/// machine: Latn(20 languages), Deva(10), Hans(4), Cyrl(4), Arab(2), and **Thai(1)**, all
/// 512-dim. Only Latn, Hans and Thai have assets downloaded here, so anything else falls
/// back rather than failing the whole build.
public final class Embedder {
    public let dimension: Int
    private var models: [NLLanguage: NLContextualEmbedding] = [:]
    private let recognizer = NLLanguageRecognizer()

    /// Languages we will attempt. Kept to the ones with assets present locally; asking for
    /// a model whose assets are absent costs a failed load per call.
    private static let supported: [NLLanguage] = [.english, .thai, .simplifiedChinese, .japanese]

    public init?() {
        guard let probe = NLContextualEmbedding(language: .english) else { return nil }
        self.dimension = probe.dimension
    }

    private func model(for language: NLLanguage) -> NLContextualEmbedding? {
        if let m = models[language] { return m }
        guard let m = NLContextualEmbedding(language: language), m.hasAvailableAssets else { return nil }
        do { try m.load() } catch { return nil }
        models[language] = m
        return m
    }

    /// Which model to embed this text with. Detection matters because a Thai string put
    /// through the Latin model is not an error — it silently produces a meaningless vector,
    /// which is the worst kind of wrong.
    public func language(of text: String) -> NLLanguage {
        recognizer.reset()
        recognizer.processString(text)
        guard let l = recognizer.dominantLanguage, Embedder.supported.contains(l) else { return .english }
        return l
    }

    /// The FULL identity of the space a vector lives in: provider, language, asset
    /// revision, dimension. Two vectors may only be compared when these strings match.
    ///
    /// Language is part of it because Apple's per-language models are separate spaces —
    /// measured, same text, en vs th cosine -0.0227. Revision is part of it because a macOS
    /// update can re-mint the assets at the same dimension, and dimension equality is not
    /// model identity.
    public func modelID(for language: NLLanguage) -> String {
        let rev = models[language]?.revision ?? NLContextualEmbedding(language: language)?.revision ?? 0
        return "apple-nlce/\(language.rawValue)/r\(rev)/\(dimension)"
    }

    /// Mean-pooled sentence vector plus the identity of the space it belongs to.
    /// Returning them together is deliberate — a vector without its space is unusable, and
    /// the previous signature made it easy to store one without the other. It did exactly
    /// that for 44,387 vectors.
    public func embed(_ text: String) -> (vector: [Float], model: String)? {
        let lang = language(of: text)
        guard let v = vector(for: text) else { return nil }
        // Report the language actually used, including the English fallback.
        let used = models[lang] != nil ? lang : .english
        return (v, modelID(for: used))
    }

    /// Mean-pooled sentence vector, L2-normalised so a dot product IS cosine similarity.
    public func vector(for text: String) -> [Float]? {
        let lang = language(of: text)
        guard let m = model(for: lang) ?? model(for: .english) else { return nil }
        guard let result = try? m.embeddingResult(for: text, language: lang) else { return nil }

        var sum = [Float](repeating: 0, count: dimension)
        var n = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += Float(v[i]) }
            n += 1
            return true
        }
        guard n > 0 else { return nil }

        var norm: Float = 0
        for i in 0..<sum.count { sum[i] /= Float(n); norm += sum[i] * sum[i] }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        for i in 0..<sum.count { sum[i] /= norm }
        return sum
    }
}

// MARK: - storage

/// Float32 little-endian, packed. Stored as a BLOB rather than JSON: 512 floats is 2 KB
/// packed against roughly 6 KB as text, and the read side wants a buffer it can dot-product
/// without parsing.
func packVector(_ v: [Float]) -> Data {
    var copy = v
    return copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
}

func unpackVector(_ d: Data, dimension: Int) -> [Float]? {
    guard d.count == dimension * MemoryLayout<Float>.size else { return nil }
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// Both vectors are already L2-normalised, so this is cosine similarity.
func dot(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0
    for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
    return s
}

public struct EmbedProgress {
    public let done: Int
    public let total: Int
    public let vectors: Int
}

public struct EmbedSummary {
    public let events: Int
    public let vectors: Int
    public let skipped: Int
    public let seconds: Double
}

/// How much of the corpus already has vectors.
public struct EmbedCoverage: Equatable {
    public var embeddedEvents: Int = 0
    public var totalEvents: Int = 0
    public var vectors: Int = 0
    public var dimension: Int = 0
    public var bytes: Int = 0
    public var assetsReady: Bool = false
    public var thaiReady: Bool = false

    /// Providers other than `apple` that have written to this index. Non-empty means the
    /// corpus has left this machine, and the UI must stop saying otherwise.
    public var remoteProviders: [String] = []
    /// A build that never recorded a finish — crashed, killed, or still running.
    public var unfinishedRuns: Int = 0

    /// Distinct chunk geometries ("100/50") that have written vectors into this index,
    /// biggest first, with their vector counts.
    ///
    /// More than one entry means the index is MIXED, and that is not self-correcting:
    /// `selectUnembedded` treats an event as done if any vector exists for
    /// (session_id, seq, model) — chunk geometry is not part of that key. So an event
    /// embedded at the old 20/10 geometry is skipped by every future build forever, and
    /// re-running to "fix" it silently does nothing.
    ///
    /// Surfaced for the same reason as `remoteProviders`: it is a fact about the index that
    /// the UI would otherwise state the opposite of.
    public var geometries: [(geom: String, vectors: Int)] = []

    public static func == (a: EmbedCoverage, b: EmbedCoverage) -> Bool {
        a.embeddedEvents == b.embeddedEvents && a.totalEvents == b.totalEvents
            && a.vectors == b.vectors && a.dimension == b.dimension && a.bytes == b.bytes
            && a.assetsReady == b.assetsReady && a.thaiReady == b.thaiReady
            && a.remoteProviders == b.remoteProviders && a.unfinishedRuns == b.unfinishedRuns
            && a.geometries.map(\.geom) == b.geometries.map(\.geom)
            && a.geometries.map(\.vectors) == b.geometries.map(\.vectors)
            && a.chatTotalEvents == b.chatTotalEvents
            && a.chatEmbeddedEvents == b.chatEmbeddedEvents
            && a.legacyVectors == b.legacyVectors
    }

    /// Chat-scoped coverage — the population the app's only build button can actually
    /// reach. The bar and headline use these; the corpus-wide numbers stay as context.
    public var chatTotalEvents: Int = 0
    public var chatEmbeddedEvents: Int = 0

    /// Vectors still in the legacy in-db table. This — not run history — is what the
    /// mixed-geometry warning gates on: `vector_runs` is append-only, so a warning derived
    /// from history alone could never clear, still citing vectors an index no longer
    /// contains after the drop.
    public var legacyVectors: Int = 0

    public var fraction: Double { totalEvents == 0 ? 0 : Double(embeddedEvents) / Double(totalEvents) }
    public var chatFraction: Double {
        chatTotalEvents == 0 ? 0 : Double(chatEmbeddedEvents) / Double(chatTotalEvents)
    }
}

public func readEmbedCoverage(dbPath: String) -> EmbedCoverage {
    var c = EmbedCoverage()
    c.assetsReady = NLContextualEmbedding(language: .english)?.hasAvailableAssets ?? false
    c.thaiReady = NLContextualEmbedding(language: .thai)?.hasAvailableAssets ?? false
    guard FileManager.default.fileExists(atPath: dbPath) else { return c }

    let db = DB(path: dbPath)
    db.exec(SQL.createEventVectors)
    db.exec(SQL.createVectorRuns)

    if let s = db.prepare(SQL.selectRemoteProviders) {
        while sqlite3_step(s) == SQLITE_ROW {
            if let p = sqlite3_column_text(s, 0) { c.remoteProviders.append(String(cString: p)) }
        }
        sqlite3_finalize(s)
    }
    if let s = db.prepare("SELECT count(*) FROM vector_runs WHERE finished_at IS NULL") {
        if sqlite3_step(s) == SQLITE_ROW { c.unfinishedRuns = Int(sqlite3_column_int64(s, 0)) }
        sqlite3_finalize(s)
    }
    if let s = db.prepare("""
        SELECT chunk_words || '/' || chunk_stride, sum(vectors)
        FROM vector_runs WHERE vectors > 0 AND chunk_words IS NOT NULL
        GROUP BY 1 ORDER BY 2 DESC
        """) {
        while sqlite3_step(s) == SQLITE_ROW {
            if let g = sqlite3_column_text(s, 0) {
                c.geometries.append((String(cString: g), Int(sqlite3_column_int64(s, 1))))
            }
        }
        sqlite3_finalize(s)
    }

    // COVERAGE COUNTS EVERY PLACE VECTORS LIVE — the legacy in-db table AND the per-class
    // sibling files. Counting only the legacy table would freeze the headline number the
    // moment the split landed, while the real index grew invisibly in the class files:
    // "24,067 / 98,797 embedded" would sit still through an entire successful build, which
    // is this project's signature failure (a number that means something other than its
    // label) arriving in the panel built to prevent it.
    //
    // Distinctness matters: an event embedded in BOTH the legacy table and a class file
    // (the deliberate re-embed that unifies geometry) is one embedded event, not two — so
    // the count runs over a UNION of (session_id, seq) pairs, not a sum of counts.
    let attached = attachVectorDBs(db, classes: VectorClass.allCases, besideIndex: dbPath)
    let sources = ["main"] + attached
    // BOTH of this embedder's spaces. Counting en alone hid every Thai vector from every
    // number on the panel — 7,879 vectors over 2,383 events, embedded, searchable, and
    // reported as absent.
    let pairUnion = sources
        .map { "SELECT session_id, seq FROM \($0).event_vectors WHERE model IN (?1, ?2)" }
        .joined(separator: " UNION ")
    let sums = sources
        .map { "SELECT count(*) n, coalesce(max(dim),0) d, coalesce(sum(length(vector)),0) b FROM \($0).event_vectors WHERE model IN (?1, ?2)" }
        .joined(separator: " UNION ALL ")
    let model = Embedder()?.modelID(for: .english) ?? "apple-nlce/en/r1/512"
    let thModel = Embedder()?.modelID(for: .thai) ?? "apple-nlce/th/r1/512"
    if let s = db.prepare("SELECT count(*) FROM (\(pairUnion))") {
        db.bindText(s, 1, model); db.bindText(s, 2, thModel)
        if sqlite3_step(s) == SQLITE_ROW { c.embeddedEvents = Int(sqlite3_column_int64(s, 0)) }
        sqlite3_finalize(s)
    }
    if let s = db.prepare("SELECT sum(n), max(d), sum(b) FROM (\(sums))") {
        db.bindText(s, 1, model); db.bindText(s, 2, thModel)
        if sqlite3_step(s) == SQLITE_ROW {
            c.vectors = Int(sqlite3_column_int64(s, 0))
            c.dimension = Int(sqlite3_column_int64(s, 1))
            c.bytes = Int(sqlite3_column_int64(s, 2))
        }
        sqlite3_finalize(s)
    }

    // CHAT-SCOPED numbers for the progress bar. The corpus denominator is 98,797 events of
    // every role, but the only build the app offers is chat-only — against the corpus total
    // the bar tops out around 37% FOREVER, which reads as a permanently stalled build to
    // someone who has already reported three false freezes. The bar must divide reachable
    // by reachable.
    if let s = db.prepare("SELECT count(*) FROM main.event_vectors") {
        if sqlite3_step(s) == SQLITE_ROW { c.legacyVectors = Int(sqlite3_column_int64(s, 0)) }
        sqlite3_finalize(s)
    }

    let chatRoles = VectorClass.chat.roles.sorted().map { "'\($0)'" }.joined(separator: ",")
    if let s = db.prepare("SELECT count(*) FROM events_fts WHERE role IN (\(chatRoles))") {
        if sqlite3_step(s) == SQLITE_ROW { c.chatTotalEvents = Int(sqlite3_column_int64(s, 0)) }
        sqlite3_finalize(s)
    }
    if let s = db.prepare("""
        SELECT count(*) FROM (\(pairUnion)) p
        JOIN events_fts e ON e.session_id = p.session_id AND e.seq = p.seq
        WHERE e.role IN (\(chatRoles))
        """) {
        db.bindText(s, 1, model); db.bindText(s, 2, thModel)
        if sqlite3_step(s) == SQLITE_ROW { c.chatEmbeddedEvents = Int(sqlite3_column_int64(s, 0)) }
        sqlite3_finalize(s)
    }
    if let s = db.prepare("SELECT count(*) FROM events_fts") {
        if sqlite3_step(s) == SQLITE_ROW { c.totalEvents = Int(sqlite3_column_int64(s, 0)) }
        sqlite3_finalize(s)
    }
    return c
}

/// Build (or extend) the vector index.
///
/// `limit` exists because this is SLOW and the UI must not pretend otherwise: ~35 ms per
/// text measured on this machine, so the full 119k-event corpus is roughly 70 minutes.
/// `minLength` skips text too short to carry meaning — a 3-character line produces a vector
/// that is noise wearing a number.
@discardableResult
/// `classes` decides WHICH corpus gets embedded, and defaults to chat alone.
///
/// Measured: conversation (`user` + `assistant`) is 16.8% of this corpus by characters;
/// the rest is tool traffic, where keyword search already scores 100% recall and where
/// paraphrase queries — the only thing this index is for — do not occur. The default turns
/// a ~5 h full build into ~1 h, and anyone who wants tool vectors asks for them by name.
public func buildEmbeddings(dbPath: String,
                            limit: Int = 0,
                            minLength: Int = 24,
                            plan: ChunkPlan = ChunkPlan(),
                            classes: [VectorClass] = [.chat],
                            shouldStop: (() -> Bool)? = nil,
                            onProgress: ((EmbedProgress) -> Void)? = nil) -> EmbedSummary {
    let t0 = Date()
    guard let embedder = Embedder() else {
        return EmbedSummary(events: 0, vectors: 0, skipped: 0, seconds: 0)
    }

    let db = DB(path: dbPath)
    db.exec(SQL.createEventVectors)
    db.exec(SQL.createVectorRuns)

    // Vectors land in PER-CLASS SIBLING FILES (sessions.chat.vec.db …), not the legacy
    // event_vectors table — see VectorStore.swift for the measured argument. Each file is
    // created first (ATTACH alone would skip a missing file by design), then attached so
    // the work-list NOT EXISTS and the inserts address it by schema name.
    //
    // Resume semantics follow from where NOT EXISTS points: the check runs against the
    // CLASS file, so events embedded only in the legacy mixed-geometry table are re-embedded
    // here at the current, correct geometry. That is deliberate — it is the rebuild the
    // mixed-geometry warning says is the only way to unify, arriving class by class.
    for cls in classes { _ = openVectorDB(class: cls, besideIndex: dbPath) }
    attachVectorDBs(db, classes: classes, besideIndex: dbPath)

    // Open the provenance row BEFORE any work, so a build that crashes or is killed leaves
    // an UNFINISHED row behind rather than no evidence at all. `finished_at IS NULL` is the
    // signal, not an accident — the same property `import_runs` was built with.
    var runId = 0
    if let r = db.prepare(SQL.insertVectorRun) {
        db.bindText(r, 1, embedder.modelID(for: .english))
        db.bindText(r, 2, "apple")   // only provider today; a remote script records its own
        db.bindText(r, 3, nil)       // endpoint nil == nothing left this machine
        db.bindInt(r, 4, plan.words)
        db.bindInt(r, 5, plan.stride)
        if sqlite3_step(r) == SQLITE_DONE { runId = db.lastInsertId }
        sqlite3_finalize(r)
    }

    // Only rows that have no vector yet, so a build is resumable — stopping and pressing
    // the button again continues instead of starting over.
    // Collecting the work list is itself slow on a full run — a NOT EXISTS over 19,482
    // events, loading their text. It reported nothing while it ran, so the UI sat at
    // "Building… 0/19,482" and looked hung before a single vector had been attempted.
    // It now emits progress with total==0, which the panel renders as an indeterminate
    // "finding work…" rather than a determinate bar frozen at zero.
    var rows: [(sessionId: Int, seq: Int, text: String, schema: String)] = []
    // Scope the work list to the model we are about to build with. A corpus already
    // embedded by a DIFFERENT model is not embedded for this one.
    let targetModel = embedder.modelID(for: .english)
    let thaiModel = embedder.modelID(for: .thai)
    // One pass per class, chat first (the order of `classes`), sharing one `limit` budget.
    // Each class's NOT EXISTS runs against its own attached file, which is what makes a
    // stopped build resume instead of restart.
    for cls in classes {
        if limit > 0 && rows.count >= limit { break }
        let schema = "vec_\(cls.rawValue)"
        var sql = SQL.selectUnembedded(rolesIn: cls.roles.sorted(), vectorSchema: schema)
        if limit > 0 { sql += " LIMIT ?3" }
        guard let s = db.prepare(sql) else { continue }
        db.bindText(s, 1, targetModel)
        db.bindText(s, 2, thaiModel)
        if limit > 0 { db.bindInt(s, 3, limit - rows.count) }
        var scanned = 0
        while sqlite3_step(s) == SQLITE_ROW {
            if shouldStop?() == true { break }
            scanned += 1
            if scanned % 2000 == 0 {
                onProgress?(EmbedProgress(done: 0, total: 0, vectors: 0))
            }
            guard let t = sqlite3_column_text(s, 2) else { continue }
            let text = String(cString: t)
            // NOTE: the SQL LIMIT is applied BEFORE this filter, so a small --limit can
            // select N rows that are all shorter than minLength and yield zero work. Seen
            // with `--limit 8` → "0 events". Harmless at real limits; documented so the
            // zero is not mistaken for a broken build.
            guard text.count >= minLength else { continue }
            rows.append((Int(sqlite3_column_int64(s, 0)), Int(sqlite3_column_int64(s, 1)),
                         text, schema))
        }
        sqlite3_finalize(s)
    }
    // First real tick: the total is now known, so the bar becomes determinate immediately
    // instead of after the first 200 events (~60 s at the measured rate).
    onProgress?(EmbedProgress(done: 0, total: rows.count, vectors: 0))

    var vectors = 0, skipped = 0
    // One prepared insert per class schema, reused across the whole run.
    var insBySchema: [String: OpaquePointer] = [:]
    for cls in classes {
        let schema = "vec_\(cls.rawValue)"
        guard let st = db.prepare(SQL.insertEventVector(schema: schema)) else {
            return EmbedSummary(events: 0, vectors: 0, skipped: rows.count, seconds: 0)
        }
        insBySchema[schema] = st
    }
    defer { for st in insBySchema.values { sqlite3_finalize(st) } }

    // PROGRESS IS REPORTED ON A CLOCK, NOT ON A COUNT.
    //
    // Measured on a real run, 42 seconds apart: 160 → 180 events but 205 → 1,461 vectors.
    // Event throughput was 0.48/s and falling; vector throughput was a steady ~30/s, which
    // is the model's own speed. Events are wildly non-uniform — a large tool result chunks
    // into hundreds of vectors — so ANY count-of-events gate reports at an interval set by
    // the size of the current event.
    //
    // At 0.48 events/s the old "every 10 events" gate updated the UI once every 21 seconds,
    // and because it sat OUTSIDE the chunk loop, a single event producing 500 chunks (~16 s
    // of embedding) reported nothing at all while it ran. Both were read as a freeze, which
    // is exactly what they look like.
    //
    // A time gate makes the display cadence independent of the data. `Date()` per chunk at
    // ~30 chunks/s is nothing next to a 33 ms model call.
    let tickInterval: TimeInterval = 0.4
    var lastTick = Date()
    /// Events actually finished. Distinct from the loop index because the loop can `break`
    /// on Stop and can `continue` past an event with no chunks.
    var processed = 0
    /// What has actually REACHED DISK — advanced only when a COMMIT returns true. This is
    /// the number every closing report uses, because counting work a failed commit will
    /// roll back is how a run claims vectors that do not exist.
    var durableVectors = 0
    var durableProcessed = 0

    db.exec(SQL.begin)
    for (i, row) in rows.enumerated() {
        if shouldStop?() == true { break }
        // `defer` inside a loop body runs at the end of EVERY iteration, including the
        // `continue` taken for an event that produced no chunks. Incrementing after the
        // chunk loop instead would undercount a run whose last events were all skipped.
        defer { processed = i + 1 }
        let (sessionId, seq, text, schema) = row
        let chunks = chunkText(text, plan: plan)
        if chunks.isEmpty { skipped += 1; continue }
        guard let ins = insBySchema[schema] else { skipped += 1; continue }

        for (ci, chunk) in chunks.enumerated() {
            guard let e = embedder.embed(chunk) else { skipped += 1; continue }
            sqlite3_reset(ins)
            db.bindInt(ins, 1, sessionId)
            db.bindInt(ins, 2, seq)
            db.bindInt(ins, 3, ci)
            db.bindText(ins, 4, e.model)          // the space this vector belongs to
            db.bindInt(ins, 5, embedder.dimension)
            let blob = packVector(e.vector)
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(ins, 6, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
            }
            db.bindText(ins, 7, String(chunk.prefix(400)))
            if sqlite3_step(ins) == SQLITE_DONE { vectors += 1 } else { skipped += 1 }

            // MID-EVENT, so a single huge event still shows movement. `done` stays at the
            // events actually FINISHED — reporting i+1 here would claim an event was
            // complete while its chunks were still being embedded — but `vectors` climbs,
            // and vectors are what is visibly being produced.
            if Date().timeIntervalSince(lastTick) >= tickInterval {
                lastTick = Date()
                onProgress?(EmbedProgress(done: i, total: rows.count, vectors: vectors))
            }
        }

        // Commit every 200 events. The tick used to share this number, which tied the UI
        // refresh rate to the transaction size for no reason.
        //
        // THE RESULT IS CHECKED, because a failed COMMIT is not a no-op: SQLite leaves the
        // transaction OPEN, the blind BEGIN that followed used to fail too ("cannot start a
        // transaction within a transaction", also discarded), inserts kept landing in the
        // still-open transaction — and when this function returned, the connection's close
        // rolled back everything since the last successful commit while the summary, the
        // final tick and vector_runs all reported it as written. Minutes of work, claimed
        // and gone. On failure we simply STAY in the open transaction; the next batch
        // boundary (or the final commit below) retries, and `durable*` only advances on a
        // commit that actually returned true.
        if (i + 1) % 200 == 0 {
            if db.exec(SQL.commit) {
                durableVectors = vectors
                durableProcessed = i + 1
                db.exec(SQL.begin)
            }
        }
    }
    let finalCommitOK = db.exec(SQL.commit)
    if finalCommitOK {
        durableVectors = vectors
        durableProcessed = processed
    } else {
        FileHandle.standardError.write(
            "embed: FINAL COMMIT FAILED — reporting only the \(durableVectors) vector(s) that reached disk; work since the last successful commit was rolled back\n"
                .data(using: .utf8)!)
    }
    // COMPLETED, not the size of the work list.
    //
    // Every report here used `rows.count`, so a run that stopped after 300 of 74,343 events
    // snapped the bar to 100%, wrote 74,343 into `vector_runs.events`, and told the user
    // "74,343 events". The database still carries the evidence: run 4 recorded 74,764
    // events against 6,586 vectors, and run 6 — the one watched in the screenshots —
    // recorded 74,343 events against 10,437 vectors. At the measured ~7 vectors/event
    // neither is arithmetically possible.
    //
    // This is the same class of defect as everything else found in this file: the tool
    // succeeded at something other than what it claimed, so nothing failed at the point of
    // the mistake.
    let completed = min(durableProcessed, rows.count)
    onProgress?(EmbedProgress(done: completed, total: rows.count, vectors: durableVectors))

    let wasStopped = shouldStop?() == true
    if runId > 0, let f = db.prepare(SQL.finishVectorRun) {
        db.bindInt(f, 1, completed)
        db.bindInt(f, 2, durableVectors)
        db.bindInt(f, 3, skipped)
        db.bindInt(f, 4, wasStopped ? 1 : 0)
        db.bindInt(f, 5, runId)
        sqlite3_step(f)
        sqlite3_finalize(f)
    }

    return EmbedSummary(events: completed, vectors: durableVectors, skipped: skipped,
                        seconds: Date().timeIntervalSince(t0))
}

/// The corpus mean vector, subtracted from everything before comparison.
///
/// WHY THIS EXISTS, measured on this corpus: without it, cosine similarity is dominated by
/// a direction shared by every vector rather than by meaning. Null test on 44,387 chunk
/// vectors — top score for the real query "sqlite crash concurrency" was 0.872, and for the
/// pure gibberish "zzzz qqqq xxxx wwww" it was 0.831. A 0.04 gap between a meaningful query
/// and nonsense is not a ranking signal. The top-8 spread within a single query was 0.872 →
/// 0.863, i.e. the order inside the result set was close to arbitrary.
///
/// This is anisotropy: mean-pooled contextual embeddings occupy a narrow cone, so every
/// pair starts out highly similar. Subtracting the corpus mean and re-normalising ("all-but-
/// the-top" / centering) removes the common component and lets the residual — which is
/// where the meaning lives — decide the ranking.
func corpusMean(_ vectors: [[Float]], dimension: Int) -> [Float] {
    guard !vectors.isEmpty else { return [Float](repeating: 0, count: dimension) }
    var m = [Float](repeating: 0, count: dimension)
    for v in vectors {
        for i in 0..<min(v.count, dimension) { m[i] += v[i] }
    }
    let n = Float(vectors.count)
    for i in 0..<dimension { m[i] /= n }
    return m
}

/// Subtract the mean and re-normalise, so the result is still a unit vector and a dot
/// product is still a cosine.
func center(_ v: [Float], mean: [Float]) -> [Float] {
    var out = v
    var norm: Float = 0
    for i in 0..<min(out.count, mean.count) {
        out[i] -= mean[i]
        norm += out[i] * out[i]
    }
    norm = norm.squareRoot()
    guard norm > 1e-6 else { return v }
    for i in 0..<out.count { out[i] /= norm }
    return out
}

/// Semantic search: embed the query, scan vectors, rank by cosine.
///
/// A brute-force scan, deliberately. At this corpus size it is the right call and the
/// research agrees — exact-vs-ANN was measured as a SMALLER lever than chunking, and an ANN
/// index is another structure to build, keep fresh, and get wrong. Revisit when the scan
/// stops being fast enough, not before.
func semanticSearch(dbPath: String, query: String, limit: Int = 20,
                    classes: [VectorClass] = VectorClass.allCases) -> [SearchHit] {
    guard let embedder = Embedder(), let q = embedder.embed(query) else { return [] }
    let qv = q.vector
    let db = DB(path: dbPath)

    // WHERE THE SCAN READS FROM decides what it costs: this is a brute-force pass over
    // every blob it can see (no index, no plan — the cost IS the bytes).
    //
    // The legacy in-db table is ALWAYS one of the branches, not a fallback. The first
    // version switched to class files the moment any existed — and the moment one existed
    // it held 29 test events, so search silently shrank from 193k vectors to 29 and every
    // older result vanished. Worse, the file is created at the START of a build, so
    // pressing Build and stopping instantly would have blinded search entirely. The union
    // keeps every vector reachable through the whole migration; the speed win arrives when
    // the legacy table is dropped after the rebuild, by the same mechanism, with no code
    // change. Chunk-level near-duplicates between legacy and class copies of one event are
    // collapsed by the text-keyed dedupe downstream.
    //
    // `classes` defaults to every class so that vectors someone built by name
    // (`--classes tools`) are never write-only; a class file that does not exist costs
    // nothing — attach skips it.
    let attached = attachVectorDBs(db, classes: classes, besideIndex: dbPath)
    let scanSQL = (attached + ["main"])
        .map(SQL.selectVectorsForSearch(schema:))
        .joined(separator: "\nUNION ALL\n")

    // Load once, then center. The whole set has to be in memory for the mean anyway, and
    // at this corpus size that is a few hundred MB at worst — the same brute-force tradeoff
    // the scan itself makes.
    var raw: [(v: [Float], id: Int, uuid: String, role: String, ts: String?, text: String)] = []
    guard let s = db.prepare(scanSQL) else { return [] }
    // ONLY vectors from the query's own space. Scanning across models is not a wider
    // search, it is a meaningless one.
    db.bindText(s, 1, q.model)
    while sqlite3_step(s) == SQLITE_ROW {
        guard let blob = sqlite3_column_blob(s, 4) else { continue }
        let n = Int(sqlite3_column_bytes(s, 4))
        let data = Data(bytes: blob, count: n)
        guard let v = unpackVector(data, dimension: embedder.dimension) else { continue }
        func txt(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        raw.append((v, Int(sqlite3_column_int64(s, 0)), txt(1) ?? "", txt(2) ?? "", txt(3), txt(5) ?? ""))
    }
    sqlite3_finalize(s)
    guard !raw.isEmpty else { return [] }

    let mean = corpusMean(raw.map(\.v), dimension: embedder.dimension)
    let cq = center(qv, mean: mean)

    let scored = raw.map { r -> (Float, Int, String, String, String?, String) in
        (dot(cq, center(r.v, mean: mean)), r.id, r.uuid, r.role, r.ts, r.text)
    }

    // DEDUPLICATE BY SOURCE EVENT before taking the top N.
    //
    // Chunking overlaps by design — C=20 with S=10 is 50% overlap, which is what stops a
    // phrase being lost at a boundary. The cost is that adjacent chunks of the same event
    // are near-identical vectors, so without this they occupy consecutive result slots and
    // crowd everything else out. Observed on the Thai query "ประชุม": the top four hits were
    // the SAME chunk text at the same score, i.e. one event using four of eight slots.
    // Keep the best-scoring chunk per (session, event) and let the rest of the corpus in.
    // Keyed on TEXT ALONE, not (session, text). The first version keyed on both and did
    // not dedupe at all, because the repeats were not overlapping chunks of one event —
    // they were the SAME text in DIFFERENT sessions (a prompt template that recurs across
    // agent transcripts). Whatever the cause, five identical snippets is five wasted result
    // slots, so identity of content is the right key.
    var best: [String: (Float, Int, String, String, String?, String)] = [:]
    for r in scored {
        let key = String(r.5.prefix(60))
        if let existing = best[key], existing.0 >= r.0 { continue }
        best[key] = r
    }

    return best.values.sorted { $0.0 > $1.0 }.prefix(limit).map { r in
        SearchHit(sessionId: r.1, uuid: r.2, role: r.3, ts: r.4,
                  snippet: String(format: "%.3f  ", r.0) + r.5)
    }
}


/// `session-viewer embed [--limit N] [--query TEXT]` — build the vector index, or run a
/// semantic query against it. Same code the UI panel drives.
public func runEmbedCLI(dbPath: String, limit: Int, query: String,
                        plan: ChunkPlan = ChunkPlan(),
                        classes: [VectorClass] = [.chat]) {
    if !query.isEmpty {
        let t0 = Date()
        let hits = semanticSearch(dbPath: dbPath, query: query, limit: 8)
        let ms = Date().timeIntervalSince(t0) * 1000
        print("semantic \(query.debugDescription) — \(hits.count) hit(s) in \(String(format: "%.0f", ms)) ms")
        for h in hits {
            let flat = h.snippet.replacingOccurrences(of: "\n", with: "⏎ ")
            print("  " + String(flat.prefix(110)))
        }
        return
    }

    let before = readEmbedCoverage(dbPath: dbPath)
    print("model      Apple NLContextualEmbedding · 512-dim · assets en=\(before.assetsReady) th=\(before.thaiReady)")
    if !before.remoteProviders.isEmpty {
        print("provenance ⚠️  remote providers in this index: \(before.remoteProviders.joined(separator: ", "))")
    }
    if before.unfinishedRuns > 0 {
        print("provenance \(before.unfinishedRuns) unfinished build(s) — crashed, stopped, or still running")
    }
    print("coverage   \(before.embeddedEvents)/\(before.totalEvents) events · \(before.vectors) vectors · \(humanBytes(before.bytes))")
    print("building…  resumable — stopping and re-running continues where it left off")

    // Print EVERY tick so the CLI proves the callback cadence the UI depends on.
    var ticks = 0
    print("chunking   C=\(plan.words) words / S=\(plan.stride) stride (256-token model window)")
    print("classes    \(classes.map(\.rawValue).joined(separator: " + ")) → sibling .vec.db files")
    let s = buildEmbeddings(dbPath: dbPath, limit: limit, plan: plan, classes: classes) { p in
        ticks += 1
        if ticks <= 6 || p.done % 500 == 0 {
            FileHandle.standardError.write("  tick \(ticks): \(p.done)/\(p.total) events, \(p.vectors) vectors\n".data(using: .utf8)!)
        }
    }
    print("progress ticks: \(ticks)")
    print("done       \(s.events) events → \(s.vectors) vectors, \(s.skipped) skipped, \(String(format: "%.1f", s.seconds))s")
    let after = readEmbedCoverage(dbPath: dbPath)
    print("coverage   \(after.embeddedEvents)/\(after.totalEvents) events · \(humanBytes(after.bytes))")
    // The split, proved from the files rather than asserted: one line per class db.
    if let em = Embedder() {
        for st in readVectorClassStats(besideIndex: dbPath,
                                       models: [em.modelID(for: .english), em.modelID(for: .thai)]) where st.exists {
            print("class      \(st.cls.rawValue): \(st.events) events · \(st.vectors) vectors · \(humanBytes(st.bytes))")
        }
    }
}

// MARK: - the provider seam: dump / load

// Any engine can index this corpus, and the contract between it and this app is a FILE.
//
//   session-viewer embed --dump  |  ssh gpu embed.py  |  session-viewer embed --load --model NAME
//
// Six independent design lenses converged on this shape and three adversarial challengers
// failed to break it. What was deliberately NOT built, with reasons:
//
//   * an `EmbeddingProvider` protocol — `Embedder` has two call sites; a protocol for two
//     call sites is ceremony, and it would not have prevented a single measured defect.
//   * a Swift HTTP client — curl in a script owns the network, so there is no URLSession,
//     no retry logic in Swift, and no API token on argv where `ps` would expose it.
//   * `POST /embed` on the existing server — `StaticFileServer` does one 8 KB receive and
//     parses only the path, so a real endpoint is more new Swift than this entire seam.
//
// Cloudflare Workers AI and a local 2x4090 box differ only by environment variables in the
// script. Neither reaches into this binary.
//
// `--dump` is also the point where session text leaves the machine, and that is deliberate:
// it is a pipe the operator typed, visible in their shell history, not a default.

/// One chunk awaiting a vector.
struct DumpRow: Codable {
    let session_id: Int
    let seq: Int
    let chunk_index: Int
    let text: String
}

/// `embed --dump` — emit the chunks that have no vector for `model`, as JSONL on stdout.
///
/// Chunking happens HERE, not in the external engine, so both halves of the pipeline agree
/// on what a chunk is. An engine that re-chunked differently would produce vectors whose
/// keys do not match any row this app will ever look up.
public func runDumpCLI(dbPath: String, model: String, plan: ChunkPlan, limit: Int,
                       classes: [VectorClass] = [.chat]) {
    let db = DB(path: dbPath)
    db.exec(SQL.createEventVectors)

    // THE SAME WORK LIST THE BUILDER USES — class files attached, per-class role filter,
    // NOT EXISTS against the class schema. The first version kept the legacy constant, so
    // it never saw class-file vectors (re-emitting work the local build had already done,
    // for an external provider to be paid for again) and it dumped every role, i.e. the
    // 83% of the corpus the split exists to exclude. A seam that disagrees with the
    // builder about what "unembedded" means is two definitions of done.
    for cls in classes { _ = openVectorDB(class: cls, besideIndex: dbPath) }
    attachVectorDBs(db, classes: classes, besideIndex: dbPath)
    let thModel = Embedder()?.modelID(for: .thai) ?? "apple-nlce/th/r1/512"

    var work = ""
    for cls in classes {
        if !work.isEmpty { work += " UNION ALL " }
        work += SQL.selectUnembedded(rolesIn: cls.roles.sorted(), vectorSchema: "vec_\(cls.rawValue)")
    }
    if limit > 0 { work += " LIMIT ?3" }
    guard let s = db.prepare(work) else { return }
    db.bindText(s, 1, model)
    db.bindText(s, 2, thModel)
    if limit > 0 { db.bindInt(s, 3, limit) }

    let enc = JSONEncoder()
    var emitted = 0
    while sqlite3_step(s) == SQLITE_ROW {
        guard let t = sqlite3_column_text(s, 2) else { continue }
        let text = String(cString: t)
        guard text.count >= 24 else { continue }
        let sid = Int(sqlite3_column_int64(s, 0))
        let seq = Int(sqlite3_column_int64(s, 1))
        for (ci, chunk) in chunkText(text, plan: plan).enumerated() {
            guard let d = try? enc.encode(DumpRow(session_id: sid, seq: seq, chunk_index: ci, text: chunk)),
                  let line = String(data: d, encoding: .utf8) else { continue }
            print(line)
            emitted += 1
        }
    }
    sqlite3_finalize(s)
    FileHandle.standardError.write("dumped \(emitted) chunks (C=\(plan.words) S=\(plan.stride))\n".data(using: .utf8)!)
}

/// One vector coming back from an external engine.
struct LoadRow: Codable {
    let session_id: Int
    let seq: Int
    let chunk_index: Int
    let dim: Int
    let vector: [Float]
    let text: String?
}

/// `embed --load --model NAME` — read JSONL vectors on stdin and store them.
///
/// Validates `vector.count == dim` and REFUSES the row otherwise. Without that check a
/// wrong-length array becomes a short BLOB that `unpackVector` silently drops at query
/// time — the row would look stored, the coverage number would count it, and search would
/// return nothing, with no error anywhere. Failing loudly at write time is the whole reason
/// this validation exists.
public func runLoadCLI(dbPath: String, model: String, endpoint: String?, plan: ChunkPlan,
                       classes: [VectorClass] = [.chat]) {
    guard !model.isEmpty else {
        FileHandle.standardError.write(
            "load: --model NAME is required — a vector without the identity of its space is unusable\n"
                .data(using: .utf8)!)
        exit(2)
    }
    // Load targets ONE class schema, symmetric with what --dump emitted. Loading a mixed
    // stream would need a per-row role lookup nothing produces today; refuse rather than
    // guess, because a vector in the wrong class file is invisible to the dump anti-join
    // and the work re-emits forever (found live 2026-08-26: two 79-chunk GPU runs, 79 rows).
    guard classes.count == 1, let cls = classes.first else {
        FileHandle.standardError.write("load: exactly one --class per load\n".data(using: .utf8)!)
        exit(2)
    }
    let db = DB(path: dbPath)
    db.exec(SQL.createEventVectors)
    db.exec(SQL.createVectorRuns)
    // Same target the builder and dump use: the per-class sibling file, created then
    // ATTACHed (ATTACH alone skips a missing file by design). Writing to main's legacy
    // table instead is the "two definitions of embedded" defect the dump side already
    // fixed — dump anti-joins vec_<class>, so main-loaded vectors re-dump forever and
    // `drop-legacy-vectors` would delete them.
    _ = openVectorDB(class: cls, besideIndex: dbPath)
    attachVectorDBs(db, classes: [cls], besideIndex: dbPath)

    var runId = 0
    if let r = db.prepare(SQL.insertVectorRun) {
        db.bindText(r, 1, model)
        // Anything arriving through this path came from outside; label it so, and record the
        // endpoint if one was given. `provider != 'apple'` is what flips the UI's
        // "on-device · no network" line into a warning.
        db.bindText(r, 2, endpoint == nil ? "external" : "remote")
        db.bindText(r, 3, endpoint)
        db.bindInt(r, 4, plan.words)
        db.bindInt(r, 5, plan.stride)
        if sqlite3_step(r) == SQLITE_DONE { runId = db.lastInsertId }
        sqlite3_finalize(r)
    }

    guard let ins = db.prepare(SQL.insertEventVector(schema: "vec_\(cls.rawValue)")) else { return }
    defer { sqlite3_finalize(ins) }

    let dec = JSONDecoder()
    var ok = 0, bad = 0, lineNo = 0
    db.exec(SQL.begin)
    while let line = readLine(strippingNewline: true) {
        lineNo += 1
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { continue }
        guard let d = t.data(using: .utf8), let row = try? dec.decode(LoadRow.self, from: d) else {
            FileHandle.standardError.write("line \(lineNo): unparseable\n".data(using: .utf8)!)
            bad += 1; continue
        }
        guard row.vector.count == row.dim else {
            FileHandle.standardError.write(
                "line \(lineNo): vector has \(row.vector.count) floats but dim says \(row.dim) — refused\n"
                    .data(using: .utf8)!)
            bad += 1; continue
        }
        // Normalise here so a dot product is a cosine regardless of what the engine returned.
        var v = row.vector
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { bad += 1; continue }
        for i in 0..<v.count { v[i] /= norm }

        sqlite3_reset(ins)
        db.bindInt(ins, 1, row.session_id)
        db.bindInt(ins, 2, row.seq)
        db.bindInt(ins, 3, row.chunk_index)
        db.bindText(ins, 4, model)
        db.bindInt(ins, 5, row.dim)
        let blob = packVector(v)
        _ = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(ins, 6, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
        }
        db.bindText(ins, 7, row.text.map { String($0.prefix(400)) })
        if sqlite3_step(ins) == SQLITE_DONE { ok += 1 } else { bad += 1 }

        if ok % 500 == 0 { db.exec(SQL.commit); db.exec(SQL.begin) }
    }
    db.exec(SQL.commit)

    if runId > 0, let f = db.prepare(SQL.finishVectorRun) {
        db.bindInt(f, 1, lineNo); db.bindInt(f, 2, ok); db.bindInt(f, 3, bad)
        db.bindInt(f, 4, 0); db.bindInt(f, 5, runId)
        sqlite3_step(f); sqlite3_finalize(f)
    }
    print("loaded \(ok) vectors as \(model), refused \(bad)")
}
