// ChunkCapTests.swift — the ceiling on chunks produced from one event.
//
// This is the single biggest lever on semantic-index build cost, and the corpus is what
// decided the number. Measured over 24,461 already-embedded events on this machine:
//
//   chunks/event   events           vectors   share of all embedding work
//   1–4            19,839  (81%)     24,804    14%
//   33–64             573             25,972    15%
//   65+               453  (1.9%)     81,804    47%    ← largest single event: 1,497 chunks
//
// 1.9% of events cost 47% of the build. Those are giant tool results — a build log, a file
// dump — sliced into hundreds of 50%-overlapping windows. Against that same distribution:
//
//   uncapped 179,947 vectors · cap 32 → 99,889 (−44%) · cap 16 → 77,196 (−57%)
//
// The cap is also a RETRIEVAL argument, not only a cost one: those windows are
// near-duplicates, so one matching query matches dozens of them and they crowd out every
// other event in the top-K.

import Testing
@testable import SessionViewerCore

@Suite("chunk cap · one event cannot dominate the index or the build")
struct ChunkCapTests {

    /// n words, space-separated, so `NLTokenizer` sees exactly n tokens.
    private func words(_ n: Int) -> String {
        (1...n).map { "w\($0)" }.joined(separator: " ")
    }

    @Test("a huge event is capped at maxChunks")
    func hugeEventIsCapped() {
        let plan = ChunkPlan(words: 100, stride: 50, maxChunks: 32)
        // 20,000 words at stride 50 would be ~400 windows uncapped.
        let chunks = chunkText(words(20_000), plan: plan)
        #expect(chunks.count == 32, "got \(chunks.count)")
    }

    @Test("a small event is untouched by the cap")
    func smallEventUnaffected() {
        let capped = ChunkPlan(words: 100, stride: 50, maxChunks: 32)
        let uncapped = ChunkPlan(words: 100, stride: 50, maxChunks: 0)
        let text = words(300)
        #expect(chunkText(text, plan: capped) == chunkText(text, plan: uncapped),
                "the cap must only bind on events that exceed it")
    }

    @Test("maxChunks: 0 disables the ceiling")
    func zeroDisablesCap() {
        let plan = ChunkPlan(words: 100, stride: 50, maxChunks: 0)
        let chunks = chunkText(words(5_000), plan: plan)
        #expect(chunks.count > 32, "expected the uncapped window count, got \(chunks.count)")
    }

    /// The kept chunks are the FIRST ones: a tool result leads with the command and the
    /// start of its output, which is the part that identifies it. The tail of a 40 KB log
    /// is the least retrievable text in the corpus.
    @Test("the cap keeps the HEAD of the event, not an arbitrary slice")
    func capKeepsTheHead() {
        let plan = ChunkPlan(words: 100, stride: 50, maxChunks: 4)
        let chunks = chunkText(words(10_000), plan: plan)
        #expect(chunks.count == 4)
        #expect(chunks.first?.hasPrefix("w1 w2 w3") == true,
                "the first chunk must still start at the beginning of the event")
    }

    @Test("the cap never produces fewer chunks than an event needs")
    func capIsACeilingNotATarget() {
        let plan = ChunkPlan(words: 100, stride: 50, maxChunks: 32)
        // Well under one window: must be a single chunk, not padded to the cap.
        #expect(chunkText(words(10), plan: plan).count == 1)
        #expect(chunkText("", plan: plan).isEmpty, "empty text yields no chunks at all")
    }

    /// Guards the default, because changing it silently changes every future build's cost
    /// and the numbers quoted in this file's header.
    ///
    /// This test used to assert ONLY `maxChunks`, and that omission let a real bug ship:
    /// the struct declared `words = 100` / `stride = 50` while its `init` defaulted the
    /// same parameters to 20/10 and overwrote them, so `ChunkPlan()` silently produced the
    /// old geometry. The CLI passed words/stride explicitly and looked fine; the app passed
    /// no plan at all, so every build launched from the window ran at 20/10 — visible only
    /// in `vector_runs`, which had been recording it correctly all along.
    ///
    /// Assert every field, not the one that was just added.
    @Test("the default plan is the documented, measured geometry")
    func defaultPlanIsDocumented() {
        let p = ChunkPlan()
        #expect(p.words == 100, "declared property default is 100; got \(p.words)")
        #expect(p.stride == 50, "declared property default is 50; got \(p.stride)")
        #expect(p.maxChunks == 32)
    }

    /// The property initializers and the init defaults are two independent declarations of
    /// the same thing, and Swift gives no warning when they disagree — the init silently
    /// wins. Pin them together.
    @Test("an explicitly-default-constructed plan matches a zero-argument one")
    func explicitAndImplicitAgree() {
        #expect(ChunkPlan(words: 100, stride: 50, maxChunks: 32).words == ChunkPlan().words)
        #expect(ChunkPlan(words: 100, stride: 50, maxChunks: 32).stride == ChunkPlan().stride)
    }

    @Test("a negative cap is clamped rather than trusted")
    func negativeCapClamped() {
        #expect(ChunkPlan(words: 100, stride: 50, maxChunks: -5).maxChunks == 0)
    }
}
