// DBView.swift — the DATABASE tab.
//
// The app could import from its first commit, and never answered three questions the
// import raises: WHERE did it go, is that file new or one I already filled, and what did
// the last run actually do. The answers all existed — `import_runs` has logged every run
// since the schema was written, and it was rendered nowhere. This tab is the display.
//
// Deliberately the third tab and not a sheet: import state is something you come back to
// and compare against, not a modal you dismiss. Chrome type sizes throughout (`Type.*`),
// because this is instrument panel, not prose — see Design.swift's CHROME/CONTENT split.

import SwiftUI
import AppKit
import Combine

struct DBView: View {
    let dbPath: String
    let root: String
    /// Driven by tab selection, same contract as LiveFleetView: no polling off-tab.
    let active: Bool

    @State private var status: DBStatus?
    @State private var loading = false
    @State private var isImporting = false
    @State private var progress: ImportProgress?
    @State private var lastResult: String?
    /// Which tier row is opened, and its rows. Loaded on demand — there is no reason to
    /// hold 754 workflow-agent rows for a panel that shows three.
    @State private var openTier: String?
    @State private var tierRows: [TierSession] = []
    @State private var openRun: Int?

    // --- step 2: the ML/NL vector index ---
    @State private var coverage: EmbedCoverage?
    @State private var embedding = false
    @State private var embedProgress: EmbedProgress?
    @State private var embedResult: String?
    /// Set by Stop; read by the build loop. A class box so the escaping closure sees writes.
    @State private var stopBox = StopFlag()

    /// When the current build began — the input to elapsed/rate/ETA.
    ///
    /// A determinate bar is not by itself evidence of progress. This one ticks every 10
    /// events at a measured ~0.3 s/event, so it advances 10/1,544 roughly every 3 seconds —
    /// under 1% per update, on a run that takes about 8 minutes. Watched for ten seconds
    /// that is indistinguishable from a hang, which is what it was reported as.
    ///
    /// The file already carries this lesson one level up ("a minute of a static Building…
    /// label is indistinguishable from a freeze"). The correction there was to show
    /// numbers; the numbers alone turn out not to be enough when they move this slowly.
    /// A clock that visibly advances, and an ETA, are what separate "slow" from "stuck".
    @State private var embedStartedAt: Date?

    /// This process's own CPU and memory, refreshed once a second while a build runs.
    /// Read via Mach rather than `ps`, whose `%cpu` is a lifetime average and reported
    /// 124.7% for this app at a moment when every thread was provably parked.
    @State private var resources: ResourceSample?

    /// Per-class vector-file stats (chat / tools), refreshed with coverage.
    @State private var classStats: [VectorClassStats] = []

    /// Once a second, and only consulted while a build is running — see the `guard` in the
    /// receiver. A view that samples the kernel every second forever, to display a figure
    /// nobody is looking at, is the kind of background cost this app has already been bitten
    /// by twice.
    private let resourceTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    final class StopFlag { var stop = false }

    /// Observing the scale here is what makes ⌘+/⌘− reach this tab at all. The CHROME vs
    /// CONTENT split (Design.swift) puts buttons and headers at fixed native sizes and
    /// scales only what you read — and the judgement that this tab was all chrome was
    /// wrong. Its dense numeric tables ARE the thing being read, so they scale; the
    /// toolbar, tab bar and buttons around them still do not.
    @AppStorage(UI_SCALE_KEY) private var uiScale: Double = 1.0

    /// The root being scanned. Defaults to ~/.claude/projects and PERSISTS, so pointing the
    /// app at a second machine's copied `.claude` survives a relaunch. Empty means default.
    @AppStorage("session-viewer.scanRoot") private var scanRoot: String = ""

    /// The same key `RootView` reads, so switching here switches the whole window.
    @AppStorage("session-viewer.dbPath") private var storedDB: String = ""

    @State private var projects: [ProjectScan] = []
    @State private var selection: Set<String> = []
    @State private var scanning = false
    @State private var didScan = false

    /// Effective root: the chosen folder, or the default. One accessor so no code path can
    /// disagree with another about what is being read.
    private var effectiveRoot: String { scanRoot.isEmpty ? root : scanRoot }

    /// ONE serial queue for every disk/db read this tab performs.
    ///
    /// `refresh()` and `scan()` each used `DispatchQueue.global(qos:)`, so they ran
    /// CONCURRENTLY — and `chooseFolder()` calls both back to back, which is what crashed
    /// the app: a `readDBStatus` prepare hit SQLITE_BUSY while `scanProjects` was mid
    /// `sqlite3_step` on the same file. A busy timeout (now set on every DB) makes that
    /// survivable; serialising makes it not happen. Both fixes are kept, because the
    /// timeout also protects against the OTHER writers — the tailer, the server, an import
    /// — which this queue cannot serialise against.
    ///
    /// Static so it is shared by every instance of the view rather than recreated on each
    /// SwiftUI struct copy.
    private static let work = DispatchQueue(label: "session-viewer.dbview", qos: .userInitiated)

    /// The semantic build gets its OWN queue, and that separation is not cosmetic.
    ///
    /// Serialising this tab's reads onto `work` fixed the refresh/scan crash, and then
    /// broke something else: the embed build is a ~100-minute job, so putting it on the
    /// same serial queue meant every subsequent `refresh()` and `loadCoverage()` sat behind
    /// it. The window showed "Building…" over a coverage bar frozen at 0/19,482 with no
    /// progress — not because the build was stuck, but because the reads that would have
    /// shown progress could never run.
    ///
    /// Safe to run concurrently with those reads: SQLite is in WAL mode (readers do not
    /// block on a writer) and every DB now carries a busy timeout from `DB.init`. The
    /// serial queue exists to stop two READS colliding, which was the actual crash; it was
    /// never the right home for a long-running writer.
    private static let embedQueue = DispatchQueue(label: "session-viewer.embed", qos: .utility)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.pane) {
                destination
                Divider()
                sourceFolder
                Divider()
                actionBar
                if didScan || !projects.isEmpty { projectTable }
                Divider()
                mlIndexPanel
                if let s = status {
                    statsGrid(s)
                    if !s.sources.isEmpty { sourceTable(s) }
                    if !s.tiers.isEmpty { tierTable(s) }
                    if !s.runs.isEmpty { runTable(s) }
                } else {
                    Text(loading ? "reading database…" : "no reading yet")
                        .font(.system(size: Type.small)).foregroundStyle(.secondary)
                }
            }
            .padding(Space.loose)
        }
        .onAppear { if active { refresh() } }
        .onChange(of: active) { _, now in if now { refresh() } }
    }

    // MARK: - where it imports TO

    /// The question "import to where?" answered literally, at the top, before anything
    /// else — with the path itself selectable and a button that opens it in Finder.
    /// A path you cannot copy or reveal is a path you have to go hunting for.
    private var destination: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                Text("Database").font(.system(size: Type.heading, weight: .semibold))
                ageBadge
                Spacer()
            }
            HStack(spacing: Space.snug) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                // .textSelection so the path can be copied into a terminal, which is the
                // first thing anyone wants to do with it.
                Text(dbPath)
                    .font(.system(size: Type.small, design: Type.mono))
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                    .help(dbPath)
                Button("Reveal") { reveal() }
                    .help("Show this file in Finder")
                    .disabled(status?.dbExists != true)
                Button("Open…") { chooseDatabase() }
                    .help("Switch this window to a different index file")
                Button("New…") { createDatabase() }
                    .help("Create an empty index and switch to it")
                if !storedDB.isEmpty {
                    Button("Default") { storedDB = ""; resetForNewDB() }
                        .help("Back to the database this app was launched with")
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dbPath, forType: .string)
                }
                .help("Copy the database path")
            }
            if let s = status {
                Text(s.dbExists
                     ? "\(humanBytes(s.dbBytes)) on disk\(s.dbModified.map { " · written \(relative($0))" } ?? "")"
                     : "not created yet — Import will create it")
                    .font(.system(size: Type.micro)).foregroundStyle(.secondary)
            }
        }
    }

    /// NEW vs EXISTING, stated rather than left to be inferred from a zero row count.
    private var ageBadge: some View {
        let (label, tint): (String, Color) = {
            switch status?.age {
            case .none:              return ("…", .secondary)
            case .missing:           return ("NEW — no database yet", .orange)
            case .empty:             return ("EMPTY — schema only", .orange)
            case .populated(let n):  return ("EXISTING — \(n.formatted()) sessions", .green)
            }
        }()
        return Text(label)
            .font(.system(size: Type.micro, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - where it reads FROM

    /// The source folder, and the scan that turns it into a choosable list.
    ///
    /// Default behaviour is unchanged and requires no scan: with nothing chosen and nothing
    /// scanned, Import reads `~/.claude/projects` exactly as before. Scanning is what you do
    /// when you want to SEE the structure first and import part of it — a second machine's
    /// copied `.claude`, an archive, a single project.
    private var sourceFolder: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(effectiveRoot)
                    .font(.system(size: Type.small, design: Type.mono))
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                    .help(effectiveRoot)
                if !scanRoot.isEmpty {
                    Text("custom")
                        .font(.system(size: Type.micro, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.18), in: Capsule())
                        .foregroundStyle(.purple)
                }
                Button("Choose…") { chooseFolder() }
                    .help("Point at another .claude/projects — e.g. a copy from another machine")
                if !scanRoot.isEmpty {
                    Button("Default") { scanRoot = ""; projects = []; didScan = false; refresh() }
                        .help("Back to ~/.claude/projects")
                }
                Button(scanning ? "Scanning…" : "Scan structure") { scan() }
                    .disabled(scanning)
                    .help("List the projects in this folder so you can import only some")
                Spacer()
            }
            if !didScan && projects.isEmpty {
                Text("not scanned — Import will read every project in this folder")
                    .font(.system(size: Type.micro)).foregroundStyle(.secondary)
            }
        }
    }

    /// The scanned projects, each choosable. This is the "show projects too" the import
    /// summary never did: the counts here are per project and come from the same
    /// `discoverFiles` walk the import itself uses.
    @ViewBuilder
    private var projectTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.snug) {
                Text("PROJECTS").font(.system(size: Type.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(projects.count) found · \(selection.count) selected")
                    .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                Spacer()
                Button("All") { selection = Set(projects.map(\.dirName)) }
                    .font(.system(size: Type.micro))
                Button("None") { selection = [] }
                    .font(.system(size: Type.micro))
                Button("Only pending") { selection = Set(projects.filter { $0.pending > 0 }.map(\.dirName)) }
                    .font(.system(size: Type.micro))
                    .help("Select just the projects the index is missing something from")
            }
            .padding(.bottom, Space.tight)

            headerRow(["project": 380, "files": 70, "size": 90, "new": 60, "changed": 80])

            ForEach(Array(projects.enumerated()), id: \.element.id) { idx, p in
                HStack(spacing: 0) {
                    Toggle(isOn: Binding(
                        get: { selection.contains(p.dirName) },
                        set: { on in
                            if on { selection.insert(p.dirName) } else { selection.remove(p.dirName) }
                        })) { EmptyView() }
                        .labelsHidden()
                        .frame(width: 24, alignment: .leading)

                    Text(p.display)
                        .font(.system(size: Content.body, design: Content.mono))
                        .lineLimit(1).truncationMode(.head)
                        .help(p.cwd == nil ? "no cwd recorded — showing the encoded dirname" : p.dirName)
                        .frame(width: 356, alignment: .leading)
                    Text(p.files.formatted())
                        .font(.system(size: Content.body, design: Content.mono))
                        .frame(width: 70, alignment: .trailing)
                    Text(humanBytes(p.bytes))
                        .font(.system(size: Content.body, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(p.newFiles == 0 ? "—" : p.newFiles.formatted())
                        .font(.system(size: Content.body, design: Content.mono))
                        .foregroundStyle(p.newFiles > 0 ? Color.orange : .secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(p.changedFiles == 0 ? "—" : p.changedFiles.formatted())
                        .font(.system(size: Content.body, design: Content.mono))
                        .foregroundStyle(p.changedFiles > 0 ? Color.yellow : .secondary)
                        .frame(width: 80, alignment: .trailing)
                    Spacer()
                }
                .padding(.vertical, 2)
                .background(idx % 2 == 1 ? Color.secondary.opacity(0.055) : .clear)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a projects folder (e.g. another machine's .claude/projects)"
        panel.directoryURL = URL(fileURLWithPath: effectiveRoot)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanRoot = url.path
        projects = []
        selection = []
        didScan = false
        refresh()
        scan()
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        let r = effectiveRoot, p = dbPath
        DBView.work.async {
            let found = scanProjects(root: r, dbPath: p)
            DispatchQueue.main.async {
                projects = found
                // Preselect what actually needs work — the common intent.
                selection = Set(found.filter { $0.pending > 0 }.map(\.dirName))
                scanning = false
                didScan = true
            }
        }
    }

    // MARK: - what Import would do, then the button

    private var actionBar: some View {
        HStack(spacing: Space.row) {
            Button(isImporting ? "Importing…" : importLabel) { runImportAction() }
                .disabled(isImporting || loading)
                .keyboardShortcut("i", modifiers: .command)
                .help("Parse new/changed files into the index (⌘I)")
            Button("Rescan") { refresh() }
                .disabled(isImporting || loading)
                .help("Re-check disk against the index without importing")

            if isImporting, let p = progress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total))
                    .frame(width: 160)
                Text("\(p.done)/\(p.total)")
                    .font(.system(size: Type.micro, design: Type.mono))
                    .foregroundStyle(.secondary)
            } else if let s = status {
                pendingSummary(s)
            }
            Spacer()
            if let r = lastResult {
                Text(r).font(.system(size: Type.micro)).foregroundStyle(.secondary)
            }
        }
    }

    /// The button says how much work it will do, so pressing it is never a surprise.
    private var importLabel: String {
        if didScan && selection.count < projects.count {
            let n = projects.filter { selection.contains($0.dirName) }.reduce(0) { $0 + $1.pending }
            return n == 0 ? "Import selected" : "Import \(n.formatted()) in \(selection.count) project\(selection.count == 1 ? "" : "s")"
        }
        guard let s = status else { return "Import" }
        return s.pendingTotal == 0 ? "Import" : "Import \(s.pendingTotal.formatted())"
    }

    @ViewBuilder
    private func pendingSummary(_ s: DBStatus) -> some View {
        HStack(spacing: Space.snug) {
            if s.upToDate {
                Label("index matches disk", systemImage: "checkmark.circle.fill")
                    .font(.system(size: Type.small)).foregroundStyle(.green)
            } else {
                if s.pendingNew > 0 { chip("\(s.pendingNew) new", .orange) }
                if s.pendingChanged > 0 { chip("\(s.pendingChanged) changed", .yellow) }
                if s.failed > 0 { chip("\(s.failed) failed", .red) }
            }
            // Pruned files are EXPECTED (30-day cleanup, see SPEC) — informational grey,
            // never an error colour, or the common case looks like damage.
            if s.goneFromDisk > 0 { chip("\(s.goneFromDisk) pruned from disk", .secondary) }
        }
    }

    private func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: Type.micro))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(c.opacity(0.15), in: Capsule())
            .foregroundStyle(c)
    }

    // MARK: - step 2: ML / NL index

    /// The semantic index panel.
    ///
    /// It states what this index is FOR rather than implying it supersedes the keyword one.
    /// On facebook-oracle's benchmark (5,000 messages, 73% Thai, substring ground truth)
    /// FTS5 trigram scored 100% against 88% for e5-small and 60% for this very model — so
    /// presenting embeddings as the upgrade would be a lie the numbers do not support. What
    /// they buy is the query trigram cannot express: a paraphrase, a synonym, a description
    /// whose words never appear in the text.
    @ViewBuilder
    private var mlIndexPanel: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                Text("SEMANTIC INDEX").font(.system(size: Type.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                // Provenance, read from vector_runs — NOT a hardcoded claim.
                //
                // This line used to always say "on-device · no network". The moment a
                // remote provider can write vectors, that sentence stops being stale and
                // starts being FALSE about whether the corpus left the machine, which is
                // the one thing an operator has to be able to trust here.
                if let c = coverage, !c.remoteProviders.isEmpty {
                    Label("text left this machine · \(c.remoteProviders.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: Type.micro)).foregroundStyle(.orange)
                } else {
                    Text("Apple NaturalLanguage · on-device · no network")
                        .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                }
                if let c = coverage, c.unfinishedRuns > 0 {
                    Text("\(c.unfinishedRuns) unfinished build\(c.unfinishedRuns == 1 ? "" : "s")")
                        .font(.system(size: Type.micro)).foregroundStyle(.yellow)
                        .help("A build that never recorded a finish — crashed, stopped, or still running")
                }
                Spacer()
            }

            if let c = coverage {
                HStack(spacing: Space.snug) {
                    modelChip("NLContextualEmbedding", .purple)
                    modelChip("\(c.dimension > 0 ? c.dimension : 512)-dim", .secondary)
                    modelChip("256-token window", .secondary)
                    chunkChip
                    chip(c.assetsReady ? "en ready" : "en assets missing", c.assetsReady ? .green : .orange)
                    chip(c.thaiReady ? "th ready" : "th assets missing", c.thaiReady ? .green : .orange)
                    Spacer()
                }

                // Coverage bar — this index is built incrementally and will usually be
                // partial, so "how much of the corpus is in it" is the headline number.
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(Color.purple.opacity(0.6))
                                .frame(width: max(2, geo.size.width * c.chatFraction))
                        }
                    }
                    .frame(height: 6)
                    // REACHABLE over REACHABLE. The denominator was the whole 98,797-event
                    // corpus, but the only build this panel offers is chat-only — so the bar
                    // topped out near 37% forever, indistinguishable from a stalled build to
                    // someone who has already reported three false freezes. The corpus-wide
                    // figure stays, as context after the number that can actually reach 100%.
                    Text("\(c.chatEmbeddedEvents.formatted()) / \(c.chatTotalEvents.formatted()) chat events embedded · corpus \(c.embeddedEvents.formatted())/\(c.totalEvents.formatted()) · \(c.vectors.formatted()) chunk vectors · \(humanBytes(c.bytes))")
                        .font(.system(size: Content.meta)).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Space.row) {
                Button(embedding ? "Building…" : "Build semantic index") { startEmbed(limit: 0) }
                    .disabled(embedding || coverage?.assetsReady != true)
                    .help("Embed every CHAT event (user + assistant) without a vector yet, into sessions.chat.vec.db. Resumable. Tool vectors: `session-viewer embed --classes tools`.")
                Button("Build 2,000") { startEmbed(limit: 2000) }
                    .disabled(embedding || coverage?.assetsReady != true)
                    .help("A bounded run, so you can try it without committing an hour")
                if embedding {
                    Button("Stop") { stopBox.stop = true }
                        .help("Stops after the current batch; progress is kept")
                }
                if let p = embedProgress {
                    if p.total > 0 {
                        ProgressView(value: Double(p.done), total: Double(p.total)).frame(width: 150)
                        Text("\(p.done)/\(p.total) · \(p.vectors) vec\(embedPace(p))")
                            .font(.system(size: Content.meta, design: Content.mono))
                            .foregroundStyle(.secondary)
                    } else {
                        // total == 0 means the work list is still being collected. A
                        // determinate bar at 0 is indistinguishable from a hang, which is
                        // exactly how this looked.
                        ProgressView().controlSize(.small)
                        Text("finding work…")
                            .font(.system(size: Content.meta)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let r = embedResult {
                    Text(r).font(.system(size: Content.meta)).foregroundStyle(.secondary)
                }
            }
            .onReceive(resourceTick) { _ in
                // Only while something is running. Sampling the kernel once a second for a
                // figure nobody is reading is exactly the kind of idle background cost this
                // app has already been bitten by twice.
                guard embedding || isImporting || scanning else { resources = nil; return }
                resources = sampleOwnResources()
            }

            // WHERE THE VECTORS LIVE — one line per class file that exists. This is how
            // the split is visible without opening a shell: chat and tools each report
            // their own events/vectors/bytes, and a class that has never been built is
            // simply absent.
            if !classStats.isEmpty {
                Text(classStats.map {
                    "\($0.cls.rawValue): \($0.events.formatted()) events · \($0.vectors.formatted()) vec · \(humanBytes($0.bytes))"
                }.joined(separator: "     "))
                    .font(.system(size: Content.meta, design: Content.mono))
                    .foregroundStyle(.secondary)
            }

            // MIXED GEOMETRY — scoped to the LEGACY table, because that is where it lives.
            //
            // Two corrections from the adversarial pass. The old text said mixed-geometry
            // events "are skipped by future builds", which the class split made false: a
            // class build's resume check runs against its own file, so it re-embeds legacy
            // events at the correct geometry — that IS the sanctioned rebuild. And the
            // counts come from `vector_runs`, which is an append-only history: derived from
            // history alone the warning could never clear, still citing 84,883 vectors an
            // index no longer contains. Gating on the class-file rebuild's own progress
            // gives it an exit: finish the chat build, drop the legacy table, warning gone.
            if let c = coverage, c.geometries.count > 1, c.legacyVectors > 0 {
                let parts = c.geometries.map { "\($0.geom) → \($0.vectors.formatted()) vec" }
                Text("⚠︎ legacy table carries mixed chunk geometry: \(parts.joined(separator: " · ")) "
                     + "(run history). The chat class build re-embeds these at the current geometry "
                     + "into sessions.chat.vec.db; when it completes, the legacy table can be dropped "
                     + "and this clears.")
                    .font(.system(size: Content.meta))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The honest note. Measured, cited, and deliberately not buried.
            Text("Keyword search (FTS5 trigram) already scores 100% recall on this corpus and is ~700× faster to build. This index is for the queries keyword search cannot express — paraphrase and synonym — not a replacement for it.")
                .font(.system(size: Content.meta)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The chunk geometry in force, shown next to the model chips. It was invisible, which
    /// is how five builds ran at a geometry nobody chose.
    private var chunkChip: some View {
        let p = ChunkPlan()
        return modelChip("C=\(p.words)/S=\(p.stride)"
                         + (p.maxChunks > 0 ? " · max \(p.maxChunks)" : ""), .secondary)
    }

    private func modelChip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: Type.micro, design: Type.mono))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(c.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(c == .secondary ? Color.secondary : c)
    }

    /// " · 2m 13s · 31/s vec · ~12h left · 182% cpu · 431 MB"
    ///
    /// RATE AND ETA COME FROM VECTORS, NOT EVENTS. Measured across three real readings of
    /// one run, events per second fell 10.6 → 3.2 → 1.7 while vectors per second held at a
    /// steady ~31, and the event-based ETA swung 1h56m → 6h28m → 12h26m in two minutes.
    /// Neither number was wrong: events are wildly non-uniform, because one large tool
    /// result chunks into hundreds of vectors. Vectors are the unit of actual work, and the
    /// model embeds them at a fixed ~33 ms each, so a vector rate is stable within seconds.
    ///
    /// The remaining vector count is still an estimate — it assumes the events left cost
    /// what the finished ones did — so the ETA keeps its "~". But it converges instead of
    /// climbing, which is the difference between an estimate and a number that looks broken.
    private func embedPace(_ p: EmbedProgress) -> String {
        guard let started = embedStartedAt else { return "" }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 1 else { return "" }

        var out = " · \(shortDuration(elapsed))"

        if p.vectors > 0 {
            let vecRate = Double(p.vectors) / elapsed
            out += " · \(Int(vecRate.rounded()))/s vec"
            // Extrapolate through vectors-per-event, which converges, rather than through
            // an event rate that does not.
            if p.done > 0, p.total > p.done, vecRate > 0 {
                let vecPerEvent = Double(p.vectors) / Double(p.done)
                let remaining = vecPerEvent * Double(p.total - p.done)
                out += " · ~\(shortDuration(remaining / vecRate)) left"
            }
        }

        // WHAT IT IS COSTING, because "slow" and "stuck" look identical on a bar and do not
        // look identical here. This was asked for directly, after a working build was
        // reported as frozen three times.
        if let r = resources { out += " · \(formatResources(r))" }
        return out
    }

    private func shortDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func startEmbed(limit: Int) {
        guard !embedding else { return }
        embedding = true
        embedResult = nil
        stopBox.stop = false
        embedProgress = EmbedProgress(done: 0, total: 0, vectors: 0)
        embedStartedAt = Date()
        let p = dbPath
        let box = stopBox
        DBView.embedQueue.async {
            // PASS THE PLAN EXPLICITLY. Relying on the parameter default is how the app
            // spent five runs at a chunk geometry nobody chose: the default was declared in
            // two places that disagreed, and the caller that named nothing got the wrong
            // one. Naming it here means the app and `session-viewer embed` are visibly the
            // same, and a future divergence has to be written down to happen.
            // classes: [.chat] — the app builds the conversation index only. Measured:
            // chat is 16.8% of the corpus by characters and the only class paraphrase
            // queries can want; tool vectors are a CLI decision (`embed --classes tools`),
            // not a button.
            let s = buildEmbeddings(dbPath: p, limit: limit, plan: ChunkPlan(), classes: [.chat],
                                    shouldStop: { box.stop }) { prog in
                DispatchQueue.main.async {
                    embedProgress = prog
                    // Refresh the coverage bar as the build runs, so the number the user is
                    // watching is the number that is changing. Previously coverage was read
                    // only at the END of a job that takes an hour.
                    if prog.done % 500 == 0 { loadCoverage() }
                }
            }
            DispatchQueue.main.async {
                embedding = false
                embedProgress = nil
                embedResult = box.stop
                    ? "stopped — \(s.vectors) vectors kept from \(s.events) events"
                    : "\(s.vectors) vectors from \(s.events) events in \(String(format: "%.0f", s.seconds))s"
                loadCoverage()
            }
        }
    }

    private func loadCoverage() {
        let p = dbPath
        DBView.work.async {
            let c = readEmbedCoverage(dbPath: p)
            // Same background pass, same refresh moment — the class line and the coverage
            // bar can never describe two different points in time.
            let cls = Embedder().map {
                readVectorClassStats(besideIndex: p,
                                     models: [$0.modelID(for: .english), $0.modelID(for: .thai)])
                    .filter(\.exists)
            } ?? []
            DispatchQueue.main.async { coverage = c; classStats = cls }
        }
    }

    // MARK: - status

    private func statsGrid(_ s: DBStatus) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                  alignment: .leading, spacing: Space.row) {
            stat("files on disk", s.onDisk.formatted())
            stat("indexed", s.imported.formatted())
            stat("projects", s.projects.formatted())
            stat("failed", s.failed.formatted(), s.failed > 0 ? .red : nil)
            stat("events", s.events.formatted())
            stat("lines", s.lines.formatted())
            stat("source size", humanBytes(s.sourceBytes))
            stat("index size", humanBytes(s.dbBytes))
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: Content.title, weight: .medium, design: Content.mono))
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.system(size: Content.meta)).foregroundStyle(.secondary)
        }
    }

    /// The three tiers, shown because a tier silently reading zero is this project's
    /// founding bug (dig.py sees 84 of 1030 files). A zero here should be visible.
    /// WHICH TOOL PRODUCED THIS. Above the tier table, because source is the coarser
    /// question: tiers only mean something within Claude Code (session/subagent/
    /// workflow_agent), while a Codex rollout is a top-level session with its own shape.
    /// Showing tiers without source would present one undifferentiated corpus.
    private func sourceTable(_ s: DBStatus) -> some View {
        let totalFiles = max(1, s.sources.reduce(0) { $0 + $1.files })
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("BY SOURCE", hint: "which tool wrote the transcript")
            headerRow(["source": 110, "tier": 150, "files": 80, "size": 100, "events": 100])
            ForEach(Array(s.sources.enumerated()), id: \.element.id) { idx, x in
                HStack(spacing: 0) {
                    HStack(spacing: Space.tight) {
                        Circle()
                            .fill(x.source == "codex" ? Color.purple : Color.accentColor)
                            .frame(width: 7, height: 7)
                        Text(x.source).font(.system(size: Content.body, design: Content.mono))
                    }
                    .frame(width: 110, alignment: .leading)
                    Text(x.tier)
                        .font(.system(size: Content.body, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(x.files.formatted())
                        .font(.system(size: Content.body, design: Content.mono))
                        .frame(width: 80, alignment: .trailing)
                    Text(humanBytes(x.bytes))
                        .font(.system(size: Content.body, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    Text(x.events.formatted())
                        .font(.system(size: Content.body, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    shareBar(Double(x.files) / Double(totalFiles))
                        .frame(width: 160, alignment: .leading)
                        .padding(.leading, Space.snug)
                    Spacer()
                }
                .padding(.vertical, 3)
                .background(idx % 2 == 1 ? Color.secondary.opacity(0.055) : .clear)
            }
        }
    }

    private func tierTable(_ s: DBStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("BY TIER", hint: "click a tier to list its largest sessions")
            headerRow(["tier": 170, "files": 80, "size": 100, "share": 200])

            ForEach(Array(s.tiers.enumerated()), id: \.element.id) { idx, t in
                let open = openTier == t.tier
                Button { toggleTier(t.tier) } label: {
                    HStack(spacing: 0) {
                        HStack(spacing: Space.tight) {
                            Image(systemName: open ? "chevron.down" : "chevron.right")
                                .font(.system(size: Content.meta * 0.85))
                                .foregroundStyle(.secondary)
                            Text(t.tier).font(.system(size: Content.body, design: Content.mono))
                        }
                        .frame(width: 170, alignment: .leading)
                        Text(t.files.formatted())
                            .font(.system(size: Content.body, design: Content.mono))
                            .frame(width: 80, alignment: .trailing)
                        Text(humanBytes(t.bytes))
                            .font(.system(size: Content.body, design: Content.mono))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        // A bar makes the 85/200/754 split legible without doing the
                        // arithmetic — the tier this project exists for is the biggest one.
                        shareBar(Double(t.files) / Double(max(1, s.tiers.reduce(0) { $0 + $1.files })))
                            .frame(width: 200, alignment: .leading)
                            .padding(.leading, Space.snug)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .background(idx % 2 == 1 ? Color.secondary.opacity(0.055) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if open {
                    tierDetail()
                }
            }
        }
    }

    /// The drill-down: the biggest sessions in the clicked tier.
    @ViewBuilder
    private func tierDetail() -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if tierRows.isEmpty {
                Text("no rows").font(.system(size: Content.meta)).foregroundStyle(.secondary)
                    .padding(.vertical, Space.tight)
            }
            ForEach(tierRows) { r in
                HStack(spacing: Space.snug) {
                    Text(r.label)
                        .font(.system(size: Content.meta, design: Content.mono))
                        .frame(width: 190, alignment: .leading)
                    Text(humanBytes(r.bytes))
                        .font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    Text("\(r.events.formatted()) ev")
                        .font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(r.project)
                        .font(.system(size: Content.meta))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
                        .font(.system(size: Content.meta))
                        .buttonStyle(.link)
                }
                .padding(.leading, Space.loose)
                .padding(.vertical, 1)
            }
        }
        .padding(.bottom, Space.snug)
    }

    private func shareBar(_ frac: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor.opacity(0.55))
                    .frame(width: max(2, geo.size.width * frac))
            }
        }
        .frame(height: 5)
    }

    private func toggleTier(_ tier: String) {
        if openTier == tier { openTier = nil; tierRows = []; return }
        openTier = tier
        tierRows = []
        let p = dbPath
        DBView.work.async {
            let rows = tierSessions(dbPath: p, tier: tier)
            DispatchQueue.main.async { if openTier == tier { tierRows = rows } }
        }
    }

    private func sectionHeader(_ title: String, hint: String) -> some View {
        HStack(spacing: Space.snug) {
            Text(title).font(.system(size: Type.micro, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(hint).font(.system(size: Type.micro)).foregroundStyle(.tertiary)
        }
        .padding(.bottom, Space.tight)
    }

    /// Column headers at CONTENT size so they stay aligned with the rows when zoomed —
    /// a header that does not scale with its column drifts out of register.
    private func headerRow(_ cols: KeyValuePairs<String, CGFloat>) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cols.enumerated()), id: \.offset) { _, pair in
                Text(pair.key)
                    .font(.system(size: Content.meta, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: pair.value, alignment: pair.key == "tier" || pair.key == "share" ? .leading : .trailing)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    /// Import history — the `import_runs` log, finally rendered. Rows are clickable and
    /// open the arithmetic behind the run, including the DURATION, which is the one number
    /// the table cannot show without doing subtraction in your head.
    private func runTable(_ s: DBStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("IMPORT HISTORY", hint: "click a run for its duration and rate")
            headerRow(["run": 60, "started": 190, "scanned": 90, "new": 70, "changed": 90, "failed": 80])

            ForEach(Array(s.runs.enumerated()), id: \.element.id) { idx, r in
                let open = openRun == r.id
                Button { openRun = open ? nil : r.id } label: {
                    HStack(spacing: 0) {
                        Text("#\(r.id)")
                            .font(.system(size: Content.body, design: Content.mono))
                            .frame(width: 60, alignment: .leading)
                        Text(r.startedAt)
                            .font(.system(size: Content.body, design: Content.mono))
                            .frame(width: 190, alignment: .trailing)
                        Text(r.scanned.formatted())
                            .font(.system(size: Content.body, design: Content.mono))
                            .frame(width: 90, alignment: .trailing)
                        Text(r.new.formatted())
                            .font(.system(size: Content.body, design: Content.mono))
                            .foregroundStyle(r.new > 0 ? Color.orange : .primary)
                            .frame(width: 70, alignment: .trailing)
                        Text(r.changed.formatted())
                            .font(.system(size: Content.body, design: Content.mono))
                            .frame(width: 90, alignment: .trailing)
                        Text(r.failed.formatted())
                            .font(.system(size: Content.body, design: Content.mono))
                            .foregroundStyle(r.failed > 0 ? .red : .primary)
                            .frame(width: 80, alignment: .trailing)
                        if r.interrupted {
                            Text("interrupted")
                                .font(.system(size: Content.meta))
                                .foregroundStyle(.orange)
                                .padding(.leading, Space.snug)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .background(idx % 2 == 1 ? Color.secondary.opacity(0.055) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if open { runDetail(r) }
            }
        }
    }

    @ViewBuilder
    private func runDetail(_ r: ImportRun) -> some View {
        let secs = runSeconds(r)
        HStack(spacing: Space.loose) {
            detailStat("duration", secs.map { fmtDuration($0) } ?? "—")
            detailStat("rate", (secs.flatMap { $0 > 0 ? Double(r.scanned) / $0 : nil })
                        .map { String(format: "%.0f files/s", $0) } ?? "—")
            detailStat("skipped", r.skipped.formatted())
            detailStat("touched", (r.new + r.changed).formatted())
            detailStat("finished", r.finishedAt ?? "never")
            Spacer()
        }
        .padding(.leading, Space.loose)
        .padding(.vertical, Space.snug)
    }

    private func detailStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: Content.body, design: Content.mono))
            Text(label).font(.system(size: Content.meta)).foregroundStyle(.secondary)
        }
    }

    /// Wall-clock of a run. Both stamps are SQLite `datetime('now')` — UTC, no zone suffix
    /// — so they are parsed with an explicit UTC formatter rather than a bare one, which
    /// would inherit this machine's Thai locale and produce a Buddhist-era year (the same
    /// trap already recorded in SPEC.md for the session list).
    private func runSeconds(_ r: ImportRun) -> Double? {
        guard let end = r.finishedAt else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let a = f.date(from: r.startedAt), let b = f.date(from: end) else { return nil }
        return b.timeIntervalSince(a)
    }

    private func fmtDuration(_ s: Double) -> String {
        s < 60 ? String(format: "%.1fs", s) : String(format: "%dm %02ds", Int(s) / 60, Int(s) % 60)
    }

    // MARK: - actions

    /// Switch the window to another index file. Everything downstream keys off the same
    /// @AppStorage value, so no view needs to be told.
    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.message = "Choose a session-viewer index (.db)"
        panel.directoryURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storedDB = url.path
        resetForNewDB()
    }

    /// Create an EMPTY index and switch to it. The schema is applied through the same
    /// `initSchema` the tests use, so a hand-made db and an app-made db are identical —
    /// and it is what finally makes `PRAGMA foreign_keys` and the trigram table present
    /// from birth rather than needing a self-heal.
    private func createDatabase() {
        let panel = NSSavePanel()
        panel.message = "Create a new, empty index"
        panel.nameFieldStringValue = "sessions.db"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)

        let schema = FileManager.default.currentDirectoryPath + "/schema.sql"
        let db = DB(path: url.path)
        if FileManager.default.fileExists(atPath: schema) {
            initSchema(db: db, schemaPath: schema)
        } else {
            // Running from a bundle or another cwd: create the tables the app cannot
            // function without, rather than failing silently with an empty file.
            db.exec(SQL.createTailState)
            db.exec(SQL.createTrigramIndex)
        }
        storedDB = url.path
        resetForNewDB()
    }

    /// Drop everything derived from the previous database.
    private func resetForNewDB() {
        status = nil
        projects = []
        selection = []
        didScan = false
        openTier = nil
        tierRows = []
        openRun = nil
        lastResult = nil
        refresh()
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dbPath)])
    }

    /// Status reads walk 1000+ files, so they never run on the main thread.
    private func refresh() {
        guard !loading else { return }
        loading = true
        let p = dbPath, r = effectiveRoot
        DBView.work.async {
            // codexRoot stays the default here deliberately: the app exposes a chooser
            // for the CLAUDE root only, so the default is the one value this call could
            // ever have. `--codex-root` on the CLI threads through for the machines where
            // it differs; if the app ever grows a codex chooser, this is the line to feed.
            let s = readDBStatus(dbPath: p, root: r)
            DispatchQueue.main.async { status = s; loading = false }
        }
        loadCoverage()
    }

    /// Same `runImport` the CLI and the History tab call — no third import path.
    private func runImportAction() {
        guard !isImporting else { return }
        isImporting = true
        progress = ImportProgress(done: 0, total: 0)
        lastResult = nil
        let p = dbPath, r = effectiveRoot
        // A scan with a selection narrows the run; no scan means the unchanged whole-root
        // behaviour. `nil` and "everything selected" are deliberately the same thing.
        let only: Set<String>? = (didScan && selection.count < projects.count) ? selection : nil
        DBView.work.async {
            let summary = runImport(dbPath: p, root: r, only: only) { done, total in
                DispatchQueue.main.async { progress = ImportProgress(done: done, total: total) }
            }
            // BOTH corpora, because the pending count above the button counts both. The
            // status diff learned to see Codex files, so an Import button that ran only
            // the Claude parser could never clear its own number — "Import 5" would do 4,
            // report success, and still say pending forever. A button's label is a
            // promise about what clicking it does.
            let codex = runCodexImport(dbPath: p, codexRoot: defaultCodexRoot)
            DispatchQueue.main.async {
                isImporting = false
                progress = nil
                lastResult = "run \(summary.runId): \(summary.new + codex.new) new · \(summary.changed + codex.changed) changed · \(summary.failed + codex.failed) failed"
                refresh()
                if didScan { scan() }   // recount so the project rows stop showing work already done
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
