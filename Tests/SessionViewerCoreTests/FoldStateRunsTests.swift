// FoldStateRunsTests.swift — the tail pane's 8-in-a-row collapse.
//
// A single real turn emits `attachment`, `last-prompt`, `custom-title`, `ai-title`,
// `mode`, `permission-mode`, `atis-latch`, `pr-link` back to back. Eight identical grey
// rows saying nothing individually is the single largest source of visual volume in the
// pane, so consecutive state lines fold into one.
//
// The property that matters and is easy to break: a NON-state line must BREAK the run.
// If it did not, a fold could swallow a real assistant turn that happened to sit between
// two bursts of bookkeeping — losing content, not noise.

import Testing
@testable import SessionViewerCore

// MARK: - helpers for reading the enum back

private extension TailItem {
    var asRun: StateRun? { if case .stateRun(let r) = self { return r }; return nil }
    var asEvent: LiveEventRow? { if case .event(let e) = self { return e }; return nil }
}

@Suite("foldStateRuns")
struct FoldStateRunsTests {

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(foldStateRuns([]).isEmpty)
    }

    /// The headline case: consecutive bookkeeping lines collapse to ONE item.
    @Test func aRunOfConsecutiveStateLinesFoldsToOneItem() {
        let items = foldStateRuns([
            row(id: 1, type: "attachment"),
            row(id: 2, type: "last-prompt"),
            row(id: 3, type: "mode"),
            row(id: 4, type: "permission-mode"),
            row(id: 5, type: "atis-latch"),
        ])
        #expect(items.count == 1)
        let run = items.first?.asRun
        #expect(run?.count == 5)
        // id is the FIRST event's id — stable and monotonic, so SwiftUI keeps its identity
        // as the run grows on the next poll.
        #expect(run?.id == 1)
        #expect(run?.types == ["attachment", "last-prompt", "mode", "permission-mode", "atis-latch"])
    }

    /// THE property. A conversational line between two bursts must split them, and must
    /// itself survive as a real event.
    @Test func aNonStateLineBetweenTwoRunsBreaksThemIntoTwo() {
        let items = foldStateRuns([
            row(id: 1, type: "mode"),
            row(id: 2, type: "permission-mode"),
            row(id: 3, type: "assistant", text: "here is the answer"),
            row(id: 4, type: "attachment"),
            row(id: 5, type: "last-prompt"),
            row(id: 6, type: "ai-title"),
        ])
        #expect(items.count == 3)
        #expect(items[0].asRun?.count == 2)
        #expect(items[0].asRun?.id == 1)
        #expect(items[1].asEvent?.id == 3)
        #expect(items[1].asEvent?.text == "here is the answer")
        #expect(items[2].asRun?.count == 3)
        #expect(items[2].asRun?.id == 4)      // the SECOND run starts its own identity
    }

    /// A run of ONE.
    ///
    /// NOTE — the doc comment on `foldStateRuns` claims "a run of one is NOT folded", but
    /// the code's `if r.count == 1 { out.append(.stateRun(r)) } else { out.append(.stateRun(r)) }`
    /// takes the same action in both branches, so a lone state line IS folded into a
    /// one-item run and renders as "1 state lines". This test pins the ACTUAL behaviour,
    /// not the comment; if the intent is what the comment says, this test is the one that
    /// will fail and say so.
    @Test func aRunOfLengthOneIsStillEmittedAsAOneItemRun() {
        let items = foldStateRuns([row(id: 7, type: "mode")])
        #expect(items.count == 1)
        #expect(items[0].asRun?.count == 1)
        #expect(items[0].asRun?.id == 7)
        #expect(items[0].asRun?.types == ["mode"])
        #expect(items[0].asEvent == nil, "a lone state line currently folds; see the note above")
    }

    @Test func allNonStateLinesPassThroughUnfoldedAndInOrder() {
        let items = foldStateRuns([
            row(id: 1, type: "user", text: "first"),
            row(id: 2, type: "assistant", text: "second"),
            row(id: 3, type: "system", text: "third"),
        ])
        #expect(items.count == 3)
        #expect(items.compactMap { $0.asEvent?.id } == [1, 2, 3])
        #expect(items.allSatisfy { $0.asRun == nil })
    }

    /// A run that is still open when the input ends must be flushed, not dropped — the
    /// trailing `flush()` after the loop. Without it, the last burst of a tail vanishes.
    @Test func aRunAtTheVeryEndIsFlushed() {
        let items = foldStateRuns([
            row(id: 1, type: "assistant", text: "hi"),
            row(id: 2, type: "mode"),
            row(id: 3, type: "permission-mode"),
        ])
        #expect(items.count == 2)
        #expect(items[0].asEvent?.id == 1)
        #expect(items[1].asRun?.count == 2)
    }

    /// `types` is DISTINCT in first-seen order — the row prints them joined by " · " and
    /// "mode · mode · mode" would be worse than the eight rows it replaced.
    @Test func repeatedTypesAreDeduplicatedButStillCounted() {
        let items = foldStateRuns([
            row(id: 1, type: "mode"),
            row(id: 2, type: "mode"),
            row(id: 3, type: "permission-mode"),
            row(id: 4, type: "mode"),
        ])
        #expect(items.count == 1)
        #expect(items[0].asRun?.count == 4)
        #expect(items[0].asRun?.types == ["mode", "permission-mode"])
    }

    /// Real state lines carry NO `timestamp` (see Fixtures — `{"type":"mode","mode":…}` has
    /// no timestamp field at all), so `lastTs` must keep the last one it actually saw
    /// instead of being overwritten with nil by the next line.
    @Test func lastTsKeepsTheMostRecentNonNilTimestamp() {
        let items = foldStateRuns([
            row(id: 1, type: "mode", ts: "2026-08-24T21:00:00.000Z"),
            row(id: 2, type: "permission-mode", ts: nil),
            row(id: 3, type: "atis-latch", ts: "2026-08-24T21:00:05.000Z"),
            row(id: 4, type: "ai-title", ts: nil),
        ])
        #expect(items[0].asRun?.lastTs == "2026-08-24T21:00:05.000Z")
    }

    @Test func aRunWithNoTimestampsAtAllHasNilLastTs() {
        let items = foldStateRuns([
            row(id: 1, type: "mode"),
            row(id: 2, type: "permission-mode"),
        ])
        #expect(items[0].asRun?.lastTs == nil)
    }

    /// A malformed line renders as lineType "malformed", which is NOT a state type — so it
    /// breaks the run and stays visible. Silently folding a truncated line into a grey
    /// "state lines" row would hide corruption the tailer went out of its way to surface.
    @Test func aMalformedLineBreaksTheRunAndSurvives() {
        let items = foldStateRuns([
            row(id: 1, type: "mode"),
            row(id: 2, type: nil, parsedOK: false, raw: "{ this is not json }"),
            row(id: 3, type: "mode"),
        ])
        #expect(items.count == 3)
        #expect(items[1].asEvent?.lineType == "malformed")
    }

    /// A parsed line with no `type` field reads as "(no type)", also not a state type.
    @Test func aTypelessLineIsNotFolded() {
        let items = foldStateRuns([row(id: 1, type: nil)])
        #expect(items.count == 1)
        #expect(items[0].asEvent?.lineType == "(no type)")
    }

    /// Every line in and every line accounted for: item ids are unique and the run counts
    /// plus the passthrough events add back up to the input size.
    @Test func nothingIsLostOrDuplicated() {
        let events = [
            row(id: 1, type: "mode"), row(id: 2, type: "attachment"),
            row(id: 3, type: "user", text: "q"),
            row(id: 4, type: "mode"),
            row(id: 5, type: "assistant", text: "a"), row(id: 6, type: "assistant", text: "b"),
            row(id: 7, type: "pr-link"), row(id: 8, type: "queue-operation"),
        ]
        let items = foldStateRuns(events)
        let folded = items.compactMap { $0.asRun?.count }.reduce(0, +)
        let passed = items.compactMap { $0.asEvent }.count
        #expect(folded + passed == events.count)
        #expect(Set(items.map(\.id)).count == items.count, "TailItem ids must stay unique")
    }
}
