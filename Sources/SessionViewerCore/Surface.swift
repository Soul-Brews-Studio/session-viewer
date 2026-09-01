import Foundation

// Surface.swift — what this MCP server currently exposes, as data.
//
// `tools/list` answers "what can I call". It does not answer "where did each of these come
// from, what is it costing me, and what is wrapped behind it" — and those are the questions
// you actually have when a client is showing 98 tools from five servers and silently
// dropping some of them. This computes that picture ONCE and every surface renders it: the
// app's MCP tab, `session-viewer tools`, and GET /mcp/surface.
//
// It enumerates the same four sources `fullMCPToolList` concatenates — built-ins,
// registry commands, promoted topics, wrapped upstreams. If this view disagreed with
// `tools/list`, the view would be a lie — and it DID, for one commit: the registry landed
// in fullMCPToolList but not here, so every introspection surface under-reported by one
// tool while the protocol told the truth. The invariant test pins the two together now.

public enum ToolOrigin: String, Codable {
    case builtIn = "built-in"
    /// Declared once in CommandRegistry.swift, serving a CLI verb and this tool from the
    /// same declaration. Its own case rather than `built-in` because the origin is the
    /// answer to "where do I edit this" — and the answer is a declaration, not MCP.swift.
    case registry
    case topic
    case upstream
}

public struct SurfaceTool: Identifiable, Codable {
    public let name: String
    public let title: String
    public let origin: ToolOrigin
    /// For upstream tools, the upstream that owns it; for topics, the topic name.
    public let source: String?
    /// Rough prompt cost. Tool definitions sit in the model's context on every turn, and
    /// the commonly cited figure is ~150 tokens each — which is why a tool budget is a real
    /// budget and not bookkeeping.
    public let approxTokens: Int
    public var id: String { name }
}

public struct SurfaceUpstream: Codable, Identifiable {
    public let name: String
    public let transport: String
    public let era: String
    public let endpoint: String?
    public let reachable: Bool
    public let toolCount: Int
    /// False = wrapped for COMPOSITION only; its tools are not in our tools/list.
    public let exposed: Bool
    public let ms: Double
    public var id: String { name }
}

public struct MCPSurface: Codable {
    public var protocolVersions: [String] = MCP_MODERN_VERSIONS
    public var handshakeVersions: [String] = MCP_HANDSHAKE_VERSIONS
    public var tools: [SurfaceTool] = []
    public var upstreams: [SurfaceUpstream] = []
    public var topicsTotal: Int = 0
    public var topicsPromoted: Int = 0

    public var builtInCount: Int { tools.filter { $0.origin == .builtIn }.count }
    public var topicCount: Int { tools.filter { $0.origin == .topic }.count }
    public var upstreamCount: Int { tools.filter { $0.origin == .upstream }.count }
    public var approxTokens: Int { tools.reduce(0) { $0 + $1.approxTokens } }

    /// Where this server's tool count sits against the limits that actually bite.
    ///
    /// These are other people's numbers, not ours, and they are about the CLIENT's total
    /// across every connected server — so a green light here is necessary, not sufficient.
    public var budgetNote: String {
        let n = tools.count
        if n <= 20 { return "\(n) tools — comfortably inside every published limit." }
        if n <= 30 { return "\(n) tools — under the ~30-50 range where selection accuracy starts to degrade." }
        if n <= 40 { return "\(n) tools — at Cursor's hard cap of 40, where excess is silently dropped." }
        return "\(n) tools — past Cursor's 40-tool cap and into the range where selection accuracy is measurably worse."
    }
}

/// Compute the surface. `probeUpstreams` costs a process spawn or HTTP round trip per
/// upstream, so the UI can ask for the cheap version while it renders.
public func readMCPSurface(dbPath: String, probeUpstreams: Bool = true) -> MCPSurface {
    var s = MCPSurface()

    // ~150 tokens per tool is the figure cited across gateway write-ups; a long description
    // costs more, so estimate from the actual text rather than assuming a constant.
    func cost(_ t: MCPTool) -> Int {
        let text = t.name.count + t.title.count + t.description.count
        let schemaBytes = (try? JSONSerialization.data(withJSONObject: t.schema))?.count ?? 0
        let estimate = (text + schemaBytes) / 4
        return max(40, estimate)
    }

    for t in mcpTools() {
        s.tools.append(SurfaceTool(name: t.name, title: t.title, origin: .builtIn,
                                   source: nil, approxTokens: cost(t)))
    }
    // REGISTRY TOOLS. This loop enumerated only mcpTools() while tools/list moved to
    // fullMCPToolList — so `session-viewer tools`, GET /mcp/surface and the MCP tab all
    // under-reported the surface by every registry tool, and the token budget (the number
    // this whole type exists to compute) was ~11% low. The exact defect fullMCPToolList's
    // own doc-comment memorializes, reintroduced on the introspection path one commit
    // later. An invariant test now pins surface count == fullMCPToolList count.
    for t in registryTools() {
        s.tools.append(SurfaceTool(name: t.name, title: t.title, origin: .registry,
                                   source: "CommandRegistry.swift", approxTokens: cost(t)))
    }

    let topics = loadTopics(dbPath: dbPath)
    s.topicsTotal = topics.count
    s.topicsPromoted = topics.filter(\.promoted).count
    for t in topicTools(dbPath: dbPath) {
        s.tools.append(SurfaceTool(name: t.name, title: t.title, origin: .topic,
                                   source: String(t.name.dropFirst(4)), approxTokens: cost(t)))
    }

    for up in loadUpstreams(dbPath: dbPath) {
        let t0 = Date()
        var reachable = false
        var count = 0
        // Only probe for TOOLS if this upstream re-exposes them; a composition-only
        // upstream still gets its reachability shown, which is what you want to know.
        if probeUpstreams, up.isExposed {
            if let r = upstreamCall(up, method: "tools/list", params: nil),
               let tools = r["tools"] as? [[String: Any]] {
                reachable = true
                count = tools.count
                for t in tools {
                    guard let n = t["name"] as? String else { continue }
                    let name = "\(up.name)__\(n)"
                    s.tools.append(SurfaceTool(
                        name: name,
                        title: (t["title"] as? String) ?? n,
                        origin: .upstream, source: up.name,
                        approxTokens: max(40, ((t["description"] as? String)?.count ?? 0) / 4 + 20)))
                }
            }
        }
        s.upstreams.append(SurfaceUpstream(
            name: up.name, transport: up.transport, era: up.effectiveEra,
            endpoint: up.url ?? up.command, reachable: reachable, toolCount: count,
            exposed: up.isExposed, ms: Date().timeIntervalSince(t0) * 1000))
    }

    return s
}

/// `session-viewer tools` — the surface as text.
public func runSurfaceCLI(dbPath: String, probe: Bool) {
    let s = readMCPSurface(dbPath: dbPath, probeUpstreams: probe)
    print("protocol   modern \(s.protocolVersions.joined(separator: ", "))")
    print("           handshake \(s.handshakeVersions.joined(separator: ", "))")
    print("tools      \(s.tools.count) total — \(s.builtInCount) built-in · \(s.topicCount) promoted topics · \(s.upstreamCount) wrapped")
    print("topics     \(s.topicsTotal) saved, \(s.topicsPromoted) promoted (all reachable via dig_topic)")
    print("context    ~\(s.approxTokens.formatted()) tokens of tool definitions")
    print("budget     \(s.budgetNote)")

    if !s.upstreams.isEmpty {
        print("")
        print("  UPSTREAMS")
        for u in s.upstreams {
            let state = u.exposed
                ? (u.reachable ? "\(u.toolCount) tools" : (probe ? "UNREACHABLE" : "not probed"))
                : "compose-only"
            print("  " + padR(u.name, 14) + padR(u.transport, 7) + padR(u.era, 9)
                      + padL(String(format: "%.0f ms", u.ms), 9) + "  " + padR(state, 14)
                      + (u.endpoint.map { String($0.prefix(52)) } ?? ""))
        }
    }

    print("")
    print("  " + padR("tool", 34) + padR("origin", 11) + padL("~tok", 6) + "  source")
    for t in s.tools {
        print("  " + padR(String(t.name.prefix(32)), 34) + padR(t.origin.rawValue, 11)
                  + padL(String(t.approxTokens), 6) + "  " + (t.source ?? ""))
    }
}
