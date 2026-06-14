// TodayView.swift
// ProjectApex — Features/Today
//
// The Phase 3 Today root: the coach/home surface (splash-today.md Part 2).
// Answers "what does my coach want from me right now?" in one glance and makes
// starting it one tap:
//
//   • ONE coach line above the hero — grounded in ≥1 concrete model number, with a
//     deterministic rule-based fallback computed with NO AI call. Collapses to an
//     empty (layout-stable) slot when nothing meaningful exists — never filler.
//     GOVERNED by docs/design/coach-voice.md (esp. D1 no-warmth): the rule outputs
//     are instrument-grade observations, no encouragement/praise/warmth.
//   • The hero next-workout card (surface + elevation.card + hairline): eyebrow,
//     pattern title, evidence lines (the SG 600 tnum lockup), meta, and a single
//     full-width one-tap Start.
//   • The compact Lens (#346) wired into the margin row — slot-reserved when
//     readiness is unavailable (the unknown/Calibrating state, not a hard gate).
//   • Coach alerts as a calm list BELOW Start — never pop-ups in front of it.
//   • Drafting-rule hairlines (#411) as the structural drawing.
//
// DORMANT: a NEW screen routed only by the dormant 3-tab shell
// (AppShell.surface(.today), behind useNewShell = false, ADR-0026). The live
// ContentView + ProgramOverviewView are untouched and keep running until #376.
//
// THE VM / START SEAM (reported in the PR): AppShell does NOT host ProgramViewModel
// yet (lifted in #376, machinery-last). So this view takes its data as an injectable
// `ViewState` (the next session + the coach line + the Lens state, reduced to a
// render model) so snapshot/unit tests drive it with fixtures. The host reads the
// SAME UserDefaults fast-path ProgramViewModel.loadProgram() consults first
// (Mesocycle.loadFromUserDefaults) plus the trainee-model digest, and renders an
// honest empty state when nothing is cached. Start wires to the existing
// session-start path behind a `// #376:` TODO — wired, not live, until the flip.
//
// MOTION: assembled at frame 1; no idle animation. Reduce-Motion crossfade is the
// only entrance (the bookend ink-flood lives in the #376 live-loop lifecycle).

import SwiftUI

// MARK: - TodayView (the new root view)

/// The Today root (splash-today.md Part 2). Injectable input: a `ViewState` reduced
/// from a Mesocycle (next session) + a TraineeModelDigest (the coach line's grounding)
/// + an optional readiness LensState. The view does no service work — the host owns
/// the data boundary.
struct TodayView: View {

    // MARK: Input types

    /// One evidence line in the hero card — the typographic signature (splash-today.md
    /// layout item 3): exercise name left (tail-truncates), the numbers right as a
    /// lockup (SG 600 tnum), units in `ink-muted`. Numbers NEVER truncate.
    struct EvidenceLine: Identifiable {
        let id = UUID()
        /// Exercise name, left column. Tail-truncates.
        let exerciseName: String
        /// The ink number run, e.g. "5×5 · 102.5" — rendered SG 600 tnum, never truncated.
        let setsRepsLoad: String
        /// The trailing unit, e.g. " kg" — `ink-muted`, beside the lockup.
        let unit: String
    }

    /// A coach-alert row (splash-today.md layout item 4) — a calm `well` row, BELOW
    /// Start, never a pop-up. Severity drives the back-off red exemption.
    struct CoachAlert: Identifiable {
        enum Severity { case backOff, normal }
        let id = UUID()
        let severity: Severity
        let icon: String
        let message: String
    }

    /// The hero next-workout card's content (splash-today.md layout item 3).
    struct SessionCard {
        /// Tracked-caps eyebrow — "TODAY · DAY 2 OF 4".
        let eyebrow: String
        /// Pattern-language title — "Lower — squat focus".
        let title: String
        /// Up to 3 evidence lines (the model showing its work).
        let evidenceLines: [EvidenceLine]
        /// "+2 accessories" overflow line, or nil.
        let overflowNote: String?
        /// `ink-muted` meta line — "~55 min".
        let meta: String
        /// The Start button's label ("Start"). Always present in the happy path.
        let startLabel: String
    }

    /// The whole reduced screen state. Injectable so tests drive it with fixtures.
    struct ViewState {
        /// The date shown in the margin row (the header's right-of-settings annotation).
        let dateLabel: String
        /// The compact Lens readiness state — `.unknown` reserves the slot honestly.
        let lensState: LensState
        /// The ONE coach line — already resolved by the rule engine. Empty ⇒ collapse.
        let coachLine: String
        /// The hero card, or nil for the honest empty state (no program cached).
        let sessionCard: SessionCard?
        /// Calm alert list below Start (may be empty).
        let alerts: [CoachAlert]

        /// True when there is no session to draw — the honest empty state.
        var isEmpty: Bool { sessionCard == nil }
    }

    // MARK: Input

    let state: ViewState
    /// The one-tap Start action. The host wires it to the existing session-start path
    /// behind a `// #376:` TODO; tests inject a spy to assert it fires.
    let onStart: () -> Void

    @Environment(\.apexTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: ViewState, onStart: @escaping () -> Void = {}) {
        self.state = state
        self.onStart = onStart
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                marginRow            // top rule + date + compact Lens
                coachLineSlot        // the ONE coach line (layout-stable; collapses)

                if let card = state.sessionCard {
                    sessionCardView(card)
                    if !state.alerts.isEmpty {
                        alertsList   // calm list BELOW Start — never a pop-up
                    }
                } else {
                    emptyState       // honest "no program" state
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.paper.color.ignoresSafeArea())
    }

    // MARK: Margin row — top rule, date, compact Lens (splash-today.md layout item 1)

    /// The top rule carries the screen's margin annotations: the date `ink-muted`
    /// leading, the compact Lens trailing. (Settings lives in AppShell's corner gear,
    /// not here — the shell owns that affordance.)
    private var marginRow: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            DraftingRule(style: .solid, showsMarginTick: true)
            HStack(alignment: .firstTextBaseline) {
                Text(state.dateLabel)
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
                    .accessibilitySortPriority(1)   // VoiceOver: after coach line + card
                Spacer()
                // The compact Lens — instrument, renders in ink (the written exemption).
                LensView(state: state.lensState)
                    .accessibilitySortPriority(0)
            }
        }
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: Coach line — the ONE verbal voice, layout-stable collapse

    /// `display` type, the screen's only verbal voice. The slot reserves vertical
    /// rhythm so a missing line reads as intentional quiet, not a broken fetch
    /// (coach-voice.md §4.1, splash-today.md layout item 2). Never ellipsized.
    @ViewBuilder
    private var coachLineSlot: some View {
        Group {
            if state.coachLine.isEmpty {
                // Collapse to an empty slot — never filler (D1 / §2.4). The reserved
                // min-height keeps the rhythm stable so absence reads as quiet.
                Color.clear
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            } else {
                Text(state.coachLine)
                    .apexFont(.display)
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)   // wraps, never truncates
                    .accessibilitySortPriority(10)                  // VoiceOver reads first
                    .accessibilityLabel(state.coachLine)
            }
        }
        .frame(minHeight: 44, alignment: .leading)   // reserved rhythm (layout-stable collapse)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: The hero session card — the screen's only elevated surface

    private func sessionCardView(_ card: TodayView.SessionCard) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Eyebrow — tracked caps, ink-muted.
            Text(card.eyebrow)
                .apexFont(.label)
                .tracking(1)
                .foregroundStyle(theme.inkMuted.color)

            // Title — pattern language, ink.
            Text(card.title)
                .apexFont(.title)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            // Evidence lines — the typographic signature (max 3 two-column rows).
            ForEach(card.evidenceLines) { line in
                evidenceRow(line)
            }
            if let overflow = card.overflowNote {
                Text(overflow)
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
            }

            // Meta line — ink-muted.
            Text(card.meta)
                .apexFont(.label)
                .foregroundStyle(theme.inkMuted.color)
                .padding(.top, Spacing.xs)

            // Start — the only accent fill on the screen, full-width, ≥56pt.
            startButton(label: card.startLabel)
                .padding(.top, Spacing.sm)
        }
        .padding(Spacing.md)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(theme.hairline.color, lineWidth: DesignGeometry.draftingRuleWidth)
        )
        .shadow(
            color: theme.appearance == .light ? Elevation.cardColor.color : .clear,
            radius: Elevation.cardRadius, x: Elevation.cardX, y: Elevation.cardY
        )
        .accessibilityElement(children: .contain)
    }

    /// One evidence row: name left (tail-truncates), the number lockup right
    /// (SG 600 tnum, never truncates) + unit `ink-muted`.
    private func evidenceRow(_ line: TodayView.EvidenceLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(line.exerciseName)
                .apexFont(.body)
                .fontWeight(.medium)
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.sm)
            // The evidence-number lockup — work number ink (SG 600 tnum), unit pencil.
            (InkPencil.run(ink: line.setsRepsLoad, pencil: line.unit, theme: theme))
                .apexFont(.display)
                .monospacedDigit()
                .lineLimit(1)               // a number never wraps…
                .fixedSize()                // …and never truncates (it gets the space it needs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.exerciseName), \(line.setsRepsLoad)\(line.unit)")
    }

    /// The Start button — full-width, ≥56pt, `rounded.md`, SG 600 `on-accent`. The
    /// only accent fill on the screen. Disabled-while-transitioning would be added by
    /// the #376 live host; here it fires the injected `onStart`.
    private func startButton(label: String) -> some View {
        Button(action: onStart) {
            Text(label)
                .apexFont(.display)
                .foregroundStyle(theme.onAccent.color)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(theme.accentFill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Coach alerts — a calm list BELOW Start (never a pop-up)

    private var alertsList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(state.alerts) { alert in
                alertRow(alert)
            }
        }
        .padding(.top, Spacing.md)
    }

    /// One `well` row with an ink icon. A back-off (safety) row renders its icon +
    /// message in `alert` (the severity-law red); normal rows render in ink.
    private func alertRow(_ alert: TodayView.CoachAlert) -> some View {
        let isBackOff = alert.severity == .backOff
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: alert.icon)
                .foregroundStyle(isBackOff ? theme.alert.color : theme.ink.color)
                .accessibilityHidden(true)
            Text(alert.message)
                .apexFont(.body)
                .foregroundStyle(isBackOff ? theme.alert.color : theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.well.color)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(alert.message)
    }

    // MARK: Empty state (honest — never a fabricated session)

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("No session yet")
                .apexFont(.body)
                .foregroundStyle(theme.ink.color)
            Text("Your next workout appears here once it's placed.")
                .apexFont(.label)
                .foregroundStyle(theme.inkMuted.color)
        }
        .padding(.vertical, Spacing.lg)
        .accessibilityElement(children: .combine)
    }
}
