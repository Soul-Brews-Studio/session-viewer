// LiveView.swift — the LIVE FLEET tab: what is being written to on this machine RIGHT
// NOW, and an incremental tail of whichever one you select.
//
// Kept in its own file, and joined to the existing window by a single line in App.swift
// (`RootView` instead of `ContentView`), on purpose: the indexed browser and the live
// monitor answer different questions and share no state. It also means this view can be
// deleted or replaced without reopening App.swift.
//
// Threading contract, which is the whole reason this is a separate model rather than a
// pile of @State: NOTHING here does IO. `LiveFleetModel` owns a serial utility queue,
// runs the directory walk and the file reads there, and hands finished value types back
// on the main queue. The p99 session file is 39.6 MB and one was 39.8 MB and live while
// this was written — the window must never touch it directly.

import SwiftUI

enum FleetMode: String, CaseIterable, Hashable {
    case all = "All"
    case live = "Live"
    case search = "Search"
    case db = "Database"
    case mcp = "MCP"
    case graph = "Graph"
}

/// The window's root: the "All" vs "Live" switch. A TabView rather than an if/else so the
/// indexed browser keeps its selection and search results while you glance at the fleet.
/// Polling is driven by the explicit `active` flag below, not by onAppear alone, so it
/// stops when you leave the tab regardless of whether AppKit keeps the view alive.
struct RootView: View {
    /// The database the whole window reads, CHANGEABLE at runtime.
    ///
    /// It used to be a `let` handed down from `launchApp`, so switching index files meant
    /// quitting and relaunching with a different `--db`. It is now @AppStorage: the picker
    /// in the Database tab writes it, every tab re-reads it, and the choice survives a
    /// relaunch. The launch argument becomes the DEFAULT rather than the only option.
    @AppStorage("session-viewer.dbPath") private var storedDB: String = ""
    let launchDB: String

    private var dbPath: String { storedDB.isEmpty ? launchDB : storedDB }
    /// LIVE FIRST. The app opens on the live fleet, not the indexed browser: the question
    /// you have on launch is "what is running right now", and history/search are what you
    /// reach for after that.
    @State private var mode: FleetMode = .live

    /// Tabs that have been opened at least once, and are therefore built and kept alive.
    /// Seeded with the launch tab so it is present on the first frame.
    @State private var visited: Set<FleetMode> = [.live]

    /// Reading the preference here is what makes the whole window re-render when it
    /// changes — `Type.*` reads UserDefaults directly, which SwiftUI cannot observe on its
    /// own. One @AppStorage at the root turns a plain defaults write into a view update.
    @AppStorage(UI_SCALE_KEY) private var uiScale: Double = 1.0
    @State private var showPalette = false

    var body: some View {
        VStack(spacing: 0) {
            // OUR OWN TAB BAR, not TabView's.
            //
            // macOS centres a TabView's bar over the CONTENT REGION, and the tabs do not all
            // have the same content region: Live/All/Database put a NavigationSplitView
            // sidebar on the left, MCP and Graph do not. So the bar centred over a different
            // width on every switch and visibly jumped sideways — a control that moves as you
            // use it, which is the one thing a tab bar must never do.
            //
            // Owning the header fixes the position to the WINDOW, and the ZStack below keeps
            // every tab alive exactly as TabView did, so selections and search results still
            // survive a glance at another tab.
            Picker("", selection: $mode) {
                ForEach(FleetMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()                      // intrinsic width — never stretches with content
            .frame(maxWidth: .infinity)       // then centred on the WINDOW, not on a pane
            .padding(.top, 6)
            .padding(.bottom, 6)

            ZStack {
                // LAZY, then kept alive — the two properties this needs, in that order.
                //
                // The first version of this ZStack built all six tabs immediately, which was
                // a regression against the TabView it replaced: macOS TabView instantiates a
                // tab the first time you select it, and this did not. That put the Metal
                // graph view, a 500-row List and the database pane into the hierarchy of
                // every session, laid out on every render — including each 2-second Live
                // poll, whose whole job is to publish new state.
                //
                // `visited` restores the laziness without giving up the reason the ZStack
                // exists: a tab you have opened stays built, so its selection, scroll
                // position and search results survive a glance at another tab. A tab you
                // have never opened costs exactly nothing.
                ForEach(FleetMode.allCases, id: \.self) { m in
                    if visited.contains(m) {
                        tab(m) { content(for: m) }
                    }
                }
            }
            .onChange(of: mode) { _, now in visited.insert(now) }
        }
        .frame(minWidth: 900, minHeight: 500)
        .overlay(alignment: .topTrailing) { textSizeControl.padding(.trailing, 12).padding(.top, 6) }
        .background {
            // A zero-size button is the reliable way to bind a global ⌘K in a plain
            // NSWindow app: there is no menu-bar item to hang it off, and .keyboardShortcut
            // only fires for a button that is actually in the hierarchy.
            // ⌘K now SELECTS the Search tab instead of opening a palette. Two search
            // surfaces that behave slightly differently is how "how do I search?" got asked
            // three times; there is one now, and the shortcut points at it.
            Button("") { mode = .search }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        }
        .sheet(isPresented: $showPalette) {
            SearchPalette(dbPath: dbPath, isPresented: $showPalette)
        }
    }

    @ViewBuilder private func content(for m: FleetMode) -> some View {
        switch m {
        case .all:    ContentView(dbPath: dbPath)
        case .live:   LiveFleetView(dbPath: dbPath, root: defaultRoot, active: mode == .live)
        case .search: SearchView(dbPath: dbPath, active: mode == .search)
        case .db:     DBView(dbPath: dbPath, root: defaultRoot, active: mode == .db)
        case .mcp:    MCPView(dbPath: dbPath, active: mode == .mcp)
        case .graph:  GraphTabView(dbPath: dbPath, root: defaultRoot, active: mode == .graph)
        }
    }

    /// One tab of the ZStack: laid out always, visible and hit-testable only when selected.
    @ViewBuilder private func tab<V: View>(_ m: FleetMode, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .opacity(mode == m ? 1 : 0)
            .allowsHitTesting(mode == m)
            .accessibilityHidden(mode != m)
            .zIndex(mode == m ? 1 : 0)
    }

    /// Text size, exposed rather than guessed. Three rounds of "still too small" is the
    /// evidence that no single hardcoded value is right for every display and every pair of
    /// eyes — Mail, Xcode and Terminal all ship this control for the same reason.
    /// ⌘+ / ⌘- are the shortcuts every Mac user already tries first.
    private var textSizeControl: some View {
        HStack(spacing: 2) {
            Button { step(-1) } label: { Image(systemName: "textformat.size.smaller") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Smaller text (⌘−)")
            Text("\(Int(uiScale * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34)
                .help("Text size — persists across launches")
            Button { step(+1) } label: { Image(systemName: "textformat.size.larger") }
                .keyboardShortcut("+", modifiers: .command)
                .help("Larger text (⌘+)")
        }
        .buttonStyle(.borderless)
    }

    /// Move to the next authored step rather than a free float, so every size in the app
    /// stays on the designed scale instead of landing on arbitrary fractional points.
    private func step(_ delta: Int) {
        let steps = Content.steps
        let current = CGFloat(uiScale)
        let idx = steps.firstIndex(where: { abs($0 - current) < 0.01 })
            ?? steps.firstIndex(where: { $0 > current })
            ?? 1
        uiScale = Double(steps[max(0, min(steps.count - 1, idx + delta))])
    }
}

// MARK: - The live tab

struct LiveFleetView: View {
    let active: Bool
    @StateObject private var model: LiveFleetModel
    @State private var selectedPath: String?

    /// What the USER asked for, independent of whether the tab happens to be on screen.
    /// Without this, pressing Stop and switching tabs silently restarts following —
    /// the visibility handler would overwrite the explicit choice. Visibility may only
    /// SUSPEND following; it may never turn it back on by itself.
    @State private var wantsFollow = true

    /// Free-text filter over the live fleet — matches project name, session uuid and agent
    /// id, because with 12+ concurrent groups "which one is neo's swift worker" is the
    /// actual question and scrolling for it is the wrong answer.
    @State private var filter = ""

    /// Observed so a text-size change re-renders this view and re-reads `Content.*`.
    /// This replaced `.id(uiScale)` on the root, which forced a whole-tree rebuild and
    /// therefore DESTROYED every @State it contained — changing the font size wiped the
    /// selected session and emptied the detail pane. Observing the value keeps the view's
    /// identity stable, so selection, filter text and expanded rows all survive.
    @AppStorage(UI_SCALE_KEY) private var liveScale: Double = 1.0

    /// Which tail rows are expanded. A Set, not a single id: comparing a command with the
    /// output it produced means having both open at once.
    @State private var expanded: Set<Int> = []

    /// Rows the user explicitly COLLAPSED. Needed because the newest rows auto-expand:
    /// without a record of "I closed this one", the next tick would helpfully re-open it.
    @State private var collapsed: Set<Int> = []

    /// Rows whose long BODY the user chose to see in full.
    ///
    /// Deliberately separate from `expanded`, which auto-opens the newest rows: a body that
    /// expanded itself would reproduce exactly the wall of text this exists to prevent. A
    /// long body always starts as an excerpt, however recent it is.
    @State private var expandedBodies: Set<Int> = []

    /// The newest N events show their full detail without a click. Those are the ones you
    /// are actually reading — a live tail is about what just happened, and clicking each
    /// arriving row to see the command output it already fetched is busywork. Older rows
    /// stay collapsed so scrollback stays scannable.

    init(dbPath: String, root: String, active: Bool) {
        self.active = active
        _model = StateObject(wrappedValue: LiveFleetModel(dbPath: dbPath, root: root))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear { if active && wantsFollow { model.start() } }
        .onDisappear { model.stop() }
        .onChange(of: active) { _, isActive in
            // Leaving the tab suspends the 2 s directory walk — a monitor nobody is
            // looking at is just background load. Coming back only resumes if the user
            // had not deliberately stopped it.
            if isActive && wantsFollow { model.start() } else { model.stop() }
        }
        .onChange(of: selectedPath) { _, path in model.attach(to: path) }
    }

    /// Single entry point for the Start/Stop control, so intent and effect cannot drift.
    private func toggleFollow() {
        wantsFollow.toggle()
        if wantsFollow { model.start() } else { model.stop() }
    }


    /// Groups after filtering. A group survives if its parent OR any child matches, so
    /// searching a worker's agent id still shows you which session it belongs to rather
    /// than an orphaned row with no context.
    /// One project, and every live session group inside it.
    ///
    /// A `LiveGroup` is keyed by session uuid, so a repo with a Claude session AND a Codex
    /// session produced TWO sections carrying the SAME project header. That reads as two
    /// unrelated projects when it is one checkout with two agents on it — which is exactly
    /// the situation this view exists to make visible.
    struct ProjectBucket: Identifiable {
        let project: String
        var groups: [LiveGroup]
        var id: String { project }
        /// Freshest write anywhere in the project — so a project sorts by its hottest
        /// session, and stays put when only one of its sessions is being written.
        var mtime: Int { groups.map(\.mtime).max() ?? 0 }
        var totalSize: Int { groups.reduce(0) { $0 + $1.totalSize } }
        var sessionCount: Int { groups.count }
        var agentCount: Int { groups.reduce(0) { $0 + $1.children.count } }
        /// Which agents are running here. Both is the interesting case.
        var sources: Set<String> {
            var out: Set<String> = []
            for g in groups {
                if let p = g.parent { out.insert(p.source) }
                for c in g.children { out.insert(c.source) }
            }
            return out
        }
    }

    /// Bucket the uuid-groups by project, preserving the group ordering already computed —
    /// projects come out ordered by their first (hottest) group, and groups keep their
    /// order within a project. No re-sort, so nothing moves under the cursor on a poll.
    private var visibleBuckets: [ProjectBucket] {
        var order: [String] = []
        var byProject: [String: ProjectBucket] = [:]
        for g in visibleGroups {
            if byProject[g.project] == nil {
                order.append(g.project)
                byProject[g.project] = ProjectBucket(project: g.project, groups: [])
            }
            byProject[g.project]?.groups.append(g)
        }
        return order.compactMap { byProject[$0] }
    }

    private var visibleGroups: [LiveGroup] {
        let groups = model.groups   // cached; see LiveFleetModel.groups
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            func hit(_ s: LiveSession) -> Bool {
                s.project.lowercased().contains(q)
                || s.sessionUUID.lowercased().contains(q)
                || (s.agentId?.lowercased().contains(q) ?? false)
                || (s.workflowRunId?.lowercased().contains(q) ?? false)
            }
            let parentHit = g.parent.map(hit) ?? false
            let kids = g.children.filter(hit)
            if parentHit { return g }
            if !kids.isEmpty { var g2 = g; g2.children = kids; return g2 }
            return nil
        }
    }

    /// A NON-interactive section label: the PROJECT, carried once for everything in it.
    ///
    /// The parent session used to live HERE, and that was the bug: a List `Section` header
    /// is not a selectable row — it takes no `.tag()`, so List selection can neither
    /// highlight it nor report it. Clicking the parent appeared to do nothing while the
    /// children selected fine. An `onTapGesture` did set the path, but with no selection
    /// highlight the click read as dead. The parent is now a real row inside the section
    /// (see `parentRow`), so List handles parent and child identically and both highlight.
    ///
    /// The header is per PROJECT rather than per session uuid. One repo worked on by both
    /// agents produced two sections with the same path in the header, which reads as two
    /// unrelated projects — when "both agents are on this checkout right now" is exactly
    /// the fact worth seeing.
    @ViewBuilder private func projectLabel(_ b: ProjectBucket) -> some View {
        HStack(spacing: Space.snug) {
            Text(b.project)
                .font(.system(size: Type.small, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)

            // Which agents are here. Both at once is the interesting case and the reason
            // these two corpora share one view at all.
            ForEach(["claude", "codex"].filter(b.sources.contains), id: \.self) { src in
                Text(src == "codex" ? "cdx" : "cc")
                    .font(.system(size: Type.micro, design: Type.mono))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background((src == "codex" ? Color.purple : Color.accentColor)
                                    .opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(src == "codex" ? Color.purple : Color.accentColor)
            }

            if b.sessionCount > 1 {
                Text("\(b.sessionCount) sessions")
                    .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
            }
            if b.agentCount > 0 {
                Text("\(b.agentCount) agent\(b.agentCount == 1 ? "" : "s")")
                    .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
            }
            Text(liveSize(b.totalSize))
                .font(.system(size: Type.micro, design: Type.mono))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// The parent session as a SELECTABLE row, so clicking it tails the session itself
    /// rather than doing nothing. Rendered flush-left; children indent under it.
    @ViewBuilder private func parentRow(_ g: LiveGroup) -> some View {
        if let p = g.parent {
            row(p)
        } else {
            // The session's own transcript has not been written to inside the live window,
            // but its workers have. Say that, rather than showing an empty slot — the
            // group is real, only the parent is quiet.
            HStack(spacing: Space.snug) {
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(String(g.sessionUUID.prefix(8)))
                        .font(.system(size: Type.title, design: Type.mono))
                        .foregroundStyle(.secondary)
                    Text("parent session quiet — only its agents are writing")
                        .font(.system(size: Type.micro))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, Space.tight)
        }
    }

    // MARK: sidebar — the fleet

    private var sidebar: some View {
        VStack(spacing: 0) {
            legend
            TextField("filter — project, session id, agent id", text: $filter)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: Type.small))
                .padding(.horizontal, Space.snug)
                .padding(.bottom, Space.snug)
            Divider()

            if model.sessions.isEmpty {
                VStack(spacing: 6) {
                    Text(model.running ? "nothing written in the last 5 minutes"
                                       : "live polling stopped")
                        .font(.system(size: Type.body)).foregroundStyle(.secondary)
                    Text("this is a normal state — sessions write in bursts at turn boundaries")
                        .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                // STICKY SELECTION. The fleet list is sorted newest-write-first and
                // re-sorts on every 2s poll, so the row you are reading physically moves
                // under the cursor — with 12 live sessions all writing, a selected row can
                // travel several positions between glances, and you lose your place while
                // looking straight at it.
                //
                // Pinning it to the top makes the thing you are watching hold still. It is
                // separated by a divider so the pin is visible rather than looking like a
                // sort bug, and it is the ONLY reordering applied — everything below stays
                // in true recency order.
                // NO STICKY PIN — deliberately removed. Pinning the selected row to the top
                // meant clicking a row REMOVED it from the list and re-rendered it above,
                // so everything below shifted and you lost your place at the exact moment
                // you were trying to focus on something. It was a workaround for a list
                // that re-sorted underneath you; the real fix is a list that does not move.
                //
                // NESTED, not flat. Subagents and workflow agents share their parent's
                // session uuid (they live under <project>/<uuid>/subagents/…), and the flat
                // list threw that away — six "different" live rows were often one session
                // and its five workers, each repeating the same project path. Grouping puts
                // the project on the parent once and indents the workers under it.
                List(selection: $selectedPath) {
                    ForEach(visibleBuckets) { b in
                        Section {
                            ForEach(b.groups) { g in
                                // Parent FIRST and selectable — `.tag` is what makes List
                                // selection able to highlight and report it.
                                parentRow(g)
                                    .tag(g.parent?.path ?? "quiet:\(g.sessionUUID)")
                                ForEach(g.children) { c in
                                    row(c)
                                        .padding(.leading, Space.loose)   // the nesting cue
                                        .tag(c.path)
                                }
                            }
                        } header: {
                            projectLabel(b)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: Space.snug) {
                Text(model.status)
                    .font(.system(size: Type.micro, design: Type.mono))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(indexSummary)
                    .font(.system(size: Type.micro, design: Type.mono))
                    .foregroundStyle(indexSummary == "all indexed" ? Color.secondary : Color.orange)
                    .help("index coverage of the sessions currently live")
            }
            .padding(6)
        }
        .navigationSplitViewColumnWidth(min: 420, ideal: 560, max: 820)
    }

    /// The dot's meaning is spelled out, not implied — three fixed buckets, each shown
    /// next to the colour that means it, above the list it applies to.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("LIVE").font(.system(size: Type.small, weight: .bold)).foregroundStyle(.secondary)
                Text("sessions written in the last")
                    .font(.system(size: Type.small)).foregroundStyle(.secondary)
                // THE WINDOW IS THE ANSWER TO "where are the subagents?".
                //
                // A worker that finished its slice ten minutes ago is genuinely not live,
                // and at a fixed 5 minutes the view could never show it — while the CLI's
                // `--window` could. The caption is now derived from the same value the
                // scan uses, so the two cannot disagree about what is being shown.
                Picker("", selection: Binding(
                    get: { model.windowSeconds },
                    set: { model.setWindow($0) }
                )) {
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("1 hour").tag(3600)
                    Text("8 hours").tag(28800)
                    Text("24 hours").tag(86400)
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("How far back a session counts as live. Widen it to see workers that have already finished.")
                Spacer()
                // Explicit start/stop, not just tab-visibility driven. Following is a
                // thing the user turns on and off — a monitor that cannot be paused is a
                // monitor you cannot read while something scrolls past.
                Button(model.running ? "Stop" : "Start", action: toggleFollow)
                .controlSize(.small)
                .keyboardShortcut(model.running ? .cancelAction : .defaultAction)
                .help(model.running
                      ? "Stop following. The file keeps growing; the tail resumes from the same offset."
                      : "Start following live sessions (rescans every 2s).")

                Text(model.running ? "following" : "paused")
                    .font(.system(size: Type.micro, design: Type.mono))
                    .foregroundStyle(model.running ? .green : .secondary)
            }
            HStack(spacing: 12) {
                ForEach([LiveHeat.hot, .warm, .cool], id: \.caption) { heat in
                    HStack(spacing: 4) {
                        Circle().fill(heatColor(heat)).frame(width: 7, height: 7)
                        Text(heat.caption(window: model.windowSeconds))
                            .font(.system(size: Type.micro)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
    }

    /// HIERARCHY, corrected. The old row led with `s.project` in the largest text — but
    /// the project is what REPEATS (7 of 12 rows read
    /// "/workspace/laris-co/neo-oracle"), while `s.label` — the agent id that
    /// actually identifies the row — was the smallest, dimmest thing in it. The biggest
    /// text on screen was the one string every row shared.
    ///
    /// Now: the identifier leads at `title`, and the repeated project trails at `small` in
    /// secondary, tail-truncated so the DISTINCTIVE end (`…/laris-co/neo-oracle`) survives
    /// rather than the shared `/workspace/` head.
    private func row(_ s: LiveSession) -> some View {
        HStack(alignment: .top, spacing: Space.snug) {
            Circle()
                .fill(heatColor(s.heat))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
                .accessibilityLabel(heatAccessibilityLabel(s.heat, secondsSinceWrite: s.secondsSinceWrite))
            VStack(alignment: .leading, spacing: Space.hair) {
                // The agent's NAME when it has one (parsed from the filename — there is
                // no name field anywhere in the transcript), else the short id.
                // "codex-freeze" tells you which worker this is; "a0dba268cf1507085" does not.
                Text(s.displayLabel)
                    .font(.system(size: Type.title,
                                  weight: s.hasAgentName ? .semibold : .regular,
                                  design: s.hasAgentName ? .default : Type.mono))
                    .lineLimit(1)
                Text(s.project)
                    .font(.system(size: Type.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                HStack(spacing: Space.snug) {
                    // Which agent is writing. Both roots are watched, and Codex workers
                    // are often the only thing live on this machine — without this the
                    // two corpora are indistinguishable in the one view whose entire job
                    // is telling you what is happening right now.
                    Text(s.source == "codex" ? "cdx" : "cc")
                        .font(.system(size: Type.micro, design: Type.mono))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background((s.source == "codex" ? Color.purple : Color.accentColor)
                                        .opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(s.source == "codex" ? Color.purple : Color.accentColor)
                    Text(s.tier).font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                    Text(liveSize(s.size)).font(.system(size: Type.micro, design: Type.mono))
                        .foregroundStyle(.secondary)
                    Text("\(liveAgo(s.secondsSinceWrite)) ago")
                        .font(.system(size: Type.micro, weight: s.heat == .hot ? .semibold : .regular,
                                      design: Type.mono))
                        .foregroundStyle(s.heat == .hot ? Color.primary : Color.secondary)
                    // INDEX state — a second, independent axis from the heat dot. A session
                    // can be live AND unindexed (started after the last import), or idle and
                    // stale. A WORD, not another colour: the dot already owns colour here.
                    if let st = model.indexState[s.path] {
                        Text(st.badge)
                            .font(.system(size: Type.micro, weight: .semibold, design: Type.mono))
                            .foregroundStyle(indexColor(st))
                            .help(st.caption)
                    }
                }
            }
        }
        .padding(.vertical, Space.tight)
        // JUST ARRIVED — a fading highlight so a new row is findable in a list that is
        // already sorted by write time and therefore reorders under you.
        //
        // `freshness` is a dictionary lookup plus one date subtraction; the fade steps once
        // per 2-second poll rather than animating continuously, which is deliberate. A
        // continuously animating background on every row is exactly the per-render work
        // that took this view to 99.9% CPU, and a stepped fade is indistinguishable from a
        // smooth one at this duration.
        // NO `.animation(value:)` HERE, deliberately.
        //
        // The first version animated on `freshness`, which reads `Date()` and therefore
        // returns a slightly different Double on EVERY render. SwiftUI compares that value
        // to decide whether to start an animation, so each render started a fresh 1.2s
        // animation on every visible row — an animation storm that never settles, on the
        // one view already known to fall over when given per-render work. It is the same
        // mistake as the computed `expanded` property, in a different costume.
        //
        // The fade steps once per 2-second poll instead. At a 6-second flash that is three
        // steps, which reads as a fade and costs one dictionary lookup per row.
        .listRowBackground(rowFlash(s))
    }

    /// 1 the instant a session appears, decaying to 0 over `flashSeconds`; 0 for everything
    /// that was already here. Returns 0 — not a highlight — for anything the model is not
    /// tracking, so a row can never be left permanently lit by a missed cleanup.
    private func freshness(_ s: LiveSession) -> Double {
        guard let at = model.appearedAt[s.path] else { return 0 }
        let age = Date().timeIntervalSince(at)
        guard age >= 0 else { return 1 }
        return max(0, 1 - age / LiveFleetModel.flashSeconds)
    }

    /// The row's flash colour, computed ONCE per render.
    ///
    /// `freshness` was previously called three times in one expression — twice in a ternary
    /// and again as an animation key — so every row paid three `Date()` reads and three
    /// dictionary lookups per render. One call, one value.
    private func rowFlash(_ s: LiveSession) -> Color {
        let f = freshness(s)
        return f > 0 ? Color.accentColor.opacity(0.30 * f) : Color.clear
    }

    // MARK: detail — the tail

    @ViewBuilder private var detail: some View {
        if let s = model.sessions.first(where: { $0.path == selectedPath }) {
            VStack(alignment: .leading, spacing: 0) {
                tailHeader(s)
                Divider()
                tailBody
            }
        } else if selectedPath != nil {
            // Selected, then it stopped writing and fell out of the 5-minute window. Say
            // so plainly rather than blanking the pane.
            VStack(spacing: 6) {
                Text("that session went quiet").foregroundStyle(.secondary)
                Text("it left the 5-minute window; it is still in the All tab")
                    .font(.system(size: Type.small)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("select a live session to tail it").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tailHeader(_ s: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(heatColor(s.heat)).frame(width: 10, height: 10)
                Text(s.project).font(.title3).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("\(liveAgo(s.secondsSinceWrite)) since last write")
                    .font(.system(size: Type.body, design: Type.mono))
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow { key("session"); Text(s.label).textSelection(.enabled) }
                GridRow { key("tier"); Text(s.tier + (s.workflowRunId.map { " · \($0)" } ?? "")) }
                GridRow { key("source"); Text(s.source == "codex" ? "codex (~/.codex/sessions)"
                                                                 : "claude (~/.claude/projects)") }
                GridRow { key("size"); Text(liveSize(s.size)) }
                GridRow { key("tail"); Text(model.tailInfo.isEmpty ? "—" : model.tailInfo) }
                GridRow { key("path"); Text(s.path).textSelection(.enabled).lineLimit(1).truncationMode(.head) }
            }
            .font(.system(size: Type.micro, design: Type.mono))
        }
        .padding(10)
    }

    private func key(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    /// Newest at the bottom, auto-scrolled. Only the delta is ever appended — the model
    /// never re-reads the file, so this list grows by the bytes the session actually
    /// wrote, not by its 39 MB size.
    private var tailBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.row) {
                    if model.events.isEmpty {
                        Text("waiting for the next write…\n(attached at the end of the file — earlier lines are in the All tab)")
                            .font(.system(size: Type.small)).foregroundStyle(.tertiary)
                            .padding(.top, Space.loose)
                    }
                    ForEach(model.foldedEvents) { item in
                        switch item {
                        case .event(let e):    eventRow(e).id(item.id)
                        case .stateRun(let r): stateRunRow(r).id(item.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(tailBottomAnchor)
                }
                .padding(Space.pane)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.events.count) { _, _ in
                // NO ANIMATION. An animated scrollTo over a LazyVStack of up to 500
                // variable-height rows re-lays-out the whole stack every frame for the
                // duration of the animation, and new events arrive faster than 0.15s on a
                // busy session — so the animations overlap and layout never settles.
                // Measured on the running app: 99.5% CPU, 3.39 GB RSS, with ViewList (224)
                // and LazyLayout (213) as the hot leaves on the main thread.
                //
                // A tail should SNAP to the bottom anyway. `tail -f` does not ease.
                do {
                    proxy.scrollTo(tailBottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// Import-state tint. `current` is deliberately the QUIETEST — the common case should
    /// recede; it is `new` and `stale` that want your attention because they mean the index
    /// does not yet have what you are looking at.
    private func indexColor(_ st: IndexState) -> Color {
        switch st {
        case .new:     return .orange
        case .stale:   return .yellow
        case .failed:  return .red
        case .current: return .secondary.opacity(0.55)
        }
    }

    /// "3 new · 2 behind" — what the index is missing right now, or nothing when it is
    /// caught up. Shown next to the scan time so one glance answers "is this captured".
    private var indexSummary: String {
        let vals = model.indexState.values
        let new = vals.filter { $0 == .new }.count
        let stale = vals.filter { $0 == .stale }.count
        let failed = vals.filter { $0 == .failed }.count
        var parts: [String] = []
        if new > 0 { parts.append("\(new) new") }
        if stale > 0 { parts.append("\(stale) behind") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "all indexed" : parts.joined(separator: " · ")
    }

    /// Background tint per speaker. Deliberately faint — this is banding, not highlighting;
    /// if a band competes with the text on it, the band has won the wrong argument.
    private func bandColor(for e: LiveEventRow) -> Color {
        switch speakerFor(lineType: e.lineType, hasText: !e.text.isEmpty) {
        case .human:  return Color.accentColor.opacity(0.10)
        case .ai:     return Color.clear
        case .system: return Color.secondary.opacity(0.05)
        }
    }

    /// True when a row shows its full detail: explicitly opened, or recent enough to be
    /// auto-expanded and not explicitly closed.
    private func isExpanded(_ e: LiveEventRow) -> Bool {
        if expanded.contains(e.id) { return true }
        if collapsed.contains(e.id) { return false }
        return isRecent(e)
    }

    /// Within the newest `autoExpandCount` events currently held.
    ///
    /// Reads the model's PUBLISHED Int, never `model.events.last`. Reaching into the array
    /// from inside a row body made every row depend on the whole events array, so one
    /// arriving event re-evaluated all ~150 rows and the LazyVStack rebuilt every
    /// placement — `LazyLayoutViewCache.updatePrefetchPhases` dominated a 99.9% CPU sample.
    private func isRecent(_ e: LiveEventRow) -> Bool {
        e.id > model.autoExpandFloor
    }

    /// A click always means "do the opposite of what I see now", whichever rule produced it.
    private func toggle(_ e: LiveEventRow) {
        if isExpanded(e) {
            expanded.remove(e.id)
            if isRecent(e) { collapsed.insert(e.id) }   // override the auto-expand
        } else {
            collapsed.remove(e.id)
            expanded.insert(e.id)
        }
    }

    private func eventRow(_ e: LiveEventRow) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            HStack(spacing: Space.snug) {
                Text(e.lineType)
                    .font(.system(size: Content.meta, weight: .semibold, design: Content.mono))
                    .foregroundStyle(e.isConversational ? Color.accentColor : Color.secondary)
                Text(shortTime(e.ts))
                    .font(.system(size: Content.meta, design: Content.mono))
                    .foregroundStyle(.tertiary)
            }
            if e.text.isEmpty {
                // A line with no prose is usually still a tool call — name and target,
                // which is what makes a tail scannable. `· no content` is the genuine
                // remainder after tools and thinking are named.
                if let tool = e.toolSummary {
                    Text(tool)
                        .font(.system(size: Content.body, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("· no content")
                        .font(.system(size: Type.small)).foregroundStyle(.tertiary)
                }
            } else if e.isCode {
                // Tool calls and their output are shell, JSON and diffs. Rendered
                // proportional they are genuinely hard to read — columns stop lining up,
                // and l/1/I and 0/O stop being distinguishable in the strings where that
                // matters most. Mono, on a tinted block, with the leading rule that says
                // "this is a quoted artifact, not something someone wrote".
                //
                // LONG BODIES SHOW AN EXCERPT. A single apply_patch here runs to hundreds
                // of lines; rendered whole it pushes every neighbouring event off screen
                // and the tail stops being a tail.
                let showAll = expandedBodies.contains(e.id)
                let body = (e.hiddenLines > 0 && !showAll) ? e.excerpt : e.text
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(body)
                        .font(.system(size: Content.body, design: Content.mono))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if e.hiddenLines > 0 {
                        // Say what the click will DO, and how much is behind it — "show
                        // more" alone gives no way to judge whether it is worth the space.
                        Button {
                            if showAll { expandedBodies.remove(e.id) }
                            else { expandedBodies.insert(e.id) }
                        } label: {
                            Text(showAll
                                 ? "collapse"
                                 : "show \(e.hiddenLines.formatted()) more line\(e.hiddenLines == 1 ? "" : "s")")
                                .font(.system(size: Content.meta, design: Content.mono))
                        }
                        .buttonStyle(.link)
                        .padding(.top, 1)
                    }
                }
                .padding(.vertical, Space.tight)
                .padding(.leading, Space.snug)
                .padding(.trailing, Space.tight)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.45))
                        .frame(width: 2)
                }
                .background(Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 4))
            } else {
                // Corpus text — 15% of it Thai, and Thai sets the floor (see Design.swift).
                // This is body size, never micro.
                Text(e.text)
                    .font(.system(size: Content.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // EXPANDED: the full command, the full output, the full reasoning — the part
            // the one-line summary has to drop. `→ result` used to render as three
            // characters while the line behind it held kilobytes of real command output.
            if isExpanded(e) {
                let details = e.expanded
                if details.isEmpty {
                    Text("(nothing further in this line)")
                        .font(.system(size: Content.meta)).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: Space.snug) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, d in
                            VStack(alignment: .leading, spacing: Space.hair) {
                                Text(d.title)
                                    .font(.system(size: Content.meta, weight: .semibold, design: Content.mono))
                                    .foregroundStyle(d.isError ? Color.red : Color.secondary)
                                Text(d.body)
                                    .font(.system(size: Content.body, design: Content.mono))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(Space.snug)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded(e) { expanded.remove(e.id) } else { expanded.insert(e.id) }
        }
        .help(expanded.contains(e.id) ? "click to collapse" : "click to expand — full command, output, reasoning")
    }

    /// The 8-in-a-row collapse. A single turn emits `attachment`, `last-prompt`,
    /// `custom-title`, `ai-title`, `mode`, `permission-mode`, `atis-latch`, `pr-link`
    /// consecutively — eight identical grey rows saying nothing individually. One line
    /// preserves the real signal ("the file moved, here is when") at a twelfth the height.
    private func stateRunRow(_ run: StateRun) -> some View {
        HStack(spacing: Space.snug) {
            Text("⋯")
                .font(.system(size: Type.micro, design: Type.mono))
                .foregroundStyle(.tertiary)
            Text("\(run.count) state line\(run.count == 1 ? "" : "s")")
                .font(.system(size: Type.small))
                .foregroundStyle(.tertiary)
            Text(run.types.joined(separator: " · "))
                .font(.system(size: Type.micro, design: Type.mono))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(shortTime(run.lastTs))
                .font(.system(size: Type.micro, design: Type.mono))
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A consecutive run of bookkeeping lines, folded into one row.
struct StateRun: Identifiable {
    let id: Int          // id of the first event in the run — stable, monotonic
    var count: Int
    var types: [String]  // distinct, in first-seen order
    var lastTs: String?
}

/// Either a real event or a folded run of state lines. Built once per render pass from the
/// flat event list, so the collapse is a VIEW concern and the model still holds every line.
enum TailItem: Identifiable {
    case event(LiveEventRow)
    case stateRun(StateRun)

    var id: Int {
        switch self {
        case .event(let e):    return e.id
        case .stateRun(let r): return r.id
        }
    }
}

/// Fold consecutive STATE_LINE_TYPES rows together; everything else passes through.
/// A run of one is NOT folded — collapsing a single line into "1 state lines" would be
/// strictly worse than just showing it.
func foldStateRuns(_ events: [LiveEventRow]) -> [TailItem] {
    var out: [TailItem] = []
    var run: StateRun?

    func flush() {
        guard let r = run else { return }
        // EVERY run folds, including a run of one.
        //
        // This used to be an if/else whose two branches were byte-identical, under a
        // comment claiming "a run of one is NOT folded". The comment described an intent
        // the code never had, and dead branches do not fail — they quietly do the other
        // thing. Found by a test author READING the code, not by anything going red.
        //
        // Resolved in favour of the code, not the comment: a folded single line still
        // shows its type and timestamp, so nothing is lost, and one uniform rule beats a
        // special case. `stateRunRow` pluralises so it never reads "1 state lines".
        out.append(.stateRun(r))
        run = nil
    }

    for e in events {
        let ty = e.lineType
        if STATE_LINE_TYPES.contains(ty) {
            if var r = run {
                r.count += 1
                if !r.types.contains(ty) { r.types.append(ty) }
                r.lastTs = e.ts ?? r.lastTs
                run = r
            } else {
                run = StateRun(id: e.id, count: 1, types: [ty], lastTs: e.ts)
            }
        } else {
            flush()
            out.append(.event(e))
        }
    }
    flush()
    return out
}

private let tailBottomAnchor = "live-tail-bottom"

// heatColor moved to Design.swift so the legend and the dots read one definition.
// The old copy also returned `.gray` for .cool — a fixed grey that does not adapt to
// light mode; Design.swift uses `.secondary`, which does.

/// "2026-08-24T21:56:55.123Z" → "21:56:55". Same prefix-trim reasoning as App.swift's
/// shortDate: the field is always this ISO shape, and this runs per row.
private func shortTime(_ iso: String?) -> String {
    guard let iso, iso.count >= 19 else { return "—" }
    let start = iso.index(iso.startIndex, offsetBy: 11)
    let end = iso.index(iso.startIndex, offsetBy: 19)
    return String(iso[start..<end])
}

// MARK: - ⌘K search palette

/// Spotlight/VSCode-style search over the indexed corpus. A sheet rather than the sidebar
/// field because ⌘K is muscle memory for "search from anywhere" — it works on either tab
/// without first navigating to the one that owns a text field.
///
/// It calls the SAME `searchEvents` as the sidebar, so it inherits the FTS5 input
/// sanitizing (`ftsQuery`) — typing `append-only` here finds hits instead of silently
/// returning nothing, which is what the raw MATCH did before.
struct SearchPalette: View {
    let dbPath: String
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.snug) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("search all indexed sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Type.title))
                    .focused($focused)
                    .onSubmit(run)
                if searching { ProgressView().controlSize(.small) }
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
            }
            .padding(Space.pane)

            Divider()

            if hits.isEmpty {
                VStack(spacing: Space.tight) {
                    Text(query.isEmpty ? "type to search, ↩ to run" : "no matches")
                        .font(.system(size: Type.body)).foregroundStyle(.secondary)
                    if !query.isEmpty {
                        Text("every word is matched as a literal phrase")
                            .font(.system(size: Type.micro)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(hits) { h in
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(h.snippet)
                            .font(.system(size: Type.body))
                            .lineLimit(2)
                        HStack(spacing: Space.snug) {
                            Text(h.role)
                                .font(.system(size: Type.micro, weight: .semibold, design: Type.mono))
                                .foregroundStyle(Color.accentColor)
                            Text(h.uuid.prefix(8))
                                .font(.system(size: Type.micro, design: Type.mono))
                                .foregroundStyle(.secondary)
                            Text(h.ts.map { String($0.prefix(19)) } ?? "—")
                                .font(.system(size: Type.micro, design: Type.mono))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, Space.hair)
                }
            }
        }
        .frame(width: 760, height: 520)
        .onAppear { focused = true }
    }

    /// Off the main thread: FTS over 17k+ rows is fast but not free, and a palette that
    /// stutters while you type is worse than one that takes a beat after ↩.
    private func run() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { hits = []; return }
        searching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let db = DB(path: dbPath)
            db.setBusyTimeout()
            let found = searchEvents(db: db, query: q, limit: 200)
            DispatchQueue.main.async {
                hits = found
                searching = false
            }
        }
    }
}
