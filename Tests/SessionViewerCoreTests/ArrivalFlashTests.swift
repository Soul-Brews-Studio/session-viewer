// ArrivalFlashTests.swift — which live rows get the "just appeared" highlight.
//
// The live list is sorted by write time, so it REORDERS while you read it. A session that
// starts mid-glance slides into a position you were not looking at, which is what the flash
// exists to solve. That makes the flash a claim — "this one is new" — and a claim that
// fires on the wrong row is worse than no highlight, because it trains you to ignore it.
//
// The behaviour is all edge cases, and none are observable by watching the window:
//   • the FIRST scan must not light up the entire fleet
//   • widening the window must not light up sessions that were already running
//   • a session that keeps writing must not re-flash — it never left
//   • entries must be forgotten, or a view left open for days accumulates one per session
//
// Time is injected rather than read, so these assert real decay instead of sleeping.

import Testing
import Foundation
@testable import SessionViewerCore

@Suite("arrival flash · only genuinely new rows are highlighted")
struct ArrivalFlashTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the first scan highlights nothing, however many sessions it finds")
    func firstScanIsSilent() {
        let live: Set<String> = ["/a.jsonl", "/b.jsonl", "/c.jsonl"]
        let out = trackArrivals(livePaths: live, known: [], previous: [:],
                                now: t0, suppress: true)
        #expect(out.isEmpty, "a flash on every row is indistinguishable from no flash")
    }

    @Test("a session that appears after the first scan is highlighted")
    func newSessionFlashes() {
        let known: Set<String> = ["/a.jsonl"]
        let live: Set<String> = ["/a.jsonl", "/b.jsonl"]
        let out = trackArrivals(livePaths: live, known: known, previous: [:],
                                now: t0, suppress: false)
        #expect(out["/b.jsonl"] == t0)
        #expect(out["/a.jsonl"] == nil, "a session that was already here is not new")
    }

    /// Widening 5 min → 1 hour reveals a batch of already-running sessions. They are new to
    /// the VIEW but not newly started, and saying otherwise would be a lie.
    @Test("widening the window does not highlight sessions that were already running")
    func windowChangeIsSuppressed() {
        let known: Set<String> = ["/a.jsonl"]
        let live: Set<String> = ["/a.jsonl", "/old1.jsonl", "/old2.jsonl", "/old3.jsonl"]
        let out = trackArrivals(livePaths: live, known: known, previous: [:],
                                now: t0, suppress: true)
        #expect(out.isEmpty)
    }

    /// The one that would leave a busy session permanently lit.
    @Test("a session that keeps writing is not re-stamped on later ticks")
    func existingEntryIsNotRefreshed() {
        let live: Set<String> = ["/a.jsonl"]
        var out = trackArrivals(livePaths: live, known: [], previous: [:],
                                now: t0, suppress: false)
        #expect(out["/a.jsonl"] == t0)

        // Three seconds later it is STILL live and still in `known`.
        out = trackArrivals(livePaths: live, known: live, previous: out,
                            now: t0.addingTimeInterval(3), suppress: false)
        #expect(out["/a.jsonl"] == t0, "the stamp must be the ARRIVAL, not the last write")
    }

    @Test("the highlight is forgotten once the flash duration has elapsed")
    func entryExpires() {
        let live: Set<String> = ["/a.jsonl"]
        var out = trackArrivals(livePaths: live, known: [], previous: [:],
                                now: t0, suppress: false)
        #expect(out["/a.jsonl"] != nil)

        out = trackArrivals(livePaths: live, known: live, previous: out,
                            now: t0.addingTimeInterval(LiveFleetModel.flashSeconds + 0.1),
                            suppress: false)
        #expect(out["/a.jsonl"] == nil, "an expired flash must not linger")
    }

    @Test("a session that drops out of the live set is forgotten immediately")
    func goneSessionIsDropped() {
        var out = trackArrivals(livePaths: ["/a.jsonl"], known: [], previous: [:],
                                now: t0, suppress: false)
        #expect(out["/a.jsonl"] != nil)

        out = trackArrivals(livePaths: [], known: ["/a.jsonl"], previous: out,
                            now: t0.addingTimeInterval(1), suppress: false)
        #expect(out.isEmpty, "no longer live means no longer highlighted")
    }

    /// The property that matters for a window left open for days.
    @Test("the map stays bounded across many ticks of churn")
    func mapDoesNotGrowUnbounded() {
        var out: [String: Date] = [:]
        var known: Set<String> = []
        for i in 0..<400 {
            let live: Set<String> = ["/session-\(i).jsonl"]      // total churn each tick
            let now = t0.addingTimeInterval(Double(i))
            out = trackArrivals(livePaths: live, known: known, previous: out,
                                now: now, suppress: false)
            known = live
        }
        #expect(out.count <= 1,
                "only currently-live, currently-flashing paths are retained — got \(out.count)")
    }

    @Test("several arrivals in one tick all share that tick's timestamp")
    func batchArrivalsShareATimestamp() {
        let out = trackArrivals(livePaths: ["/a.jsonl", "/b.jsonl", "/c.jsonl"],
                                known: ["/a.jsonl"], previous: [:],
                                now: t0, suppress: false)
        #expect(out.count == 2)
        #expect(out["/b.jsonl"] == t0 && out["/c.jsonl"] == t0)
    }
}
