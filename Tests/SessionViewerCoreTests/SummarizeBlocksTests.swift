// SummarizeBlocksTests.swift — the ONE summarizer shared by the SwiftUI live pane, the
// `session-viewer tail` CLI and the web/WS server.
//
// What it replaced was the placeholder `· no text (tool call or result)`, which threw away
// the single most useful field on the MOST COMMON line in a transcript. Measured over 408
// real content blocks from live workflow transcripts: tool_use 140, tool_result 139,
// thinking 75, text 54. So before this function existed, roughly two-thirds of a tail
// rendered as blank rows.
//
// The subtle one is `thinking`. In stored transcripts the `thinking` string is USUALLY
// EMPTY (len=0) with only an opaque `signature` beside it — the content is stripped at
// write time, not lost by the parser. A fixture invented by hand would have put prose in
// that field and "proved" a preview path that almost never fires in production, while the
// real 18% of blocks kept rendering as empty rows. Hence `Fx.thinkingEmpty` /
// `Corpus.thinkingEmpty`, both taken verbatim off disk.

import Testing
import Foundation
@testable import SessionViewerCore

@Suite("summarizeBlocks — tool_use")
struct SummarizeToolUseTests {

    /// Name AND target. The target is the one field per tool a human scanning a tail
    /// actually wants, and it is chosen by a fixed key order — `command` before
    /// `description`, because the command IS the answer.
    @Test func bashRendersNameAndCommand() {
        let out = LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.toolUseBash))
        // 73-char command, capped at 72 + an ellipsis.
        #expect(out == "Bash · find /workspace/fixture12/thClaws/thClaws -type f -name \"*.md\" | head -2…")
    }

    @Test func readRendersItsFilePath() {
        let out = LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.toolUseRead))
        #expect(out == "Read · /workspace/thClaws/thClaws")
    }

    /// `file_path` must beat the much longer `old_string`/`new_string` that sit beside it.
    @Test func editPrefersFilePathOverTheOtherStringFields() {
        let out = LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.toolUseEdit))
        #expect(out == "Edit · /workspace/digger-oracle/LiveView.swift")
        #expect(out?.contains("let steps") == false, "an old_string/new_string must not become the target")
    }

    /// No recognized key ⇒ the NAME alone, which is still real information. Returning nil
    /// here would put the row back to "no content".
    @Test func aToolWithNoRecognizedInputKeyStillRendersItsName() {
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.toolUseSkillNoTarget)) == "Skill")
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.toolUseEmptyInput)) == "EnterPlanMode")
    }

    /// Real whole lines, straight off disk, through the same call. Verified shapes: a Bash
    /// command containing `ψ` (this corpus is not ASCII), a WebFetch whose target is a URL,
    /// a ToolSearch whose target is a query, and a ListAgents with an empty input.
    @Test func realCorpusLinesRenderTheirNameAndTarget() {
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolUseBashShort)
                == "Bash · ls -la ψ 2>&1 | head -3")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolUseRead)
                == "Read · /workspace/laris-co/Nat-s-Agents/package.json")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolUseWebFetch)
                == "WebFetch · https://github.com/indragiek/INDANCSClient")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolUseToolSearch)
                == "ToolSearch · select:WebSearch,WebFetch")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolUseListAgents) == "ListAgents")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolUseSkill) == "Skill")
    }

    /// A tail row is one line high. A multi-line heredoc must not become a multi-line row,
    /// and a long one-liner must not push the age and size off the pane.
    @Test func aMultiLineCommandCollapsesToItsFirstLineAndIsCapped() {
        let block = #"{"type":"tool_use","id":"toolu_x","name":"Bash","input":{"command":"cat <<'EOF' > /tmp/x\nline two\nline three\nEOF"}}"#
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(block)) == "Bash · cat <<'EOF' > /tmp/x")

        let long = String(repeating: "x", count: 200)
        let longBlock = #"{"type":"tool_use","id":"toolu_y","name":"Bash","input":{"command":"echo "# + long + #""}}"#
        let out = LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(longBlock))
        #expect(out?.hasSuffix("…") == true)
        // "Bash · " + 72 characters + "…"
        #expect(out?.count == 7 + 72 + 1)
        #expect(out == "Bash · echo " + String(repeating: "x", count: 67) + "…")
    }

    /// An EMPTY string under a recognized key is skipped, not rendered as a dangling " · ".
    @Test func anEmptyTargetValueIsSkipped() {
        let block = #"{"type":"tool_use","id":"toolu_z","name":"Bash","input":{"command":"","description":"do the thing"}}"#
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(block)) == "Bash · do the thing")
    }

    /// A block with no `name` falls back to the literal "tool" rather than dropping the row.
    @Test func aNamelessToolUseFallsBackToTool() {
        let block = #"{"type":"tool_use","id":"toolu_n","input":{"file_path":"/tmp/a"}}"#
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(block)) == "tool · /tmp/a")
    }
}

@Suite("summarizeBlocks — tool_result")
struct SummarizeToolResultTests {

    @Test func successAndFailureAreDistinguishable() {
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.userLine(Fx.toolResultOK)) == "→ result")
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.userLine(Fx.toolResultError)) == "→ error")
    }

    /// THE case an invented fixture misses: many real `tool_result` blocks carry no
    /// `is_error` key at all. Absent must mean success, not "unknown" and not a crash.
    @Test func anAbsentIsErrorKeyMeansSuccess() {
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.userLine(Fx.toolResultNoErrorKey)) == "→ result")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolResultNoIsErrorKey) == "→ result")
    }

    @Test func realCorpusResultLinesRenderTheRightMarker() {
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolResultOK) == "→ result")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.toolResultError) == "→ error")
    }

    /// `is_error` arrives as a JSON bool and reaches Swift through NSNumber bridging. A
    /// JSON string "true" is NOT a bool and must read as the safe default, not as an error.
    @Test func aStringIsErrorIsNotTreatedAsAFailure() {
        let block = #"{"type":"tool_result","tool_use_id":"toolu_s","content":"x","is_error":"true"}"#
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.userLine(block)) == "→ result")
    }
}

@Suite("summarizeBlocks — thinking")
struct SummarizeThinkingTests {

    /// The measured normal case: `thinking` is an EMPTY string with only a signature.
    /// It must still produce "thinking…" — in a tail, "it is reasoning" is real signal,
    /// and a long silent gap otherwise looks like a stall.
    @Test func anEmptyThinkingStringStillRendersThinking() {
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.thinkingEmpty)) == "thinking…")
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.thinkingEmpty) == "thinking…")
    }

    /// A missing `thinking` key entirely — same output, same reason.
    @Test func aThinkingBlockWithNoTextKeyStillRendersThinking() {
        let block = #"{"type":"thinking","signature":"Ep0ECqgB"}"#
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(block)) == "thinking…")
    }

    /// The rare block that KEPT its text gets a one-line preview, capped at 64.
    @Test func aThinkingBlockThatKeptItsTextGetsAPreview() {
        let short = #"{"type":"thinking","thinking":"Let me check the offset first.\nThen the size.","signature":"x"}"#
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(short))
                == "thinking… Let me check the offset first.")

        let long = String(repeating: "a", count: 100)
        let block = #"{"type":"thinking","thinking":""# + long + #"","signature":"x"}"#
        let out = LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(block))
        #expect(out == "thinking… " + String(repeating: "a", count: 64) + "…")
    }

    /// Whitespace-only content is indistinguishable from empty for a reader, so it takes
    /// the bare form rather than "thinking… " with a trailing space.
    @Test func whitespaceOnlyThinkingTakesTheBareForm() {
        let block = #"{"type":"thinking","thinking":"   \n  ","signature":"x"}"#
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(block)) == "thinking…")
    }
}

@Suite("summarizeBlocks — multiple blocks and non-renderable lines")
struct SummarizeCompositionTests {

    /// The real shape of an assistant turn: it reasons, then calls a tool, in ONE line.
    /// Parts join with three spaces, in block order.
    @Test func severalBlocksInOneLineJoinInOrder() {
        let out = LiveEventRow.summarizeBlocks(
            raw: Fx.assistantLine(Fx.thinkingEmpty, Fx.toolUseRead))
        #expect(out == "thinking…   Read · /workspace/thClaws/thClaws")
    }

    @Test func twoToolCallsInOneLineBothAppear() {
        let out = LiveEventRow.summarizeBlocks(
            raw: Fx.assistantLine(Fx.toolUseRead, Fx.toolUseSkillNoTarget))
        #expect(out == "Read · /workspace/thClaws/thClaws   Skill")
    }

    /// A `text` block is prose — the caller renders `event.text` for it. Returning nil is
    /// what lets the caller distinguish "state line" from "had content we could not name".
    @Test func aTextOnlyLineReturnsNil() {
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.textBlock)) == nil)
    }

    /// A `text` block sitting NEXT to a tool call is skipped, but the tool call still
    /// renders — the whole line must not go nil because one block was prose.
    @Test func aTextBlockBesideAToolCallDoesNotSuppressTheToolCall() {
        let out = LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(Fx.textBlock, Fx.toolUseRead))
        #expect(out == "Read · /workspace/thClaws/thClaws")
    }

    @Test func anEmptyContentArrayReturnsNil() {
        #expect(LiveEventRow.summarizeBlocks(raw: Fx.assistantLine()) == nil)
    }
}

@Suite("summarizeBlocks — malformed input returns nil rather than throwing")
struct SummarizeMalformedTests {

    /// Real session files DO get truncated mid-write, and the tailer surfaces those lines
    /// rather than dropping them — so this function is handed genuine garbage in normal
    /// operation. `try?` + optional casts mean every one of these is a nil, not a throw and
    /// not a trap.
    @Test(arguments: [
        "",                                       // empty line
        "{ this is not json }",                   // the tail selftest's own malformed line
        "{\"type\":\"user\"",                     // truncated mid-object — the real shape
        "not json at all",
        "[]",                                     // valid JSON, wrong root type
        "null",
        "\"a string\"",
        "42",
        "{}",                                     // no message key
        "{\"message\":null}",
        "{\"message\":\"a string, not a dict\"}", // message present, wrong type
        "{\"message\":{}}",                       // message present, no content
        "{\"message\":{\"content\":null}}",
        "{\"message\":{\"content\":\"plain string content\"}}",   // the OTHER real shape
        "{\"message\":{\"content\":[1,2,3]}}",    // array of the wrong element type
        "{\"message\":{\"content\":[{\"type\":\"unknown_block\"}]}}",
    ])
    func malformedOrUnrenderableInputIsNil(_ raw: String) {
        #expect(LiveEventRow.summarizeBlocks(raw: raw) == nil)
    }

    /// The corpus's own malformed fixture, and a non-UTF8-ish placeholder of the kind
    /// `makeEvent` substitutes when a line will not decode.
    @Test func corpusMalformedAndTheNonUTF8PlaceholderAreNil() {
        #expect(LiveEventRow.summarizeBlocks(raw: Corpus.malformed) == nil)
        #expect(LiveEventRow.summarizeBlocks(raw: "<non-utf8 4096 bytes>") == nil)
    }

    /// A single unknown block among known ones must be skipped, not abort the line.
    @Test func anUnknownBlockTypeIsSkippedNotFatal() {
        let unknown = #"{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search"}"#
        let out = LiveEventRow.summarizeBlocks(raw: Fx.assistantLine(unknown, Fx.toolUseRead))
        #expect(out == "Read · /workspace/thClaws/thClaws")
    }

    /// `LiveEventRow` computes the summary ONCE at construction (a live tail re-renders
    /// constantly and re-parsing a 30 KB line per pass would be paid over and over for a
    /// constant answer). Malformed input must not break that init either.
    @Test func theRowInitAbsorbsMalformedRawWithoutTrapping() {
        let bad = row(id: 1, type: nil, parsedOK: false, raw: "{ this is not json }")
        #expect(bad.toolSummary == nil)
        #expect(bad.lineType == "malformed")

        let good = row(id: 2, type: "assistant", raw: Fx.assistantLine(Fx.toolUseRead))
        #expect(good.toolSummary == "Read · /workspace/thClaws/thClaws")
    }
}
