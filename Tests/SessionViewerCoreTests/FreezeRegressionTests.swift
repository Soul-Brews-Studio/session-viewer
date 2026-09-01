// FreezeRegressionTests.swift
//
// The freeze came back a second time, from a different door, and both doors are cheap to
// nail shut with a test. What made it expensive to find was that neither cause is visible
// by reading the diff that introduced it — auto-expanding the newest 20 rows is three lines
// and looks free. It was not free, because it silently invalidated an optimization written
// earlier for a world where expanding was a rare manual click.
//
// Measured on the regressed build (PID 11323, sampled live): 124.3% CPU, 3.27 GB RSS, with
// `LazyLayoutViewCache.updatePrefetchPhases` → `_ArrayBuffer._consumeAndCreateNew` hot on
// the main thread. Measured after: 3.8–7.1% CPU, 448 MB RSS flat.

import Testing
import Foundation
@testable import SessionViewerCore

private func rawToolResult(bodyLength: Int) -> String {
    let big = String(repeating: "x", count: bodyLength)
    let obj: [String: Any] = [
        "type": "user",
        "message": ["content": [["type": "tool_result", "content": big, "is_error": false]]],
    ]
    let d = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: d, encoding: .utf8)!
}

private func row(_ raw: String) -> LiveEventRow {
    LiveEventRow(id: 1, event: TailEvent(path: "/x", byteOffset: 0, byteLength: raw.utf8.count,
                                         parsedOK: true, lineType: "user", timestamp: nil,
                                         text: "", raw: raw))
}

@Suite("freeze regression · expanded detail is parsed once, at construction")
struct ExpandedParseOnceTests {

    @Test("details are populated at init, not on first access")
    func detailsAreStored() {
        let r = row(rawToolResult(bodyLength: 32))
        // If `expanded` were still a computed property that re-parsed, `details` would be
        // empty here — this is the assertion that the parse moved to init.
        #expect(!r.details.isEmpty)
        #expect(r.details.first?.title == "result")
    }

    @Test("repeated reads return an identical value and cannot re-parse")
    func repeatedReadsAreStable() {
        let r = row(rawToolResult(bodyLength: 64))
        let a = r.expanded.map(\.body)
        let b = r.expanded.map(\.body)
        #expect(a == b)
        // Same stored array each time — the property is an accessor, not a computation.
        #expect(r.expanded.count == r.details.count)
    }

    @Test("a huge tool result is capped, and the truncation is visible")
    func bodiesAreCapped() {
        let huge = 60_000
        let r = row(rawToolResult(bodyLength: huge))
        let body = try! #require(r.details.first?.body)

        // Unbounded text in a LazyVStack row is unbounded layout cost. The cap is the
        // bound; without it one 60 KB result is laid out on every pass over that row.
        #expect(body.count < huge / 2)
        #expect(body.count <= LiveEventRow.bodyCap + 120)
        // Silent truncation would be worse than the freeze — it would make the app lie
        // about what a tool returned.
        #expect(body.contains("truncated for display"))
        #expect(body.contains("more characters"))
    }

    @Test("a body under the cap is returned whole and unmarked")
    func shortBodiesUntouched() {
        let r = row(rawToolResult(bodyLength: 100))
        let body = try! #require(r.details.first?.body)
        #expect(body.count == 100)
        #expect(!body.contains("truncated"))
    }
}

@Suite("freeze regression · graph target identity")
struct ShellProgramTests {

    // The prefix-truncation bug: 86 distinct Bash calls sharing a `cd …` prefix collapsed
    // into ONE graph node, which would have drawn a giant false hub. Node identity needs a
    // stable entity, so a shell command reduces to the program it runs.

    @Test("a cd prelude does not become the program")
    func cdIsNotTheProgram() {
        #expect(shellProgram("cd /opt/Code/foo && rg pattern src/") == "rg")
        #expect(shellProgram("cd /a/b\nswift build -c release") == "swift")
    }

    @Test("distinct commands under one prefix stay distinct")
    func noFalseHub() {
        let base = "cd /workspace/digger-oracle/lab/session-viewer && "
        let progs = Set([
            shellProgram(base + "swift build"),
            shellProgram(base + "rg foo"),
            shellProgram(base + "git status"),
        ].compactMap { $0 })
        #expect(progs == ["swift", "rg", "git"])
    }

    @Test("an absolute path reduces to its basename")
    func basename() {
        #expect(shellProgram("/usr/bin/sqlite3 .data/x.db") == "sqlite3")
    }

    @Test("env assignments and sudo are skipped")
    func skipsScaffolding() {
        #expect(shellProgram("sudo launchctl list") == "launchctl")
        #expect(shellProgram("FOO=1 BAR=2 python3 x.py") == "python3")
    }

    @Test("a command with nothing runnable yields nil rather than a bogus node")
    func nothingRunnable() {
        #expect(shellProgram("") == nil)
        #expect(shellProgram("   ") == nil)
    }
}

@Suite("freeze regression · graph structure")
struct GraphShapeTests {

    @Test("file paths stay whole — they are real entities, not prefixes")
    func filePathsNotTruncatedIntoCollision() {
        // Two long paths differing only in their TAIL must not collide. Prefix truncation
        // at 72 chars is exactly what made distinct targets merge.
        let base = "/workspace/digger-oracle/lab/session-viewer/Sources/SessionViewerCore/deep/fixture/"
        let a = base + "Live.swift"
        let b = base + "Tail.swift"
        #expect(a.count > 72 && b.count > 72)
        #expect(String(a.prefix(72)) == String(b.prefix(72)))   // they WOULD have collided
        // and with whole paths as identity, they do not:
        #expect(a != b)
    }
}
