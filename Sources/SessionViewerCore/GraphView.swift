import SwiftUI
import MetalKit
import simd

// GraphView.swift — the GRAPH tab: pick a session, see its beats/tools/targets as a
// GPU-laid-out knowledge graph.
//
// The SwiftUI side owns NOTHING about the simulation. It picks a file, builds the graph on
// a background queue, hands the result to the renderer once, and then gets out of the way:
// MTKView drives frames from the display link, not from SwiftUI's update cycle. Publishing
// per-frame state into SwiftUI is precisely the churn that produced the freeze in TODO.md.

/// NSViewRepresentable bridge. `preferredFramesPerSecond` is deliberately 60 rather than
/// ProMotion's 120 — the layout anneals to a stop within a few seconds, so the extra
/// frames buy nothing and cost power on a laptop.
struct MetalGraphView: NSViewRepresentable {
    let graph: SessionGraph
    @Binding var zoom: Double
    @Binding var pan: CGSize
    @Binding var picked: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: GraphRenderer?
        /// Identity of the graph currently uploaded, so `updateNSView` re-uploads on a real
        /// change instead of every SwiftUI pass (which would reset the layout constantly).
        var loadedSignature: String = ""
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.055, 0.062, 0.085, 1.0)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        if let dev = view.device, let r = GraphRenderer(device: dev) {
            context.coordinator.renderer = r
            view.delegate = r
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        let sig = "\(graph.nodes.count)/\(graph.edges.count)/\(graph.nodes.first?.label ?? "")"
        if sig != context.coordinator.loadedSignature {
            context.coordinator.loadedSignature = sig
            r.load(graph)
        }
        r.camera.scale = Float(zoom)
        r.camera.offset = SIMD2(Float(pan.width), Float(-pan.height))
    }
}

struct GraphTabView: View {
    let dbPath: String
    let root: String
    let active: Bool

    /// A row in the picker. Its own type rather than `LiveSession`: that struct carries
    /// liveness (`secondsSinceWrite`, heat) which is meaningless here — the graph tab reads
    /// files at rest, and borrowing a shape for fields you must then invent is how the two
    /// drift apart.
    struct Row: Identifiable, Hashable {
        let path: String
        let label: String
        let tier: String
        let size: Int
        var id: String { path }
    }

    @State private var sessions: [Row] = []
    @State private var selected: String?
    @State private var graph = SessionGraph()
    @State private var building = false
    @State private var zoom: Double = 1.0
    @State private var pan: CGSize = .zero
    @State private var picked: Int?

    var body: some View {
        HSplitView {
            sessionList.frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            VStack(spacing: 0) {
                canvas
                legend
            }
            .frame(minWidth: 420)
        }
        .onAppear { if active { loadSessions() } }
        .onChange(of: active) { _, now in if now { loadSessions() } }
    }

    // MARK: - left: what to graph

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SESSIONS").font(.system(size: Type.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rescan") { loadSessions() }.font(.system(size: Type.micro))
            }
            .padding(.horizontal, Space.row).padding(.vertical, Space.snug)

            List(sessions, id: \.path, selection: $selected) { s in
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.label).font(.system(size: Type.small, weight: .medium))
                    Text("\(s.tier) · \(humanBytes(s.size))")
                        .font(.system(size: Type.micro)).foregroundStyle(.secondary)
                }
                .tag(s.path)
            }
            .onChange(of: selected) { _, path in if let path { build(path) } }
        }
    }

    // MARK: - right: the GPU canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            MetalGraphView(graph: graph, zoom: $zoom, pan: $pan, picked: $picked)
                .gesture(
                    DragGesture()
                        .onChanged { v in pan = CGSize(width: v.translation.width, height: v.translation.height) }
                )

            if building {
                Text("building graph…")
                    .font(.system(size: Type.small)).padding(Space.snug)
            } else if graph.nodes.isEmpty {
                Text(selected == nil ? "select a session" : "no graphable structure in this file")
                    .font(.system(size: Type.small)).foregroundStyle(.secondary).padding(Space.row)
            }

            HStack(spacing: Space.snug) {
                Spacer()
                Button { zoom = max(0.15, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: Type.micro, design: Type.mono))
                    .frame(width: 42)
                Button { zoom = min(6, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                Button("Reset") { zoom = 1; pan = .zero }
                    .font(.system(size: Type.micro))
            }
            .padding(Space.snug)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The legend is not decoration: four colours with no key is a puzzle, and the counts
    /// double as the answer to "was this session mostly work or mostly talk".
    private var legend: some View {
        HStack(spacing: Space.pane) {
            key(.blue, "beat", graph.beats)
            key(.orange, "tool", graph.tools)
            key(.green, "target", graph.targets)
            if graph.recurring > 0 {
                Text("\(graph.recurring) revisited")
                    .font(.system(size: Type.micro)).foregroundStyle(.secondary)
                    .help("Targets touched by more than one beat — the cross-session links")
            }
            Spacer()
            if graph.truncated {
                Label("tail only", systemImage: "scissors")
                    .font(.system(size: Type.micro)).foregroundStyle(.orange)
                    .help("File exceeded the graph read cap; showing the most recent 8 MB")
            }
            Text("\(graph.edges.count) edges")
                .font(.system(size: Type.micro, design: Type.mono)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.row).padding(.vertical, Space.snug)
    }

    private func key(_ c: Color, _ label: String, _ n: Int) -> some View {
        HStack(spacing: Space.tight) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(label) \(n)").font(.system(size: Type.micro))
        }
    }

    // MARK: - work

    private func loadSessions() {
        let r = root
        DispatchQueue.global(qos: .userInitiated).async {
            // Newest first, and skip files too small to have structure — a graph of a
            // 200-byte file is three dots and a lie about there being something to see.
            let files = discoverFiles(root: r)
                .filter { $0.size > 4096 }
                .sorted { $0.mtime > $1.mtime }
                .prefix(300)
                .map { f in
                    Row(path: f.path,
                        label: agentDisplayName(agentId: f.agentId) ?? String(f.sessionUUID.prefix(8)),
                        tier: f.tier,
                        size: f.size)
                }
            DispatchQueue.main.async { sessions = Array(files) }
        }
    }

    private func build(_ path: String) {
        building = true
        DispatchQueue.global(qos: .userInitiated).async {
            let g = buildSessionGraph(path: path)
            DispatchQueue.main.async {
                graph = g
                building = false
                zoom = 1; pan = .zero
            }
        }
    }
}
