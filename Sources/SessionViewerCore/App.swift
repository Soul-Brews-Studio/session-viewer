// App.swift — the SwiftUI window. Reads the same local sqlite file the CLI writes.
//
// Deliberately read-only except for one write path: the Import button, which runs the
// exact same `runImport` (main.swift) on a background queue — no import logic lives
// here, only scheduling + progress relay. Keeping the rest a reader means the future
// Bun/Drizzle ingest can take over writes without this file changing at all.

import SwiftUI
import AppKit

public func launchApp(dbPath: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(dbPath: dbPath)
    app.delegate = delegate
    app.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let dbPath: String
    var window: NSWindow?

    init(dbPath: String) { self.dbPath = dbPath }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // RootView is the All/Live tab switch (LiveView.swift); ContentView is its "All"
        // tab, unchanged. The live fleet monitor is kept entirely out of this file — it
        // shares no state with the indexed browser and polls the filesystem instead of
        // reading the db.
        let view = RootView(launchDB: dbPath)
        let hosting = NSHostingView(rootView: view)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Session Viewer"
        win.contentView = hosting
        // Remember size and position across launches. Without this the window reopens at
        // 1200x760 on whatever Space AppKit picks, every single time.
        win.setFrameAutosaveName("SessionViewerMain")
        if win.frame.origin == .zero { win.center() }
        win.makeKeyAndOrderFront(nil)
        window = win
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// One progress tick from a background `runImport` call — see `runImportAction` below.
struct ImportProgress {
    let done: Int
    let total: Int
}

struct ContentView: View {
    let dbPath: String

    @State private var sessions: [SessionRow] = []
    @State private var hits: [SearchHit] = []
    @State private var typeCounts: [TypeCount] = []
    @State private var selected: SessionRow?
    @State private var tierFilter: String = "all"

    /// Activity window — "which sessions were WRITTEN in the last N". The same
    /// `parseSinceWindow` the registry's list command uses, so the UI, the CLI and the MCP
    /// tool cannot disagree about what "3h" means. "today" is local midnight, not 24h.
    @State private var sinceFilter: String = "all"
    private let sinceChoices = ["all", "30m", "3h", "today", "7d"]
    @State private var query: String = ""
    @State private var status: String = ""
    /// See LiveFleetView: observed so a text-size change re-renders without a rebuild that
    /// would discard `selected`, `query` and the loaded rows.
    @AppStorage(UI_SCALE_KEY) private var allScale: Double = 1.0

    @State private var isImporting = false
    @State private var importProgress: ImportProgress?

    // Sorting is done by SQLite (ORDER BY), not in Swift, so it applies to the whole
    // table before LIMIT — sorting the 500 rows already fetched would silently sort a
    // window of the corpus instead of the corpus. Defaults match the old fixed
    // `ORDER BY s.file_mtime DESC`, so first paint is unchanged.
    @State private var sortKey: SessionSort = .mtime
    @State private var sortDir: SortDirection = .desc

    private let tiers = ["all", "session", "subagent", "workflow_agent"]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear(perform: reload)
        .onChange(of: selected) { _, row in loadTypeCounts(for: row) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tierFilter) {
                    ForEach(tiers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: tierFilter) { _, _ in reload() }

                Picker("", selection: $sinceFilter) {
                    ForEach(sinceChoices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Only sessions written in this window (index mtime). today = since local midnight.")
                .onChange(of: sinceFilter) { _, _ in reload() }

                Button("Reload", action: reload)

                // Every allow-listed key, including the two with no visible column
                // (project, lines). Same applySort path as the column headers.
                Menu {
                    ForEach(SessionSort.allCases, id: \.self) { key in
                        Button(action: { applySort(key) }) {
                            Text(key == sortKey ? "\(key.rawValue) \(sortDir.arrow)" : key.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("sort by…")

                Spacer()

                importControl
            }
            .padding(8)

            TextField("search indexed text…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runSearch)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            if !query.isEmpty && !hits.isEmpty {
                // Each hit is a Button, not a plain row, so clicking one selects its
                // session and drives the same detail pane the sidebar list uses.
                List(hits) { hit in
                    Button(action: { selectHit(hit) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.snippet)
                                .font(.system(size: Type.body)).lineLimit(3)
                                .foregroundStyle(.primary)
                            Text("\(hit.role) · \(hit.uuid.prefix(8)) · \(hit.ts ?? "—")")
                                .font(.system(size: Type.micro)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                sortHeader
                List(sessions, selection: $selected) { row in
                    HStack(spacing: ColW.gap) {
                        // A blank description is common — Codex rollouts and workflow
                        // agents often have none — so the uuid column below is what makes
                        // such a row identifiable at all.
                        Text(row.description ?? "—")
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 3) {
                            Circle()
                                .fill(row.source == "codex" ? Color.purple : Color.accentColor)
                                .frame(width: 6, height: 6)
                            Text(row.source == "codex" ? "cdx" : "cc")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: ColW.source, alignment: .leading)
                        Text(row.uuid.prefix(8))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(width: ColW.uuid, alignment: .leading)
                        Text(row.tier)
                            .foregroundStyle(.secondary)
                            .frame(width: ColW.tier, alignment: .leading)
                        Text("\(row.eventCount)")
                            .frame(width: ColW.events, alignment: .trailing)
                        Text("\(row.size / 1000)")
                            .frame(width: ColW.size, alignment: .trailing)
                        Text(compactStamp(iso: row.startedAt))
                            .foregroundStyle(.secondary)
                            .frame(width: ColW.time, alignment: .leading)
                        Text(compactStamp(epoch: row.mtime))
                            .foregroundStyle(.secondary)
                            .frame(width: ColW.time, alignment: .leading)
                    }
                    .font(.system(size: Type.small))
                    .tag(row)
                }
            }

            Divider()
            Text(status).font(.system(size: Type.small)).foregroundStyle(.secondary).padding(6)
        }
        // This sidebar is a 6-column TABLE, not a list of labels, so it needs real width:
        // at 480 the description clipped to "VERIFIED FACT…" and the tier to "workflo…"
        // while ~1200px of detail pane sat empty. `ideal` is what NavigationSplitView
        // actually honours on first open; min alone does not claim the space.
        .navigationSplitViewColumnWidth(min: 620, ideal: 900, max: 1200)
    }

    /// Clickable column headers. Click a column to sort by it, click the active column
    /// again to reverse; the active column carries the ▲/▼ indicator and bold text.
    ///
    /// Each header hands `applySort` a `SessionSort` CASE, never a string — the header
    /// title is display text and never reaches the SQL. See SQL.swift.
    private var sortHeader: some View {
        HStack(spacing: ColW.gap) {
            header(.description, width: nil, align: .leading)
            // Not sortable: `source` and `uuid` are identity, not a ranking. Every sortable
            // header maps to a SessionSort case, and inventing cases for these would widen
            // the allow-list that keeps ORDER BY safe for no gain.
            Text("src").frame(width: ColW.source, alignment: .leading)
            Text("session").frame(width: ColW.uuid, alignment: .leading)
            header(.tier, width: ColW.tier, align: .leading)
            header(.events, width: ColW.events, align: .trailing)
            header(.size, width: ColW.size, align: .trailing)
            header(.started, width: ColW.time, align: .leading)
            header(.mtime, width: ColW.time, align: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func header(_ key: SessionSort, width: CGFloat?, align: Alignment) -> some View {
        let active = key == sortKey
        Button(action: { applySort(key) }) {
            HStack(spacing: 2) {
                if align == .trailing { Spacer(minLength: 0) }
                Text(key.label)
                    .font(.system(size: Type.micro, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(active ? sortDir.arrow : " ").font(.system(size: Type.micro))
                if align == .leading { Spacer(minLength: 0) }
            }
            // The whole header cell is the hit target, not just the glyphs.
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("sort by \(key.rawValue)")
    }

    /// Click a header: same column → reverse; new column → its natural direction.
    /// Re-queries SQLite rather than re-sorting `sessions` in memory (see `sortKey`).
    private func applySort(_ key: SessionSort) {
        if key == sortKey {
            sortDir = sortDir.toggled
        } else {
            sortKey = key
            sortDir = key.defaultDirection
        }
        reload()
    }

    /// Import button + its own progress indicator. Disabled while running so a second
    /// click can't start an overlapping import; the spinner/bar is the only feedback
    /// this needs since `runImportAction` relays progress back onto `status` too.
    private var importControl: some View {
        HStack(spacing: 6) {
            if isImporting {
                if let p = importProgress, p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                        .frame(width: 70)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Button(isImporting ? "Importing…" : "Import", action: runImportAction)
                .disabled(isImporting)
        }
    }

    @ViewBuilder private var detail: some View {
        if let s = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.description ?? s.uuid).font(.title3)
                    // Knowing the path is only half of it — the reason you want a session's
                    // location is to hand it to something else. Selecting a wrapped monospace
                    // path out of a Grid is exactly the fiddly step these two buttons remove.
                    HStack(spacing: Space.snug) {
                        Button("Copy uuid") { setClipboard(s.uuid) }
                        Button("Copy path") { setClipboard(s.path) }
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: s.path)])
                        }
                    }
                    .controlSize(.small)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        row("uuid", s.uuid)
                        row("source", s.source == "codex" ? "codex (~/.codex/sessions)"
                                                          : "claude (~/.claude/projects)")
                        row("tier", s.tier)
                        row("project", s.project)
                        row("started", s.startedAt ?? "—")
                        row("lines", "\(s.lineCount)")
                        row("events", "\(s.eventCount)")
                        row("size", "\(s.size / 1000) KB")
                        row("path", s.path)
                    }
                    .font(.system(size: Type.body, design: Type.mono))

                    // Per-line-type breakdown from session_type_counts — makes the
                    // ~14-types-not-3 reality (SPEC.md) visible per session, not just
                    // the 3 conversational roles event_count/events_fts summarize.
                    if !typeCounts.isEmpty {
                        Divider()
                        Text("line types (\(typeCounts.count))").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                            ForEach(typeCounts) { tc in
                                GridRow {
                                    Text(tc.lineType).foregroundStyle(.secondary)
                                    Text("\(tc.count)").textSelection(.enabled)
                                }
                            }
                        }
                        .font(.system(size: Type.body, design: Type.mono))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("select a session").foregroundStyle(.secondary)
        }
    }

    /// `NSPasteboard` appends to whatever is already on the general board unless you clear
    /// it first, so a copy without `clearContents()` can silently paste the previous value.
    private func setClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }

    private func reload() {
        let db = DB(path: dbPath)
        sessions = fetchSessions(db: db,
                                 tier: tierFilter == "all" ? nil : tierFilter,
                                 sort: sortKey,
                                 direction: sortDir,
                                 since: parseSinceWindow(sinceFilter))
        // SAY WHEN THIS IS A PAGE, NOT THE WHOLE SET. `fetchSessions` applies a LIMIT, and
        // the status line previously read "500 sessions" against a 1,891-row table — which
        // states a total it does not have. Silent under-reporting is the exact failure this
        // project exists to catch; stating it about our own list is worse than a stranger's.
        let total = countSessions(db: db) ?? sessions.count
        let shown = sessions.count
        var scope = tierFilter == "all" ? "" : " · tier \(tierFilter)"
        if sinceFilter != "all" { scope += " · last \(sinceFilter)" }
        status = shown < total
            ? "showing \(shown) of \(total) sessions\(scope) · sort \(sortKey.rawValue) \(sortDir.rawValue) · \(dbPath)"
            : "\(total) sessions\(scope) · sort \(sortKey.rawValue) \(sortDir.rawValue) · \(dbPath)"
    }

    private func runSearch() {
        guard !query.isEmpty else { hits = []; return }
        let db = DB(path: dbPath)
        hits = searchEvents(db: db, query: query)
        status = "\(hits.count) matches for “\(query)”"
    }

    /// A search hit's session may belong to a tier the sidebar isn't currently
    /// showing, so this fetches by id directly rather than looking it up in `sessions`.
    private func selectHit(_ hit: SearchHit) {
        let db = DB(path: dbPath)
        if let row = fetchSession(db: db, id: hit.sessionId) {
            selected = row
        }
    }

    private func loadTypeCounts(for row: SessionRow?) {
        guard let row else { typeCounts = []; return }
        let db = DB(path: dbPath)
        typeCounts = fetchTypeCounts(db: db, sessionId: row.id)
    }

    /// Runs the exact `runImport` code path (main.swift, same one `just import` calls)
    /// on a background queue so the window never freezes on the 39.6 MB p99 file or the
    /// full ~975-file corpus. No import logic is duplicated here — this only schedules
    /// the call and relays its per-file progress back to @State on the main queue.
    private func runImportAction() {
        guard !isImporting else { return }
        isImporting = true
        importProgress = ImportProgress(done: 0, total: 0)
        status = "importing…"
        let path = dbPath

        DispatchQueue.global(qos: .userInitiated).async {
            let summary = runImport(dbPath: path, root: defaultRoot) { done, total in
                DispatchQueue.main.async {
                    importProgress = ImportProgress(done: done, total: total)
                    status = "importing \(done)/\(total)…"
                }
            }
            // Both corpora — same reasoning as DBView's button: the pending counts
            // include Codex files, so the action must too.
            let codex = runCodexImport(dbPath: path, codexRoot: defaultCodexRoot)
            DispatchQueue.main.async {
                isImporting = false
                importProgress = nil
                status = "import: \(summary.new + codex.new) new, \(summary.changed + codex.changed) changed, "
                    + "\(summary.skipped + codex.skipped) skipped, \(summary.failed + codex.failed) failed"
                reload()
            }
        }
    }
}

/// Fixed widths shared by `sortHeader` and the list rows — the two must agree or the
/// headers stop pointing at the columns they sort.
/// Column widths SCALE WITH THE TYPE. They used to be fixed at sizes chosen for 9-11pt
/// text; when the type scale grew, the columns did not, so "workflow_agent" clipped to
/// "workflo…" and bigger text just meant more truncation. Widths are now derived, so one
/// preference moves the whole grid coherently.
private enum ColW {
    static var gap: CGFloat { 6 * Content.scale }
    static var source: CGFloat { 54 * Content.scale }
    static var uuid: CGFloat { 74 * Content.scale }
    static var tier: CGFloat { 92 * Content.scale }
    static var events: CGFloat { 52 * Content.scale }
    static var size: CGFloat { 56 * Content.scale }
    static var time: CGFloat { 88 * Content.scale }
}

/// "2026-08-24T10:15:30.123Z" → "08-24 10:15" — a plain substring trim, not a
/// DateFormatter: started_at is always this ISO shape (straight from the jsonl
/// `timestamp` field), and this runs per row across a list of up to 500. The year is
/// dropped to fit the column; the full value is in the detail pane.
private func compactStamp(iso: String?) -> String {
    guard let iso, iso.count >= 16 else { return "—" }
    let s = iso.index(iso.startIndex, offsetBy: 5)
    let e = iso.index(iso.startIndex, offsetBy: 16)
    return String(iso[s..<e]).replacingOccurrences(of: "T", with: " ")
}

/// file_mtime (unix epoch) → a formatted stamp, **in UTC on the Gregorian calendar**.
///
/// Both pins are load-bearing, both were caught by running it on this machine:
///   * locale — the default locale here is Thai, so `DateFormatter` renders the Buddhist
///     era and prints file mtimes as **2569**-08-24. `en_US_POSIX` pins the calendar.
///   * timezone — `started_at` comes straight out of the jsonl as UTC (…Z) and is shown
///     by a substring trim, so rendering mtime in local time would put the two adjacent
///     time columns 7 hours apart and make "started after it was modified" look normal.
///
/// One shared formatter: allocating a DateFormatter per row across 500 rows per reload
/// is a known cost. Lives here rather than in main.swift because top-level-code globals
/// there initialize in statement order, after the subcommand switch has already run.
let utcStampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

func utcStamp(epoch: Int, format: String) -> String {
    guard epoch > 0 else { return "—" }
    utcStampFormatter.dateFormat = format
    return utcStampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

private func compactStamp(epoch: Int) -> String { utcStamp(epoch: epoch, format: "MM-dd HH:mm") }

extension SessionRow: Hashable {
    static func == (a: SessionRow, b: SessionRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
