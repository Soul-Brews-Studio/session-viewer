// Design.swift — the one place type, spacing and status colour are defined.
//
// WHY THIS FILE EXISTS. Before it, the UI had 29 hardcoded `.font(.system(size:))` calls
// and 3 semantic styles. Measured distribution: 7pt ×1, 9pt ×10, 10pt ×10, 11pt ×8.
// macOS system body is 13pt, so EVERY string in the app sat 2–6pt below the platform
// baseline, and 28 of 29 lived inside a 2pt band — small AND flat, which is why nothing
// on screen had anywhere for the eye to land. Making text bigger meant editing 29 sites
// and re-deriving every relationship by hand; that is why the complaint survived three
// separate passes over this UI.
//
// THE THAI FLOOR — the constraint that actually sets the minimum, and the one a generic
// type scale would miss. 154 of 1000 indexed descriptions contain Thai, and the live
// transcript pane is frequently all Thai. Thai stacks up to three vertical levels on one
// base glyph (base + สระบน + วรรณยุกต์). Latin degrades gracefully as it shrinks — the
// glyphs just get small. Thai does not: the tone mark and the upper vowel collide into an
// unreadable blob well before the Latin around them looks wrong. So a size that reads as
// merely "dense" in English is genuinely illegible in Thai, and the floor here is set by
// Thai, not by Latin. `micro` (11pt) is the smallest size any TEXT may use; below that is
// reserved for non-glyph marks. Nothing that can contain corpus content goes under `body`.
//
// DYNAMIC TYPE. Sizes are @ScaledMetric-backed at the call site via `Scaled`, so the app
// follows the user's Larger Text setting instead of ignoring it. Absolute constants alone
// silently opt out of an accessibility setting the OS offers.

import SwiftUI

/// The user's text-size preference, persisted. `1.0` = the macOS-native scale below.
///
/// This exists because "is 13pt big enough?" has no correct answer from here: it depends on
/// display size, viewing distance, and eyes. Guessing produced three rounds of "still too
/// small". Native apps (Mail, Xcode, Terminal) all expose this rather than picking for you,
/// so the app asks once and remembers, instead of the author guessing forever.
let UI_SCALE_KEY = "uiTextScale"

/// CHROME — the interface itself: buttons, pickers, column headers, legends, status bars.
/// These are FIXED at macOS-native sizes and are NOT user-scalable, on purpose.
///
/// Scaling chrome with content is the mistake VSCode, Safari and Mail all avoid: bumping
/// the reading size should not make your buttons and column headers lurch around, because
/// the chrome was already the right size — it is the *content* that was too small. A
/// toolbar that grows with the text also breaks its own layout (a 1.8× "Reload" button
/// pushes the Import button off the edge) while solving nothing the user asked for.
enum Type {
    /// 11pt — the Thai legibility floor. Metadata only (ids, byte counts, ages).
    /// Do NOT put corpus text here; see the Thai note above.
    static let micro: CGFloat = 11
    /// 12pt — secondary labels, column headers.
    static let small: CGFloat = 12
    /// 13pt — macOS system body. Chrome labels a human reads but does not study.
    static let body: CGFloat = 13
    /// 15pt — row titles, the thing that identifies a row.
    static let title: CGFloat = 15
    /// 20pt — pane headings.
    static let heading: CGFloat = 20

    static let mono = Font.Design.monospaced
}

/// CONTENT — corpus text: transcript lines, tool summaries, session descriptions, search
/// snippets. Everything the user actually *reads* rather than operates. This is what the
/// ⌘+/⌘− control moves.
///
/// The split exists because "make the font bigger" always meant this half. Chrome at
/// 13pt is correct macOS; a 39 MB Thai transcript at 13pt is not comfortable reading, and
/// only the person reading it knows what is.
enum Content {
    /// Clamped: below 0.85 Thai tone marks collide (see the Thai floor above); above 1.8
    /// a line of transcript stops fitting the pane on a laptop display.
    static var scale: CGFloat {
        let raw = UserDefaults.standard.double(forKey: UI_SCALE_KEY)
        return raw == 0 ? 1.0 : max(0.85, min(1.8, CGFloat(raw)))
    }

    /// 13pt @1.0 — the reading size. Transcript prose, descriptions, snippets.
    static var body: CGFloat { (13 * scale).rounded() }
    /// 11pt @1.0 — content-adjacent metadata that should grow WITH the text it labels
    /// (a line's role and timestamp), so a scaled-up transcript does not end up with
    /// 11pt labels pinned to 23pt prose.
    static var meta: CGFloat { (11 * scale).rounded() }
    /// 15pt @1.0 — the identifier that leads a row.
    static var title: CGFloat { (15 * scale).rounded() }

    static let mono = Font.Design.monospaced
    static let steps: [CGFloat] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.8]
}

enum Space {
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let snug: CGFloat = 8
    static let row: CGFloat = 10
    static let pane: CGFloat = 14
    static let loose: CGFloat = 20
}

/// Status colour for a live session's heat. Kept here so the legend and the dots cannot
/// drift apart — they read the same function.
///
/// Colour is never the ONLY carrier: every dot ships with its age in text beside it
/// ("5s ago"), because a red/green distinction is invisible to a red-green colourblind
/// user and to VoiceOver alike.
func heatColor(_ heat: LiveHeat) -> Color {
    switch heat {
    case .hot:  return .green
    case .warm: return .yellow
    case .cool: return .secondary
    }
}

/// Spoken description of a status dot, for VoiceOver. Without this the dot is a
/// `Circle().fill(...)` — a shape with no accessible name, and the state it encodes is
/// simply absent for a screen-reader user.
func heatAccessibilityLabel(_ heat: LiveHeat, secondsSinceWrite: Int) -> String {
    switch heat {
    case .hot:  return "writing now, last wrote \(liveAgo(secondsSinceWrite)) ago"
    case .warm: return "active, last wrote \(liveAgo(secondsSinceWrite)) ago"
    case .cool: return "idle, last wrote \(liveAgo(secondsSinceWrite)) ago"
    }
}

// MARK: - Line-type grouping

/// Which jsonl line types are session/UI bookkeeping rather than conversation.
///
/// Measured on a real burst: a single turn emits `attachment`, `last-prompt`,
/// `custom-title`, `ai-title`, `mode`, `permission-mode`, `atis-latch`, `pr-link` back to
/// back — eight consecutive rows, each rendering as an identical grey "· state line".
/// Individually none is worth a row; collapsed, they are one honest line that still says
/// the file moved. This is the single largest source of visual volume in the tail pane.
let STATE_LINE_TYPES: Set<String> = [
    "attachment", "last-prompt", "custom-title", "ai-title", "mode",
    "permission-mode", "atis-latch", "pr-link", "queue-operation",
    "file-history-snapshot", "file-history-delta", "agent-name",
]


// MARK: - Library-level defaults

/// The session corpus root. Defined HERE rather than in main.swift because both the views
/// and the CLI need it, and a value the library depends on cannot live in the executable
/// that imports the library.
public let defaultRoot = "\(NSHomeDirectory())/.claude/projects"


// MARK: - Speaker banding

/// Who produced a line, for zebra banding in the transcript.
///
/// Alternating by ROW is the usual zebra and is wrong here: consecutive rows are usually
/// the same speaker (an assistant turn is often 5+ rows of tool calls), so per-row stripes
/// would cut a single turn into slices and imply boundaries that do not exist. Banding by
/// SPEAKER instead makes each turn one visual block, and the thing you actually scan for —
/// where the human spoke — becomes findable at a glance.
public enum Speaker {
    case human      // a real user turn
    case ai         // assistant output, including its tool calls
    case system     // tool results, state lines, everything mechanical

    public init(lineType: String) {
        switch lineType {
        case "user":      self = .human
        case "assistant": self = .ai
        default:          self = .system
        }
    }
}

/// A tool RESULT arrives as `type: "user"` because the transcript models it as input to the
/// model — but it is not a human speaking, and banding it as one puts a false landmark in
/// the middle of an assistant turn. A `user` line that carries no prose is machinery.
public func speakerFor(lineType: String, hasText: Bool) -> Speaker {
    let s = Speaker(lineType: lineType)
    if s == .human && !hasText { return .system }
    return s
}
