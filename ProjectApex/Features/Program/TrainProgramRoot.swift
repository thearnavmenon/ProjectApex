// TrainProgramRoot.swift
// ProjectApex — Features/Program
//
// The Phase 3 Train program root: the plan, drawn as a measured vertical day-spine
// (train.md §3, ADR-0028). The left edge is the time datum; days hang off it down
// the page; the generation horizon is a marked position on the spine.
//
//   • Above the horizon — generated days render INK with numbers (real prescriptions).
//   • Below the horizon — skeleton days render PENCIL shape-only (pattern/focus, no
//     number) inside the to-be-placed sparse-diagonal hatch zone.
//   • A drawn GenerationHorizonBreak datum separates the two (material alone is
//     insufficient — ink-muted already means time/metadata everywhere else).
//   • The commitment gradient is DISCRETE tiers (CommitmentTier), not a fade.
//   • Position lockup "Week X of N" via DraftingRegister.
//   • This-week days are spine rows, each with a StatusTick; rest days are
//     first-class recessed RestWellNode nodes.
//   • No streaks / rings / counters / adherence (honesty — a plan, not a report card).
//
// DORMANT: a NEW screen routed only by the dormant 3-tab shell (AppShell.surface(.train),
// behind useNewShell = false, ADR-0026). The live ProgramOverviewView + ContentView are
// untouched and keep running until the #376 flip.
//
// THE TICK MAPPING + THE INVERSION LIVE HERE (StatusTick is a dumb primitive,
// train.md §3 / ADR-0028 two-axis model):
//   - (TrainingDayStatus + horizon position) → StatusTickValue is mapped in this file.
//   - Rest day  = a day-of-week with NO TrainingDay  → RestWellNode.
//   - Skeleton day = a day in a MesocycleSkeleton/WeekIntent with no generated
//     PlannedExercises (below the horizon) → pencil shape only.
//   No enum case is added to the persisted Codable TrainingDayStatus; no model changes.
//
// MOTION: every row renders assembled at frame 1; a day re-resolving on screen
// hard-swaps assembled (≤150ms crossfade in the host's #376 lifecycle), never a
// tween/cascade/flourish; no idle animation (train.md §2).
//
// THE PROGRAMVIEWMODEL SEAM (reported in the PR): AppShell does NOT host
// ProgramViewModel yet (lifted in #376, machinery-last). So this view takes its data
// as an injectable `ViewState` (a Mesocycle + skeleton + the current-week index,
// reduced to spine rows) so snapshot/unit tests drive it with fixtures. The host
// reads the SAME UserDefaults fast-path ProgramViewModel.loadProgram() uses first
// (Mesocycle.loadFromUserDefaults, a @MainActor sync source needing no service), and
// renders an honest empty state when no program is cached. See `// #376:` below.

import SwiftUI

// MARK: - TrainProgramRoot (the new root view)

/// The Train program root, drawn as a vertical day-spine (train.md §3).
/// Injectable input: a `ViewState` reduced from a Mesocycle (+ skeleton). The
/// view does no service work — the host owns the data boundary.
struct TrainProgramRoot: View {

    // MARK: Input types

    /// One row on the day-spine: a placed (ink) training day, a skeleton (pencil)
    /// shape, or a first-class rest node. Derived in `ViewState.rows(...)`; the
    /// view only draws what it is handed.
    struct DayRow: Identifiable {
        enum Kind: Equatable {
            /// A placed training day above the horizon — ink with its exercise brief.
            case placed(tick: StatusTickValue, exerciseBrief: String)
            /// A skeleton day below the horizon — pencil shape only (focus, no number).
            case skeleton(focus: String)
            /// A rest day — derived from a day-of-week gap; a recessed well node.
            case rest(recoveryLine: String)
        }

        let id: String
        /// 1 = Monday … 7 = Sunday (ISO-8601). The spine orders rows by this.
        let dayOfWeek: Int
        /// Short pattern / focus label, e.g. "Push A", "Lower — squat focus".
        let title: String
        /// The discrete commitment tier (this-week / compressed / glyph-per-day).
        let tier: CommitmentTier
        /// True for today's row — the one quiet static "today" marker (no pulse).
        let isToday: Bool
        let kind: Kind
    }

    /// The whole reduced screen state. Injectable so tests drive it with fixtures.
    struct ViewState {
        /// 1-based current week number (the work number, ink).
        let weekNumber: Int
        /// Total weeks in the cycle (the "of N", pencil).
        let totalWeeks: Int
        /// The cycle's name / intent if it has one ("Strength block"); else nil.
        let cycleName: String?
        /// The this-week spine rows (placed days + rest nodes), in day order.
        let thisWeekRows: [DayRow]
        /// The compressed horizon rows below the datum (skeleton shape only).
        let horizonRows: [DayRow]

        /// True when there is nothing to draw — the honest empty state.
        var isEmpty: Bool { thisWeekRows.isEmpty && horizonRows.isEmpty }
    }

    // MARK: Input

    let state: ViewState

    @Environment(\.apexTheme) private var theme

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                positionLockup

                if state.isEmpty {
                    emptyState
                } else {
                    thisWeekSpine
                    horizonZone
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.paper.color.ignoresSafeArea())
    }

    // MARK: Position lockup — "Week X of N" (DraftingRegister grammar)

    /// "Week 2 of 6" + the cycle name/intent if present (splash-today.md evidence
    /// lockup: work numbers ink, "of N" pencil). No "weeks completed" bar — that is
    /// the banned adherence totalizer (train.md §3, §11.4).
    private var positionLockup: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            DraftingRule(style: .solid, showsMarginTick: true)

            // "Week 2" ink + " of 6" pencil.
            (InkPencil.run(
                ink: "Week \(state.weekNumber)",
                pencil: " of \(state.totalWeeks)",
                theme: theme
            ))
            .apexFont(.title)
            .monospacedDigit()

            if let name = state.cycleName, !name.isEmpty {
                Text(name)
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
            }
        }
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Week \(state.weekNumber) of \(state.totalWeeks)"
            + (state.cycleName.map { ". \($0)" } ?? "")
        )
    }

    // MARK: This week — the spine, in full

    private var thisWeekSpine: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.thisWeekRows) { row in
                spineRow(row)
                Divider().overlay(theme.hairline.color)
            }
        }
        .padding(.top, Spacing.sm)
    }

    /// One this-week row: a status tick (or a rest well node) + the day's brief.
    @ViewBuilder
    private func spineRow(_ row: DayRow) -> some View {
        switch row.kind {
        case .rest(let recoveryLine):
            // Rest is first-class — a recessed well node, never a gap or grayed cell.
            RestWellNode(recoveryLine: recoveryLine)
                .padding(.vertical, Spacing.xs)

        case .placed(let tick, let brief):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                StatusTick(
                    value: tick,
                    isToday: row.isToday,
                    accessibilityLabel: tickLabel(for: tick, title: row.title)
                )
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(row.title)               // pattern / focus — ink
                        .apexFont(.body)
                        .foregroundStyle(theme.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if !brief.isEmpty {
                        Text(brief)               // the session's exercises in brief — ink
                            .apexFont(.label)
                            .foregroundStyle(theme.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)

        case .skeleton(let focus):
            // A this-week day can fall below the horizon (per-day granularity): render
            // it as a pencil shape-only row even within the week. No tick (undrawn).
            skeletonRow(title: row.title, focus: focus)
        }
    }

    // MARK: The horizon, compressed — skeleton shape only, on the gradient

    /// The remaining weeks below the datum: the drawn horizon break, then the
    /// to-be-placed hatch zone carrying the pencil skeleton rows.
    @ViewBuilder
    private var horizonZone: some View {
        if !state.horizonRows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // The drawn datum — "PLACED ABOVE · SHAPE BELOW".
                GenerationHorizonBreak()
                    .padding(.vertical, Spacing.sm)

                // The skeleton zone: the sparse-diagonal hatch behind the pencil rows.
                ZStack(alignment: .topLeading) {
                    ToBePlacedHatch()
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(state.horizonRows) { row in
                            horizonRow(row)
                        }
                    }
                }
            }
        }
    }

    /// A skeleton row below the datum, rendered at its commitment tier:
    ///   - .compressed   → a brief pencil shape (focus line).
    ///   - .glyphPerDay  → one pencil glyph (the title only).
    @ViewBuilder
    private func horizonRow(_ row: DayRow) -> some View {
        switch row.kind {
        case .skeleton(let focus):
            switch row.tier {
            case .glyphPerDay:
                skeletonRow(title: row.title, focus: "")    // one pencil glyph per day
            case .compressed, .thisWeek:
                skeletonRow(title: row.title, focus: focus)  // compressed brief shape
            }
        case .rest(let recoveryLine):
            RestWellNode(recoveryLine: recoveryLine)
                .padding(.vertical, Spacing.xs)
        case .placed(let tick, let brief):
            // Defensive: a placed day in the horizon set still draws as a placed row.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                StatusTick(value: tick, accessibilityLabel: tickLabel(for: tick, title: row.title))
                Text(brief.isEmpty ? row.title : "\(row.title) · \(brief)")
                    .apexFont(.label)
                    .foregroundStyle(theme.ink.color)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    /// A pencil shape-only row (no tick, no number) — the skeleton render.
    private func skeletonRow(title: String, focus: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .apexFont(.body)
                .foregroundStyle(theme.inkMuted.color)     // pencil — model hasn't placed it
                .fixedSize(horizontal: false, vertical: true)
            if !focus.isEmpty {
                Text(focus)
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.leading, Spacing.lg)                     // inset so the hatch reads behind it
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). Shape only — placed closer to the day.")
    }

    // MARK: Empty state (honest — never a fabricated frame)

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("No program yet")
                .apexFont(.body)
                .foregroundStyle(theme.ink.color)
            Text("Your plan appears here once it's generated.")
                .apexFont(.label)
                .foregroundStyle(theme.inkMuted.color)
        }
        .padding(.vertical, Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: VoiceOver copy for a tick (the instrument has no fallback copy)

    private func tickLabel(for value: StatusTickValue, title: String) -> String {
        switch value {
        case .filled:  return "\(title) — done."
        case .hollow:  return "\(title) — scheduled."
        case .undrawn: return "\(title) — shape only."
        }
    }
}

// MARK: - Derivation (the tick mapping + the inversion — PURE, testable, no model change)

extension TrainProgramRoot {

    /// The day-status tick mapping (train.md §3, ADR-0028 two-axis model). StatusTick
    /// is a dumb primitive, so THIS is where (TrainingDayStatus + horizon position)
    /// resolves to a StatusTickValue:
    ///   - completed                          → .filled  (a logged fact — no count/ring)
    ///   - generated / paused                 → .hollow  (committed, not done)
    ///   - pending ABOVE the horizon          → .hollow  (placed-and-waiting)
    ///   - skeleton / BELOW the horizon       → .undrawn (the hatch zone carries it)
    ///   - skipped                            → .hollow  (stayed-hollow — NO shame mark;
    ///                                          "missed = a day the plan moved past")
    ///
    /// `isAboveHorizon` is the generation-horizon position: a day is above the
    /// horizon when its session has been generated (has placed prescriptions). A
    /// `pending` day below the horizon is skeleton → `.undrawn`.
    static func tickValue(for status: TrainingDayStatus, isAboveHorizon: Bool) -> StatusTickValue {
        switch status {
        case .completed:
            return .filled
        case .generated, .paused:
            return .hollow
        case .skipped:
            // Stayed-hollow: a missed day is just a day the plan moved past — no shame mark.
            return .hollow
        case .pending:
            // Placed-but-waiting reads hollow above the horizon; skeleton below it.
            return isAboveHorizon ? .hollow : .undrawn
        }
    }

    /// THE INVERSION (train.md §3 #357 amendment): a placed day has generated
    /// `PlannedExercise`s; a skeleton day does not. A day is "above the horizon"
    /// iff it carries real prescriptions — derived from EXISTING state, no model
    /// change. A `.completed`/`.generated`/`.paused` day is always above the
    /// horizon (it has been resolved) even if its exercise array wasn't persisted.
    static func isAboveHorizon(_ day: TrainingDay) -> Bool {
        if !day.exercises.isEmpty { return true }
        switch day.status {
        case .completed, .generated, .paused, .skipped: return true
        case .pending: return false
        }
    }
}

// MARK: - ViewState construction from a Mesocycle (+ optional skeleton)

extension TrainProgramRoot.ViewState {

    /// The canonical rest-day line (train.md §3: state what recovery buys, never a gap).
    static let restLine = "Rest — recovery builds the adaptation."

    /// Builds the screen state from a live `Mesocycle`. The current week is the
    /// week index supplied (ProgramViewModel.currentWeekIndex in the host); rows are
    /// derived for this week (full spine, rest-from-gaps) and the remaining weeks
    /// (compressed skeleton shapes on the discrete commitment gradient).
    ///
    /// `trainingDaysPerWeek` drives rest-day derivation: any of the 7 weekdays with
    /// no `TrainingDay` in the week becomes a `RestWellNode` (the gap → rest inversion).
    /// `todayWeekday` (1…7, default = the live weekday) marks the one static today row.
    static func from(
        mesocycle: Mesocycle,
        currentWeekIndex: Int,
        todayWeekday: Int = Calendar.current.component(.weekday, from: Date())
    ) -> TrainProgramRoot.ViewState {
        let weeks = mesocycle.weeks
        guard !weeks.isEmpty else {
            return TrainProgramRoot.ViewState(
                weekNumber: 1, totalWeeks: mesocycle.totalWeeks,
                cycleName: nil, thisWeekRows: [], horizonRows: []
            )
        }
        let weekIdx = min(max(0, currentWeekIndex), weeks.count - 1)
        let thisWeek = weeks[weekIdx]

        // ── This week: placed/skeleton day rows + rest-from-gaps, in weekday order. ──
        let thisWeekRows = spineRows(
            for: thisWeek,
            todayWeekday: convertToISOWeekday(todayWeekday),
            tier: .thisWeek
        )

        // ── The horizon: remaining weeks, compressed skeleton shapes on the gradient. ──
        var horizonRows: [TrainProgramRoot.DayRow] = []
        for (offset, week) in weeks.enumerated() where offset > weekIdx {
            // Distance-from-now in days, bucketed into the discrete tier.
            let weeksOut = offset - weekIdx
            let tier = CommitmentTier.forDistance(days: weeksOut * 7)
            for day in week.trainingDays.sorted(by: { $0.dayOfWeek < $1.dayOfWeek }) {
                let focus = day.dayLabel.replacingOccurrences(of: "_", with: " ")
                horizonRows.append(
                    TrainProgramRoot.DayRow(
                        id: day.id.uuidString,
                        dayOfWeek: day.dayOfWeek,
                        title: focus,
                        tier: tier,
                        isToday: false,
                        kind: .skeleton(focus: weekFocusLine(week))
                    )
                )
            }
        }

        // Cycle name from the periodization model, humanized (e.g. "Linear Periodization").
        let cycleName = mesocycle.periodizationModel
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        return TrainProgramRoot.ViewState(
            weekNumber: thisWeek.weekNumber,
            totalWeeks: mesocycle.totalWeeks,
            cycleName: cycleName.isEmpty ? nil : cycleName,
            thisWeekRows: thisWeekRows,
            horizonRows: horizonRows
        )
    }

    /// The this-week spine: every weekday 1…7. A weekday with a `TrainingDay`
    /// renders a placed/skeleton row (per the horizon); a weekday with NO
    /// `TrainingDay` renders a `RestWellNode` (the gap → rest inversion).
    static func spineRows(
        for week: TrainingWeek,
        todayWeekday: Int,
        tier: CommitmentTier
    ) -> [TrainProgramRoot.DayRow] {
        let daysByWeekday = Dictionary(
            week.trainingDays.map { ($0.dayOfWeek, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [TrainProgramRoot.DayRow] = []
        for weekday in 1...7 {
            if let day = daysByWeekday[weekday] {
                let title = day.dayLabel.replacingOccurrences(of: "_", with: " ")
                let above = TrainProgramRoot.isAboveHorizon(day)
                if above {
                    rows.append(
                        TrainProgramRoot.DayRow(
                            id: day.id.uuidString,
                            dayOfWeek: weekday,
                            title: title,
                            tier: tier,
                            isToday: weekday == todayWeekday,
                            kind: .placed(
                                tick: TrainProgramRoot.tickValue(for: day.status, isAboveHorizon: true),
                                exerciseBrief: exerciseBrief(day)
                            )
                        )
                    )
                } else {
                    // A this-week day below the horizon — skeleton shape only.
                    rows.append(
                        TrainProgramRoot.DayRow(
                            id: day.id.uuidString,
                            dayOfWeek: weekday,
                            title: title,
                            tier: tier,
                            isToday: weekday == todayWeekday,
                            kind: .skeleton(focus: "numbers placed closer to the day")
                        )
                    )
                }
            } else {
                // No TrainingDay this weekday → a first-class rest node (the gap inversion).
                rows.append(
                    TrainProgramRoot.DayRow(
                        id: "rest-\(week.id.uuidString)-\(weekday)",
                        dayOfWeek: weekday,
                        title: "Rest",
                        tier: tier,
                        isToday: weekday == todayWeekday,
                        kind: .rest(recoveryLine: restLine)
                    )
                )
            }
        }
        return rows
    }

    /// A terse exercise brief for a placed day, e.g. "Bench · Overhead Press · Cable Fly".
    /// Names only — no loads (the day-preview, §4, carries the full prescription).
    private static func exerciseBrief(_ day: TrainingDay) -> String {
        day.exercises.map(\.name).joined(separator: " · ")
    }

    /// The week's focus line for a skeleton row — humanized from the week label, or
    /// the phase if there is no label. Pattern/focus only, never a number.
    private static func weekFocusLine(_ week: TrainingWeek) -> String {
        if let label = week.weekLabel, !label.isEmpty { return label }
        return week.phase.rawValue.capitalized
    }

    /// `Calendar.weekday` is 1 = Sunday … 7 = Saturday; the model's `dayOfWeek` is
    /// 1 = Monday … 7 = Sunday (ISO-8601). Convert so "today" lands on the right row.
    private static func convertToISOWeekday(_ calendarWeekday: Int) -> Int {
        // calendar: 1=Sun,2=Mon,…,7=Sat  →  ISO: 1=Mon,…,6=Sat,7=Sun
        let iso = ((calendarWeekday + 5) % 7) + 1
        return iso
    }
}

// MARK: - TrainProgramRootHost (wired to deps, rendered by AppShell)

/// The live host: the data boundary for the dormant Train surface.
///
/// THE #376 SEAM — reported in the PR. AppShell does NOT host `ProgramViewModel`
/// yet (its lifecycle is lifted in #376, machinery-last). Rather than reach for a
/// ProgramViewModel that does not exist on `deps`, this host reads the SAME
/// UserDefaults fast-path `ProgramViewModel.loadProgram()` consults first
/// (`Mesocycle.loadFromUserDefaults()` — a `@MainActor` sync source needing no
/// service). When no program is cached, it renders the honest empty state.
///
/// What #376 must lift here when ProgramViewModel becomes available to the shell:
///   - the live current-week index (`ProgramViewModel.currentWeekIndex(in:)`) instead
///     of the cache's first incomplete week derived locally;
///   - the generation-in-flight states (`.generating` / `.generatingSession`) so a
///     day re-resolving on screen hard-swaps assembled (≤150ms crossfade);
///   - observation of `currentMesocycle` so an in-place day mutation re-renders.
struct TrainProgramRootHost: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(\.apexTheme) private var theme
    @State private var state: TrainProgramRoot.ViewState?

    var body: some View {
        Group {
            if let state {
                TrainProgramRoot(state: state)
            } else {
                // Loading-or-empty: render the bare root with an empty state, frame-1.
                TrainProgramRoot(state: .init(
                    weekNumber: 1, totalWeeks: 12,
                    cycleName: nil, thisWeekRows: [], horizonRows: []
                ))
            }
        }
        .task {
            // #376: replace this UserDefaults read with the hosted ProgramViewModel
            // (live week index + generation-in-flight states + in-place observation).
            guard let mesocycle = Mesocycle.loadFromUserDefaults() else { return }
            let weekIdx = Self.firstIncompleteWeekIndex(in: mesocycle)
            state = .from(mesocycle: mesocycle, currentWeekIndex: weekIdx)
        }
    }

    /// The current-week index, derived locally from the cache (mirrors
    /// `ProgramViewModel.currentWeekIndex(in:)`): the first week containing a
    /// non-terminal day. #376 swaps this for the hosted ProgramViewModel's own.
    static func firstIncompleteWeekIndex(in mesocycle: Mesocycle) -> Int {
        for (wIdx, week) in mesocycle.weeks.enumerated() {
            for day in week.trainingDays where day.status != .completed && day.status != .skipped {
                return wIdx
            }
        }
        return max(0, mesocycle.weeks.count - 1)
    }
}
