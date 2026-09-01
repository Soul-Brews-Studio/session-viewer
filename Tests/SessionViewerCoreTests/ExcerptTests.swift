// ExcerptTests.swift — the "show N more lines" split for long code bodies.
//
// A tool body in this corpus is routinely hundreds of lines: one `apply_patch` observed
// live ran past the whole detail pane and pushed every neighbouring event off screen, so
// the tail stopped being a tail. The excerpt exists to bound that, and the number in the
// control ("show 214 more lines") is a CLAIM about what the click will reveal — if it is
// wrong the control is lying about its own cost, which is worse than not truncating.
//
// Two shapes have to be handled, and a line count alone catches only the first:
//   • tall and narrow — hundreds of short lines
//   • one enormous line — a serialized JSON blob or a whole patch on a single line, which
//     passes any line-count check while still being unbounded to lay out.
//
// The properties asserted below are the ones the view actually depends on:
//   1. short bodies are returned untouched, with hidden == 0, so no control is offered
//   2. head + hidden accounts for every line — the figure shown is not invented
//   3. the character cap fires even when the line count is tiny
//   4. hidden is never negative, whatever the input

import Testing
@testable import SessionViewerCore

@Suite("excerpt · long code bodies split into head + a truthful remainder")
struct ExcerptTests {

    private func lines(_ s: String) -> Int {
        s.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    @Test("a short body is returned whole and offers no control")
    func shortBodyUntouched() {
        let s = "one\ntwo\nthree"
        let cut = LiveEventRow.excerptOf(s)
        #expect(cut.head == s)
        #expect(cut.hidden == 0)
    }

    @Test("empty text is not a special case")
    func emptyText() {
        let cut = LiveEventRow.excerptOf("")
        #expect(cut.head == "")
        #expect(cut.hidden == 0)
    }

    @Test("a body exactly at the line limit is still shown whole")
    func exactlyAtLimit() {
        let s = (1...LiveEventRow.excerptLines).map(String.init).joined(separator: "\n")
        let cut = LiveEventRow.excerptOf(s)
        #expect(cut.hidden == 0, "at the boundary, nothing is hidden and no control is shown")
        #expect(cut.head == s)
    }

    @Test("one line past the limit hides exactly one line")
    func onePastLimit() {
        let s = (1...(LiveEventRow.excerptLines + 1)).map(String.init).joined(separator: "\n")
        let cut = LiveEventRow.excerptOf(s)
        #expect(cut.hidden == 1)
        #expect(lines(cut.head) == LiveEventRow.excerptLines)
    }

    /// The figure in the control must ACCOUNT for the body: what is shown plus what is
    /// claimed to be hidden is the whole thing. A drifting count is the failure this test
    /// exists to catch, because nothing in the UI would reveal it.
    @Test("shown lines + hidden lines == the body's lines, for a tall body")
    func accountingHoldsForTallBody() {
        let total = 300
        let s = (1...total).map { "line \($0)" }.joined(separator: "\n")
        let cut = LiveEventRow.excerptOf(s)
        #expect(cut.hidden > 0)
        #expect(lines(cut.head) + cut.hidden == total)
    }

    /// The case a line count alone would miss entirely.
    @Test("one enormous single line is cut by characters, not passed through")
    func singleHugeLineIsCut() {
        let s = String(repeating: "x", count: LiveEventRow.excerptChars * 8)
        let cut = LiveEventRow.excerptOf(s)
        #expect(lines(s) == 1, "precondition: a line-count check would let this through")
        #expect(cut.head.count <= LiveEventRow.excerptChars)
        #expect(cut.head.count < s.count, "the body must actually be shortened")
    }

    /// A single line cannot be "hidden" once it has started rendering, so the count must
    /// not claim otherwise — it may be 0 here, but it must never go negative.
    @Test("hidden is never negative")
    func hiddenNeverNegative() {
        for n in [0, 1, 2, LiveEventRow.excerptChars, LiveEventRow.excerptChars * 4] {
            let cut = LiveEventRow.excerptOf(String(repeating: "y", count: n))
            #expect(cut.hidden >= 0, "n=\(n)")
        }
    }

    /// The realistic shape: a patch that is both long AND wide.
    @Test("a long wide body is bounded on both axes")
    func longAndWide() {
        let wide = String(repeating: "z", count: 400)
        let s = (1...80).map { _ in wide }.joined(separator: "\n")
        let cut = LiveEventRow.excerptOf(s)
        #expect(cut.hidden > 0)
        #expect(cut.head.count <= LiveEventRow.excerptChars,
                "the character cap must win when lines are wide")
        #expect(lines(cut.head) + cut.hidden == lines(s))
    }
}
