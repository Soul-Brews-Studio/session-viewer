// FTSQueryTests.swift — the regression suite for the two search bugs that shipped.
//
// Both bugs had the same signature and it is the worst one a search box can have: ZERO
// RESULTS, NO ERROR. `searchEvents` (Store.swift) reads rows with
// `while sqlite3_step(stmt) == SQLITE_ROW`, so SQLITE_ERROR and SQLITE_DONE are the same
// thing to that loop. A malformed MATCH expression therefore does not raise — it returns
// an empty result set that looks exactly like "nothing matched".
//
//   BUG 1 (silent wrong answer). `append-only` went to MATCH unquoted. `-` is an FTS5
//          operator, so FTS5 parsed `only` as a column name and failed at step with
//          "no such column: only". The box said "no matches".
//   BUG 2 (looked broken while working as written). Quoting fixed bug 1 but a quoted FTS5
//          phrase matches WHOLE tokens only, so typing `9c` to find session `9cda6f37`
//          matched nothing. Every incremental search UI treats the last token as a prefix,
//          because the user has not finished typing it.
//
// So these tests do not only assert the STRING `ftsQuery` builds. They run it against a
// real in-memory FTS5 table and distinguish three outcomes the app's own loop cannot:
// rows, no rows, and step-failed. Asserting the string alone would have passed for the
// broken version of bug 2 as easily as the fixed one.

import Foundation
import SQLite3
import Testing

@testable import SessionViewerCore

// MARK: - A real FTS5 table, so "it errors" and "it matches nothing" stay distinguishable

/// In-memory FTS5 over a handful of real corpus strings.
///
/// This links the same system libsqlite3 the app does. SPEC.md records that bare `sqlite3`
/// on this machine resolves to the Android SDK build, which has NO FTS5 — if that ever
/// became the linked library, `init` below fails loudly on CREATE VIRTUAL TABLE instead of
/// letting every query quietly return nothing.
private final class FTS5Probe {
    private var handle: OpaquePointer?

    /// What `sqlite3_step` actually did — the distinction `searchEvents` throws away.
    enum Outcome: Equatable {
        case rows([String])
        case stepFailed(String)

        var rowCount: Int {
            switch self {
            case .rows(let r):  return r.count
            case .stepFailed:   return 0     // …which is precisely why this must not be conflated
            }
        }
    }

    init(_ rows: [String]) {
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK else {
            fatalError("sqlite3_open(\":memory:\") failed")
        }
        guard sqlite3_exec(handle, "CREATE VIRTUAL TABLE docs USING fts5(body);", nil, nil, nil) == SQLITE_OK else {
            fatalError("no FTS5 in the linked sqlite3: \(String(cString: sqlite3_errmsg(handle))) — see SPEC.md")
        }
        for row in rows {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO docs(body) VALUES (?);", -1, &stmt, nil) == SQLITE_OK else {
                fatalError("insert prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
            sqlite3_bind_text(stmt, 1, row, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                fatalError("insert step failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
            sqlite3_finalize(stmt)
        }
    }

    deinit { sqlite3_close(handle) }

    /// Binds `expression` exactly the way `searchEvents` binds `ftsQuery(query)`.
    func match(_ expression: String) -> Outcome {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT body FROM docs WHERE docs MATCH ? ORDER BY rowid;",
                                 -1, &stmt, nil) == SQLITE_OK else {
            return .stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, expression, -1, SQLITE_TRANSIENT)

        var out: [String] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            case SQLITE_DONE:
                return .rows(out)
            default:
                return .stepFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

/// Corpus rows. Sentences 1–3 are from this project's own SPEC.md; row 4 carries the real
/// session uuid `9cda6f37-…` that the `9c` bug was about; row 5 contains literal double
/// quotes, and row 6 is Thai (15% of indexed descriptions are).
private let probeRows = [
    "Import identity is (path, mtime, size) — no content hashing.",
    "session files are append-only in practice, so size+mtime is a sound change signal",
    "byte offset is absolute within the file, and byte offsets survive a restart",
    "session \(Corpus.sessionUUID9c) ran /oracle-family-scan on 2026-08-20",
    #"the user typed "append-only" into the search box and got nothing back"#,
    "เซสชันนี้เขียนไฟล์ append-only ตลอด",
]

// MARK: - The string ftsQuery builds

@Suite("ftsQuery — expression construction")
struct FTSQueryStringTests {

    @Test("BUG 1: a hyphenated word never reaches FTS5 as a bare `-` operator")
    func hyphenIsQuotedNotOperated() {
        let q = ftsQuery("append-only")
        // The hyphen survives, but INSIDE a quoted phrase, where FTS5 treats it as text.
        #expect(q == #""append-only"*"#)
        // Belt and braces: nothing outside a quoted region may be an operator character.
        #expect(!unquotedRegions(of: q).contains { $0.contains("-") })
    }

    @Test("BUG 2: the last token is a PREFIX match, so `9c` can find 9cda6f37")
    func lastTokenIsAPrefix() {
        #expect(ftsQuery("9c") == #""9c"*"#)
        #expect(ftsQuery("9c").hasSuffix("*"))
    }

    @Test("only the LAST token gets `*` — `byte off` is not `byte*`")
    func onlyTheLastTokenIsAPrefix() {
        // "the word byte, and something starting with off" — not "anything starting with byte".
        #expect(ftsQuery("byte off") == #""byte" "off"*"#)
        #expect(ftsQuery("a b c") == #""a" "b" "c"*"#)
    }

    @Test("a literal double quote is escaped by DOUBLING, not dropped and not left bare")
    func doubleQuoteIsDoubled() {
        // FTS5's only in-string escape is "" for a literal quote.
        #expect(ftsQuery("\"hello\"") == #""""hello"""*"#)
        #expect(ftsQuery("say \"hi\"") == #""say" """hi"""*"#)
        // Every phrase must still be balanced: an odd number of quote characters anywhere
        // would mean the expression is truncated mid-phrase.
        #expect(ftsQuery("\"hello\"").filter { $0 == "\"" }.count % 2 == 0)
    }

    @Test("whitespace-only and empty input collapse to the empty phrase, never to bare SQL",
          arguments: ["", " ", "\t", "\n", "   \t \n  "])
    func emptyInputIsAnEmptyPhrase(_ raw: String) {
        #expect(ftsQuery(raw) == "\"\"")
    }

    @Test("interior whitespace of every kind is a token separator")
    func whitespaceSplitting() {
        #expect(ftsQuery("byte\toff") == #""byte" "off"*"#)
        #expect(ftsQuery("  byte   off  ") == #""byte" "off"*"#)
        #expect(ftsQuery("byte\noff") == #""byte" "off"*"#)
    }

    @Test("other FTS5 operator characters are neutralised the same way",
          arguments: [":", "^", "(", ")", "*", "NOT", "OR", "AND"])
    func operatorCharactersAreQuoted(_ token: String) {
        let q = ftsQuery("alpha \(token)")
        #expect(q.hasPrefix(#""alpha" "#))
        // Whatever it was, it is now inside a phrase, so it is text.
        #expect(q.contains("\"\(token)\"*") || q.contains("\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"*"))
    }

    /// The parts of an expression that are NOT inside a double-quoted phrase — i.e. the
    /// only places an FTS5 operator could still be live.
    private func unquotedRegions(of expression: String) -> [String] {
        var regions: [String] = []
        var current = ""
        var inQuotes = false
        for ch in expression {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes { current.append(ch) } else if !current.isEmpty { regions.append(current); current = "" }
        }
        if !current.isEmpty { regions.append(current) }
        return regions
    }
}

// MARK: - The same expressions against a real FTS5 table

@Suite("ftsQuery — executed against real FTS5")
struct FTSQueryExecutionTests {

    @Test("PROOF of bug 1: the raw input FAILS at step; ftsQuery's output does not")
    func rawHyphenFailsAtStepAndTheFixDoesNot() {
        let db = FTS5Probe(probeRows)

        // What the box used to send. This is the silent failure: the app's row loop cannot
        // tell this apart from an honest empty result.
        let old = db.match("append-only")
        guard case .stepFailed(let message) = old else {
            Issue.record("expected the raw hyphenated term to fail at sqlite3_step, got \(old)")
            return
        }
        #expect(message.contains("no such column"))

        // What it sends now.
        let fixed = db.match(ftsQuery("append-only"))
        guard case .rows(let hits) = fixed else {
            Issue.record("ftsQuery output must never fail at step, got \(fixed)")
            return
        }
        #expect(hits.count == 3)   // the SPEC line, the quoted-quote line, and the Thai line
        #expect(hits.contains { $0.contains("size+mtime is a sound change signal") })
    }

    @Test("PROOF of bug 2: `9c` finds session 9cda6f37; the pre-fix exact phrase did not")
    func shortPrefixFindsTheSession() {
        let db = FTS5Probe(probeRows)

        // The pre-fix expression: a quoted phrase matches whole tokens only.
        #expect(db.match(#""9c""#) == .rows([]))

        // The fix.
        guard case .rows(let hits) = db.match(ftsQuery("9c")) else {
            Issue.record("prefix match must not fail at step")
            return
        }
        #expect(hits.count == 1)
        #expect(hits[0].contains(Corpus.sessionUUID9c))
    }

    @Test("typing the uuid out further keeps matching — prefix search narrows, never breaks",
          arguments: ["9c", "9cd", "9cda", "9cda6f", "9cda6f37"])
    func everyPrefixOfTheUUIDStillMatches(_ typed: String) {
        let db = FTS5Probe(probeRows)
        guard case .rows(let hits) = db.match(ftsQuery(typed)) else {
            Issue.record("\(typed.debugDescription) failed at step")
            return
        }
        #expect(hits.count == 1)
    }

    @Test("multi-word input is an implicit AND, with only the last word open-ended")
    func multiWordIsAnAndOfPhrases() {
        let db = FTS5Probe(probeRows)
        // "byte" AND something starting with "off" — the byte-offset row only.
        #expect(db.match(ftsQuery("byte off")) == .rows([probeRows[2]]))
        // A word that exists AND one that does not → no rows, but NOT an error.
        #expect(db.match(ftsQuery("byte zzzz")) == .rows([]))
    }

    @Test("a literal double quote in the box is a search, not a syntax error")
    func quotedInputExecutes() {
        let db = FTS5Probe(probeRows)
        let outcome = db.match(ftsQuery("\"append-only\""))
        guard case .rows = outcome else {
            Issue.record("doubling failed to produce a valid expression: \(outcome)")
            return
        }
    }

    @Test("empty input runs and returns nothing — it does not produce invalid SQL",
          arguments: ["", "   ", "\n\t"])
    func emptyInputIsValidSQL(_ raw: String) {
        let db = FTS5Probe(probeRows)
        #expect(db.match(ftsQuery(raw)) == .rows([]))
    }

    @Test("Thai input executes — 15% of indexed descriptions contain Thai")
    func thaiExecutes() {
        let db = FTS5Probe(probeRows)
        // Recall is a separate, open question (TODO.md: unicode61 is whitespace-based and
        // measured at 18% recall for Thai; trigram scored 100%). What is asserted here is
        // only the thing this function owns: it must not blow up on non-Latin input.
        guard case .rows = db.match(ftsQuery("เซสชันนี้")) else {
            Issue.record("Thai input must not fail at step")
            return
        }
    }

    @Test("every real punctuation-bearing term a user might type executes without erroring",
          arguments: ["append-only", "file-history-snapshot", "permission-mode",
                      "session_type_counts", "ORDER BY", "9cda6f37-b582", "wf_8b429bba-965",
                      "agent-acat-artist-5a897953c7b59c51", "C++", "a:b", "(paren)", "^caret",
                      "NOT OR AND", "--", "*", "\"", "\"\"\""])
    func noInputCanReachFTS5AsSyntax(_ typed: String) {
        let db = FTS5Probe(probeRows)
        if case .stepFailed(let message) = db.match(ftsQuery(typed)) {
            Issue.record("\(typed.debugDescription) → \(ftsQuery(typed).debugDescription) failed: \(message)")
        }
    }
}
