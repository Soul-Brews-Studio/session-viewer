// main.swift — dispatch ONLY. `diff` / `import` / `list` / `search` / `live` / `tail` run
// headless (called by the justfile); no argument launches the SwiftUI window.
//
// Every subcommand body lives in the SessionViewerCore library, not here. That split is a
// build-layout requirement, not a preference: a SwiftPM `executableTarget` cannot be
// imported by a `testTarget`, so code that only lives in this target can never be unit
// tested. This file is what is left over — top-level code, which is the one thing a
// library target cannot hold.

import Foundation
import SessionViewerCore

let args = CommandLine.arguments

func flag(_ name: String, default def: String) -> String {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return def }
    return args[i + 1]
}

let defaultRoot = "\(NSHomeDirectory())/.claude/projects"
let defaultDB = FileManager.default.currentDirectoryPath + "/.data/sessions.db"

// Reject unknown flags before dispatching.
//
// `flag()` above silently returns its default for anything it does not find, so a typo has
// never been an error — it has been a SILENT FALLBACK TO THE DEFAULT BEHAVIOUR. That is not
// hypothetical: `tail --self-test` (the real flag is `--selftest`) fell through to the
// unmodified `tail`, whose default is follow-forever, and sat blocked for 94 minutes looking
// exactly like a hung app. The same shape is now far more dangerous, because
// `embed --chunk-word 100` (missing the s) would silently rebuild the whole corpus at the
// default geometry — a ~30-minute mistake with no error at the point it was made.
//
// One allow-list for the whole CLI rather than per-subcommand: a flag valid nowhere is
// always a mistake, and a flag valid for another subcommand is a mistake worth naming too.
// TailOptions.parse keeps its own stricter per-subcommand check.
// The verb table, flag allow-lists and usage text live in SessionViewerCore
// (CLISurface.swift) so the test target can hold them to their invariants — an
// executableTarget is untestable, and untestable lists are how the usage string
// drifted to five of seventeen verbs.
let VALUED_FLAGS = CLI_VALUED_FLAGS
let BOOLEAN_FLAGS = CLI_BOOLEAN_FLAGS
let VERBS = CLI_VERBS
func usageText() -> String { cliUsageText() }

// `--help` was rejected as an unknown flag with exit 2 — the allow-list runs before
// dispatch and has no entry for it. Handled here, before that check.
if args.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" || $0 == "help" }) {
    print(usageText())
    exit(0)
}

do {
    var i = 1
    while i < args.count {
        let a = args[i]
        guard a.hasPrefix("--") else { i += 1; continue }
        let name = String(a.dropFirst(2))
        if VALUED_FLAGS.contains(name) {
            // A valued flag with no value is an error HERE, not two layers down: skipping
            // it by two swallowed the NEXT flag (so `list --root --bogus` sailed past this
            // very allow-list), and letting it through fed `flag()` a value of "--limit",
            // which DB() then used to CREATE a sqlite file named "--limit" in the cwd.
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                FileHandle.standardError.write(
                    "flag --\(name) needs a value\n".data(using: .utf8)!)
                exit(2)
            }
            i += 2; continue
        }
        if BOOLEAN_FLAGS.contains(name) { i += 1; continue }
        let known = VALUED_FLAGS.union(BOOLEAN_FLAGS).sorted().map { "--\($0)" }.joined(separator: " ")
        FileHandle.standardError.write(
            "unknown flag: \(a)\nknown flags: \(known)\n".data(using: .utf8)!)
        exit(2)
    }
}

let subcommand = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil

// REGISTRY FIRST. A verb the registry owns is declared once and serves both surfaces;
// the switch below is the legacy dispatch, shrinking one verb at a time as they migrate.
if let verb = subcommand,
   runRegistryCLI(verb: verb, argv: Array(args.dropFirst(2)),
                  dbPath: flag("db", default: defaultDB),
                  root: flag("root", default: defaultRoot)) {
    exit(0)
}

switch subcommand {
case "diff":
    runDiff(dbPath: flag("db", default: defaultDB), root: flag("root", default: defaultRoot))
case "import":
    // --force rebuilds every row: use it after a schema change that adds an index, since
    // the (path, mtime, size) diff will otherwise skip unchanged files and leave the new
    // index permanently empty while reporting success.
    runImport(dbPath: flag("db", default: defaultDB),
              root: flag("root", default: defaultRoot),
              force: args.contains("--force"))
case "graph":
    // Headless twin of the Graph tab. The GPU renders the layout; the STRUCTURE — beats,
    // tools, targets, and which targets more than one beat came back to — is computed on
    // the CPU by `buildSessionGraph`, and that is the part worth checking. A picture of a
    // wrong graph still looks like a graph.
    runGraphCLI(path: flag("path", default: ""),
                top: Int(flag("top", default: "12")) ?? 12,
                listNodes: args.contains("--nodes"))
case "embed":
    // Headless twin of the ML/NL index panel. Slow by nature (~35 ms/text measured), so
    // --limit exists to make a bounded run possible.
    let ePlan = ChunkPlan(words: Int(flag("chunk-words", default: "100")) ?? 100,
                          stride: Int(flag("chunk-stride", default: "50")) ?? 50)
    // --classes is parsed BEFORE the --dump branch on purpose: the first layout parsed it
    // after, which made the flag unreachable on the dump path — a provider seam that could
    // not be told which corpus to dump.
    let clsArg = flag("classes", default: "chat")
    let embedClasses: [VectorClass]
    switch clsArg {
    case "chat":  embedClasses = [.chat]
    case "tools": embedClasses = [.tools]
    case "all":   embedClasses = VectorClass.allCases
    default:
        FileHandle.standardError.write(
            "unknown --classes value: \(clsArg)\nknown: chat tools all\n".data(using: .utf8)!)
        exit(2)
    }
    if args.contains("--dump") {
        // The provider seam. Chunking happens here so both halves agree what a chunk is.
        runDumpCLI(dbPath: flag("db", default: defaultDB),
                   model: flag("model", default: "apple-nlce/en/r1/512"),
                   plan: ePlan,
                   limit: Int(flag("limit", default: "0")) ?? 0,
                   classes: embedClasses)
        break
    }
    if args.contains("--load") {
        runLoadCLI(dbPath: flag("db", default: defaultDB),
                   model: flag("model", default: ""),
                   endpoint: args.contains("--in") ? flag("in", default: nil as String? ?? "") : nil,
                   plan: ePlan)
        break
    }
    runEmbedCLI(dbPath: flag("db", default: defaultDB),
                limit: Int(flag("limit", default: "0")) ?? 0,
                query: flag("query", default: ""),
                plan: ChunkPlan(words: Int(flag("chunk-words", default: "100")) ?? 100,
                                stride: Int(flag("chunk-stride", default: "50")) ?? 50),
                classes: embedClasses)
case "eval":
    // Retrieval measurement — keyword vs semantic on the same queries, same db.
    // Built BEFORE tuning anything else, because every knob added so far (trigram,
    // chunk geometry, mean-centering, model scoping) changed a number nobody could read.
    if args.contains("--generate") {
        generateEvalQueries(dbPath: flag("db", default: defaultDB),
                            outPath: flag("out", default: "eval/queries.jsonl"),
                            count: Int(flag("count", default: "12")) ?? 12)
    } else {
        runEval(dbPath: flag("db", default: defaultDB),
                queriesPath: flag("file", default: "eval/queries.jsonl"),
                verbose: args.contains("--verbose"))
    }
case "searches":
    // The search log as text — same table the Search tab's history panel reads.
    runSearchLogCLI(dbPath: flag("db", default: defaultDB),
                    limit: Int(flag("limit", default: "25")) ?? 25)
case "mcp":
    // MCP server over stdio, protocol 2026-07-28 (modern/stateless — no initialize
    // handshake). stdio rather than Streamable HTTP: no port, no Origin validation, no
    // auth surface — this fleet's own recorded verdict, and this binary is already a CLI.
    // NOTE: stdout is the protocol channel; diagnostics must go to stderr.
    runMCPServer(dbPath: flag("db", default: defaultDB), root: flag("root", default: defaultRoot))
case "tools":
    // The live MCP surface — what is exposed, where each tool comes from, and what it
    // costs. Same computation the app's MCP tab and GET /mcp/surface render.
    runSurfaceCLI(dbPath: flag("db", default: defaultDB), probe: !args.contains("--no-probe"))
case "upstreams":
    // What other MCP servers this one wraps, and whether they answer.
    runUpstreamsCLI(dbPath: flag("db", default: defaultDB))
case "codex":
    // What Codex has, without importing it. Reading before writing is the discipline this
    // whole project exists for — dig.py's glob bug is what it was built to avoid repeating.
    if args.contains("--import") {
        let s = runCodexImport(dbPath: flag("db", default: defaultDB),
                               codexRoot: flag("codex-root", default: defaultCodexRoot)) { done, total in
            if done % 50 == 0 {
                FileHandle.standardError.write("  … \(done)/\(total)\n".data(using: .utf8)!)
            }
        }
        print("codex import: \(s.new) new · \(s.changed) changed · \(s.skipped) skipped · \(s.failed) failed")
        print("parented:     \(s.parented) of \(s.files) linked to their parent thread")
        print("elapsed:      \(String(format: "%.1f", s.seconds))s")
    } else {
        runCodexScanCLI(root: flag("codex-root", default: defaultCodexRoot))
    }
case "scan":
    // Headless twin of the Database tab's "Scan structure" button.
    runScanCLI(root: flag("root", default: defaultRoot), dbPath: flag("db", default: defaultDB))
case "status":
    // Headless twin of the Database tab — same `readDBStatus`, so what that tab claims
    // about where the db is, whether it is new, and what Import would do is verifiable
    // without a window. Established pattern here: `tail`/`live`/`search` each exist
    // because a GUI-only code path is a code path nobody can test.
    // --codex-root threads through to the pruned/pending diff — hardcoding the default
    // there would resurrect all 627 phantom "pruned" rows the moment a non-default root
    // is in use, which is the exact lie this diff just stopped telling.
    runStatusCLI(dbPath: flag("db", default: defaultDB), root: flag("root", default: defaultRoot),
                 codexRoot: flag("codex-root", default: defaultCodexRoot))
case "search":
    // Headless twin of the app's search box: calls the SAME `searchEvents`, so the FTS5
    // input handling is testable without launching a window. It exists because that path
    // had a bug only the GUI could hit — a hyphenated term like `append-only` parsed as
    // FTS5 syntax and failed at sqlite3_step, which the row loop reads as "no rows", so
    // the box silently returned nothing instead of erroring.
    runSearchCLI(dbPath: flag("db", default: defaultDB),
                 query: args.dropFirst(2).first(where: { !$0.hasPrefix("--") }) ?? "",
                 limit: Int(flag("limit", default: "20")) ?? 20)
case "serve":
    // The app as a SERVER. Answers the "do we need a webview?" question a better way: the
    // native window keeps its native list, and a browser becomes a SECOND CLIENT of the
    // same stream — full CSS in the browser, nothing replaced, and the stream can reach
    // another machine, which a WebView never could.
    runServe(root: flag("root", default: defaultRoot),
             dbPath: flag("db", default: defaultDB),
             port: UInt16(flag("port", default: "8779")) ?? 8779,
             windowSeconds: Int(flag("window", default: "300")) ?? 300,
             webRoot: flag("web", default: FileManager.default.currentDirectoryPath + "/web"))
case "live":
    // Headless twin of the app's Live tab: the same `scanLiveSessions` for the fleet list
    // and, with --attach FILE, the same `liveAttachTailer` the detail pane uses. Both the
    // scan cost and the "reads the delta, not the file" claim are measurable here without
    // launching a window.
    //
    // --run-model runs LiveFleetModel itself on a runloop (no window) and asserts every
    // publish lands on the main thread — the threading contract the UI depends on.
    // (Renamed from --model: that name is now VALUED, for `embed --load --model NAME`, and
    // a flag cannot be both boolean and valued. The dev-only path gets the longer name.)
    if args.contains("--run-model") {
        runLiveModel(root: flag("root", default: defaultRoot),
                     dbPath: flag("db", default: defaultDB),
                     windowSeconds: Int(flag("window", default: "300")) ?? 300,
                     attachPath: flag("attach", default: ""),
                     seconds: Double(flag("for", default: "15")) ?? 15)
    } else {
        runLive(root: flag("root", default: defaultRoot),
                dbPath: flag("db", default: defaultDB),
                windowSeconds: Int(flag("window", default: "300")) ?? 300,
                repeats: Int(flag("repeat", default: "1")) ?? 1,
                intervalSeconds: Double(flag("interval", default: "2")) ?? 2,
                attachPath: flag("attach", default: ""))
    }
case "tail":
    // RECONCILED (the follow-up the previous comment here asked for). There was briefly a
    // second `--path FILE` shape backed by Live.swift's own `LiveTail`, written before
    // Tail.swift existed. Tail.swift landed; LiveTail is deleted, and the app's live detail
    // pane now drives Tail.swift's `SessionTailer` directly — so there is ONE tailer, and
    // `tail --selftest` proves the behaviour the window relies on.
    //
    //   tail  → TailWatcher: follows EVERY currently-live file (mtime within --window),
    //           persists per-file byte offsets in session_tail_state so a restart resumes,
    //           and holds back a trailing partial line instead of parsing a half-written one.
    runTail(options: TailOptions.parse(args, defaultRoot: defaultRoot, defaultDB: defaultDB))
// "list" is REGISTRY-OWNED (CommandRegistry.swift) — dispatched before this switch, so
// the verb never reaches it. The case was deleted; a dead branch here would be the drift
// restarting under a new name.
case .some(let other):
    FileHandle.standardError.write(
        "unknown subcommand: \(other)\n\n\(usageText())".data(using: .utf8)!)
    exit(2)
case nil:
    launchApp(dbPath: flag("db", default: defaultDB))
}
