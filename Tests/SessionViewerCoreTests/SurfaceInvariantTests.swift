// SurfaceInvariantTests.swift — the drift class, held by a test instead of a factory.
//
// A 3-judge panel picked a Runtime Command Registry (3–1) to make CLI/MCP drift
// structurally impossible. The skeptic's counterpoint won the scheduling argument: every
// drift bug actually observed here was LIST-LEVEL — a usage string naming 5 of 17 verbs,
// an HTTP tools/list advertising 15 tools while stdio advertised 45, a flag in the
// allow-list that no dispatch ever read — and a test over the lists catches that whole
// class for a fraction of the registry's ~900 lines. The registry waits for the next
// genuinely new command; until then, these are the invariants.
//
// What CANNOT be asserted from here: that main.swift's dispatch switch actually handles
// every verb in CLI_VERBS. The switch lives in the executable target, which a testTarget
// cannot import (Package.swift documents this). That residue is exactly the argument the
// registry will use when its time comes.

import Testing
import Foundation
@testable import SessionViewerCore

@Suite("surface invariants · the lists that drifted before cannot drift silently again")
struct SurfaceInvariantTests {

    // MARK: CLI

    @Test("every verb is unique and carries a real summary")
    func verbsUniqueAndDescribed() {
        let names = CLI_VERBS.map(\.verb)
        #expect(Set(names).count == names.count, "duplicate verb in CLI_VERBS")
        for v in CLI_VERBS {
            #expect(!v.summary.isEmpty, "\(v.verb) has no summary")
            #expect(v.verb == v.verb.lowercased(), "\(v.verb): verbs are lowercase")
            #expect(!v.verb.contains(" "), "\(v.verb): verbs are single words")
        }
    }

    /// The exact failure of 2026-08-25: the usage string named five of seventeen verbs.
    /// Derived from the one table it can no longer under-report, but assert it anyway —
    /// a future hand-edit that hardcodes the string again should fail loudly here.
    @Test("the usage text names every verb")
    func usageNamesEveryVerb() {
        let usage = cliUsageText()
        for v in CLI_VERBS {
            #expect(usage.contains("  \(v.verb)"), "usage text is missing \(v.verb)")
        }
    }

    /// A flag in both sets would be parsed as valued on one path and boolean on another —
    /// same word, two arities, and which one wins depends on Set iteration order.
    @Test("valued and boolean flag sets are disjoint")
    func flagSetsDisjoint() {
        let overlap = CLI_VALUED_FLAGS.intersection(CLI_BOOLEAN_FLAGS)
        #expect(overlap.isEmpty, "flag(s) claimed by both sets: \(overlap.sorted())")
    }

    /// `--help` bypasses the allow-list by design; everything else in the usage footer's
    /// "common flags" line must actually be allowed, or the help teaches a flag that
    /// exits 2 — the inverse of the --self-test bug.
    @Test("flags the usage text advertises are in the allow-list")
    func advertisedFlagsAreAllowed() {
        for f in ["db", "root", "sort", "dir", "tier", "limit"] {
            #expect(CLI_VALUED_FLAGS.contains(f), "usage advertises --\(f) but the allow-list rejects it")
        }
    }

    // MARK: MCP — one derivation, both transports

    /// stdio's tools/list, HTTP's tools/list, describe_tool AND readMCPSurface all derive
    /// from `fullMCPToolList`. The earlier version of this comment named only the first
    /// three — and the fourth consumer promptly drifted, exactly as this suite's header
    /// predicts: the registry landed in fullMCPToolList but not in the surface, so
    /// `session-viewer tools` reported 14 tools while tools/list served 15, and the token
    /// budget (the number MCPSurface exists to compute) ran ~11% low. The test below the
    /// property tests pins the two counts together so a fifth consumer cannot repeat it.
    @Test("tool names are unique and spec-legal on the empty-db surface")
    func toolNamesUniqueAndLegal() throws {
        // A db path that exists but has no topics/upstreams: the built-in surface.
        let tmp = NSTemporaryDirectory() + "surface-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let tools = fullMCPToolList(dbPath: tmp)
        #expect(!tools.isEmpty)

        let names = tools.map(\.name)
        #expect(Set(names).count == names.count, "duplicate MCP tool name")

        // The MCP spec's charset: [A-Za-z0-9_.-], 1–128 chars.
        let legal = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        for n in names {
            #expect((1...128).contains(n.count), "\(n): length \(n.count) outside 1–128")
            #expect(n.allSatisfy { legal.contains($0) }, "\(n): illegal character for MCP")
        }
        for t in tools {
            #expect(!t.description.isEmpty, "\(t.name) has no description")
            #expect(t.schema["type"] as? String == "object", "\(t.name): schema root must be object")
        }
    }

    /// The drift that happened: introspection under-reporting the protocol. On an empty
    /// db topics and upstreams contribute nothing, so surface count == fullMCPToolList
    /// count isolates exactly the built-in + registry sources that diverged.
    @Test("the introspection surface reports every tool the protocol serves")
    func surfaceMatchesProtocol() throws {
        let tmp = NSTemporaryDirectory() + "surface-parity-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let surface = readMCPSurface(dbPath: tmp, probeUpstreams: false)
        let served = fullMCPToolList(dbPath: tmp)
        #expect(surface.tools.count == served.count,
                "surface \(surface.tools.count) vs tools/list \(served.count) — an introspection surface that under-reports the protocol is a lie about your own tool surface")
        #expect(surface.tools.map(\.name).sorted() == served.map(\.name).sorted())
        #expect(surface.tools.contains { $0.origin == .registry },
                "registry tools must carry their own origin — 'where do I edit this' answers 'a declaration', not 'MCP.swift'")
    }

    /// `dig_topic` reaches every topic without costing a slot, so it must always be in the
    /// built-in set — the promote/demote economy collapses without it.
    @Test("the stable dig_topic entry point is always exposed")
    func digTopicAlwaysPresent() {
        let names = mcpTools().map(\.name)
        #expect(names.contains("dig_topic"))
        #expect(names.contains("search_sessions"))
    }
}
