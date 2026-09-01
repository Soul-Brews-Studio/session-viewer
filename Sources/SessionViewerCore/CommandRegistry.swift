// CommandRegistry.swift — one declaration per command; the CLI verb and the MCP tool are
// both derived from it, so they cannot drift.
//
// This is the Runtime Command Registry a 3-judge panel chose 3–1 over build-time codegen
// and schema-down derivation, landing now because its stated blocker — "wait for the next
// genuinely new command" — arrived: the time-window filter (`--since 30m|3h|today|7d`) is
// that command, and it ships here as the registry's first occupant, owning `list` (CLI)
// and `list_sessions` (MCP) end to end.
//
// The judges' grafts, all present:
//   • ONE VALIDATOR, not two parsers (schema-down's framing): argv and MCP JSON both
//     become [String: Any] and pass through the same `validate` — "both surfaces enforce
//     the same rules" is true by construction, not by review.
//   • Typed choice with no force-unwrap: `.choice` carries its legal values, rendered from
//     a closed CaseIterable enum at the declaration site. An illegal value is a refusal
//     with the legal list, never a crash of a running MCP server.
//   • Strict coercion: `--limit abc` is an error, not a silent fall to the default — the
//     `--self-test` failure shape, one layer down, closed.
//   • Process-owning verbs are STRUCTURALLY absent: a RegistryCommand returns
//     CommandOutput; serve/tail/mcp never fit its type and stay in main.swift's switch.
//   • Output carries `structured` alongside text, so MCP gets data and the CLI gets prose
//     without `if surface == .cli` branches growing inside handlers.
//
// What the registry does NOT do (stated, because pretending otherwise is how surfaces
// rot): it cannot force main.swift's dispatch to consult it — that wiring is one line in
// the executable, asserted by the smoke test in SurfaceInvariantTests as far as a test
// target can reach.

import Foundation

// MARK: - Declaration

public enum ParamKind {
    case string
    /// Bounded integer. The bounds are part of the declaration because SQLite gives
    /// `LIMIT -5` a meaning nobody asked for — NO limit — so `list --limit -5` dumped the
    /// entire 3,296-row corpus (probed, not guessed). A bound violated is a refusal naming
    /// the range, on both surfaces, from the one validator.
    case integer(min: Int?, max: Int?)
    case bool
    /// Legal values, rendered from a closed enum at the declaration site — the same
    /// discipline SessionSort uses for ORDER BY: the string never comes from the caller.
    case choice([String])

    /// Sugar so an unbounded int stays terse at declaration sites.
    public static var int: ParamKind { .integer(min: nil, max: nil) }
    public static func int(min: Int? = nil, max: Int? = nil) -> ParamKind {
        .integer(min: min, max: max)
    }
}

public struct CommandParam {
    let name: String
    let help: String
    let kind: ParamKind
    let defaultValue: Any?
    let required: Bool

    init(_ name: String, _ kind: ParamKind, _ help: String,
         default defaultValue: Any? = nil, required: Bool = false) {
        self.name = name
        self.kind = kind
        self.help = help
        self.defaultValue = defaultValue
        self.required = required
    }
}

public struct CommandContext {
    public let dbPath: String
    public let root: String
}

public struct CommandOutput {
    /// What a person reads. The CLI prints exactly this.
    public let text: String
    /// What a model consumes. MCP returns text too, but a structured payload beside it
    /// means adding `--json` later is a serializer, not a rewrite.
    public let structured: [String: Any]?
    /// A refusal, not a result. MCP sets `isError: true` from this and the CLI exits 2 —
    /// without it, every validation failure over MCP looked like a SUCCESSFUL tool result
    /// ("error: …" as ordinary text), and `list --since garbage` printed to stdout and
    /// exited 0 while `--limit abc` exited 2: two error contracts in one binary.
    public var isError: Bool = false
}

public struct RegistryCommand {
    /// CLI verb (`list`) — must appear in CLI_VERBS so usage keeps naming it.
    public let verb: String
    /// MCP tool name (`list_sessions`) — verbs and tool names have different conventions,
    /// and pretending otherwise would break every already-installed client.
    public let toolName: String
    public let title: String
    public let summary: String
    public let params: [CommandParam]
    public let run: ([String: Any], CommandContext) -> CommandOutput
}

// MARK: - The one validator

/// Validate raw arguments — from EITHER surface — against a declaration.
///
/// Returns the coerced, defaulted argument map, or a human-readable refusal. Unknown keys
/// are rejected: a misspelled parameter that silently falls to its default is the
/// `--self-test` bug, and it does not get to exist here on either surface.
/// A refusal, as an Error so it fits Result. The message IS the interface.
struct ValidationRefusal: Error { let message: String }

func validateArgs(_ raw: [String: Any], against params: [CommandParam],
                  commandName: String) -> Result<[String: Any], ValidationRefusal> {
    let declared = Set(params.map(\.name))
    for k in raw.keys where !declared.contains(k) {
        return .failure(ValidationRefusal(message: "\(commandName): unknown parameter '\(k)'. Known: \(declared.sorted().joined(separator: ", "))"))
    }

    var out: [String: Any] = [:]
    for p in params {
        guard let v = raw[p.name] else {
            if p.required { return .failure(ValidationRefusal(message: "\(commandName): missing required parameter '\(p.name)'")) }
            if let d = p.defaultValue { out[p.name] = d }
            continue
        }
        switch p.kind {
        case .string:
            guard let s = coerceString(v) else {
                return .failure(ValidationRefusal(message: "\(commandName): '\(p.name)' must be a string"))
            }
            out[p.name] = s
        case .integer(let lo, let hi):
            // Strict: "abc" refuses. Accepts a real Int (MCP JSON) or a numeric string
            // (argv) — both surfaces, one rule.
            let parsed: Int
            if let i = v as? Int { parsed = i }
            else if let s = v as? String, let i = Int(s) { parsed = i }
            else { return .failure(ValidationRefusal(message: "\(commandName): '\(p.name)' must be an integer, got '\(v)'")) }
            if let lo, parsed < lo {
                return .failure(ValidationRefusal(message: "\(commandName): '\(p.name)' must be ≥ \(lo), got \(parsed)"))
            }
            if let hi, parsed > hi {
                return .failure(ValidationRefusal(message: "\(commandName): '\(p.name)' must be ≤ \(hi), got \(parsed)"))
            }
            out[p.name] = parsed
        case .bool:
            if let b = v as? Bool { out[p.name] = b }
            else if let s = v as? String { out[p.name] = (s == "true" || s == "1" || s == "") }
            else { return .failure(ValidationRefusal(message: "\(commandName): '\(p.name)' must be a boolean")) }
        case .choice(let legal):
            guard let s = coerceString(v), legal.contains(s) else {
                return .failure(ValidationRefusal(message: "\(commandName): '\(p.name)' must be one of \(legal.joined(separator: " | ")), got '\(coerceString(v) ?? "\(v)")'"))
            }
            out[p.name] = s
        }
    }
    return .success(out)
}

private func coerceString(_ v: Any) -> String? {
    if let s = v as? String { return s }
    if let i = v as? Int { return String(i) }
    return nil
}

// MARK: - Derivations: MCP tool + CLI flags, from the same declaration

extension RegistryCommand {
    /// The MCP tool, derived. `choice` becomes a JSON Schema `enum`, which fixes the
    /// list_sessions defect the inventory recorded: legal sorts stated in prose where a
    /// model cannot parse them.
    var mcpTool: MCPTool {
        var props: [String: Any] = [:]
        for p in params {
            var prop: [String: Any] = ["description": p.help]
            switch p.kind {
            case .string: prop["type"] = "string"
            case .integer(let lo, let hi):
                prop["type"] = "integer"
                if let lo { prop["minimum"] = lo }
                if let hi { prop["maximum"] = hi }
            case .bool:   prop["type"] = "boolean"
            case .choice(let legal):
                prop["type"] = "string"
                prop["enum"] = legal
            }
            if let d = p.defaultValue { prop["default"] = d }
            props[p.name] = prop
        }
        return MCPTool(
            name: toolName, title: title, description: summary,
            schema: ["type": "object", "properties": props,
                     "required": params.filter(\.required).map(\.name)])
    }
}

// MARK: - The registry

/// Every registry command. Grows one entry per migrated or new command; order is the
/// order `--help` and tools/list present them in.
func registryCommands() -> [RegistryCommand] {
    [listSessionsCommand(), importIndexCommand()]
}

// MARK: - Known roots (seed of the roots registry, TODO.md "Next")

/// Named corpus roots the sync command can import. Read from `<db-dir>/roots.json`
/// (`[{"name": "...", "path": "..."}]`, the workers.json pattern: data beside the index,
/// not code) — falling back to the built-in pair this machine actually has. The `root`
/// parameter's choice list stays static ("all"/"local"/"remote") until the roots registry
/// grows a dynamic schema; an unknown name in roots.json is reachable via "all".
func knownSessionRoots(ctx: CommandContext) -> [(name: String, path: String)] {
    let dir = (ctx.dbPath as NSString).deletingLastPathComponent
    if let data = FileManager.default.contents(atPath: dir + "/roots.json"),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
        let roots = arr.compactMap { r -> (String, String)? in
            guard let n = r["name"], let p = r["path"] else { return nil }
            return (n, p)
        }
        if !roots.isEmpty { return roots }
    }
    return [("local", ctx.root), ("remote", "/Users/remote/.claude/projects")]
}

/// `sync` / `import_index` — the registry's second occupant, and the first one that
/// WRITES. The CLI verb is deliberately NOT `import`: that verb's `--root <path>`
/// contract predates the registry and must keep taking arbitrary paths; this one takes
/// NAMED roots so an MCP client can never point the indexer at an arbitrary directory.
func importIndexCommand() -> RegistryCommand {
    RegistryCommand(
        verb: "sync",
        toolName: "import_index",
        title: "Import new/changed transcripts into the index",
        summary: """
            Incremental import over the known corpus roots (local = this account, remote = \
            remote@m5's 29k-file corpus, all = both). `since` bounds which files are even \
            considered, by file mtime: 7d = touched this week, today, 30m, Nm/Nh/Nd, \
            YYYY-MM-DD. The (path, mtime, size) diff still skips unchanged files inside \
            the window, so this is always safe to re-run.
            """,
        params: [
            // Named `corpus`, NOT `root`: `--root` is a GLOBAL flag main.swift consumes
            // before the registry validator runs, so a param named `root` can never
            // receive a CLI value — it silently defaults and broadens scope (observed:
            // `sync --root local` imported both corpora). Same bridge-hazard family as
            // the first occupant's --since rejection, opposite direction.
            CommandParam("corpus", .choice(["all", "local", "remote"]),
                         "Which corpus root(s) to import.", default: "all"),
            CommandParam("since", .string,
                         "Only consider files modified in this window (default: no bound).",
                         default: "all"),
        ],
        run: { args, ctx in
            let rootArg = args["corpus"] as? String ?? "all"
            let sinceArg = args["since"] as? String ?? "all"
            let since = parseSinceWindow(sinceArg)
            if since == nil && !(sinceArg == "all" || sinceArg.isEmpty) {
                let msg = "sync: cannot parse since '\(sinceArg)' — use 30m, 3h, today, 7d, Nm/Nh/Nd or YYYY-MM-DD"
                return CommandOutput(text: "error: \(msg)", structured: ["error": msg],
                                     isError: true)
            }
            let cutoff = since   // parseSinceWindow already returns epoch seconds

            let roots = knownSessionRoots(ctx: ctx)
                .filter { rootArg == "all" || $0.name == rootArg }
            guard !roots.isEmpty else {
                let msg = "sync: no known root named '\(rootArg)'"
                return CommandOutput(text: "error: \(msg)", structured: ["error": msg],
                                     isError: true)
            }

            var text = ""
            var structured: [[String: Any]] = []
            var totalNew = 0, totalChanged = 0, totalFailed = 0
            for r in roots {
                guard FileManager.default.fileExists(atPath: r.path) else {
                    text += "\(r.name): root missing on disk (\(r.path)) — skipped\n"
                    structured.append(["root": r.name, "skipped": "missing"])
                    continue
                }
                let s = runImport(dbPath: ctx.dbPath, root: r.path, sinceCutoff: cutoff)
                totalNew += s.new; totalChanged += s.changed; totalFailed += s.failed
                text += "\(r.name): run \(s.runId) — \(s.new) new, \(s.changed) changed, "
                    + "\(s.skipped) unchanged, \(s.failed) failed\n"
                structured.append(["root": r.name, "run_id": s.runId, "new": s.new,
                                   "changed": s.changed, "skipped": s.skipped,
                                   "failed": s.failed])
            }
            let scope = cutoff != nil ? " · files touched in last \(sinceArg)" : ""
            text += "total: \(totalNew) new, \(totalChanged) changed\(scope)"
            return CommandOutput(text: text,
                                 structured: ["roots": structured, "new": totalNew,
                                              "changed": totalChanged,
                                              "failed": totalFailed],
                                 isError: totalFailed > 0)
        })
}

/// MCP entries for the registry — appended to the surface by `fullMCPToolList`.
func registryTools() -> [MCPTool] {
    registryCommands().map(\.mcpTool)
}

/// Dispatch an MCP call if the name belongs to the registry. nil = not ours.
func callRegistryTool(name: String, args: [String: Any], dbPath: String, root: String)
    -> CommandOutput? {
    guard let cmd = registryCommands().first(where: { $0.toolName == name }) else { return nil }
    switch validateArgs(args, against: cmd.params, commandName: name) {
    case .failure(let r):
        return CommandOutput(text: "error: \(r.message)", structured: ["error": r.message],
                             isError: true)
    case .success(let validated):
        return cmd.run(validated, CommandContext(dbPath: dbPath, root: root))
    }
}

/// Dispatch a CLI invocation if the verb belongs to the registry. Returns false when the
/// verb is not registered, so main.swift falls through to its switch. Exits 2 on a
/// validation refusal — same contract as the flag allow-list.
public func runRegistryCLI(verb: String, argv: [String], dbPath: String, root: String) -> Bool {
    guard let cmd = registryCommands().first(where: { $0.verb == verb }) else { return false }

    // argv → raw map, using ONLY the declared names: `--sort mtime --limit 40` becomes
    // ["sort": "mtime", "limit": "40"]. The global allow-list has already rejected
    // unknown flags, so what reaches here is at worst a flag belonging to another verb —
    // which the validator's unknown-key rule then names precisely.
    var raw: [String: Any] = [:]
    let declared = Set(cmd.params.map(\.name))
    // Global flags that legitimately ride alongside any verb and are consumed by
    // main.swift's own `flag()` reads — never the registry's business.
    let globals: Set<String> = ["db", "root"]
    // One predicate, applied to EVERY branch that consumes a value. The first version
    // applied it to declared params but skipped globals with an unconditional `i += 2` —
    // so `list --root --sort events` swallowed `--sort` whole and ran at defaults with
    // exit 0, printing "sort mtime desc" for a run that asked for events: the exact
    // confidently-wrong silent fallback this file's own doc-comment vows to kill, born in
    // the commit that killed it elsewhere. The guard existed three lines below the bug.
    func valueFollows(_ i: Int) -> Bool {
        i + 1 < argv.count && !argv[i + 1].hasPrefix("--")
    }
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("--") {
            let name = String(a.dropFirst(2))
            if globals.contains(name) {
                // A global with no value is refused, not skipped-by-one: `flag()` in
                // main.swift resolves `--db --limit` to the literal "--limit" and CREATES
                // a sqlite file by that name in the cwd — two fossils of exactly that
                // ("--since", "''") were found lying in the repo root.
                guard valueFollows(i) else {
                    FileHandle.standardError.write(
                        "\(cmd.verb): flag --\(name) needs a value\n".data(using: .utf8)!)
                    exit(2)
                }
                i += 2; continue
            }
            // UNDECLARED comes first: `list --verbose` must get the unknown-parameter
            // refusal (which names the legal set), not "needs a value" — a wrong
            // diagnosis that sends the user hunting for a value that will never help.
            guard declared.contains(name) else { raw[name] = argv.count > i + 1 ? argv[i + 1] : ""; break }
            let boolParam: Bool
            if case .some(.bool) = cmd.params.first(where: { $0.name == name })?.kind {
                boolParam = true
            } else { boolParam = false }
            if valueFollows(i) {
                raw[name] = argv[i + 1]; i += 2; continue
            }
            // No value follows. Presence is only a value for a declared BOOL param —
            // for anything else, `list --since --limit 3` silently becoming "no window"
            // is the --self-test silent-fallback shape, and it refuses instead.
            if boolParam { raw[name] = ""; i += 1; continue }
            FileHandle.standardError.write(
                "\(cmd.verb): flag --\(name) needs a value\n".data(using: .utf8)!)
            exit(2)
        }
        i += 1
    }

    switch validateArgs(raw, against: cmd.params, commandName: cmd.verb) {
    case .failure(let r):
        FileHandle.standardError.write("\(r.message)\n".data(using: .utf8)!)
        exit(2)
    case .success(let validated):
        let out = cmd.run(validated, CommandContext(dbPath: dbPath, root: root))
        if out.isError {
            FileHandle.standardError.write("\(out.text)\n".data(using: .utf8)!)
            exit(2)
        }
        print(out.text)
        return true
    }
}

// MARK: - Time windows

/// "30m" / "3h" / "7d" / "today" / "2026-08-20" → epoch lower bound, or nil for
/// unparseable input. `now` injected so tests assert real arithmetic, not sleep.
///
/// "today" is LOCAL MIDNIGHT, deliberately distinct from "24h": at 09:00, `today` is a
/// 9-hour window. That is what the word means on a clock, and conflating it with 24h was
/// called out as the trap when this feature was first proposed.
public func parseSinceWindow(_ s: String, now: Date = Date(),
                             calendar: Calendar = .current) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    if t.isEmpty || t == "all" { return nil }
    if t == "today" {
        return Int(calendar.startOfDay(for: now).timeIntervalSince1970)
    }
    if t.count >= 2, let unit = t.last, let n = Int(t.dropLast()), n > 0 {
        // CHECKED multiply. `n * 86400` on hostile input ("999999999999999999d") is an
        // overflow TRAP in Swift — a crash of whatever process is parsing, including a
        // running MCP server handed the string by a model. Overflow means the window
        // reaches before the epoch anyway, so it degrades to nil like any other
        // unparseable input rather than taking the process down.
        let factor: Int
        switch unit {
        case "m": factor = 60
        case "h": factor = 3600
        case "d": factor = 86400
        default:  return nil
        }
        let (seconds, overflow) = n.multipliedReportingOverflow(by: factor)
        if overflow { return nil }
        return Int(now.timeIntervalSince1970) - seconds
    }
    // ISO date: a lower bound at that day's local midnight.
    //
    // GREGORIAN, EXPLICITLY — never the caller's calendar. On a Thai-locale machine
    // Calendar.current is Buddhist, and "2026-08-20" parsed under it is BE 2026 = CE 1483:
    // an epoch five centuries in the past, so the "filter" matched every row while the
    // footer confidently printed "active in last 2026-08-20". Serve.swift's isoNow()
    // recorded this exact trap ("never the machine's Buddhist calendar") and this parser
    // walked into it anyway. Only the TIME ZONE comes from the caller — the day boundary
    // is local; the numbering system is not negotiable in an ISO string.
    var greg = Calendar(identifier: .gregorian)
    greg.timeZone = calendar.timeZone
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    f.calendar = greg
    f.timeZone = greg.timeZone
    if let d = f.date(from: t) {
        // ROUND-TRIP, then BOUND — two deceptions the parse alone lets through:
        //
        // ICU's `yyyy` is a MINIMUM width, and short months roll over: "26-08-25" parsed
        // as year 26, and "2026-02-29" quietly became March 1st. Either way the footer
        // printed "active in last <the string you typed>" while filtering on a different
        // instant — for year 26, an epoch so deep that all 1,984 rows matched, the same
        // all-rows deception the Buddhist fix just closed, re-entered through width.
        // Formatting the parsed date back and demanding the exact input catches both in
        // one check: a rolled-over or short-year date never round-trips.
        guard f.string(from: d) == t else { return nil }
        // And a sanity window: session transcripts did not exist before 2000 and a bound
        // 100 years out catches "20260-01-01"-class typos that DO round-trip.
        let year = greg.component(.year, from: d)
        guard (2000...2100).contains(year) else { return nil }
        return Int(d.timeIntervalSince1970)
    }
    return nil
}

// MARK: - The first occupant: list / list_sessions with time windows

func listSessionsCommand() -> RegistryCommand {
    RegistryCommand(
        verb: "list",
        toolName: "list_sessions",
        title: "List indexed sessions",
        summary: """
            Most recent sessions in the index, newest first by default. `since` narrows to \
            sessions ACTIVE in a window — written to, not started, so a long-running \
            session stays visible: 30m ≈ running right now, today = since local midnight, \
            7d = this week. Also accepts Nm/Nh/Nd and YYYY-MM-DD.
            """,
        params: [
            CommandParam("sort", .choice(SessionSort.allCases.map(\.rawValue)),
                         "Sort key.", default: SessionSort.mtime.rawValue),
            CommandParam("dir", .choice(SortDirection.allCases.map(\.rawValue)),
                         "Sort direction.", default: SortDirection.desc.rawValue),
            CommandParam("tier", .choice(["all", "session", "subagent", "workflow_agent"]),
                         "File tier filter.", default: "all"),
            CommandParam("since", .string,
                         "Activity window: 30m, 3h, today, 7d, Nm/Nh/Nd, or YYYY-MM-DD.",
                         default: "all"),
            CommandParam("limit", .int(min: 1, max: 5000), "Max rows.", default: 40),
        ],
        run: { args, ctx in
            // The choice params were validated against the enums' own rawValues, so these
            // lookups cannot fail — and if a refactor ever breaks that, the fallback is
            // the default, not a crash (the graft that killed `E(rawValue:)!`).
            let sort = SessionSort(rawValue: args["sort"] as? String ?? "") ?? .mtime
            let dir = SortDirection(rawValue: args["dir"] as? String ?? "") ?? .desc
            let tierArg = args["tier"] as? String ?? "all"
            let sinceArg = args["since"] as? String ?? "all"
            let limit = args["limit"] as? Int ?? 40

            let since = parseSinceWindow(sinceArg)
            if since == nil && !(sinceArg == "all" || sinceArg.isEmpty) {
                let msg = "list: cannot parse since '\(sinceArg)' — use 30m, 3h, today, 7d, Nm/Nh/Nd or YYYY-MM-DD"
                return CommandOutput(text: "error: \(msg)", structured: ["error": msg],
                                     isError: true)
            }

            let db = DB(path: ctx.dbPath)
            let rows = fetchSessions(db: db,
                                     tier: tierArg == "all" ? nil : tierArg,
                                     sort: sort, direction: dir,
                                     since: since, limit: limit)

            var text = ""
            var structured: [[String: Any]] = []
            for r in rows {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd HH:mm"
                let mod = f.string(from: Date(timeIntervalSince1970: Double(r.mtime)))
                text += "\(padR(r.source == "codex" ? "cdx" : "cc", 4))"
                    + "\(padR(r.tier, 15))\(padR(String(r.uuid.prefix(8)), 10))"
                    + "\(padL("\(r.eventCount)", 7)) ev  \(padR(mod, 17))"
                    + "\(r.description?.prefix(60) ?? "—")\n"
                structured.append([
                    "uuid": r.uuid, "tier": r.tier, "source": r.source,
                    "events": r.eventCount, "modified": mod,
                    "description": r.description ?? "",
                ])
            }
            let scope = since != nil ? " · active in last \(sinceArg)" : ""
            text += "\(rows.count) session(s)\(scope) · sort \(sort.rawValue) \(dir.rawValue)"
            return CommandOutput(text: text,
                                 structured: ["sessions": structured, "count": rows.count])
        })
}
