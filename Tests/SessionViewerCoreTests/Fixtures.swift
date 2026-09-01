// Fixtures.swift — BLOCK-level fixtures and value-type builders.
//
// DIVISION OF LABOUR with CorpusFixtures.swift. That file's `enum Corpus` holds WHOLE
// real lines, verbatim, and is the right thing to reach for when a test wants "what the
// tailer actually read off disk". This file holds the two things a whole line cannot give
// you:
//
//   1. `Fx` — individual content BLOCKS plus envelope builders, so a test can compose a
//      line carrying two blocks at once (`thinking` + `tool_use` in one assistant turn is
//      the normal shape, and `summarizeBlocks` joins them — a property no single-block
//      fixture can exercise).
//   2. `row(…)` / `session(…)` — builders for `LiveEventRow` and `LiveSession`, the value
//      types `foldStateRuns` and `groupLiveSessions` take. Those functions never see JSON.
//
// The blocks below are byte-for-byte from ~/.claude/projects on 2026-08-24; the assistant
// and user ENVELOPES around them are the real line shape with only `message.usage` — a
// ~2 KB token-accounting blob nothing under test reads — removed.

import Foundation
@testable import SessionViewerCore

enum Fx {

    // MARK: - Content blocks (verbatim)

    /// `thinking` with an EMPTY string and only a signature. This is the MEASURED normal
    /// case, not an edge case: content is stripped at write time, so the honest render is a
    /// bare "thinking…" with no preview. Signature truncated (it is opaque base64 and
    /// nothing reads it); the `thinking:""` that the assertion turns on is untouched.
    static let thinkingEmpty = #"{"type":"thinking","thinking":"","signature":"Ep0ECqgBCBEYAipAZwfLY0tG7OjVm0mnS1QXe0zn2vL1p/CKMnfXVqqNFQxSkQiIapPSaGPKIUVE3xHzqa9ykF4enweZZynBgI1i4DIPY2xhdWRlLXNvbm5ldC01OABCCHRoaW5raW5n"}"#

    /// 73 characters of `command` — one over `toolTarget`'s 72-char cap, so this fixture is
    /// also the truncation boundary.
    static let toolUseBash = #"{"type":"tool_use","id":"toolu_01PnsRzkhn8t7ELhrXRcaUyh","name":"Bash","input":{"command":"find /workspace/fixture12/thClaws/thClaws -type f -name \"*.md\" | head -20"},"caller":{"type":"direct"}}"#

    static let toolUseRead = #"{"type":"tool_use","id":"toolu_019jiuHP3mAKUZHcTTYXX6cB","name":"Read","input":{"file_path":"/workspace/thClaws/thClaws"},"caller":{"type":"direct"}}"#

    /// `input` holds replace_all / file_path / old_string / new_string. Only `file_path` is
    /// in `toolTarget`'s key list, and it must win over the much longer string fields.
    static let toolUseEdit = #"{"type":"tool_use","id":"toolu_01TXwrrEiK9WpHmqHZe8KQa9","name":"Edit","input":{"replace_all":false,"file_path":"/workspace/digger-oracle/LiveView.swift","old_string":"        let steps = Type.steps","new_string":"        let steps = Content.steps"},"caller":{"type":"direct"}}"#

    /// A real tool_use whose `input` has NONE of the eight keys `toolTarget` looks for.
    static let toolUseSkillNoTarget = #"{"type":"tool_use","id":"toolu_017Am8hxnnRKvLg29swjT4GN","name":"Skill","input":{"skill":"rrr"},"caller":{"type":"direct"}}"#

    /// A real tool_use with a literally EMPTY input object.
    static let toolUseEmptyInput = #"{"type":"tool_use","id":"toolu_01FMFWB6rAoD4vWGMQsQfd5d","name":"EnterPlanMode","input":{},"caller":{"type":"direct"}}"#

    static let toolResultOK = #"{"tool_use_id":"toolu_01LjTiLemGcGU6uEhxJkqedk","type":"tool_result","content":"/workspace/thClaws/thClaws/crates/core/Cargo.toml","is_error":false}"#

    static let toolResultError = #"{"type":"tool_result","content":"EISDIR: illegal operation on a directory, read '/workspace/thClaws/thClaws'","is_error":true,"tool_use_id":"toolu_019jiuHP3mAKUZHcTTYXX6cB"}"#

    /// No `is_error` key at all — a real and common shape, and the one an invented fixture
    /// would never have produced.
    static let toolResultNoErrorKey = #"{"type":"tool_result","tool_use_id":"toolu_01CRVKZi5ksh5xHtAVzjRj96","content":[{"type":"text","text":"Fork started — processing in background"}]}"#

    /// From …/ai-gateway-router-oracle/143d0350-…/subagents/agent-a052c19756e417196.jsonl
    static let textBlock = #"{"type":"text","text":"wrote 02-chasing-the-websocket.md — 1487 words"}"#

    // MARK: - Envelopes
    //
    // The real assistant / user line shape around one or more content blocks. Verbatim
    // field names, order and values from
    // …/laris-co/neo-oracle/cafd5a9d-…/subagents/agent-acat-artist-5a897953c7b59c51.jsonl.

    static func assistantLine(_ blocks: String...) -> String {
        #"{"parentUuid":"278b2cf2-f927-4efd-a652-2d09eeb63f21","isSidechain":true,"agentId":"acat-artist-5a897953c7b59c51","message":{"model":"claude-sonnet-5","id":"msg_011CeMMMMrEheixcYVoy9RCC","type":"message","role":"assistant","content":["#
        + blocks.joined(separator: ",")
        + #"],"stop_reason":"tool_use","stop_sequence":null},"uuid":"32719e91-e6f7-4dd9-8cbd-fdb023da02ec","timestamp":"2026-08-24T09:39:44.101Z","type":"assistant","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main"}"#
    }

    static func userLine(_ blocks: String...) -> String {
        #"{"parentUuid":"32719e91-e6f7-4dd9-8cbd-fdb023da02ec","isSidechain":true,"promptId":"ded4fe75-67f3-4c06-82df-f0851364659d","agentId":"acat-artist-5a897953c7b59c51","type":"user","message":{"role":"user","content":["#
        + blocks.joined(separator: ",")
        + #"]},"uuid":"a46f2c42-91bb-466d-9a0e-b09c567271b1","timestamp":"2026-08-24T09:39:46.555Z","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main"}"#
    }
}

// MARK: - Builders for the value types under test

/// A `LiveEventRow` over a `TailEvent`. `raw` defaults to a line with no `message` key so
/// `summarizeBlocks` returns nil and the row's identity comes purely from `lineType` —
/// which is the only thing `foldStateRuns` keys on.
func row(id: Int, type: String?, ts: String? = nil, text: String = "",
         parsedOK: Bool = true, raw: String = "{}") -> LiveEventRow {
    LiveEventRow(id: id, event: TailEvent(
        path: "/Users/example/.claude/projects/-p/s.jsonl",
        byteOffset: id * 100, byteLength: raw.utf8.count,
        parsedOK: parsedOK, lineType: type, timestamp: ts, text: text, raw: raw))
}

/// A `LiveSession` with the fields the grouping actually reads. `age` defaults well inside
/// the "hot" bucket so heat never silently changes an ordering assertion.
func session(uuid: String, tier: String, agentId: String? = nil,
             project: String = "/workspace/laris-co/neo-oracle",
             mtime: Int, size: Int = 1_000, age: Int = 5,
             workflowRunId: String? = nil, path: String? = nil) -> LiveSession {
    LiveSession(
        path: path ?? "/Users/example/.claude/projects/-p/\(uuid)/\(agentId ?? "self").jsonl",
        project: project, tier: tier, sessionUUID: uuid, agentId: agentId,
        workflowRunId: workflowRunId, size: size, mtime: mtime, secondsSinceWrite: age)
}
