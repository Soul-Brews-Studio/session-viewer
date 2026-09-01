import SwiftUI
import AppKit

// SearchView.swift — the SEARCH tab.
//
// Search already existed twice: a ⌘K palette and a field inside the All tab. It was asked
// "how do I search?" three separate times anyway, which is the answer — a keyboard shortcut
// and a field buried in another tab are not a feature anyone can find. A named tab is.
//
// It also carries the visualization, because the two belong together. The score SPREAD of a
// result set is the single most diagnostic thing about a query, and this project learned
// that the hard way: the semantic index looked plausible until its top-8 was seen spanning
// 0.01, at which point the ranking was revealed as close to arbitrary. The same view makes
// a stopword obvious — `the` scores 0.0 flat, `crash` spans -9.0 to -7.9.

struct SearchView: View {
    let dbPath: String
    let active: Bool

    enum Engine: String, CaseIterable, Identifiable {
        case keyword = "Keyword"
        case semantic = "Semantic"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var engine: Engine = .keyword
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var ranMs: Double = 0
    @State private var ranQuery = ""
    @State private var indexNote = ""
    @State private var log: [SearchLogRow] = []
    @State private var showLog = false
    @State private var topics: [Topic] = []
    @State private var showTopics = false
    @State private var savingTopic = false
    @FocusState private var focused: Bool
    @AppStorage(UI_SCALE_KEY) private var uiScale: Double = 1.0

    private static let work = DispatchQueue(label: "session-viewer.search", qos: .userInitiated)

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if showTopics { topicsPanel; Divider() }
            if showLog { historyPanel; Divider() }
            if !hits.isEmpty { spreadPanel; Divider() }
            results
        }
        .onAppear { if active { focused = true } }
    }

    // MARK: - the bar

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("search every indexed session — English or ไทย", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Content.title))
                    .focused($focused)
                    .onSubmit(run)
                if searching { ProgressView().controlSize(.small) }
                Picker("", selection: $engine) {
                    ForEach(Engine.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: engine) { _, _ in if !query.isEmpty { run() } }
                Button("Search", action: run)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    showLog.toggle()
                    if showLog && log.isEmpty { loadLog() }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Search history — every query, which index answered, and what came back")
                Button {
                    showTopics.toggle()
                    if showTopics { loadTopicsUI() }
                } label: { Image(systemName: "bookmark") }
                    .help("Saved topics — a query you keep coming back to, with everything it has found")
                Button("Save as topic") { saveTopic() }
                    .disabled(savingTopic || ranQuery.isEmpty)
                    .help("Remember this search under a name, and accumulate what it finds over time")
            }
            HStack(spacing: Space.snug) {
                // Which index will answer, stated BEFORE you press it — the routing rule is
                // otherwise invisible and surprising (a 2-character query cannot use trigram).
                if engine == .keyword {
                    Text(usesTrigram(query) ? "trigram · substring, works inside Thai words"
                                            : "unicode61 · prefix, for queries under 3 characters")
                        .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                } else {
                    Text("cosine over on-device vectors · only events already embedded")
                        .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                }
                Spacer()
                if !ranQuery.isEmpty {
                    Text("\(hits.count) hits · \(String(format: "%.0f", ranMs)) ms\(indexNote)")
                        .font(.system(size: Type.micro, design: Type.mono))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Space.pane)
    }

    // MARK: - the visualization

    /// Score spread. Not decoration — this is the diagnostic.
    ///
    /// A wide spread means the top hit is genuinely better than the tenth. A flat one means
    /// the engine returned a pile in no meaningful order, and the bars make that visible at
    /// a glance instead of requiring someone to read numbers and compare them.
    private var spreadPanel: some View {
        let strengths = hits.map(\.strength)
        let lo = strengths.min() ?? 0
        let hi = strengths.max() ?? 1
        let range = hi - lo
        // A spread under ~5% of the top score cannot separate anything.
        let flat = hi > 0 && (range / hi) < 0.05

        return VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.snug) {
                Text("SCORE SPREAD").font(.system(size: Type.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(engine == .keyword ? "bm25" : "cosine")
                    .font(.system(size: Type.micro, design: Type.mono))
                    .foregroundStyle(.tertiary)
                if flat {
                    Label("flat — this query does not discriminate", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: Type.micro)).foregroundStyle(.orange)
                        .help("Every result scores about the same, so their order is close to arbitrary. Usually a stopword, or an index that cannot rank this query.")
                } else {
                    Text("top \(String(format: "%.2f", hi)) · bottom \(String(format: "%.2f", lo))")
                        .font(.system(size: Type.micro, design: Type.mono))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            // One bar per hit, tallest = best. Shape carries the message: a staircase is a
            // healthy ranking, a flat wall is not.
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hits.prefix(60)) { h in
                    let frac = range > 0 ? (h.strength - lo) / range : 1
                    RoundedRectangle(cornerRadius: 1)
                        .fill(flat ? Color.orange.opacity(0.45) : Color.accentColor.opacity(0.75))
                        .frame(height: max(2, 26 * frac + 3))
                        .help(String(format: "%.3f", h.score))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, Space.pane)
        .padding(.vertical, Space.snug)
    }

    // MARK: - topics

    /// Saved topics, and the promote toggle.
    ///
    /// The ★ column is the whole point of the panel. EVERY topic runs from here and from
    /// the MCP `dig_topic` tool; promoting one additionally gives it a dedicated
    /// `dig_<name>` MCP tool. That is worth doing for a topic you reach for constantly —
    /// a specifically-named tool measurably helps a model pick correctly — and not worth
    /// doing for the rest, because every tool is charged against a budget shared with every
    /// other MCP server the client has connected. The count is shown for that reason.
    private var topicsPanel: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.snug) {
                Text("TOPICS").font(.system(size: Type.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("★ = has its own MCP tool")
                    .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(topics.filter(\.promoted).count) of \(topics.count) promoted")
                    .font(.system(size: Type.micro, design: Type.mono)).foregroundStyle(.tertiary)
                Button("Reload") { loadTopicsUI() }.font(.system(size: Type.micro))
            }
            if topics.isEmpty {
                Text("No topics yet — run a search and press “Save as topic”.")
                    .font(.system(size: Content.meta)).foregroundStyle(.tertiary)
            }
            ForEach(topics) { t in
                HStack(spacing: Space.snug) {
                    Button {
                        setPromoted(t, !t.promoted)
                    } label: {
                        Image(systemName: t.promoted ? "star.fill" : "star")
                            .foregroundStyle(t.promoted ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(t.promoted ? "Demote — frees an MCP tool slot; the topic stays"
                                     : "Promote — give this topic its own dig_\(t.name) MCP tool")

                    Button { query = t.query; engine = t.engine == "semantic" ? .semantic : .keyword; run() } label: {
                        HStack(spacing: Space.snug) {
                            Text(t.name)
                                .font(.system(size: Content.body, design: Content.mono))
                                .frame(width: 150, alignment: .leading)
                            Text(t.query)
                                .font(.system(size: Content.meta))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: 200, alignment: .leading)
                            Text(t.engine)
                                .font(.system(size: Content.meta, design: Content.mono))
                                .foregroundStyle(.tertiary).frame(width: 66, alignment: .leading)
                            // A topic that used to find things and now finds none is the
                            // interesting row — the corpus moved, or the query rotted.
                            Text(t.lastHits < 0 ? "never run" : "\(t.lastHits) hits")
                                .font(.system(size: Content.meta, design: Content.mono))
                                .foregroundStyle(t.lastHits == 0 && t.runs > 0 ? Color.orange : Color.secondary.opacity(0.7))
                                .frame(width: 76, alignment: .trailing)
                            Text("×\(t.runs)")
                                .font(.system(size: Content.meta, design: Content.mono))
                                .foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { forget(t) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Forget this topic and everything it captured")
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, Space.pane)
        .padding(.vertical, Space.snug)
    }

    private func loadTopicsUI() {
        let p = dbPath
        SearchView.work.async {
            let t = loadTopics(dbPath: p)
            DispatchQueue.main.async { topics = t }
        }
    }

    private func setPromoted(_ t: Topic, _ on: Bool) {
        let p = dbPath
        SearchView.work.async {
            _ = setTopicPromoted(dbPath: p, name: t.name, promoted: on)
            let all = loadTopics(dbPath: p)
            DispatchQueue.main.async { topics = all }
        }
    }

    private func forget(_ t: Topic) {
        let p = dbPath
        SearchView.work.async {
            _ = forgetTopic(dbPath: p, name: t.name)
            let all = loadTopics(dbPath: p)
            DispatchQueue.main.async { topics = all }
        }
    }

    /// Save the search that just ran. Named from the query itself — a name the user must
    /// invent before seeing whether the search was any good is a name they will regret.
    private func saveTopic() {
        guard !ranQuery.isEmpty, !savingTopic else { return }
        savingTopic = true
        let p = dbPath, q = ranQuery, e = engine == .semantic ? "semantic" : "keyword"
        SearchView.work.async {
            _ = try? traceTopic(dbPath: p, root: defaultRoot, name: q, query: q, engine: e)
            let all = loadTopics(dbPath: p)
            DispatchQueue.main.async {
                topics = all
                showTopics = true
                savingTopic = false
            }
        }
    }

    // MARK: - history

    /// The search log. Its most useful rows are the ones that found NOTHING, and the ones
    /// whose scores were flat — a result set that could not rank what it returned. Both are
    /// marked, because neither is visible from a hit count alone.
    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.snug) {
                Text("HISTORY").font(.system(size: Type.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("click to re-run").font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                Spacer()
                Button("Reload") { loadLog() }.font(.system(size: Type.micro))
            }
            if log.isEmpty {
                Text("no searches yet").font(.system(size: Content.meta)).foregroundStyle(.tertiary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(log.enumerated()), id: \.element.id) { idx, r in
                        Button {
                            query = r.query
                            engine = r.engine == "vectors" ? .semantic : .keyword
                            run()
                        } label: {
                            HStack(spacing: Space.snug) {
                                Text(String(r.ts.suffix(8)))
                                    .font(.system(size: Content.meta, design: Content.mono))
                                    .foregroundStyle(.tertiary).frame(width: 62, alignment: .leading)
                                Text(r.query)
                                    .font(.system(size: Content.meta))
                                    .lineLimit(1).frame(width: 220, alignment: .leading)
                                Text(r.engine)
                                    .font(.system(size: Content.meta, design: Content.mono))
                                    .foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                // Zero hits is the row worth finding again.
                                Text("\(r.hits)")
                                    .font(.system(size: Content.meta, design: Content.mono))
                                    .foregroundStyle(r.hits == 0 ? .orange : .secondary)
                                    .frame(width: 46, alignment: .trailing)
                                Text(String(format: "%.0f ms", r.ms))
                                    .font(.system(size: Content.meta, design: Content.mono))
                                    .foregroundStyle(.tertiary).frame(width: 62, alignment: .trailing)
                                if r.flat {
                                    Text("flat").font(.system(size: Content.meta))
                                        .foregroundStyle(.orange)
                                        .help("Scores were all within 5% — this query could not rank what it returned")
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .background(idx % 2 == 1 ? Color.secondary.opacity(0.05) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(.horizontal, Space.pane)
        .padding(.vertical, Space.snug)
    }

    private func loadLog() {
        let p = dbPath
        SearchView.work.async {
            let rows = readSearchLog(dbPath: p, limit: 40)
            DispatchQueue.main.async { log = rows }
        }
    }

    // MARK: - results

    private var results: some View {
        Group {
            if hits.isEmpty {
                VStack(spacing: Space.snug) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(ranQuery.isEmpty
                         ? "Type a query and press ↩"
                         : "No matches for \(ranQuery.debugDescription)")
                        .font(.system(size: Content.body)).foregroundStyle(.secondary)
                    if !ranQuery.isEmpty && engine == .semantic {
                        Text("The semantic index is built separately — see the Database tab.")
                            .font(.system(size: Content.meta)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { idx, h in
                            row(h, idx: idx)
                        }
                    }
                    .padding(.horizontal, Space.pane)
                    .padding(.vertical, Space.snug)
                }
            }
        }
    }

    private func row(_ h: SearchHit, idx: Int) -> some View {
        let strengths = hits.map(\.strength)
        let hi = strengths.max() ?? 1
        let frac = hi > 0 ? h.strength / hi : 0

        return HStack(alignment: .top, spacing: Space.snug) {
            // Per-row strength, so relative relevance is readable without the header chart.
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: max(2, 34 * frac), height: 4)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(h.snippet))
                    .font(.system(size: Content.body))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.snug) {
                    Text(h.role).font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.secondary)
                    if let ts = h.ts {
                        Text(String(ts.prefix(19)))
                            .font(.system(size: Content.meta, design: Content.mono))
                            .foregroundStyle(.tertiary)
                    }
                    Text(String(format: "%.2f", h.score))
                        .font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.tertiary)
                    Text(h.uuid.prefix(8))
                        .font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.tight)
        .background(idx % 2 == 1 ? Color.secondary.opacity(0.05) : .clear)
    }

    /// Render FTS5's «…» markers as real emphasis rather than leaving punctuation on screen.
    private func highlighted(_ s: String) -> AttributedString {
        var out = AttributedString()
        var emph = false
        for part in s.components(separatedBy: CharacterSet(charactersIn: "«»")) {
            var piece = AttributedString(part)
            if emph {
                piece.foregroundColor = .accentColor
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            out.append(piece)
            emph.toggle()
        }
        return out
    }

    // MARK: - run

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching else { return }
        searching = true
        let p = dbPath
        let e = engine
        let t0 = Date()
        SearchView.work.async {
            let found = e == .keyword
                ? searchEvents(db: {
                    let db = DB(path: p); return db
                  }(), query: q, limit: 100)
                : semanticSearch(dbPath: p, query: q, limit: 100)
            let ms = Date().timeIntervalSince(t0) * 1000
            // Log every search, including the ones that return nothing — an empty result is
            // the row you most want to look back at, and the wording is what you forget.
            let engine = e == .keyword ? (usesTrigram(q) ? "trigram" : "unicode61") : "vectors"
            logSearch(dbPath: p, query: q, engine: engine,
                      model: e == .semantic ? Embedder()?.modelID(for: .english) : nil,
                      hits: found, ms: ms)
            let recent = readSearchLog(dbPath: p, limit: 40)
            DispatchQueue.main.async {
                hits = found
                ranMs = ms
                ranQuery = q
                searching = false
                indexNote = " · \(engine)"
                log = recent
            }
        }
    }
}
