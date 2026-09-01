import SwiftUI
import AppKit

// MCPView.swift — the MCP tab: what this server exposes, and what it costs.
//
// `tools/list` answers "what can I call". The question you actually have, when a client is
// showing 98 tools from five servers and silently dropping some, is "where did each of
// these come from and what is it costing me". This renders that.
//
// It calls the same `readMCPSurface` the CLI and `GET /mcp/surface` use, which in turn
// calls the same `mcpTools()`/`topicTools()`/`upstreamTools()` the protocol handler calls.
// A view of your own tool surface that could disagree with the surface would be worse than
// no view.

struct MCPView: View {
    let dbPath: String
    let active: Bool

    @State private var surface: MCPSurface?
    @State private var loading = false
    @State private var probe = true
    @AppStorage(UI_SCALE_KEY) private var uiScale: Double = 1.0

    private static let work = DispatchQueue(label: "session-viewer.mcpview", qos: .userInitiated)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.pane) {
                header
                if let s = surface {
                    budget(s)
                    if !s.upstreams.isEmpty { upstreams(s) }
                    toolTable(s)
                } else {
                    Text(loading ? "reading surface…" : "not loaded")
                        .font(.system(size: Type.small)).foregroundStyle(.secondary)
                }
            }
            .padding(Space.loose)
        }
        .onAppear { if active { load() } }
        .onChange(of: active) { _, now in if now { load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                Text("MCP").font(.system(size: Type.heading, weight: .semibold))
                if let s = surface {
                    chip("modern \(s.protocolVersions.joined(separator: ", "))", .purple)
                    chip("+\(s.handshakeVersions.count) handshake", .secondary)
                }
                Spacer()
                Toggle("Probe upstreams", isOn: $probe)
                    .toggleStyle(.checkbox)
                    .font(.system(size: Type.micro))
                    .help("Probing costs a process spawn or HTTP round trip per upstream")
                Button("Reload") { load() }.disabled(loading)
            }
            // Both transports, stated, because which one a client used changes what it can
            // receive — list_changed only reaches stdio.
            Text("stdio · `session-viewer mcp`     ·     Streamable HTTP · POST /mcp (loopback, Origin-checked)")
                .font(.system(size: Type.micro, design: Type.mono)).foregroundStyle(.tertiary)
        }
    }

    /// The number that decides whether promoting another topic is a good idea.
    private func budget(_ s: MCPSurface) -> some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.loose) {
                stat("\(s.tools.count)", "tools exposed")
                stat("\(s.builtInCount)", "built-in")
                stat("\(s.topicCount)", "promoted topics")
                stat("\(s.upstreamCount)", "wrapped")
                stat("~\(s.approxTokens.formatted())", "tokens of definitions")
                Spacer()
            }
            HStack(spacing: Space.snug) {
                Image(systemName: s.tools.count > 40 ? "exclamationmark.triangle.fill"
                                : s.tools.count > 30 ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(s.tools.count > 40 ? .red : s.tools.count > 30 ? .orange : .green)
                Text(s.budgetNote)
                    .font(.system(size: Content.meta)).foregroundStyle(.secondary)
            }
            // The limits are the CLIENT's, across every connected server — so a green light
            // here is necessary, not sufficient. Saying so beats implying otherwise.
            Text("These limits apply to the client's TOTAL across every connected server, not to this one alone. \(s.topicsTotal) topic(s) saved, \(s.topicsPromoted) promoted — the rest cost nothing and run via dig_topic.")
                .font(.system(size: Content.meta)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func upstreams(_ s: MCPSurface) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text("WRAPPED SERVERS").font(.system(size: Type.micro, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(s.upstreams.enumerated()), id: \.offset) { _, u in
                HStack(spacing: Space.snug) {
                    Circle().fill(u.reachable ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(u.name).font(.system(size: Content.body, design: Content.mono))
                        .frame(width: 120, alignment: .leading)
                    Text(u.transport).font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    // The era is worth showing: a legacy upstream needs an initialize
                    // handshake, and speaking modern at one gets silence, not an error.
                    let eraColor: Color = u.era == "legacy" ? .orange : .secondary
                    Text(u.era).font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(eraColor)
                        .frame(width: 66, alignment: .leading)
                    let reachColor: Color = u.reachable ? .secondary : .orange
                    Text(u.reachable ? "\(u.toolCount) tools" : "unreachable")
                        .font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(reachColor)
                        .frame(width: 90, alignment: .trailing)
                    Text(String(format: "%.0f ms", u.ms))
                        .font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.tertiary).frame(width: 66, alignment: .trailing)
                    Text(u.endpoint ?? "")
                        .font(.system(size: Content.meta)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
            }
        }
    }

    private func toolTable(_ s: MCPSurface) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("EXPOSED TOOLS").font(.system(size: Type.micro, weight: .semibold))
                .foregroundStyle(.secondary).padding(.bottom, Space.tight)
            HStack(spacing: 0) {
                Text("tool").frame(width: 260, alignment: .leading)
                Text("origin").frame(width: 100, alignment: .leading)
                Text("~tokens").frame(width: 80, alignment: .trailing)
                Text("source").padding(.leading, Space.snug)
                Spacer()
            }
            .font(.system(size: Content.meta, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.bottom, 2)

            ForEach(Array(s.tools.enumerated()), id: \.element.id) { idx, t in
                HStack(spacing: 0) {
                    Text(t.name)
                        .font(.system(size: Content.body, design: Content.mono))
                        .frame(width: 260, alignment: .leading)
                    Text(t.origin.rawValue)
                        .font(.system(size: Content.meta))
                        .foregroundStyle(originColor(t.origin))
                        .frame(width: 100, alignment: .leading)
                    Text("\(t.approxTokens)")
                        .font(.system(size: Content.meta, design: Content.mono))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    Text(t.source ?? "")
                        .font(.system(size: Content.meta)).foregroundStyle(.tertiary)
                        .padding(.leading, Space.snug)
                    Spacer()
                }
                .padding(.vertical, 2)
                .background(idx % 2 == 1 ? Color.secondary.opacity(0.055) : .clear)
            }
        }
    }

    private func originColor(_ o: ToolOrigin) -> Color {
        switch o {
        case .builtIn:  return .secondary
        case .registry: return .blue
        case .topic:    return .yellow
        case .upstream: return .purple
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: Content.title, weight: .medium, design: Content.mono))
            Text(label).font(.system(size: Content.meta)).foregroundStyle(.secondary)
        }
    }

    private func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: Type.micro, design: Type.mono))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(c.opacity(0.15), in: Capsule())
            .foregroundStyle(c == .secondary ? Color.secondary : c)
    }

    private func load() {
        guard !loading else { return }
        loading = true
        let p = dbPath, doProbe = probe
        MCPView.work.async {
            let s = readMCPSurface(dbPath: p, probeUpstreams: doProbe)
            DispatchQueue.main.async { surface = s; loading = false }
        }
    }
}
