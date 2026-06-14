// TodayRootHost.swift
// ProjectApex — Features/Today
//
// The data boundary for the dormant Today surface + the pure ViewState reducer.
//
// THE #376 SEAM (reported in the PR). AppShell does NOT host ProgramViewModel yet
// (its lifecycle is lifted in #376, machinery-last). Rather than reach for a
// ProgramViewModel that does not exist on `deps`, this host reads the SAME sources
// ProgramViewModel.loadProgram() consults first:
//   • Mesocycle.loadFromUserDefaults()  — the next session (a @MainActor sync source);
//   • deps.traineeModelService.read()   — the trainee model → TraineeModelDigest,
//                                         the coach line's grounding numbers.
// When no program is cached, it renders the honest empty state. Readiness is NOT yet
// a deps service (the P4 stub), so the Lens is slot-reserved at `.unknown` — the
// honest Calibrating state, NOT a hard gate (splash-today.md §The Lens).
//
// What #376 must lift here when ProgramViewModel becomes available to the shell:
//   • the live next-incomplete day (ProgramViewModel.nextIncompleteDay(in:)) +
//     generation-in-flight states, instead of the cache's first incomplete day;
//   • the real session-start path off Start (PreWorkoutView / WorkoutViewModel —
//     the same flow the legacy switchToTab(1) → presentLiveLoop reaches);
//   • a real ReadinessScore source for the Lens (the P4 computation), instead of
//     the honest `.unknown` slot;
//   • durable coach-alert binding to the existing ack machinery (calibration-review
//     ack, re-armed re-calibration banner #305, goal review P5-D06).

import SwiftUI

// MARK: - TodayRootHost (wired to deps, rendered by AppShell)

/// The live host: the data boundary for the dormant Today surface. Builds the
/// injectable `TodayView.ViewState` from the cached program + the trainee-model
/// digest, then renders the pure `TodayView`.
struct TodayRootHost: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(\.apexTheme) private var theme
    @State private var state: TodayView.ViewState?

    var body: some View {
        Group {
            if let state {
                TodayView(state: state, onStart: start)
            } else {
                // Loading-or-empty: render the bare root with an honest empty state,
                // frame-1 (no spinner — local-first, splash-today.md §Degraded).
                TodayView(state: .empty, onStart: start)
            }
        }
        .task {
            // #376: replace these reads with the hosted ProgramViewModel (live
            // next-incomplete day + generation-in-flight states + observation) and a
            // real ReadinessScore source for the Lens.
            let mesocycle = Mesocycle.loadFromUserDefaults()
            let digest = await loadDigest()
            state = .from(mesocycle: mesocycle, digest: digest)
        }
    }

    /// Read the trainee model and project it to a digest (the coach line's grounding).
    /// Returns nil on a cold model (the coach line then collapses honestly).
    private func loadDigest() async -> TraineeModelDigest? {
        guard let model = await deps.traineeModelService.read() else { return nil }
        return TraineeModelDigest(from: model)
    }

    /// The one-tap Start action.
    ///
    /// #376: wire this to the existing session-start path — the same flow the legacy
    /// `switchToTab(1)` → `presentLiveLoop` reaches (PreWorkoutView → WorkoutViewModel
    /// → WorkoutSessionManager.startSession). It is intentionally inert in the dormant
    /// shell: there is no backend change in this slice, and the live-loop host is
    /// lifted in #376 (machinery-last, ADR-0026). The button is wired + tappable now so
    /// the surface is complete; the action becomes live at the flip.
    private func start() {
        // #376: deps-driven session start goes here (no-op until the live-loop lift).
    }
}

// MARK: - ViewState reduction from a Mesocycle (+ digest) — PURE, testable

extension TodayView.ViewState {

    /// The honest empty state — no program cached, no coach line, the Lens reserved.
    static let empty = TodayView.ViewState(
        dateLabel: Self.todayDateLabel(),
        lensState: .unknown,
        coachLine: "",
        sessionCard: nil,
        alerts: []
    )

    /// Build the screen state from the cached program + the trainee-model digest.
    /// PURE over its inputs (no service, no I/O) so unit/snapshot tests drive it.
    ///
    /// - The next session is the first non-terminal training day across the cache
    ///   (mirrors ProgramViewModel.nextIncompleteDay — #376 swaps in the live one).
    /// - The coach line is the deterministic rule engine over the digest, anchored to
    ///   the next session's primary-lift pattern (CoachLineRules). Empty ⇒ collapse.
    /// - The Lens is `.unknown` (slot-reserved) until a readiness source exists (#376).
    static func from(
        mesocycle: Mesocycle?,
        digest: TraineeModelDigest?,
        asOf reference: Date = Date()
    ) -> TodayView.ViewState {
        let dateLabel = todayDateLabel(asOf: reference)

        guard let mesocycle,
              let next = nextIncompleteDay(in: mesocycle) else {
            // No program / no session → honest empty state (the coach line still
            // collapses; a session tally would have no session anchor anyway).
            let line = digest.map { CoachLineRules.line(for: $0, nextPattern: nil) } ?? ""
            return TodayView.ViewState(
                dateLabel: dateLabel,
                lensState: .unknown,
                coachLine: line,
                sessionCard: nil,
                alerts: []
            )
        }

        let (day, week) = next
        let pattern = primaryPattern(of: day)

        // The coach line — deterministic, grounded in the digest, anchored to the
        // next session's pattern. Empty when nothing meaningful is true (collapse).
        let coachLine = digest.map {
            CoachLineRules.line(for: $0, nextPattern: pattern)
        } ?? ""

        let card = sessionCard(for: day, week: week, totalWeeks: mesocycle.totalWeeks)

        return TodayView.ViewState(
            dateLabel: dateLabel,
            lensState: .unknown,   // #376: real ReadinessScore source
            coachLine: coachLine,
            sessionCard: card,
            alerts: []             // #376: durable alert binding to ack machinery
        )
    }

    // MARK: Session-card reduction

    /// Reduce a TrainingDay into the hero card content (splash-today.md layout item 3).
    private static func sessionCard(
        for day: TrainingDay, week: TrainingWeek, totalWeeks: Int
    ) -> TodayView.SessionCard {
        let title = day.dayLabel.replacingOccurrences(of: "_", with: " ")
        let dayCount = week.trainingDays.count
        let eyebrow = "TODAY · WEEK \(week.weekNumber) OF \(totalWeeks) · \(dayCount)-DAY"

        // Up to 3 evidence lines, model-placed order (the day's exercise order).
        let shown = day.exercises.prefix(3)
        let evidence = shown.map { ex in
            TodayView.EvidenceLine(
                exerciseName: ex.name,
                setsRepsLoad: "\(ex.sets)×\(ex.repRange.min)–\(ex.repRange.max)",
                unit: " reps"
            )
        }
        let overflowCount = day.exercises.count - shown.count
        let overflow = overflowCount > 0 ? "+\(overflowCount) accessories" : nil

        return TodayView.SessionCard(
            eyebrow: eyebrow,
            title: title,
            evidenceLines: Array(evidence),
            overflowNote: overflow,
            meta: estimatedDuration(exerciseCount: day.exercises.count),
            startLabel: "Start"
        )
    }

    /// A terse "~N min" estimate from the exercise count (the meta line). A rough
    /// local heuristic — #376 can swap a model-derived estimate if one exists.
    private static func estimatedDuration(exerciseCount: Int) -> String {
        let minutes = max(20, exerciseCount * 12)
        return "~\(minutes) min"
    }

    // MARK: Next-session selection (mirrors ProgramViewModel.nextIncompleteDay)

    /// The first non-terminal (not completed, not skipped) training day across the
    /// cache, searched week-by-week then day-by-day. #376 swaps the live
    /// ProgramViewModel.nextIncompleteDay (which also honors the soft-skip set).
    static func nextIncompleteDay(
        in mesocycle: Mesocycle
    ) -> (day: TrainingDay, week: TrainingWeek)? {
        for week in mesocycle.weeks {
            for day in week.trainingDays where day.status != .completed && day.status != .skipped {
                return (day, week)
            }
        }
        return nil
    }

    /// The next session's primary-lift movement pattern, derived from the day's first
    /// exercise via the canonical ExerciseLibrary (no backend/model change). nil when
    /// the day has no exercises or the id is unknown — the coach line then falls
    /// through to the non-pattern rules (session tally) or collapses.
    static func primaryPattern(of day: TrainingDay) -> MovementPattern? {
        guard let first = day.exercises.first else { return nil }
        return ExerciseLibrary.lookup(first.exerciseId)?.movementPattern
    }

    // MARK: Date label

    /// "Sat 14 Jun" — the margin-row date annotation. Refreshes on render (the host's
    /// `.task` re-runs on appear), so a day rollover shows the right date.
    static func todayDateLabel(asOf reference: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: reference)
    }
}
