// CLISurface.swift — the CLI's verb table and flag allow-lists, IN THE LIBRARY.
//
// These lived in main.swift, and Package.swift's own comment says why that was a problem:
// a SwiftPM executableTarget cannot be imported by a testTarget, so anything defined there
// is permanently untestable. That is how the usage string advertised five of seventeen
// verbs for weeks — the two lists could drift and nothing could assert they had not.
//
// Moving them here is the cheap half of the command-factory verdict: the 3-judge panel
// chose a Runtime Registry, and the skeptic's counterpoint stood — every motivating bug
// was list-level drift that an invariant test catches for a fraction of the cost. The
// registry waits for the next genuinely new command; SurfaceInvariantTests holds the line
// until then.

import Foundation

/// Every subcommand, with a one-line summary — the single list `--help` and the
/// unknown-subcommand error both print. main.swift's dispatch switch must cover exactly
/// these; the invariant test asserts the properties that CAN drift silently.
public let CLI_VERBS: [(verb: String, summary: String)] = [
    ("import",    "index new + changed transcripts into the db (skips unchanged)"),
    ("sync",      "registry import over the known roots — --corpus all|local|remote, --since 7d"),
    ("diff",      "show what an import WOULD do — nothing is written"),
    ("codex",     "index ~/.codex/sessions rollouts alongside the Claude corpus"),
    ("scan",      "discover transcript files on disk without touching the db"),
    ("list",      "list indexed sessions — --sort, --dir, --tier, --limit"),
    ("status",    "index summary: per-tier and per-source counts, date range"),
    ("search",    "full-text search the indexed conversational content"),
    ("searches",  "the search log — what was queried, and what it returned"),
    ("graph",     "session graph as nodes and edges"),
    ("embed",     "build or dump the on-device semantic index"),
    ("eval",      "measure retrieval — keyword vs semantic, against labelled queries"),
    ("live",      "who is writing RIGHT NOW, machine-wide"),
    ("tail",      "follow one transcript file as it is written"),
    ("serve",     "WebSocket + HTTP + MCP over Streamable HTTP on one port"),
    ("mcp",       "MCP server on stdio (a client normally launches this, not you)"),
    ("tools",     "this server's MCP tool surface, and what it costs in context"),
    ("upstreams", "wrapped MCP servers — reachability, era, tool counts"),
]

/// Flags that take a value. One allow-list for the whole CLI: a flag valid nowhere is
/// always a mistake, and a flag valid for another subcommand is a mistake worth naming.
///
/// REGISTRY PARAMS ARE UNIONED IN AUTOMATICALLY — this is the mid-migration bridge hazard
/// both losing designs warned about, made structural instead of policed by a test:
/// declaring a parameter on a RegistryCommand IS what admits its flag, so a new `--since`
/// cannot be rejected by a list nobody remembered to update. (It was, on first run:
/// `list --since 3h` → "unknown flag: --since". This union is that failure's tombstone.)
public let CLI_VALUED_FLAGS: Set<String> = {
    var base: Set<String> = [
        "db", "root", "path", "attach", "dir", "sort", "tier", "web", "port", "window",
        "limit", "for", "interval", "repeat", "top", "query", "out", "count", "file",
        "chunk-words", "chunk-stride", "rewind", "rescan", "model", "in", "codex-root", "classes",
    ]
    for cmd in registryCommands() {
        for p in cmd.params { base.insert(p.name) }
    }
    return base
}()

/// Boolean flags — present or absent, no value.
public let CLI_BOOLEAN_FLAGS: Set<String> = [
    "force", "generate", "run-model", "nodes", "verbose", "selftest", "raw", "once", "no-db",
    "dump", "load", "no-probe", "import",
]

/// The `--help` / unknown-subcommand text, built from the one verb table.
public func cliUsageText() -> String {
    let width = CLI_VERBS.map(\.verb.count).max() ?? 10
    var out = "usage: session-viewer <subcommand> [flags]\n"
    out += "       session-viewer [--db PATH]        # no subcommand: open the app window\n\n"
    for v in CLI_VERBS {
        out += "  " + v.verb.padding(toLength: width + 2, withPad: " ", startingAt: 0)
             + v.summary + "\n"
    }
    out += "\ncommon flags: --db PATH  --root PATH  --sort \(SessionSort.usage)"
         + "  --dir \(SortDirection.usage)\n"
         + "              --tier all|session|subagent|workflow_agent  --limit N\n"
    out += "\nrun `session-viewer <subcommand> --help` is NOT supported; flags are listed on error.\n"
    return out
}
