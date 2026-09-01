import Foundation

// Graph.swift — turning ONE session file into a knowledge graph.
//
// The shape is chosen from what this corpus actually contains, not from a generic
// node/edge template. A session transcript is already a list; drawing that list as a chain
// of dots teaches nothing you could not get by scrolling. The structure worth seeing is
// what a linear read HIDES: which beats reach for the same tool, and which touch the same
// file — because those are the edges that connect parts of a session that are far apart
// in time.
//
//   BEAT    one human turn plus every assistant/tool line until the next human turn.
//           This is the "beat" unit: the actual quantum of work in a session.
//   TOOL    a tool NAME (Bash, Read, Edit, WebFetch…). Shared by many beats.
//   TARGET  what a tool acted on — a path, a URL, a pattern.
//
//   beat ─┬─► tool ──► target
//         └─► next beat            (temporal spine)
//
// A target touched by beats 3 and 47 draws an edge across the whole session. That is the
// thing the transcript cannot show you, and the reason this view earns its GPU.

public enum GraphNodeKind: Int32 {
    case beat = 0
    case tool = 1
    case target = 2
    case session = 3
}

public struct GraphNode {
    public let id: Int
    public let kind: GraphNodeKind
    public let label: String
    /// Beats keep their byte offset so clicking a node can jump the tail to that line.
    public let byteOffset: Int
    /// How many times this node was referenced — drives node radius.
    public var weight: Int
}

public struct GraphEdge {
    public let a: Int
    public let b: Int
    /// Temporal spine edges are stiffer than reference edges, so the layout keeps the
    /// session's chronology legible instead of collapsing it into a hairball.
    public let spine: Bool
}

public struct SessionGraph {
    public var nodes: [GraphNode] = []
    public var edges: [GraphEdge] = []
    public var beats: Int = 0
    public var tools: Int = 0
    public var targets: Int = 0
    /// Targets referenced by more than one beat — the cross-links that justify the view.
    public var recurring: Int = 0
    public var truncated: Bool = false
}

/// Build the graph by streaming the file. Deliberately reuses `SessionTailer` rather than
/// adding a second parser: it already holds back partial lines, survives malformed ones,
/// and is the thing `tail --selftest` proves. A second reader here would be a second
/// source of truth about what a session file contains.
///
/// `maxBytes` caps the read — the p99 file is 39.6 MB and the graph of a whole 39 MB
/// session is not a thing anyone can look at. Truncation is REPORTED, never silent.
public func buildSessionGraph(path: String, maxBytes: Int = 8 << 20) -> SessionGraph {
    var g = SessionGraph()

    guard let st = statFile(path) else { return g }

    // Finding the line boundary to start on is not a formality here.
    // `alignedOffset` scans FORWARD for a newline and returns EOF when it finds none within
    // `scanLimit` (default 1 MB). Lines in this corpus routinely exceed 1 MB — a single
    // tool result can be tens of MB — so seeking 8 MB back from the end of a big file lands
    // mid-giant-line, gets pushed to EOF, and the graph comes back EMPTY while reporting
    // success. Observed exactly that: 70 nodes one run, 0 the next, from file growth alone.
    //
    // So: scan as far as we are already willing to read, and if even that finds no boundary
    // (the tail really is one enormous line), fall back to the start of the file rather than
    // returning nothing.
    var start = 0
    if st.size > maxBytes {
        let aligned = SessionTailer.alignedOffset(path: path,
                                                  approx: st.size - maxBytes,
                                                  scanLimit: maxBytes)
        start = aligned >= st.size ? 0 : aligned
    }
    g.truncated = start > 0

    let tailer = SessionTailer(path: path, offset: start)
    guard let read = try? tailer.read(maxBytes: maxBytes) else { return g }

    var toolIdx: [String: Int] = [:]
    var targetIdx: [String: Int] = [:]
    var targetBeats: [Int: Set<Int>] = [:]   // target node id -> beats that referenced it
    var currentBeat: Int? = nil
    var lastBeat: Int? = nil
    var beatNo = 0

    func addNode(_ kind: GraphNodeKind, _ label: String, _ offset: Int) -> Int {
        let id = g.nodes.count
        g.nodes.append(GraphNode(id: id, kind: kind, label: label, byteOffset: offset, weight: 1))
        return id
    }

    for e in read.events {
        guard e.parsedOK, let t = e.lineType else { continue }

        // A `user` line with real text opens a new beat. Tool RESULTS also arrive as
        // `user` lines with no text — those belong to the beat already open, so the
        // hasText check is what keeps one beat from shattering into dozens.
        if t == "user" && !e.text.isEmpty {
            beatNo += 1
            let label = e.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? e.text
            let id = addNode(.beat, String(label.prefix(64)), e.byteOffset)
            if let prev = lastBeat { g.edges.append(GraphEdge(a: prev, b: id, spine: true)) }
            lastBeat = id
            currentBeat = id
            g.beats += 1
            continue
        }

        guard let beat = currentBeat else { continue }

        // Tool calls hang off the open beat.
        for (name, target) in toolCalls(raw: e.raw) {
            let toolId: Int
            if let existing = toolIdx[name] {
                toolId = existing
                g.nodes[existing].weight += 1
            } else {
                toolId = addNode(.tool, name, e.byteOffset)
                toolIdx[name] = toolId
                g.tools += 1
            }
            g.edges.append(GraphEdge(a: beat, b: toolId, spine: false))

            guard let target, !target.isEmpty else { continue }
            let key = "\(name)\u{1}\(target)"
            let tId: Int
            if let existing = targetIdx[key] {
                tId = existing
                g.nodes[existing].weight += 1
            } else {
                tId = addNode(.target, String(target.prefix(64)), e.byteOffset)
                targetIdx[key] = tId
                g.targets += 1
            }
            g.edges.append(GraphEdge(a: toolId, b: tId, spine: false))
            targetBeats[tId, default: []].insert(beat)
        }
    }

    // The payoff edges: a target touched by more than one beat links those beats directly.
    for (tId, beats) in targetBeats where beats.count > 1 {
        g.recurring += 1
        let sorted = beats.sorted()
        for i in 0..<(sorted.count - 1) {
            g.edges.append(GraphEdge(a: sorted[i], b: sorted[i + 1], spine: false))
        }
        g.nodes[tId].weight += beats.count
    }

    return g
}

/// `session-viewer graph --path FILE` — the graph the GPU tab renders, as text. The same
/// `buildSessionGraph`; the only difference is that nothing is drawn. Exists for the
/// reason `tail`/`live`/`status` exist here: a GPU-only code path cannot be checked in CI,
/// on a headless box, or by anyone whose window is on another Space.
public func runGraphCLI(path: String, top: Int = 12, listNodes: Bool = false) {
    guard !path.isEmpty else {
        FileHandle.standardError.write("graph: --path FILE is required\n".data(using: .utf8)!)
        exit(2)
    }
    let t0 = Date()
    let g = buildSessionGraph(path: path)
    let ms = Date().timeIntervalSince(t0) * 1000

    print("file       \(path)")
    print("built in   \(String(format: "%.0f", ms)) ms\(g.truncated ? "  (tail only — file exceeded read cap)" : "")")
    print("nodes      \(g.nodes.count)  (\(g.beats) beats · \(g.tools) tools · \(g.targets) targets)")
    print("edges      \(g.edges.count)  (\(g.edges.filter { $0.spine }.count) spine)")
    print("revisited  \(g.recurring) targets touched by more than one beat")

    let heaviest = g.nodes.filter { $0.kind != .beat }.sorted { $0.weight > $1.weight }.prefix(top)
    if !heaviest.isEmpty {
        print("")
        print("  weight  kind    label")
        for n in heaviest {
            print("  " + padL(String(n.weight), 6) + "  " + padR("\(n.kind)", 6) + "  " + n.label)
        }
    }

    guard listNodes else { return }

    // Every node, grouped by kind. The BEAT labels are the part worth reading: they are the
    // human turns, in order, and reading them down the page is a table of contents for the
    // session that no other view in this app produces.
    print("")
    print("── BEATS (human turns, in order) ──")
    for n in g.nodes where n.kind == .beat {
        print("  #" + padR(String(n.id), 3) + " @" + padR(String(n.byteOffset), 10) + " " + n.label)
    }
    print("")
    print("── TOOLS ──")
    for n in g.nodes.filter({ $0.kind == .tool }).sorted(by: { $0.weight > $1.weight }) {
        print("  ×" + padR(String(n.weight), 4) + " " + n.label)
    }
    print("")
    print("── TARGETS ──")
    for n in g.nodes.filter({ $0.kind == .target }).sorted(by: { $0.weight > $1.weight }) {
        print("  ×" + padR(String(n.weight), 4) + " " + n.label)
    }
}

/// Every (toolName, target) pair on one line. Shares `LiveEventRow`'s field priority for
/// "what did this tool act on" so the graph and the tail agree about what a call touched.
func toolCalls(raw: String) -> [(String, String?)] {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = obj["message"] as? [String: Any],
          let blocks = message["content"] as? [[String: Any]]
    else { return [] }

    var out: [(String, String?)] = []
    for b in blocks where (b["type"] as? String) == "tool_use" {
        let name = (b["name"] as? String) ?? "tool"
        out.append((name, graphToolTarget(input: b["input"] as? [String: Any])))
    }
    return out
}

/// What a tool call ACTED ON, as a node identity.
///
/// This is not the same question `LiveEventRow.toolTarget` answers. That one produces a
/// human label for one row and truncating is harmless. Here the string becomes a NODE KEY,
/// so two calls that map to the same string become the same node — and a truncating prefix
/// is then actively wrong. Measured on this session: taking `command`'s first 72 chars
/// merged 86 distinct Bash invocations into one "target" (they all began with the same
/// `cd …/session-viewer`), which the graph would have drawn as a giant false hub. Node
/// identity needs a STABLE entity, not a readable prefix.
///
/// So: file paths and URLs are real entities and used directly. A shell command is not —
/// it is a one-off — and is reduced to the program it runs, which IS a stable entity and
/// is the thing worth linking beats through.
private func graphToolTarget(input: [String: Any]?) -> String? {
    guard let input else { return nil }

    // Real, stable entities first.
    for key in ["file_path", "path", "url", "notebook_path"] {
        if let v = input[key] as? String, !v.isEmpty { return v }
    }
    // A shell command: the binary, not the invocation.
    if let cmd = input["command"] as? String, !cmd.isEmpty {
        if let bin = shellProgram(cmd) { return "$ \(bin)" }
    }
    // A search: the pattern is the entity — the thing you were looking for.
    if let p = input["pattern"] as? String, !p.isEmpty { return String(p.prefix(48)) }
    if let q = input["query"] as? String, !q.isEmpty { return String(q.prefix(48)) }
    return nil
}

/// The program a shell command actually runs, skipping the parts that are scaffolding.
/// `cd X && rg foo` is an `rg` call; treating it as a `cd` call is how the false hub above
/// happened. Not a shell parser and does not try to be — it walks leading noise and takes
/// the first real word.
func shellProgram(_ command: String) -> String? {
    // Two classes of scaffolding, and conflating them was a real bug caught by
    // FreezeRegressionTests: `cd` CONSUMES ITS ARGUMENT. Skipping only the word `cd` left
    // the next word — the directory — to be read as the program, so
    // `cd /opt/…/session-viewer && swift build` reported `session-viewer` (the directory's
    // basename) instead of `swift`. It looked plausible in output precisely because the
    // directory was named after the binary.
    let skipWithArg: Set<String> = ["cd", "pushd", "export"]
    let skipBare: Set<String> = ["sudo", "env", "time", "nohup", "exec", "command",
                                 "then", "else", "do", "!", "{", "(", "builtin"]

    let segments = command
        .replacingOccurrences(of: "\n", with: " ; ")
        .components(separatedBy: CharacterSet(charactersIn: ";|&"))

    for seg in segments {
        let words = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var i = 0
        while i < words.count {
            let w = words[i]
            if w.isEmpty || w.hasPrefix("-") || w.hasPrefix("$") || w.hasPrefix(">") || w.hasPrefix("<") {
                i += 1; continue
            }
            if w.contains("=") && !w.hasPrefix("/") { i += 1; continue }   // VAR=value prefix
            if skipWithArg.contains(w) { i += 2; continue }                 // skip the word AND its target
            if skipBare.contains(w) { i += 1; continue }
            // A path invocation reduces to its basename: /usr/bin/sqlite3 -> sqlite3.
            let base = w.split(separator: "/").last.map(String.init) ?? w
            guard !base.isEmpty else { i += 1; continue }
            return base.count > 32 ? String(base.prefix(32)) : base
        }
    }
    return nil
}
