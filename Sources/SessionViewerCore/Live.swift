// Live.swift — the LIVE FLEET view's data layer: which sessions are being written to
// right now, machine-wide, and an incremental tail of the selected one.
//
// This file owns POLICY and PRESENTATION for that view. It owns no file-reading
// mechanics — those are Tail.swift's:
//
//   • liveness      → `liveFiles(root:withinSeconds:)`, which is itself a filter over
//                     `discoverFiles` (Ingest.swift), the verified three-tier walk. There
//                     is exactly one definition of "live" and one of "discovered".
//   • tailing       → `SessionTailer`, byte-exact, holds back a trailing partial line,
//                     and `SessionTailer.alignedOffset` for the leading edge.
//
// (An earlier draft of this file carried its own minimal incremental reader, written when
// Tail.swift did not yet exist. It was deleted the moment Tail.swift landed rather than
// left to drift into a second, subtly different tailer.)
//
// The two measured facts behind the design:
//
//   1. Session .jsonl files are APPEND-ONLY — a file's head md5 stayed constant while it
//      grew 3825889 → 3850991 bytes. So the detail pane seeks to an offset and reads the
//      delta; it never re-reads the file. The p99 file is 39.6 MB and one was 39.8 MB and
//      LIVE while this was written.
//   2. Multi-session is the NORMAL case: 6 sessions writing concurrently at 21:48, and 13
//      live files (3 tiers, 3 repos) on the first run of `session-viewer live`. Hence a
//      fleet list, not a single-file follow.
//
// Threading: NOTHING here does IO on the main thread. `LiveFleetModel` owns a serial
// utility queue, runs the directory walk and the file reads there, and hands finished
// value types back to @Published properties on the main queue.
//
// Polling, not FSEvents/vnode: the reasoning is written out at length above
// `TailWatcher` in Tail.swift and applies identically here — the watch set is not a fixed
// set of files (workflow runs create new agent-*.jsonl mid-run), and writes are bursty at
// turn boundaries, so sub-second wakeup latency buys nothing anyone can perceive.

import Foundation
import Combine
import SQLite3

// MARK: - Heat: what the coloured dot means

/// How recently a live session wrote. Deliberately three coarse buckets, not a gradient —
/// the point of the dot is to be readable at a glance, and the exact age is printed as
/// text right next to it anyway.
enum LiveHeat {
    case hot     // ≤ 30 s — mid-turn, actively writing
    case warm    // ≤ 2 min — between turns, still alive
    case cool    // ≤ window — probably finishing or waiting on a human

    init(secondsSinceWrite s: Int) {
        if s <= 30 { self = .hot } else if s <= 120 { self = .warm } else { self = .cool }
    }

    var caption: String { caption(window: 300) }

    /// The `cool` bucket means "≤ the liveness window", so its caption is only correct for
    /// the window actually in force. It said "idle (≤5m)" unconditionally, which became
    /// wrong the moment the window could be widened — and a legend that misdescribes the
    /// dots is worse than no legend.
    func caption(window: Int) -> String {
        switch self {
        case .hot:  return "writing (≤30s)"
        case .warm: return "active (≤2m)"
        case .cool: return "idle (≤\(liveWindowLabel(window)))"
        }
    }
}

// MARK: - One live session

struct LiveSession: Identifiable, Equatable {
    let path: String
    let project: String          // real cwd when the index knows it, else the raw dirname
    let tier: String
    let sessionUUID: String
    let agentId: String?
    let workflowRunId: String?
    let size: Int
    let mtime: Int
    let secondsSinceWrite: Int
    /// "claude" or "codex" — which agent is writing this file. Both roots are watched, and
    /// on this machine Codex workers are frequently the ONLY thing live, so a fleet view
    /// that showed just `~/.claude/projects` would report an idle machine that was not.
    var source: String = "claude"

    var id: String { path }
    var heat: LiveHeat { LiveHeat(secondsSinceWrite: secondsSinceWrite) }

    /// Short human label: session prefix, plus the agent id for tier 2/3 rows (a workflow
    /// run puts dozens of agents under ONE session uuid, so the uuid alone is ambiguous).
    var label: String {
        let head = String(sessionUUID.prefix(8))
        guard let agentId else { return head }
        return "\(head) · \(agentId)"
    }
}

/// "4s" / "1m 07s" / "3m 21s" — the age is the whole point of the row, so it is spelled
/// out rather than left to a relative-date formatter that would say "less than a minute".
func liveAgo(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s)s" }
    return String(format: "%dm %02ds", s / 60, s % 60)
}

/// Which live rows arrived since the last scan, and when — the state behind the "just
/// appeared" highlight.
///
/// Pure so it can be tested: the interesting behaviour is all in the edge cases, and none
/// of them are observable by looking at the window.
///
/// - `suppress` covers the FIRST scan and a window change. In both, every row is new to the
///   view without any of them being newly started, and lighting all of them up says
///   nothing — a flash that fires on everything is indistinguishable from no flash.
/// - Entries for paths that are no longer live, or whose flash has finished, are dropped.
///   Without that this map would accumulate one entry per session ever seen, for a view
///   that is left open for days.
/// - An existing entry is never refreshed: a row that keeps writing is not re-arriving, and
///   re-stamping it would leave a busy session permanently lit.
func trackArrivals(livePaths: Set<String>,
                   known: Set<String>,
                   previous: [String: Date],
                   now: Date,
                   suppress: Bool,
                   flashSeconds: TimeInterval = LiveFleetModel.flashSeconds) -> [String: Date] {
    var out = previous
    if !suppress {
        for p in livePaths where !known.contains(p) && out[p] == nil {
            out[p] = now
        }
    }
    return out.filter {
        livePaths.contains($0.key) && now.timeIntervalSince($0.value) < flashSeconds
    }
}

/// "5 min" / "1 hour" / "24 hours" — the window, spelled the same way everywhere it is
/// shown. The status line divided by 60 unconditionally, which reads as "1440m" once the
/// window is selectable beyond an hour.
func liveWindowLabel(_ seconds: Int) -> String {
    if seconds < 3600 { return "\(seconds / 60) min" }
    let h = seconds / 3600
    return "\(h) hour\(h == 1 ? "" : "s")"
}

func liveSize(_ bytes: Int) -> String {
    if bytes < 1_000 { return "\(bytes) B" }
    if bytes < 1_000_000 { return "\(bytes / 1_000) KB" }
    return String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

/// The fleet scan: `liveFiles` (Tail.swift) decides what is live — this only decorates it
/// with the display fields the view needs and sorts newest-first. No second mtime rule, no
/// second directory walk, and no extra stat: DiscoveredFile already carries mtime and size
/// from discovery's own `attributesOfItem`.
/// `codexRoot` may be nil to watch only the Claude tree; the default watches both, because
/// "who is writing right now, machine-wide" is false if it silently means "…in one of the
/// two agent homes".
func scanLiveSessions(root: String,
                      windowSeconds: Int,
                      projectNames: [String: String],
                      codexRoot: String? = defaultCodexRoot,
                      now: Date = Date()) -> [LiveSession] {
    let nowSec = Int(now.timeIntervalSince1970)
    var out = liveFiles(root: root, withinSeconds: windowSeconds, now: now).map { f in
        LiveSession(
            path: f.path,
            project: projectNames[f.projectDirName] ?? f.projectDirName,
            tier: f.tier,
            sessionUUID: f.sessionUUID,
            agentId: f.agentId,
            workflowRunId: f.workflowRunId,
            size: f.size,
            mtime: f.mtime,
            secondsSinceWrite: max(0, nowSec - f.mtime),
            source: "claude")
    }

    if let codexRoot {
        out += liveCodexFiles(root: codexRoot, withinSeconds: windowSeconds, now: now).map { f in
            // A rollout carries its real cwd in the header, so the project is known
            // directly rather than looked up by encoded dirname.
            //
            // THE FULL cwd, NOT ITS LAST COMPONENT. Codex writes exactly the same string
            // the index stores for a Claude project — verified: a Codex header carries
            // "/workspace/laris-co/kvm-oracle", identical to `projects.cwd`.
            // Shortening it to "kvm-oracle" made the two agents working in ONE repo group
            // as two unrelated projects, which is the opposite of what this view is for:
            // when both are running on the same checkout, that is precisely the thing you
            // want to see side by side.
            // NEST CODEX SUBAGENTS UNDER THEIR PARENT, exactly as Claude's are.
            //
            // Codex has the same two-level structure and states it in the header: a worker
            // carries `parent_thread_id` (and `session_id` equal to it), `thread_source:
            // subagent`, plus `agent_nickname`/`agent_role`. Treating every rollout as a
            // top-level session threw that away — `kvm-oracle` listed the main session and
            // then Hume, Herschel, Halley and Godel as four unrelated peers of it, when
            // they are its children. Grouping is by session uuid, so adopting the parent's
            // uuid is what puts them underneath it.
            //
            // Tier is the CLAUDE vocabulary on purpose: one grouping rule, one set of
            // filters, and `--tier subagent` means the same thing in both corpora.
            let isChild = f.isSubagent
            return LiveSession(
                path: f.path,
                project: f.cwd ?? "codex",
                tier: isChild ? "subagent" : "session",
                sessionUUID: f.parentThreadID ?? f.sessionUUID,
                // Name AND role — "Hume" says which worker, "researcher" says what it is
                // for, and the role is otherwise not visible anywhere in this view.
                agentId: f.agentNickname.map { n in
                    f.agentRole.map { "\(n) · \($0)" } ?? n
                },
                workflowRunId: nil,
                size: f.size,
                mtime: f.mtime,
                secondsSinceWrite: max(0, nowSec - f.mtime),
                source: "codex")
        }
    }

    out.sort { $0.mtime > $1.mtime }
    return out
}

// MARK: - Project names (dirname → real cwd, from the index)

extension DB {
    /// The live poll reads the db while an import may be writing it. Without this a
    /// contended `sqlite3_step` returns SQLITE_BUSY, and a `while step(...) == SQLITE_ROW`
    /// loop reads that as "no more rows" — a *silently truncated* result set rather than an
    /// error. Set on every db this view opens. (TailOffsetStore does the same thing inline
    /// for the same reason.)
    func setBusyTimeout(_ ms: Int32 = 3_000) {
        sqlite3_busy_timeout(handle, ms)
    }
}

/// SPEC.md: a project's real path comes from the file's own `cwd`, never from decoding the
/// dirname. This reads the cwd the importer already recorded; a project seen live but never
/// imported has no row here and falls back to the raw dirname — shown as-is, never decoded.
func loadProjectNames(db: DB) -> [String: String] {
    let stmt = db.prepare(SQL.selectProjectPaths)
    var map: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let dirC = sqlite3_column_text(stmt, 0) else { continue }
        let dir = String(cString: dirC)
        if let cwdC = sqlite3_column_text(stmt, 1) { map[dir] = String(cString: cwdC) }
    }
    sqlite3_finalize(stmt)
    return map
}

// MARK: - One row in the tail pane

/// A `TailEvent` plus a monotonic id. SwiftUI needs a stable, unique Identifiable key;
/// `byteOffset` is nearly that but restarts at 0 if a file is replaced under us
/// (`TailRead.truncated`), which would collide. The counter never does.
struct LiveEventRow: Identifiable {
    let id: Int
    let event: TailEvent

    /// A tool call is not "no text". It has a NAME and a TARGET, and both are already in
    /// the raw line — the old placeholder ("· no text (tool call or result)") threw away
    /// the single most useful thing about the most common line in the file. Computed once
    /// at construction, not per render: a live tail re-renders constantly and re-parsing
    /// a 30 KB line on every pass would be paid over and over for a constant answer.
    let toolSummary: String?

    /// The expanded bodies, parsed ONCE at construction alongside `toolSummary`.
    ///
    /// This was a computed property, with a comment arguing it should stay lazy so that
    /// result bodies were not retained for rows nobody opened. That reasoning was correct
    /// when expanding was a rare click — and was silently invalidated by auto-expanding the
    /// newest 20 rows, which turned "parsed on demand" into "parsed 20× per tick, forever".
    /// Measured under that regression: 99.9% CPU / 1.1 GB RSS, with the sample dominated by
    /// LazyLayoutViewCache.updatePrefetchPhases rebuilding placements.
    ///
    /// Bodies are CAPPED here (see `bodyCap`) rather than held whole, which answers the
    /// original memory objection directly: worst case is now bounded at roughly
    /// maxEvents × blocks × bodyCap instead of being unbounded in the size of a tool result.
    let details: [ExpandedDetail]

    /// The first `excerptLines` of `text`, plus how much was withheld.
    ///
    /// Computed HERE, with `toolSummary` and `details`, for the reason recorded above them:
    /// a tail re-renders constantly, and anything derived per render is paid on every row
    /// on every 2-second tick, forever. That is the exact shape of the regression that took
    /// this view to 99.9% CPU and 1.1 GB — so an excerpt is a stored property, never a
    /// computed one.
    let excerpt: String
    /// Lines withheld from `excerpt`; 0 when the whole body is shown.
    let hiddenLines: Int

    init(id: Int, event: TailEvent) {
        self.id = id
        self.event = event
        // ONE parse producing both, instead of two passes over the same 30 KB line.
        let parsed = LiveEventRow.parseBlocks(raw: event.raw)
        self.toolSummary = parsed.summary
        self.details = parsed.details

        let cut = LiveEventRow.excerptOf(event.text)
        self.excerpt = cut.head
        self.hiddenLines = cut.hidden
    }

    var lineType: String { event.parsedOK ? (event.lineType ?? "(no type)") : "malformed" }
    var isConversational: Bool { event.lineType.map { CONVERSATIONAL_TYPES.contains($0) } ?? false }
    var text: String { event.text }

    /// Is this line CODE rather than prose?
    ///
    /// A tool call and its output are shell, JSON and diffs — proportional type makes them
    /// genuinely hard to read: columns do not line up, and `l`/`1`/`I` and `0`/`O` stop
    /// being distinguishable in exactly the strings where the difference matters. Prose
    /// stays proportional because 15% of this corpus is Thai, which sets the size floor
    /// and reads worse mono.
    ///
    /// Both formats land here: Claude emits `tool_use`/`tool_result` directly, and the
    /// Codex adapter maps `custom_tool_call`/`function_call` onto the same two names, so
    /// one predicate covers both corpora.
    var isCode: Bool {
        guard let t = event.lineType else { return false }
        return t == "tool_use" || t == "tool_result"
    }
    var ts: String? { event.timestamp }

    /// Verified against the real corpus, 2026-08-24: a `tool_use` block carries
    /// `name` ("Bash") plus an `input` dict; a `tool_result` carries `is_error`;
    /// a `thinking` block carries `thinking`. Measured over 408 real content blocks from
    /// live workflow transcripts: tool_use 140, tool_result 139, thinking 75, text 54 —
    /// so `thinking` is 18% of all blocks and rendered as an empty row until it was
    /// handled here. Returns nil only when the line truly has no renderable block, so the
    /// caller can still distinguish "state line" from "had content we could not name".
    static func summarizeBlocks(raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return nil }

        var parts: [String] = []
        for b in blocks {
            switch b["type"] as? String {
            case "tool_use":
                let name = (b["name"] as? String) ?? "tool"
                if let target = LiveEventRow.toolTarget(input: b["input"] as? [String: Any]) {
                    parts.append("\(name) · \(target)")
                } else {
                    parts.append(name)
                }
            case "tool_result":
                // `is_error` arrives as a JSON bool; NSNumber bridging makes `as? Bool`
                // the reliable read here.
                let failed = (b["is_error"] as? Bool) ?? false
                parts.append(failed ? "→ error" : "→ result")
            case "thinking":
                // Was 18% of blocks and drew an empty row. In a tail, "it is reasoning"
                // is real signal — a long silent gap otherwise looks like a stall.
                //
                // MEASURED, and stronger than "usually": the `thinking` string is ALWAYS
                // empty in stored transcripts. Two independent counts on this machine —
                // 22093/22093 and 11495/11495 — found ZERO non-empty ones. So the preview
                // branch below is unreachable against real corpus data; it is kept only
                // because the field is documented to carry text and a future writer may
                // start retaining it. Originally written as "usually EMPTY" —
                // (len=0) with only an opaque `signature` alongside it — the content is
                // stripped at write time, not lost by this parser. So bare "thinking…" is
                // the correct, honest output for most of these, and the preview branch
                // below only fires on the rare block that kept its text. Do not "fix" the
                // missing preview by digging into `signature`: it is not the reasoning.
                if let t = b["thinking"] as? String, !t.isEmpty {
                    let flat = t.split(whereSeparator: \.isNewline)
                        .first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    parts.append(flat.isEmpty ? "thinking…"
                                 : "thinking… " + (flat.count > 64 ? String(flat.prefix(64)) + "…" : flat))
                } else {
                    parts.append("thinking…")
                }
            default:
                continue
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    /// The one field per tool that a human scanning a transcript actually wants. Ordered
    /// by specificity — `command` before `description`, because the command IS the answer
    /// and the description is a restatement of it.
    private static func toolTarget(input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "pattern", "path", "url", "query", "prompt", "description"] {
            if let v = input[key] as? String, !v.isEmpty {
                let flat = v.split(whereSeparator: \.isNewline).first.map(String.init) ?? v
                return flat.count > 72 ? String(flat.prefix(72)) + "…" : flat
            }
        }
        return nil
    }
}

// MARK: - Attach policy

/// How the live pane starts following a file. ONE definition, used by both the window
/// (`LiveFleetModel.attach`) and `session-viewer live --attach`, so what the CLI proves is
/// what the UI does.
///
/// Rewind from EOF rather than start at EOF (TailWatcher's default) so the pane shows
/// recent context on click instead of an empty box until the next turn — and rather than
/// start at 0, which on the 39.6 MB p99 file would read 39.6 MB to show the last few
/// lines. `alignedOffset` snaps FORWARD to the next newline, because landing mid-line
/// would emit the leading fragment as a malformed event (Tail.swift's hold-back rule
/// protects only the trailing edge).
func liveAttachTailer(path: String, rewindBytes: Int = LiveFleetModel.attachRewindBytes) -> SessionTailer {
    let size = statFile(path)?.size ?? 0
    let start = SessionTailer.alignedOffset(path: path, approx: max(0, size - rewindBytes))
    return SessionTailer(path: path, offset: start)
}

// MARK: - The model the view binds to

/// Owns the poll timer, the fleet scan, and one `SessionTailer` for the selected session.
///
/// Deliberately NOT built on `TailWatcher`: that class follows the WHOLE live set at once
/// and persists offsets, which is right for `session-viewer tail` (a logger) and wrong for
/// this pane (one selected file, no persistence — a UI that resumed a week-old offset and
/// replayed megabytes on click would be a bug, not a feature). Both use the same
/// `SessionTailer` underneath, so the byte-exact behaviour is shared.
final class LiveFleetModel: ObservableObject {
    @Published private(set) var sessions: [LiveSession] = []
    @Published private(set) var events: [LiveEventRow] = []

    /// DERIVED, cached — the freeze fix. These used to be computed inside `body`
    /// (`foldStateRuns(model.events)` in a ForEach, `groupLiveSessions(model.sessions)` in
    /// a computed property). SwiftUI re-evaluates `body` on every view-graph update, so a
    /// 500-element array of `TailItem` enums was being rebuilt continuously — a `sample` of
    /// the running app showed the main thread at 1517/1719 samples inside
    /// `AG::Graph::UpdateStack::update()`, with `initializeWithCopy`/`destroy for TailItem`
    /// on the stack. That is the spinning cursor.
    ///
    /// Computing them here means they change exactly when the DATA changes (every 2s poll
    /// or tail read), not every time SwiftUI touches the view tree.
    @Published private(set) var foldedEvents: [TailItem] = []
    @Published private(set) var groups: [LiveGroup] = []

    /// Lowest event id that auto-expands. Published as a plain Int, and that is the point:
    /// the view used to answer "is this row recent?" by reading `model.events.last?.id`
    /// INSIDE the row body, which made every one of the ~150 rows depend on the whole
    /// events ARRAY. Every tick then re-evaluated every row. An Int changes once per tick
    /// and compares in a nanosecond.
    @Published private(set) var autoExpandFloor: Int = Int.min

    /// path -> is this file in the index, and is the index current for it. Computed on the
    /// SAME background tick as the fleet scan (one db read for all rows), so the view never
    /// queries and never blocks.
    @Published private(set) var indexState: [String: IndexState] = [:]
    @Published private(set) var status: String = "live: stopped"
    @Published private(set) var attachedPath: String?
    @Published private(set) var tailInfo: String = ""
    @Published private(set) var running = false

    let dbPath: String
    let root: String

    /// How far back "live" reaches, CHANGEABLE at runtime.
    ///
    /// It was a `let` fixed at 5 minutes, and that quietly decided what the view could ever
    /// show. Codex subagents finish their slice and go quiet: measured here, six workers on
    /// one session had all last written 12–18 minutes earlier, so they were correctly "not
    /// live" and correctly invisible — and the view offered no way to look further back,
    /// while `session-viewer live --window` had done so all along.
    ///
    /// TWO COPIES ON PURPOSE. `tick()` runs on the io queue and reads the window there;
    /// this published one exists for the caption and is only ever touched on main. A single
    /// `var` read from both would be a data race in the one class whose whole contract is
    /// that no IO happens on the main thread.
    @Published private(set) var windowSeconds: Int
    /// io-queue copy of the above. Never read on main.
    private var ioWindow: Int

    /// path → the moment it FIRST appeared in the live set, for the "just arrived" flash.
    ///
    /// Model-driven rather than a per-row `.onAppear`: these rows live in a lazy `List`, so
    /// `onAppear` fires when a row scrolls into view and would flash sessions that have
    /// been running for an hour. Arrival is a property of the DATA, so the data decides it.
    ///
    /// Entries are dropped once they stop mattering (see `tick`), so this stays the size of
    /// the handful of sessions that appeared in the last few seconds — not a growing log.
    @Published private(set) var appearedAt: [String: Date] = [:]

    /// Live paths as of the previous tick. The set difference is what "new" means.
    private var knownPaths: Set<String> = []

    /// Suppress the flash for one tick — used for the FIRST scan and after a window change,
    /// where every row is new to the view and flashing all of them says nothing. A flash
    /// that fires on everything is indistinguishable from no flash at all.
    private var suppressFlashOnce = true

    /// How long a new row stays highlighted. Long enough to catch out of the corner of an
    /// eye at a 2-second poll, short enough that a busy fleet is not permanently lit.
    static let flashSeconds: TimeInterval = 6

    /// Cap on retained tail rows. A busy session emits hundreds per burst and this pane is
    /// a monitor, not a transcript reader — old rows are dropped from the front.
    /// Retained tail rows. Dropped 500 → 150 after measuring the freeze: every retained
    /// row is another view SwiftUI diffs and lays out on each update, and a LIVE tail is
    /// for watching what is happening now — the All tab holds the history. 150 still fills
    /// a tall window several times over.
    static let maxEvents = 150

    /// How many of the newest events render expanded. Lives on the MODEL now, because the
    /// model is what computes `autoExpandFloor` from it — a copy on the view would be a
    /// second source of truth for the same window.
    static let autoExpandCount = 20

    /// On attach, rewind this far from EOF (snapped forward to a line boundary) so the pane
    /// shows recent context immediately instead of an empty box until the next turn. On the
    /// 39.6 MB p99 file this is a 256 KB read, not a 39.6 MB one — which is the entire
    /// point of the append-only fact.
    static let attachRewindBytes = 256 * 1024

    /// Max `read()` rounds per tick, mirroring TailWatcher's catch-up bound: one file with a
    /// large backlog must not stall the tick that also refreshes the fleet list.
    private static let catchupRounds = 4

    private let io = DispatchQueue(label: "session-viewer.live-fleet", qos: .utility)
    private var timer: DispatchSourceTimer?            // io only
    private var tailer: SessionTailer?                 // io only
    private var eventSeq = 0                           // io only
    private var projectNames: [String: String] = [:]   // io only
    private var namesLoadedAt: Date?                   // io only

    init(dbPath: String, root: String, windowSeconds: Int = 300) {
        self.dbPath = dbPath
        self.root = root
        self.windowSeconds = windowSeconds
        self.ioWindow = windowSeconds
    }

    func start(interval: TimeInterval = 2.0) {
        io.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.io)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
            DispatchQueue.main.async { self.running = true }
        }
    }

    func stop() {
        io.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            DispatchQueue.main.async {
                self.running = false
                self.status = "live: stopped"
            }
        }
    }

    /// Attach the tail to a session (or detach with nil). `events` is cleared so the pane
    /// never shows the previous session's lines while the io queue catches up.
    ///
    /// The clear is deferred with `main.async` rather than done inline. This is called from
    /// `.onChange(of: selectedPath)`, i.e. from *inside* the List's selection delegate
    /// callback; publishing there mutates the view's data source while AppKit is still in
    /// its NSTableView delegate, which logs "Application performed a reentrant operation in
    /// its NSTableView delegate. This warning will become an assert in the future."
    /// Observed in the real window before this hop was added.
    func attach(to path: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachedPath = path
            self.events = []
            self.foldedEvents = []
            self.autoExpandFloor = Int.min
            self.tailInfo = path == nil ? "" : "attaching…"
        }
        io.async { [weak self] in
            guard let self else { return }
            self.eventSeq = 0
            guard let path else { self.tailer = nil; return }
            self.tailer = liveAttachTailer(path: path)   // shared policy — see above
            self.tick()          // first delta now, without waiting a whole interval
        }
    }

    /// Change the liveness window. Main thread only.
    ///
    /// Rescans immediately rather than waiting out the poll interval — the click asked a
    /// question ("what has run in the last hour?") and making it wait two seconds for an
    /// answer reads as a control that did not work.
    func setWindow(_ seconds: Int) {
        guard seconds != windowSeconds else { return }
        windowSeconds = seconds
        // Widening the window reveals a batch of already-running sessions at once. They are
        // new to the VIEW but not newly started, and lighting them all up would be a lie.
        suppressFlashOnce = true
        io.async { [weak self] in
            guard let self else { return }
            self.ioWindow = seconds
            self.tick()
        }
    }

    // MARK: - the poll (io queue only)

    private func tick() {
        let t0 = Date()
        refreshProjectNamesIfStale()
        let live = scanLiveSessions(root: root, windowSeconds: ioWindow,
                                    projectNames: projectNames, now: t0)
        let (fresh, info) = readTail()
        // Same background tick, one db read for every row — see indexStates().
        let db = DB(path: dbPath)
        db.setBusyTimeout()
        let states = indexStates(db: db, for: live)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let stamp = LiveFleetModel.clock.string(from: Date())

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // WHICH ROWS ARE NEW — computed here, on main, where `knownPaths` lives.
            let now = Date()
            let livePaths = Set(live.map(\.path))
            self.appearedAt = trackArrivals(livePaths: livePaths,
                                            known: self.knownPaths,
                                            previous: self.appearedAt,
                                            now: now,
                                            suppress: self.suppressFlashOnce)
            self.suppressFlashOnce = false
            self.knownPaths = livePaths

            self.sessions = live
            self.groups = groupLiveSessions(live)
            self.indexState = states
            self.tailInfo = info
            if !fresh.isEmpty {
                self.events.append(contentsOf: fresh)
                let over = self.events.count - LiveFleetModel.maxEvents
                if over > 0 { self.events.removeFirst(over) }
                self.foldedEvents = foldStateRuns(self.events)
                self.autoExpandFloor = (self.events.last?.id ?? 0) - LiveFleetModel.autoExpandCount
            }
            self.status = "\(live.count) live in last \(liveWindowLabel(self.windowSeconds)) · scan \(ms) ms · \(stamp)"
        }
    }

    /// io queue only. Returns the newly appended rows and a one-line description of where
    /// the tailer now stands — offset, lines seen, and any held-back partial, which is the
    /// normal mid-burst state and worth showing rather than hiding.
    private func readTail() -> ([LiveEventRow], String) {
        guard let t = tailer else { return ([], "") }
        var rows: [LiveEventRow] = []
        var note = ""
        do {
            var rounds = 0
            while rounds < LiveFleetModel.catchupRounds {
                rounds += 1
                let r = try t.read()
                for e in r.events {
                    eventSeq += 1
                    rows.append(LiveEventRow(id: eventSeq, event: e))
                }
                if r.heldBackBytes > 0 { note = " · holding \(r.heldBackBytes)B partial line" }
                if r.truncated { note += " · file replaced — restarted at 0" }
                if !r.moreAvailable { break }
            }
            return (rows, "offset \(t.offset) · \(t.linesSeen) lines seen" + note)
        } catch {
            // A file vanishing mid-follow is expected (pruning, SPEC.md), not corruption.
            return (rows, "\(error)")
        }
    }

    /// The dirname→cwd map only changes when a new project is imported, so it is not worth
    /// re-opening the db for it every 2 s.
    private func refreshProjectNamesIfStale() {
        if let at = namesLoadedAt, Date().timeIntervalSince(at) < 30 { return }
        let db = DB(path: dbPath)
        db.setBusyTimeout()
        projectNames = loadProjectNames(db: db)
        namesLoadedAt = Date()
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - CLI: `session-viewer live` — the fleet list, headless

/// Exists so the fleet view is verifiable without launching a GUI, and so the scan cost is
/// measurable. Same `scanLiveSessions` the window calls.
///
/// Distinct from `session-viewer tail` (Tail.swift), which FOLLOWS content across the whole
/// live set. This one answers "who is alive right now", which is the sidebar's question.
public func runLive(root: String, dbPath: String, windowSeconds: Int, repeats: Int, intervalSeconds: Double,
             attachPath: String = "") {
    let db = DB(path: dbPath)
    db.setBusyTimeout()
    let names = loadProjectNames(db: db)

    // --attach FILE reproduces the detail pane exactly: same liveAttachTailer, same
    // per-tick read. Printing size alongside offset is the proof that the delta — not the
    // file — is what gets read.
    var attached: SessionTailer? = nil
    if !attachPath.isEmpty {
        let t = liveAttachTailer(path: attachPath)
        attached = t
        let size = statFile(attachPath)?.size ?? 0
        print("attach \(attachPath)")
        print("  size \(size) B · start offset \(t.offset) B · rewound \(size - t.offset) B "
              + "(\(LiveFleetModel.attachRewindBytes) B requested, snapped to a line boundary)")
    }

    for i in 0..<max(1, repeats) {
        let t0 = Date()
        let live = scanLiveSessions(root: root, windowSeconds: windowSeconds, projectNames: names)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("— \(LiveFleetModel.clock.string(from: Date())) · \(live.count) live in last \(liveWindowLabel(windowSeconds)) · scan \(ms) ms")
        for s in live {
            let dot: String
            switch s.heat {
            case .hot:  dot = "●"      // ≤30s
            case .warm: dot = "◍"      // ≤2m
            case .cool: dot = "○"      // ≤window
            }
            let cols = [dot, pad(s.source == "codex" ? "cdx" : "cc", 4),
                        pad(s.tier, 14), pad(s.label, 34), pad(liveSize(s.size), 9),
                        pad(liveAgo(s.secondsSinceWrite) + " ago", 11), s.project]
            print("  " + cols.joined(separator: " "))
        }
        if let t = attached {
            let size = statFile(t.path)?.size ?? -1
            if let r = try? t.read() {
                var line = "  tail: +\(r.events.count) line(s) · read \(r.bytesConsumed) B "
                    + "· offset \(t.offset) / size \(size)"
                if r.heldBackBytes > 0 { line += " · holding \(r.heldBackBytes) B partial" }
                if r.truncated { line += " · TRUNCATED, restarted at 0" }
                print(line)
                for e in r.events.suffix(3) {
                    let ty = e.parsedOK ? (e.lineType ?? "(no type)") : "malformed"
                    let head = e.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                    print("     @\(e.byteOffset) \(pad(ty, 14)) \(String(head.prefix(90)))")
                }
            } else {
                print("  tail: read failed (file gone?)")
            }
        }
        if i + 1 < repeats { Thread.sleep(forTimeInterval: intervalSeconds) }
    }
}

private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: - CLI: `session-viewer live --model` — drive the real model, headless

/// Runs `LiveFleetModel` itself — the exact object the SwiftUI view binds to — with a
/// runloop instead of a window, and prints what it publishes.
///
/// This verifies what the helper functions alone cannot: that the timer fires, that the
/// io queue does the reading, and that every published update arrives on the MAIN thread
/// (the requirement that keeps a 39 MB file off the UI). Each line below asserts
/// `Thread.isMainThread` at the moment of delivery rather than assuming it.
public func runLiveModel(root: String, dbPath: String, windowSeconds: Int, attachPath: String, seconds: Double) {
    let model = LiveFleetModel(dbPath: dbPath, root: root, windowSeconds: windowSeconds)
    var bag: [AnyCancellable] = []
    var offMainThread = 0
    var lastEventCount = 0

    func mark() -> String {
        if Thread.isMainThread { return "main" }
        offMainThread += 1
        return "OFF-MAIN(!)"
    }

    model.$status
        .sink { s in guard !s.isEmpty else { return }; print("[\(mark())] status: \(s)") }
        .store(in: &bag)

    model.$tailInfo
        .sink { s in guard !s.isEmpty else { return }; print("[\(mark())] tail:   \(s)") }
        .store(in: &bag)

    model.$events
        .sink { rows in
            let m = mark()
            guard rows.count != lastEventCount else { return }
            let added = rows.count - lastEventCount
            lastEventCount = rows.count
            guard added > 0 else { print("[\(m)] events: cleared"); return }
            print("[\(m)] events: +\(added) → \(rows.count) retained (cap \(LiveFleetModel.maxEvents))")
            for r in rows.suffix(3) {
                let head = r.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                print("          \(pad(r.lineType, 16)) \(head.isEmpty ? "(no text)" : String(head.prefix(80)))")
            }
        }
        .store(in: &bag)

    print("model: root=\(root) window=\(windowSeconds)s attach=\(attachPath.isEmpty ? "(none)" : attachPath)")
    model.start()
    if !attachPath.isEmpty { model.attach(to: attachPath) }

    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    model.stop()
    print("model: stopped — \(offMainThread == 0 ? "ALL publishes arrived on the main thread" : "\(offMainThread) publish(es) arrived OFF the main thread")")
}

// MARK: - Parent/child grouping for the live fleet

/// One top-level session and the subagents / workflow agents running underneath it.
///
/// The relationship is already in the data and was being thrown away: a subagent
/// transcript lives at `<project>/<uuid>/subagents/…` and a workflow agent at
/// `<project>/<uuid>/subagents/workflows/wf_*/…`, so ALL of them share the parent's
/// `sessionUUID`. Rendering them as a flat list hid that a burst of 6 "different" live
/// rows was often one session and its five workers — and it forced every row to repeat the
/// project path, which is precisely the repetition that made the sidebar unreadable.
struct LiveGroup: Identifiable {
    let sessionUUID: String
    let project: String
    var parent: LiveSession?        // nil when the parent session itself is not currently live
    var children: [LiveSession]

    var id: String { sessionUUID }

    /// Freshest write anywhere in the group — a parent that has gone quiet while its
    /// workers are hammering is still an active group and must sort as one.
    var mtime: Int {
        max(parent?.mtime ?? 0, children.map(\.mtime).max() ?? 0)
    }

    var totalSize: Int {
        (parent?.size ?? 0) + children.reduce(0) { $0 + $1.size }
    }

    /// The group's heat is its hottest member, for the same reason as `mtime`.
    var heat: LiveHeat {
        let secs = min(parent?.secondsSinceWrite ?? .max,
                       children.map(\.secondsSinceWrite).min() ?? .max)
        return LiveHeat(secondsSinceWrite: secs == .max ? 9_999 : secs)
    }
}

/// Group live sessions by their shared session uuid, newest group first, children newest
/// first within a group. A session with no workers is a group of one and still renders as
/// a parent — no special case at the call site.
func groupLiveSessions(_ sessions: [LiveSession]) -> [LiveGroup] {
    var byUUID: [String: LiveGroup] = [:]
    for s in sessions {
        var g = byUUID[s.sessionUUID]
            ?? LiveGroup(sessionUUID: s.sessionUUID, project: s.project, parent: nil, children: [])
        if s.tier == "session" { g.parent = s } else { g.children.append(s) }
        byUUID[s.sessionUUID] = g
    }
    return byUUID.values
        .map { g -> LiveGroup in
            var g = g
            // STABLE child order — by identity, never by write time. Sorting children by
            // mtime made them swap places on every 2s poll while you were reading them.
            g.children.sort { ($0.agentId ?? $0.path) < ($1.agentId ?? $1.path) }
            return g
        }
        .sorted(by: stableGroupOrder)
}

/// Ordering that does NOT move rows under the cursor.
///
/// The old order was `mtime` descending, recomputed every 2s. With a dozen sessions all
/// writing, that reshuffled the list continuously: the row you were reading physically
/// travelled, and clicking one was a moving target. A pinned-selection hack was tried and
/// removed — it made clicking WORSE, because selecting a row lifted it out of the list and
/// shifted everything below it.
///
/// Instead, order on two keys that barely change:
///   1. ACTIVE (hot/warm) before STALE (cool). This is a coarse bucket that flips at most
///      once per session as it goes quiet, so "green on top" holds without churn.
///   2. Within a bucket, the session uuid — completely stable for the life of a session.
///
/// Recency is still visible: every row prints its own age, and the heat dot re-colours in
/// place. The information moved from POSITION (which forces motion) to APPEARANCE (which
/// does not).
func stableGroupOrder(_ a: LiveGroup, _ b: LiveGroup) -> Bool {
    let aStale = a.heat == .cool
    let bStale = b.heat == .cool
    if aStale != bStale { return !aStale }        // active group first
    return a.sessionUUID < b.sessionUUID          // then a key that never moves
}

// MARK: - Agent names

/// The human name of a spawned agent, recovered from its filename.
///
/// There is no name FIELD anywhere in a subagent transcript — verified across 193 files,
/// every one returned nothing for agentName/name/title/description. But the name is right
/// there in the path: a named agent writes `agent-a<name>-<hex>.jsonl`, an unnamed one
/// writes `agent-a<hex>.jsonl`. So `agent-acodex-freeze-f0999ee5173fe31d` is the agent
/// named `codex-freeze`.
///
/// This matters because a fleet list of `a0dba268cf1507085` tells you nothing, while
/// `learn-snippets` / `dna-skeptic` / `codex-freeze` tells you exactly which worker you are
/// looking at. Verified against 12 real files.
/// The two tiers encode `agentId` DIFFERENTLY, which this has to absorb — discovery
/// (Ingest.swift) strips `agent-` for workflow agents but not for plain subagents:
///
///   subagent        agentId = "agent-aomx-hermes-addon-2594fe35f9890054"
///   workflow_agent  agentId = "acodex-freeze-f0999ee5173fe31d"
///
/// Handling only the second form produced the visible bug `gent-aomx-hermes-addon` — the
/// leading `a` of `agent-` was eaten as if it were the id prefix. Strip an optional
/// `agent-` FIRST, then the single `a`, then the trailing hex.
func agentDisplayName(agentId: String?) -> String? {
    guard var raw = agentId else { return nil }
    if raw.hasPrefix("agent-") { raw = String(raw.dropFirst("agent-".count)) }
    guard raw.hasPrefix("a") else { return nil }
    let rest = String(raw.dropFirst())
    // Trailing 16+ hex chars are the id; whatever precedes them is the name.
    guard let m = rest.range(of: "[-]?[0-9a-f]{16,}$", options: .regularExpression) else {
        return nil
    }
    let name = String(rest[rest.startIndex..<m.lowerBound])
    return name.isEmpty ? nil : name
}

extension LiveSession {
    /// Name if the agent has one, else the short id — never an empty row label.
    var displayLabel: String {
        if let n = agentDisplayName(agentId: agentId) { return n }
        guard let agentId else { return String(sessionUUID.prefix(8)) }
        return String(agentId.prefix(10))
    }

    /// True when the row is showing a real human-given name rather than a hash.
    var hasAgentName: Bool { agentDisplayName(agentId: agentId) != nil }
}

// MARK: - Expanded detail

/// The FULL content of a line, for the expanded view — the part the one-line summary
/// necessarily throws away.
///
/// `summarizeBlocks` deliberately truncates (a tool target at 72 chars, a thinking preview
/// at 64) because a scannable tail needs one line per event. But the data behind it is
/// right there: a `tool_use` carries its whole `input` dict, and a `tool_result` carries up
/// to kilobytes of real command output — measured 750 chars of `git status` in a real line.
/// Rendering `→ result` and nothing else discarded exactly the thing you wanted to read.
public struct ExpandedDetail {
    public let title: String        // "Bash" / "→ result" / "thinking"
    public let body: String         // full command, full output, full reasoning
    public let isError: Bool
}

extension LiveEventRow {
    /// Largest body kept per block. A tool result in this corpus can run to tens of KB;
    /// laying that out inside a LazyVStack row is unbounded work for text nobody reads in
    /// a tail view. Truncation is SHOWN, not silent — see the marker appended below.
    static let bodyCap = 4000

    /// Retained for source compatibility with call sites that read `.expanded`.
    /// Now a stored-array accessor, not a re-parse.
    public var expanded: [ExpandedDetail] { details }

    /// How much of a long body is shown before "show more".
    ///
    /// A single `apply_patch` in this corpus runs to hundreds of lines; rendered whole it
    /// pushes every neighbouring event off the screen, so the tail stops being a tail. Both
    /// limits apply — 14 lines catches the tall-and-narrow case, 900 characters catches the
    /// one-enormous-line case that a line count alone would let through.
    static let excerptLines = 14
    static let excerptChars = 900

    /// Split a body into what is shown by default and how many lines that withholds.
    /// Returns `hidden: 0` when the whole thing fits, which is what the view tests to
    /// decide whether a "show more" control is warranted at all.
    static func excerptOf(_ s: String) -> (head: String, hidden: Int) {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > excerptLines || s.count > excerptChars else { return (s, 0) }

        var head = lines.prefix(excerptLines).joined(separator: "\n")

        if head.count > excerptChars {
            // The character cap fires — a body that is WIDE as well as tall. Cut back to
            // the last complete line rather than mid-line.
            //
            // A test caught the alternative being wrong: chopping mid-line left a partial
            // line on screen that counted as neither shown nor hidden, and "show N more
            // lines" over-claimed by one. Ending on a line boundary makes the arithmetic
            // exact — and a code block that stops at a newline reads as an excerpt, where
            // one that stops mid-token reads as corruption.
            let cutPoint = String(head.prefix(excerptChars))
            if let lastBreak = cutPoint.lastIndex(of: "\n") {
                head = String(cutPoint[cutPoint.startIndex..<lastBreak])
            } else {
                // A single line longer than the cap: there is no boundary to fall back to,
                // so cut it and count it as shown — the user IS looking at part of it.
                head = cutPoint
            }
        }

        let shown = head.split(separator: "\n", omittingEmptySubsequences: false).count
        return (head, max(0, lines.count - shown))
    }

    static func cap(_ s: String) -> String {
        guard s.count > bodyCap else { return s }
        return String(s.prefix(bodyCap)) + "\n… +\((s.count - bodyCap).formatted()) more characters (truncated for display)"
    }

    /// The single parse. Returns the one-line summary AND the expanded bodies, so a row
    /// costs exactly one JSONSerialization pass over its raw line for its whole lifetime
    /// instead of one per body evaluation per expanded row.
    static func parseBlocks(raw: String) -> (summary: String?, details: [ExpandedDetail]) {
        (summary: summarizeBlocks(raw: raw), details: expandedDetails(raw: raw))
    }

    static func expandedDetails(raw: String) -> [ExpandedDetail] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any]
        else { return [] }

        // A plain-string content is a whole user/assistant message with no blocks.
        if let s = message["content"] as? String, !s.isEmpty {
            return [ExpandedDetail(title: (obj["type"] as? String) ?? "message", body: cap(s), isError: false)]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }

        var out: [ExpandedDetail] = []
        for b in blocks {
            switch b["type"] as? String {
            case "tool_use":
                let name = (b["name"] as? String) ?? "tool"
                let input = b["input"] as? [String: Any] ?? [:]
                // Pretty-print the whole input, not just the one field the summary picked.
                let body: String
                if let d = try? JSONSerialization.data(withJSONObject: input,
                                                       options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: d, encoding: .utf8) {
                    body = s
                } else {
                    body = String(describing: input)
                }
                out.append(ExpandedDetail(title: name, body: cap(body), isError: false))

            case "tool_result":
                let failed = (b["is_error"] as? Bool) ?? false
                var body = ""
                if let s = b["content"] as? String {
                    body = s
                } else if let arr = b["content"] as? [[String: Any]] {
                    body = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                out.append(ExpandedDetail(title: failed ? "error" : "result",
                                          body: body.isEmpty ? "(empty result)" : cap(body),
                                          isError: failed))

            case "thinking":
                let t = (b["thinking"] as? String) ?? ""
                out.append(ExpandedDetail(title: "thinking",
                                          body: t.isEmpty ? "(reasoning not retained in this transcript)" : cap(t),
                                          isError: false))

            case "text":
                if let t = b["text"] as? String, !t.isEmpty {
                    out.append(ExpandedDetail(title: "text", body: cap(t), isError: false))
                }
            default:
                continue
            }
        }
        return out
    }
}

// MARK: - Index state (is this session captured?)

/// Whether a file on disk is in the index, and whether the index is current for it.
///
/// This is a SEPARATE AXIS from liveness, and conflating them was tempting and wrong: a
/// session can be live AND unindexed (started after the last import), or idle AND stale
/// (imported, then grew, then went quiet). Two axes, two indicators — heat says "is it
/// moving", this says "is it captured".
public enum IndexState: String {
    case new       // on disk, never imported
    case current   // imported, and the file has not changed since
    case stale     // imported, but the file has grown since — the index is behind
    case failed    // import was attempted and recorded a failure

    public var caption: String {
        switch self {
        case .new:     return "not imported"
        case .current: return "indexed"
        case .stale:   return "index behind"
        case .failed:  return "import failed"
        }
    }

    /// Short badge text. Deliberately a WORD, not a coloured dot alone — the heat dot
    /// already owns colour in this row, and a second colour-only signal beside it would be
    /// unreadable for a colour-blind reader and ambiguous for everyone else.
    public var badge: String {
        switch self {
        case .new:     return "NEW"
        case .current: return "IDX"
        case .stale:   return "•••"
        case .failed:  return "ERR"
        }
    }
}

/// One row of what the index knows about a path — enough to classify without re-statting.
struct IndexedFact {
    let mtime: Int
    let size: Int
    let status: String
}

/// Classify every live file against the index in ONE db read, not one query per row.
/// Called on the same background tick as the fleet scan; the view never queries.
func indexStates(db: DB, for sessions: [LiveSession]) -> [String: IndexState] {
    var known: [String: IndexedFact] = [:]
    let stmt = db.prepare(SQL.selectKnownFiles)
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let p = sqlite3_column_text(stmt, 0) else { continue }
        known[String(cString: p)] = IndexedFact(
            mtime: Int(sqlite3_column_int64(stmt, 1)),
            size: Int(sqlite3_column_int64(stmt, 2)),
            status: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "")
    }
    sqlite3_finalize(stmt)

    var out: [String: IndexState] = [:]
    for s in sessions {
        guard let k = known[s.path] else { out[s.path] = .new; continue }
        if k.status == "failed" { out[s.path] = .failed }
        else if k.mtime != s.mtime || k.size != s.size { out[s.path] = .stale }
        else { out[s.path] = .current }
    }
    return out
}
