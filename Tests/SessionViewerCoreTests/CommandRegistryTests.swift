// CommandRegistryTests.swift — one declaration, two surfaces, one validator.
//
// The registry's promise is that the CLI verb and the MCP tool CANNOT disagree, because
// both are derived from the same declaration and both feed the same validator. These tests
// hold the derivation and the validator; SurfaceInvariantTests holds the surrounding
// surface. The failure modes asserted here are the ones already paid for elsewhere:
// silent fallback on a typo (--self-test, 94 minutes), a crash on an illegal enum value
// (the E(rawValue:)! graft), and an allow-list nobody remembered to update (--since was
// rejected on its first real run — the union in CLISurface.swift is that bug's fix, and
// registryFlagsAreAllowed is its regression test).

import Testing
import Foundation
@testable import SessionViewerCore

@Suite("command registry · one declaration serves both surfaces honestly")
struct CommandRegistryTests {

    private let params = listSessionsCommand().params

    // MARK: the one validator

    @Test("an unknown parameter is refused with the known list, never silently dropped")
    func unknownParamRefused() {
        let r = validateArgs(["sorrt": "mtime"], against: params, commandName: "list")
        guard case .failure(let refusal) = r else {
            Issue.record("a misspelled parameter validated — the --self-test shape returns")
            return
        }
        #expect(refusal.message.contains("unknown parameter 'sorrt'"))
        #expect(refusal.message.contains("sort"), "the refusal must name the legal parameters")
    }

    @Test("a non-integer limit is refused, not silently defaulted")
    func strictIntCoercion() {
        guard case .failure(let r) = validateArgs(["limit": "abc"], against: params,
                                                  commandName: "list") else {
            Issue.record("'abc' passed as an integer")
            return
        }
        #expect(r.message.contains("'limit' must be an integer"))
    }

    /// Probed before fixing: `list --limit -5` dumped all 3,296 rows, because SQLite reads
    /// a negative LIMIT as NO limit. The bound is part of the declaration now.
    @Test("out-of-range integers are refused with the bound, not passed to SQLite")
    func intBoundsEnforced() {
        for bad in ["-5", "0"] {
            guard case .failure(let r) = validateArgs(["limit": bad], against: params,
                                                      commandName: "list") else {
                Issue.record("limit \(bad) validated — negative LIMIT means unbounded in SQLite")
                continue
            }
            #expect(r.message.contains("≥ 1"))
        }
    }

    @Test("argv strings and MCP JSON ints both coerce to the same value")
    func bothSurfacesOneRule() throws {
        // argv delivers "40"; MCP JSON delivers 40. One validator, one result.
        let a = try validateArgs(["limit": "40"], against: params, commandName: "list").get()
        let b = try validateArgs(["limit": 40], against: params, commandName: "list").get()
        #expect(a["limit"] as? Int == 40)
        #expect(b["limit"] as? Int == 40)
    }

    @Test("an illegal choice value is a refusal naming the legal set — never a crash")
    func choiceRefusesWithLegalSet() {
        guard case .failure(let r) = validateArgs(["sort": "wibble"], against: params,
                                                  commandName: "list") else {
            Issue.record("illegal sort validated")
            return
        }
        #expect(r.message.contains("mtime"), "the refusal must list what IS legal")
    }

    @Test("defaults are applied for absent optional parameters")
    func defaultsApplied() throws {
        let v = try validateArgs([:], against: params, commandName: "list").get()
        #expect(v["sort"] as? String == "mtime")
        #expect(v["limit"] as? Int == 40)
        #expect(v["tier"] as? String == "all")
    }

    // MARK: the derivations

    @Test("the derived MCP schema carries a real enum for every choice parameter")
    func choiceBecomesEnum() throws {
        let tool = listSessionsCommand().mcpTool
        let props = try #require(tool.schema["properties"] as? [String: Any])
        let sort = try #require(props["sort"] as? [String: Any])
        let legal = try #require(sort["enum"] as? [String],
                                 "sorts stated in prose was the recorded defect; enum is the fix")
        #expect(Set(legal) == Set(SessionSort.allCases.map(\.rawValue)))
    }

    /// The bridge hazard, as a regression test: every registry parameter must be admitted
    /// by the global flag allow-list, or the CLI rejects a flag the declaration grants.
    /// `--since` failed exactly this way on its first real invocation.
    @Test("every registry parameter is admitted by the CLI flag allow-list")
    func registryFlagsAreAllowed() {
        for cmd in registryCommands() {
            for p in cmd.params {
                #expect(CLI_VALUED_FLAGS.contains(p.name),
                        "\(cmd.verb) declares '\(p.name)' but the allow-list rejects --\(p.name)")
            }
        }
    }

    @Test("registry verbs appear in CLI_VERBS, and tool names collide with no built-in")
    func registrySurfacesConsistent() {
        let verbs = Set(CLI_VERBS.map(\.verb))
        let builtinTools = Set(mcpTools().map(\.name))
        for cmd in registryCommands() {
            #expect(verbs.contains(cmd.verb),
                    "\(cmd.verb): a registry verb missing from CLI_VERBS is invisible in --help")
            #expect(!builtinTools.contains(cmd.toolName),
                    "\(cmd.toolName): a registry tool shadowing a built-in would be dispatch-order-dependent")
        }
    }

    // MARK: time windows

    private let noon = Date(timeIntervalSince1970: 1_756_100_000)   // fixed instant

    @Test("relative windows subtract exactly what they say")
    func relativeWindows() {
        let now = noon
        #expect(parseSinceWindow("30m", now: now) == Int(now.timeIntervalSince1970) - 1800)
        #expect(parseSinceWindow("3h", now: now) == Int(now.timeIntervalSince1970) - 10800)
        #expect(parseSinceWindow("7d", now: now) == Int(now.timeIntervalSince1970) - 604800)
        #expect(parseSinceWindow("45m", now: now) == Int(now.timeIntervalSince1970) - 2700)
    }

    /// The distinction called out when the feature was proposed: at 09:00, "today" is a
    /// nine-hour window, not twenty-four.
    @Test("today means local midnight, not a 24-hour window")
    func todayIsMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let since = parseSinceWindow("today", now: noon, calendar: cal)
        #expect(since == Int(cal.startOfDay(for: noon).timeIntervalSince1970))
        #expect(since != Int(noon.timeIntervalSince1970) - 86400,
                "today collapsed into 24h — the exact conflation this parser exists to avoid")
    }

    @Test("all and empty mean no bound; garbage means nil, which the command reports")
    func sentinelAndGarbage() {
        #expect(parseSinceWindow("all") == nil)
        #expect(parseSinceWindow("") == nil)
        #expect(parseSinceWindow("yesterdayish") == nil)
        #expect(parseSinceWindow("0m") == nil, "a zero-length window is not a window")
        #expect(parseSinceWindow("-5h") == nil)
    }

    /// THE headline regression test, previously missing: the Buddhist-calendar bug only
    /// fires when the CALLER's calendar is Buddhist (Calendar.current on a Thai-locale
    /// machine), and the old test injected gregorian — the one calendar under which the
    /// broken and fixed code were identical. Under Buddhist reckoning "2026-08-20" must
    /// still mean CE 2026: the pre-fix code read it as BE 2026 = CE 1483, an epoch five
    /// centuries deep that matched every row while the footer printed the window
    /// confidently. A fix without this test reverts silently.
    @Test("an ISO date under a Buddhist-calendar caller still means the Gregorian year")
    func isoDateSurvivesBuddhistCaller() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let since = try #require(parseSinceWindow("2026-08-20", now: noon, calendar: buddhist))
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = buddhist.timeZone
        let comps = greg.dateComponents([.year], from: Date(timeIntervalSince1970: Double(since)))
        #expect(comps.year == 2026,
                "parsed as \(comps.year ?? 0) — BE/CE conflation matches every row in the index")
    }

    /// ICU's `yyyy` is a minimum width and short months roll over — both re-open the
    /// all-rows deception through a different door, so both must refuse.
    @Test("short years and rolled-over dates refuse instead of matching everything")
    func isoRejectsWidthAndRollover() {
        #expect(parseSinceWindow("26-08-25") == nil, "year 26 is an epoch that matches all rows")
        #expect(parseSinceWindow("999-08-25") == nil)
        #expect(parseSinceWindow("0000-01-01") == nil)
        #expect(parseSinceWindow("2026-02-29") == nil, "2026 is not a leap year — rollover to Mar 1 is a different window than the one echoed")
        #expect(parseSinceWindow("2026-04-31") == nil)
        #expect(parseSinceWindow("2026-08-20") != nil, "the legitimate case must keep working")
    }

    @Test("an ISO date is that day's local midnight")
    func isoDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let since = parseSinceWindow("2026-08-20", now: noon, calendar: cal)
        #expect(since != nil)
        if let since {
            let d = Date(timeIntervalSince1970: Double(since))
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: d)
            #expect(comps.year == 2026 && comps.month == 8 && comps.day == 20 && comps.hour == 0)
        }
    }
}
