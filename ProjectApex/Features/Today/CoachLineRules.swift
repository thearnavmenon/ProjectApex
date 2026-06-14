// CoachLineRules.swift
// ProjectApex — Features/Today
//
// The deterministic coach-line rule engine for Today (splash-today.md layout item 2,
// coach-voice.md §2.2 "deterministic local fallback"). This is the PRIMARY path for
// v1 — the AI line is an optional upgrade, never a dependency (coach-voice.md D4).
//
// GOVERNED by docs/design/coach-voice.md. Every output:
//   • is grounded in ≥1 verifiable model number (§2.1) drawn from TraineeModelDigest;
//   • is instrument-grade — D1 no-warmth: factual observation, NO encouragement,
//     praise, friendliness, hype, or mascot voice (§3.2, §5 banned registers);
//   • fits the hard character budget (§4.1); a line over budget is rejected;
//   • collapses to "" (an empty slot) when nothing meaningful is true — never filler
//     (§2.4). The slot's layout-stable collapse is the view's job (TodayView).
//
// The RANKED rules (highest priority fires first) — each cites its constitution
// clauses in `// clause:` and is grounded in a named digest number:
//
//   1. floorPosition   — the next session's pattern floor (PatternProjection.floor).
//                        "Squat floor at 105 kg — square in the band."
//                        Grounds: §2.1 (number). Clause: §3.3 flat-day grammar — a
//                        held position is stated as a true number, not punished.
//   2. ratchetNear     — the same pattern is `ahead` of its band → the forward hook.
//                        "Squat 2.5 kg under the next floor."
//                        Grounds: §2.1 (floor/stretch gap). Clause: §3.3 forward hook
//                        (a deterministic distance-to-ratchet fact, not invention).
//   3. calibrating     — the pattern's confidence is bootstrapping/calibrating.
//                        "Squat still calibrating — 3 sessions logged."
//                        Grounds: §2.1 (totalSessionCount). Clause: §2.4 absent-data-
//                        stated + §3.6 beginner-reassurance form (names the mechanism
//                        and the count; the count is model-derived per D5).
//   4. sessionTally    — last-resort grounded fact: the lifetime session count.
//                        "42 sessions logged."
//                        Grounds: §2.1 (totalSessionCount). Clause: §3.1 terse honesty.
//   5. (collapse)      — none fire (placeholder goal / no projections / 0 sessions)
//                        → "" empty slot. Clause: §2.4 / D1 (never generic
//                        encouragement, never filler).
//
// All rules are PURE and synchronous — no AI call, no service, no I/O. The whole
// engine is one `static func` over a digest, so the rule selection is unit-testable
// against fixtures.

import Foundation

// MARK: - CoachLineRules

enum CoachLineRules {

    // MARK: Length contract (coach-voice.md §4.1)

    /// Hard character budget — coach-voice.md §4.1 ("approximately 60–80 characters …
    /// fits 2 lines at default type"). A line over this fails validation and the next
    /// rule (ultimately the empty collapse) fires. Picked at 80 = the upper bound of
    /// the spec's stated range; every deterministic template below is well under it.
    static let maxCharacters = 80

    // MARK: The banned-warmth lexicon (coach-voice.md §5 / D1)

    /// The warmth / encouragement / hype vocabulary D1 forbids (coach-voice.md §5
    /// banned registers, §3.2). The constitution-adherence guard asserts that no
    /// deterministic output contains any of these as a whole word. This is the
    /// executable form of D1 "no warmth" — a string with one of these is, by
    /// definition, not instrument-grade.
    static let bannedWarmthWords: [String] = [
        // praise-inflation / generic encouragement (§5 rows 2–3)
        "amazing", "great", "awesome", "incredible", "fantastic", "nice",
        "good job", "well done", "proud", "love", "perfect", "excellent",
        "crushed", "crush", "killing", "smashed", "smash",
        // hype / mascot register (§5 row 4)
        "beast", "beast mode", "let's go", "lets go", "let's get it",
        "you got this", "you've got this", "keep it up", "keep pushing",
        "keep going", "go hard", "push hard", "stay strong",
        // greetings / second-person openers (§5 row 1, §3.2)
        "welcome", "good morning", "good evening", "hey", "hi there",
    ]

    // MARK: The engine

    /// Produce the ONE deterministic coach line for the given digest + next-session
    /// pattern. Returns "" (the empty-slot collapse) when nothing meaningful is true.
    ///
    /// `nextPattern` is the movement pattern of the next session's primary lift (the
    /// pattern the line speaks to). When nil — no session to anchor to — the engine
    /// falls through to the non-pattern rules (session tally) or collapses.
    static func line(
        for digest: TraineeModelDigest,
        nextPattern: MovementPattern?
    ) -> String {
        for rule in orderedRules {
            if let candidate = rule(digest, nextPattern),
               isValid(candidate) {
                return candidate
            }
        }
        return ""   // collapse — never filler (§2.4 / D1)
    }

    /// Which rule fired, for the unit tests' "right rule for the model state" assertions.
    /// Returns nil when the line collapses.
    static func firingRule(
        for digest: TraineeModelDigest,
        nextPattern: MovementPattern?
    ) -> Rule? {
        for (kind, rule) in zip(Rule.allCases, orderedRules) {
            if let candidate = rule(digest, nextPattern), isValid(candidate) {
                return kind
            }
        }
        return nil
    }

    // MARK: Validation (the length + warmth gate)

    /// A candidate is valid iff it is non-empty, within the character budget (§4.1),
    /// carries no ellipsis (§4.1: a truncated grounding is a fabrication), and uses
    /// no banned-warmth vocabulary (§5 / D1). The empty-collapse path is the absence
    /// of any valid candidate.
    static func isValid(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        guard line.count <= maxCharacters else { return false }
        guard !line.contains("…") && !line.contains("...") else { return false }
        return !containsBannedWarmth(line)
    }

    /// True iff the line contains any banned-warmth word as a whole word (case- and
    /// punctuation-insensitive). The guard the constitution-adherence test asserts.
    static func containsBannedWarmth(_ line: String) -> Bool {
        let tokens = Set(
            line.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        for banned in bannedWarmthWords {
            let parts = banned.split(separator: " ").map(String.init)
            if parts.count == 1 {
                if tokens.contains(parts[0]) { return true }
            } else {
                // Multi-word phrase: substring match on the normalized line.
                let normalized = line.lowercased()
                if normalized.contains(banned) { return true }
            }
        }
        return false
    }

    // MARK: - Rule kinds (for test assertions)

    enum Rule: CaseIterable {
        case calibrating
        case floorPosition
        case ratchetNear
        case sessionTally
    }

    /// The ranked rules, in priority order — `Rule.allCases` order MUST match this
    /// array (firingRule zips them). Calibrating outranks floor-position because an
    /// estimated floor must not be stated as fact while the band is still being
    /// established (§2.4 absent-data-stated > §3.3 flat-day grammar).
    private static var orderedRules: [(TraineeModelDigest, MovementPattern?) -> String?] {
        [
            calibratingRule,     // .calibrating
            floorPositionRule,   // .floorPosition
            ratchetNearRule,     // .ratchetNear
            sessionTallyRule,    // .sessionTally
        ]
    }

    // MARK: Rule 1 — floor position (§2.1 grounding; §3.3 flat-day grammar)

    /// "Squat floor at 105 kg — square in the band." A held position stated as a true
    /// number (§3.3: a flat day is respected, not punished — the number is the warmth).
    /// Fires only when the pattern is on-track or behind (not ahead — that is the
    /// forward-hook rule's job) and we have a real floor.
    private static func floorPositionRule(
        _ digest: TraineeModelDigest, _ pattern: MovementPattern?
    ) -> String? {
        guard let pattern,
              let proj = projection(for: pattern, in: digest),
              proj.floor > 0 else { return nil }
        guard proj.progress == .onTrack || proj.progress == .behind || proj.progress == .achieved
        else { return nil }
        return "\(pattern.displayName) floor at \(formatKg(proj.floor)) kg — square in the band."
    }

    // MARK: Rule 2 — ratchet near (§3.3 forward hook — deterministic distance fact)

    /// "Squat 2.5 kg under the next floor." The forward hook: a deterministic
    /// distance-to-stretch fact (§3.3) — fires when the pattern is `ahead`, i.e.
    /// pushing the top of its band, and the stretch sits above the floor.
    private static func ratchetNearRule(
        _ digest: TraineeModelDigest, _ pattern: MovementPattern?
    ) -> String? {
        guard let pattern,
              let proj = projection(for: pattern, in: digest),
              proj.progress == .ahead,
              proj.stretch > proj.floor else { return nil }
        let gap = proj.stretch - proj.floor
        return "\(pattern.displayName) \(formatKg(gap)) kg under the next floor."
    }

    // MARK: Rule 3 — calibrating (§2.4 absent-data-stated + §3.6 beginner form)

    /// "Squat still calibrating — 3 sessions logged." Names the mechanism and the
    /// model-derived count (§3.6 beginner-reassurance form; the count is the digest's
    /// totalSessionCount, never hardcoded — D5). Fires when the next pattern's
    /// confidence is still bootstrapping/calibrating.
    private static func calibratingRule(
        _ digest: TraineeModelDigest, _ pattern: MovementPattern?
    ) -> String? {
        guard let pattern,
              let summary = digest.perPatternSummary.first(where: { $0.pattern == pattern }),
              !summary.confidence.isMeasured else { return nil }
        let n = digest.totalSessionCount
        guard n > 0 else { return nil }
        return "\(pattern.displayName) still calibrating — \(n) \(sessionWord(n)) logged."
    }

    // MARK: Rule 4 — session tally (§3.1 terse honesty — last-resort grounded fact)

    /// "42 sessions logged." The last grounded fact when nothing sharper is true — a
    /// plain count, no adjective (§3.1). Fires only when at least one session exists;
    /// zero sessions collapses (the empty-slot, §2.4).
    private static func sessionTallyRule(
        _ digest: TraineeModelDigest, _ pattern: MovementPattern?
    ) -> String? {
        let n = digest.totalSessionCount
        guard n > 0 else { return nil }
        return "\(n) \(sessionWord(n)) logged."
    }

    // MARK: - Helpers

    /// The pattern's projection from the digest, if present.
    private static func projection(
        for pattern: MovementPattern, in digest: TraineeModelDigest
    ) -> PatternProjection? {
        digest.projections?.patternProjections.first { $0.pattern == pattern }
    }

    /// Round to the nearest 0.5 kg (gym-plate granularity); whole numbers drop the
    /// decimal. Mirrors the formatKg convention in ProgressRootLedger.
    static func formatKg(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    private static func sessionWord(_ n: Int) -> String {
        n == 1 ? "session" : "sessions"
    }
}
