// AgentDisplayNameTests.swift — the agent name is recovered from the FILENAME, because
// there is no name field anywhere in a subagent transcript (verified across 193 files).
//
// The bug this guards against shipped and was visible in the fleet list as `gent-aomx-…`:
// the two tiers encode `agentId` DIFFERENTLY, and handling only one form ate the leading
// `a` of `agent-` as if it were the id prefix.
//
//   subagent        agentId = "agent-aomx-hermes-addon-2594fe35f9890054"   (Ingest keeps `agent-`)
//   workflow_agent  agentId = "acodex-freeze-f0999ee5173fe31d"             (Ingest strips it)
//
// Every id in the "real" cases below is a real filename from ~/.claude/projects on
// 2026-08-24, listed by `fd -t f 'agent-a.*\.jsonl$' ~/.claude/projects`.

import Testing
@testable import SessionViewerCore

@Suite("agentDisplayName — named agents")
struct AgentDisplayNameNamedTests {

    /// Both tiers, same agent-name shape. These pairs ARE the regression: before the fix,
    /// the `agent-` form returned "gent-…" instead of the name.
    @Test(arguments: [
        // (agentId as stored, expected display name)
        ("acodex-freeze-f0999ee5173fe31d", "codex-freeze"),
        ("agent-acodex-freeze-f0999ee5173fe31d", "codex-freeze"),
        ("aomx-hermes-addon-2594fe35f9890054", "omx-hermes-addon"),
        ("agent-aomx-hermes-addon-2594fe35f9890054", "omx-hermes-addon"),
        // real files on disk, 2026-08-24
        ("acat-artist-5a897953c7b59c51", "cat-artist"),
        ("agent-alearn-quickref-4c43901587731565", "learn-quickref"),
        ("agent-alearn-snippets-bb5b829bc5ded19a", "learn-snippets"),
        ("aseek-crossrepo-fb8c1efc61fce79f", "seek-crossrepo"),
        ("aseek-repo-git-fc4ba9759ddf08d5", "seek-repo-git"),
        // a NUMBER inside the name — the hex run must stop at the last `-`, not eat "-2"
        ("atimestamp-miner-2-1ad4e7b3a36d1cc3", "timestamp-miner-2"),
    ])
    func realNamedAgentsResolveToTheirName(_ id: String, _ expected: String) {
        #expect(agentDisplayName(agentId: id) == expected)
    }

    /// The specific shipped symptom, stated as its own test so a regression names itself.
    @Test func theGentPrefixBugStaysFixed() {
        let name = agentDisplayName(agentId: "agent-aomx-hermes-addon-2594fe35f9890054")
        #expect(name != "gent-aomx-hermes-addon")
        #expect(name == "omx-hermes-addon")
    }
}

@Suite("agentDisplayName — unnamed agents return nil")
struct AgentDisplayNameUnnamedTests {

    /// `a` + exactly 16 hex and nothing else: there is no name to show, so the caller
    /// falls back to the short id rather than printing an empty label.
    @Test(arguments: [
        "a57242de08014761b",
        "agent-a57242de08014761b",
        // real unnamed files on disk, 2026-08-24
        "a0dba268cf1507085",
        "agent-a0dba268cf1507085",
        "a0304d170f79ef932",
        "aaf22cd6f992e65f3",
        "aff0d0bed25090515",
    ])
    func unnamedAgentsAreNil(_ id: String) {
        #expect(agentDisplayName(agentId: id) == nil)
    }

    /// `displayLabel` is where that nil is absorbed — the row must never be blank.
    @Test func theRowLabelFallsBackToAnIdRatherThanEmpty() {
        let unnamed = session(uuid: "cafd5a9d-e3db-492a-a8fd-56db4fb438fa", tier: "subagent",
                              agentId: "a0dba268cf1507085", mtime: 1_756_000_000)
        #expect(unnamed.hasAgentName == false)
        #expect(unnamed.displayLabel == "a0dba268cf")    // first 10 chars of the id
        #expect(!unnamed.displayLabel.isEmpty)

        let named = session(uuid: "cafd5a9d-e3db-492a-a8fd-56db4fb438fa", tier: "subagent",
                            agentId: "acat-artist-5a897953c7b59c51", mtime: 1_756_000_000)
        #expect(named.hasAgentName)
        #expect(named.displayLabel == "cat-artist")

        // No agentId at all (a tier-1 session row) → the session uuid's first 8.
        let parent = session(uuid: "cafd5a9d-e3db-492a-a8fd-56db4fb438fa", tier: "session",
                             mtime: 1_756_000_000)
        #expect(parent.displayLabel == "cafd5a9d")
    }
}

@Suite("agentDisplayName — malformed input is nil, never a crash")
struct AgentDisplayNameMalformedTests {

    @Test func nilInIsNilOut() {
        #expect(agentDisplayName(agentId: nil) == nil)
    }

    /// Each of these fails a different guard: no `a` prefix, nothing after the prefix,
    /// too few hex digits, or a tail that is not hex at all.
    @Test(arguments: [
        "",                                 // empty
        "a",                                // prefix only, nothing after
        "agent-",                           // prefix stripped to empty
        "agent-a",                          // ditto, one char
        "-",                                // no `a`
        "a-",                               // `a` then a dash, no hex run
        "banana",                           // no hex tail
        "codex-freeze-f0999ee5173fe31d",    // real hex tail but no leading `a`
        "a1234567890abcde",                 // 15 hex — one short of the 16 minimum
        "acodex-freeze-nothexatall",        // tail is not hex
        "aNAME-F0999EE5173FE31D",           // UPPERCASE hex — the regex is [0-9a-f] only
        "agent-agent-agent-",               // repeated prefixes
        "🙂",                                // non-ASCII, no prefix
        "a🙂-f0999ee5173fe31d",             // emoji inside the name region
    ])
    func malformedInputsReturnNilWithoutCrashing(_ id: String) {
        // The emoji case is the one that would resolve to a name; every other row is nil.
        let out = agentDisplayName(agentId: id)
        if id == "a🙂-f0999ee5173fe31d" {
            #expect(out == "🙂", "a multi-byte name must survive the byte-agnostic slicing")
        } else {
            #expect(out == nil, "expected nil for \(id.debugDescription), got \(String(describing: out))")
        }
    }

    /// Pathological lengths: dropFirst/range-of are index-safe, but this proves it rather
    /// than assuming it, and it is the shape a truncated filename would take.
    @Test func extremeInputsDoNotTrap() {
        #expect(agentDisplayName(agentId: String(repeating: "a", count: 100_000)) == nil)
        #expect(agentDisplayName(agentId: String(repeating: "-", count: 5_000)) == nil)
        #expect(agentDisplayName(agentId: String(repeating: "f", count: 64)) == nil)        // no `a` prefix
        #expect(agentDisplayName(agentId: "a" + String(repeating: "f", count: 64)) == nil)  // all hex ⇒ empty name
    }

    /// A name made only of hex characters still resolves — the run has to stop at the `-`,
    /// not swallow the name because it happens to be spellable in hex.
    @Test func aHexLookingNameStillResolves() {
        #expect(agentDisplayName(agentId: "adeadbeef-f0999ee5173fe31d") == "deadbeef")
        #expect(agentDisplayName(agentId: "agent-adecaf-2594fe35f9890054") == "decaf")
    }
}
