// CorpusFixtures.swift — REAL lines lifted verbatim from ~/.claude/projects on m5,
// 2026-08-24. Not invented shapes.
//
// WHY VERBATIM MATTERS HERE. Every bug these suites regress was a bug about the SHAPE of
// a real line, not about arithmetic: `thinking` blocks store an EMPTY string next to an
// opaque `signature`; a `tool_result` sometimes has no `is_error` key at all; a subagent
// `agentId` keeps its `agent-` prefix while a workflow agent's does not. A hand-written
// fixture would have quietly agreed with whatever the code already did.
//
// PROVENANCE — every line below came out of one of these files:
//   …/-opt-Code-github-com-laris-co-neo-oracle/cafd5a9d-e3db-492a-a8fd-56db4fb438fa.jsonl
//   …/cafd5a9d-…/subagents/agent-acat-artist-5a897953c7b59c51.jsonl
//   …/cafd5a9d-…/subagents/agent-alearn-snippets-bb5b829bc5ded19a.jsonl
//   …/cafd5a9d-…/subagents/workflows/wf_8b429bba-965/agent-a2ebf25d653e7b4cc.jsonl
//   …/-opt-Code-github-com-laris-co-neo-oracle/9cda6f37-b582-4d73-ae6a-d61ab339cda0.jsonl
//
// TWO EDITS, both declared, neither touching a field any code under test reads:
//   1. `message.usage` / `message.diagnostics` removed — a ~1.5 KB token-accounting blob.
//   2. the `thinking` block's base64 `signature` and one traceback string are truncated.
// Everything else — key order, nesting, `\u001b` escapes, Thai/ψ characters — is as
// written to disk. Raw string literals (#"…"#) are used so the JSON's own quotes and
// backslash escapes survive into the parser untouched.

import Foundation

enum Corpus {

    // MARK: - Assistant lines carrying one content block

    /// `tool_use` · Bash with a SHORT command, so the un-truncated path is exercised.
    /// Real: session cafd5a9d…, 2026-08-18T04:48:18.837Z. Note the ψ in the command —
    /// this corpus is not ASCII and the summarizer must not assume it is.
    static let toolUseBashShort = #"{"parentUuid":"689cf264-a8b6-43cd-8027-1c5eb24df488","isSidechain":false,"message":{"model":"claude-sonnet-5","id":"msg_011Ce9cGmMfVr27rYeHe8WKn","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_015mkfvfw9iNFpyGrvCao5FT","name":"Bash","input":{"command":"ls -la ψ 2>&1 | head -3","description":"Check if psi is a symlink"},"caller":{"type":"direct"}}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null},"requestId":"req_011Ce9cGkVaEcSkuF7yJB7ht","attributionSkill":"recap","type":"assistant","uuid":"816616b4-7707-4631-a111-6469fd7dd495","timestamp":"2026-08-18T04:48:18.837Z","effort":"high","session_id":"9cda6f37-b582-4d73-ae6a-d61ab339cda0","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.239","gitBranch":"main","sessionKind":"bg"}"#

    /// `tool_use` · Bash with a 174-character command — the truncation path.
    /// Real: agent-acat-artist-5a897953c7b59c51, 2026-08-24T09:39:45Z.
    static let toolUseBashLong = #"{"parentUuid":"278b2cf2-f927-4efd-a652-2d09eeb63f21","isSidechain":true,"agentId":"acat-artist-5a897953c7b59c51","message":{"model":"claude-sonnet-5","id":"msg_011CeMMMMrEheixcYVoy9RCC","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_019fFQPvYCdPDPiv3kBNK4kM","name":"Bash","input":{"command":"mkdir -p /Users/example/.claude/jobs/cafd5a9d/tmp/cats && ls -la /Users/example/.claude/jobs/cafd5a9d/tmp/cats && /opt/homebrew/bin/python3 -c \"import PIL; print(PIL.__version__)\"","description":"Ensure output dir exists and check Pillow version"},"caller":{"type":"direct"}}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null},"type":"assistant","uuid":"32719e91-e6f7-4dd9-8cbd-fdb023da02ec","timestamp":"2026-08-24T09:39:45.900Z","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main"}"#

    /// `tool_use` · Read — proves `file_path` is picked up when there is no `command`.
    /// Real: agent-alearn-snippets-bb5b829bc5ded19a, 2026-08-24T06:43:47.831Z.
    static let toolUseRead = #"{"parentUuid":"6e9675cd-a77a-4547-8d50-7dacc67686b0","isSidechain":true,"agentId":"alearn-snippets-bb5b829bc5ded19a","message":{"model":"claude-haiku-4-5-20251001","id":"msg_011CeM7w7ikX9SQR7Ms5WZ7R","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_019Dy9Fobtw3U7uCwyAfCrRs","name":"Read","input":{"file_path":"/workspace/laris-co/Nat-s-Agents/package.json"},"caller":{"type":"direct"}}],"stop_reason":null,"stop_sequence":null,"stop_details":null},"requestId":"req_011CeM7w72L6s3CekaFGks1g","type":"assistant","uuid":"b38620a9-447f-4232-bdbe-862403f05f80","timestamp":"2026-08-24T06:43:47.831Z","sessionKind":"bg","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main"}"#

    /// `tool_use` · WebFetch — `url` wins, and `prompt` (present, and far longer) does not.
    /// This is the exact line behind TODO.md's "Verified live: WebFetch · https://…/INDANCSClient".
    /// Real: workflows/wf_8b429bba-965/agent-a2ebf25d653e7b4cc, 2026-08-24T15:19:13.803Z.
    static let toolUseWebFetch = #"{"parentUuid":"c8411d21-f92f-48b4-8fba-4d61a975fc09","isSidechain":true,"agentId":"a2ebf25d653e7b4cc","message":{"model":"claude-opus-5","id":"msg_011CeMoEbHTWtxCWG68mt2cP","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01YDoFfkYGk1zmePtj1gGtMF","name":"WebFetch","input":{"url":"https://github.com/indragiek/INDANCSClient","prompt":"Extract the full README. Specifically: what does it say about consuming ANCS on OS X / macOS with CoreBluetooth? Is there a limitation? What is INDANCSServer vs INDANCSClient? What role does each take (central/peripheral)? Any mention of advertising the ANCS solicited service UUID, pairing, bonding?"},"caller":{"type":"direct"}}],"stop_reason":null,"stop_sequence":null,"stop_details":null},"requestId":"req_011CeMoEa6XFPfzhidYRTE2e","attributionAgent":"workflow-subagent","type":"assistant","uuid":"c837301e-9577-423c-af7e-e6b77b9368ea","timestamp":"2026-08-24T15:19:13.803Z","effort":"xhigh","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main","slug":"lively-launching-creek"}"#

    /// `tool_use` · ToolSearch — `query` is the 6th key in the preference list, reached
    /// only because none of command/file_path/pattern/path/url is present.
    /// Real: session cafd5a9d…, 2026-08-24T12:54:52.309Z.
    static let toolUseToolSearch = #"{"parentUuid":"7ab09e38-0605-4e61-b2fe-1b0e95435f56","isSidechain":false,"message":{"model":"claude-opus-5","id":"msg_011CeMcDJBzixmLMemFwAXQs","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01Pnqbom8AAvgLrR8MniWwnH","name":"ToolSearch","input":{"query":"select:WebSearch,WebFetch","max_results":2},"caller":{"type":"direct"}}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null},"requestId":"req_011CeMcD9kjpAr7rKYpJMmYD","type":"assistant","uuid":"87622e37-cdad-4849-95d8-d2a5daa3bdca","timestamp":"2026-08-24T12:54:52.309Z","effort":"xhigh","session_id":"9cda6f37-b582-4d73-ae6a-d61ab339cda0","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main","slug":"lively-launching-creek"}"#

    /// `tool_use` · ListAgents with a literally EMPTY input object. `{}` is not nil, so the
    /// "no input" guard does not fire — the key loop has to come up empty on its own.
    /// Real: session cafd5a9d…, 2026-08-22T12:06:33.065Z.
    static let toolUseListAgents = #"{"parentUuid":"d8b4e6e2-7f63-4d16-87ca-4213a9914360","isSidechain":false,"message":{"model":"claude-sonnet-5","id":"msg_011CeHkvH5akLuke1X1qQPpY","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01EGSCbsUADtauAEuman5WX9","name":"ListAgents","input":{},"caller":{"type":"direct"}}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null},"requestId":"req_011CeHkvAGZ2GuuEkP1z2qcM","type":"assistant","uuid":"9dbe0cfc-b426-40fa-b748-57cba3b255ea","timestamp":"2026-08-22T12:06:33.065Z","effort":"high","session_id":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","sessionKind":"bg","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.239","gitBranch":"main"}"#

    /// `tool_use` · Skill with a NON-EMPTY input none of whose keys is recognized
    /// (`skill`). Different from ListAgents: there IS input, it just says nothing the
    /// renderer can use. The honest output is the bare tool name.
    /// Real: session 9cda6f37…, 2026-08-20T06:12:10.337Z.
    static let toolUseSkill = #"{"parentUuid":"53e6d1e2-b1ce-4039-be59-5699c309391d","isSidechain":false,"message":{"model":"claude-sonnet-5","id":"msg_011CeDWHcXwMmVwjc1X6iYSP","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_0182HonwMYRtT6XJR9e48D8K","name":"Skill","input":{"skill":"rrr"},"caller":{"type":"direct"}}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null},"requestId":"req_011CeDWHZxuhAHf4zsFLg4SQ","type":"assistant","uuid":"9ab726a2-964e-4287-9754-6fd0e4c52171","timestamp":"2026-08-20T06:12:10.337Z","effort":"high","session_id":"9cda6f37-b582-4d73-ae6a-d61ab339cda0","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"9cda6f37-b582-4d73-ae6a-d61ab339cda0","version":"2.1.237","gitBranch":"main"}"#

    /// `thinking` with an EMPTY string and an opaque `signature`.
    ///
    /// MEASURED corpus-wide on m5, 2026-08-24: **22093 of 22093** stored `thinking` blocks
    /// have `"thinking":""`. Not "usually empty" — no counter-example exists in 1000+
    /// files. The reasoning is stripped at write time; the signature is not the reasoning.
    /// Real: agent-acat-artist-…, 2026-08-24T09:39:45.247Z. Signature truncated (opaque).
    static let thinkingEmpty = #"{"parentUuid":"776ec3c0-9467-4eaf-8a1d-8365caaa321c","isSidechain":true,"agentId":"acat-artist-5a897953c7b59c51","message":{"model":"claude-sonnet-5","id":"msg_011CeMMMMrEheixcYVoy9RCC","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"Ep0ECqgBCBEYAipAZwfLY0tG7OjVm0mnS1QXe0zn2vL1p/CKMnfXVqqNFQxSkQiIapPSaGPKIUVE3xHzqa9ykF4enweZZynBgI1i4DIPY2xhdWRlLXNvbm5ldC01OABCCHRoaW5raW5n"}],"stop_reason":null,"stop_sequence":null,"stop_details":null},"requestId":"req_011CeMMMH9xfLRmvPdaVs26X","type":"assistant","uuid":"278b2cf2-f927-4efd-a652-2d09eeb63f21","timestamp":"2026-08-24T09:39:45.247Z","effort":"high","sessionKind":"bg","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main","slug":"lively-launching-creek"}"#

    // MARK: - tool_result lines (these arrive as type "user", not "assistant")

    /// `is_error: false`. Real: agent-acat-artist-…, 2026-08-24T09:39:46.555Z.
    static let toolResultOK = #"{"parentUuid":"32719e91-e6f7-4dd9-8cbd-fdb023da02ec","isSidechain":true,"promptId":"ded4fe75-67f3-4c06-82df-f0851364659d","agentId":"acat-artist-5a897953c7b59c51","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_019fFQPvYCdPDPiv3kBNK4kM","type":"tool_result","content":"total 0\ndrwxr-xr-x@  2 local  staff   64 Aug 24 16:39 .\ndrwxr-xr-x@ 16 local  staff  512 Aug 24 16:39 ..\n12.2.0","is_error":false}]},"uuid":"a46f2c42-91bb-466d-9a0e-b09c567271b1","timestamp":"2026-08-24T09:39:46.555Z","sourceToolAssistantUUID":"32719e91-e6f7-4dd9-8cbd-fdb023da02ec","sessionKind":"bg","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main","slug":"lively-launching-creek"}"#

    /// `is_error: true`, and note it is the SECOND key after `content` — key order is not
    /// stable across lines in this corpus, which is one reason parsing is dictionary-based.
    /// The `\u001b[35m…` sequences are the real ANSI colour codes as stored.
    /// Real: agent-acat-artist-…, 2026-08-24T09:42:16.301Z. Traceback body truncated;
    /// `toolUseResult` (a duplicate of the same text) removed.
    static let toolResultError = #"{"parentUuid":"bfc99f70-de90-4a69-bd34-f3b0de736d40","isSidechain":true,"promptId":"ded4fe75-67f3-4c06-82df-f0851364659d","agentId":"acat-artist-5a897953c7b59c51","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Exit code 1\nTraceback (most recent call last):\n  File \u001b[35m\"/Users/example/.claude/jobs/cafd5a9d/tmp/cats/make_cats.py\"\u001b[0m, line \u001b[35m215\u001b[0m, in \u001b[35mdraw_cat\u001b[0m\n\u001b[1;35mKeyError\u001b[0m: \u001b[35m'inner_ear_color'\u001b[0m","is_error":true,"tool_use_id":"toolu_01GqH3fwwFahFo1nCgh5VX7S"}]},"uuid":"251af0bc-b893-49c7-ab53-4923880e9314","timestamp":"2026-08-24T09:42:16.301Z","sourceToolAssistantUUID":"bfc99f70-de90-4a69-bd34-f3b0de736d40","sessionKind":"bg","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main","slug":"lively-launching-creek"}"#

    /// A `tool_result` with **no `is_error` key at all**, and whose `content` is a nested
    /// array of blocks rather than a string. Both shapes are real and both would break a
    /// parser that assumed `is_error` is always present or `content` is always a String.
    /// Real: session cafd5a9d…, 2026-08-24T12:54:52.311Z (the reply to toolUseToolSearch).
    static let toolResultNoIsErrorKey = #"{"parentUuid":"87622e37-cdad-4849-95d8-d2a5daa3bdca","isSidechain":false,"promptId":"85c43195-ab83-4e30-9484-cff56420fe31","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01Pnqbom8AAvgLrR8MniWwnH","content":[{"type":"tool_reference","tool_name":"WebSearch"},{"type":"tool_reference","tool_name":"WebFetch"}]}]},"uuid":"eb72f55d-beb7-4e57-b1f5-3612865e31af","timestamp":"2026-08-24T12:54:52.311Z","sourceToolAssistantUUID":"87622e37-cdad-4849-95d8-d2a5daa3bdca","session_id":"9cda6f37-b582-4d73-ae6a-d61ab339cda0","userType":"external","entrypoint":"cli","cwd":"/workspace/laris-co/neo-oracle","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa","version":"2.1.241","gitBranch":"main","slug":"lively-launching-creek"}"#

    // MARK: - State lines (SPEC.md's "~14 types, only half conversational")

    /// These four are verbatim whole lines — they really are this short, and they really
    /// do carry NO `timestamp` field, which is why a folded run's `lastTs` is usually nil.
    static let stateMode           = #"{"type":"mode","mode":"normal","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa"}"#
    static let statePermissionMode = #"{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa"}"#
    static let stateAtisLatch      = #"{"type":"atis-latch","atis":"","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa"}"#
    static let stateLastPrompt     = #"{"type":"last-prompt","lastPrompt":"we have many neo memory in many session in different user! so now it want you to check gh command help me organize make this all private to laris-co our orgs","leafUuid":"07816f75-e1bf-4f24-a48e-ee2386842d7a","sessionId":"cafd5a9d-e3db-492a-a8fd-56db4fb438fa"}"#

    /// Not JSON at all. Taken from `runTailSelfTest` (Tail.swift), which uses exactly this
    /// string to stand in for a line truncated mid-write — a thing that really happens.
    static let malformed = "{ this is not json }"

    // MARK: - Real identifiers

    /// The session whose 8-char prefix `9cda6f37` is the one a user typed `9c` looking for.
    /// It exists on disk: …/-opt-Code-github-com-laris-co-neo-oracle/9cda6f37-….jsonl
    static let sessionUUID9c = "9cda6f37-b582-4d73-ae6a-d61ab339cda0"
    static let sessionUUIDCafd = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"

    static let projectDir = "/Users/example/.claude/projects/-opt-Code-github-com-laris-co-neo-oracle"
    static let projectCwd = "/workspace/laris-co/neo-oracle"
}
