// LiveLoopView.swift
// ProjectApex — Phase 3 UI overhaul · Slice 8 (#350)
//
// The live-session loop core (docs/design/live-loop.md §1–4 only). One screen owns
// the current set: the hero-num lockup (exercise + target weight × reps), the
// full-bleed bottom Done ink slab (relabels to "Finish" on the last set of the
// session), and the card morph to the rest timer after a log. Binds to the existing
// WorkoutViewModel/WorkoutSessionManager FSM — no backend change.
//
// DORMANT (#350): this is a NEW screen, NOT wired into the live shell. The legacy
// ActiveSetView / RestTimerView remain live in the frozen ContentView until the
// close-out slice. This file routes nowhere and replaces nothing.
//
// Scope cut (roadmap §4 Q13): §1–4 only. AMRAP, Adjust (tap-the-number steppers),
// and the full ink-flood entrance are DEFERRED to #351 — hooks/TODOs only here.
// The entrance is stubbed to a plain crossfade per the deferral.
//
// "Work is ink, time is pencil" (§1): work numbers render `ink`; time digits render
// `ink-muted`. The model carries the split so the view never picks a colour by hand.

import SwiftUI

// MARK: - LiveLoopModel

/// The pure, value-type render model for the live loop. Derives every piece of
/// presented text/state from the FSM-public inputs (sessionState, prescription,
/// rest seconds) plus the read-only TrainingDay (needed only to know when the
/// current set is the last of the *whole session* — the actor keeps trainingDay /
/// exerciseIndex private, so the view supplies the day as a read-only input).
///
/// No SwiftUI, no colour: testable in a headless unit target. The view maps
/// `ink`/`pencil` roles onto the theme; the model only labels which is which.
struct LiveLoopModel: Equatable {

    /// Which half of the loop is on screen.
    enum Phase: Equatable {
        case set    // performing the current set — hero prescription + Done slab
        case rest   // post-log rest — pencil countdown is the temporary hero
        case other  // idle / preflight / exerciseComplete / sessionComplete / error
    }

    let phase: Phase

    // MARK: Set-state fields (the hero lockup)

    /// Exercise name — glance tier 1 (§3). Empty in non-set phases.
    let exerciseName: String

    /// "set 2 of 5" muted beside the exercise name. Empty when unknown.
    let setPositionText: String

    /// The hero weight token, ink (§1 "work is ink"). E.g. "82.5 kg" or "BW".
    /// No trailing ".0" (§3 false-precision rule).
    let heroWeightText: String

    /// The connective × glyph plus reps, pencil register per §3 (× is `ink-muted`,
    /// connective tissue). Always uses U+00D7, never the letter x. E.g. " × 8".
    let heroRepsText: String

    /// The Done slab's label — "Done" normally, "Finish" on the last set of the
    /// whole session (§3 / §8: one slab, label changes exactly once per session).
    let doneLabel: String

    /// True when the current set is the last set of the last exercise — drives the
    /// Done → Finish relabel. Computed from the read-only TrainingDay.
    let isLastSetOfSession: Bool

    /// Whether the Done slab accepts a tap. False while a log is in flight or a
    /// morph is animating (§3 disabled-while-morphing guard against double-logs).
    let doneEnabled: Bool

    // MARK: Rest-state fields

    /// The rest countdown digits, pencil register (§1 / §4.2 `ink-muted`). "1:30".
    let restDigitsText: String

    /// The next-set preview line shown during rest (§4.5). Empty when unknown.
    let nextPreviewText: String

    // MARK: - Derivation

    /// The U+00D7 multiplication sign — never the ASCII letter "x" (§3 micro-spec).
    static let times = "\u{00D7}"

    /// Build the model from the FSM-public state. `trainingDay` is read-only and used
    /// only to determine `isLastSetOfSession` (the actor keeps its position private).
    init(
        sessionState: SessionState,
        prescription: SetPrescription?,
        restSecondsRemaining: Int,
        trainingDay: TrainingDay
    ) {
        switch sessionState {
        case .active(let exercise, let setNumber):
            self.phase = .set
            self.exerciseName = exercise.name
            self.setPositionText = "set \(setNumber) of \(exercise.sets)"
            let rx = prescription
            self.heroWeightText = Self.weightText(weightKg: rx?.weightKg ?? 0)
            self.heroRepsText = " \(Self.times) \(rx?.reps ?? exercise.repRange.max)"
            let last = Self.computeIsLastSetOfSession(exercise: exercise, setNumber: setNumber, trainingDay: trainingDay)
            self.isLastSetOfSession = last
            self.doneLabel = last ? "Finish" : "Done"
            // doneEnabled is overlaid by the view's in-flight/morph guards; the
            // model's default is "a prescription exists to log".
            self.doneEnabled = rx != nil
            self.restDigitsText = ""
            self.nextPreviewText = ""

        case .resting(let nextExercise, let setNumber):
            self.phase = .rest
            self.exerciseName = ""
            self.setPositionText = ""
            self.heroWeightText = ""
            self.heroRepsText = ""
            self.doneLabel = "Done"
            self.isLastSetOfSession = false
            self.doneEnabled = false
            self.restDigitsText = Self.restDigits(restSecondsRemaining)
            self.nextPreviewText = "Next: \(nextExercise.name) · set \(setNumber)"

        default:
            self.phase = .other
            self.exerciseName = ""
            self.setPositionText = ""
            self.heroWeightText = ""
            self.heroRepsText = ""
            self.doneLabel = "Done"
            self.isLastSetOfSession = false
            self.doneEnabled = false
            self.restDigitsText = ""
            self.nextPreviewText = ""
        }
    }

    /// The current set is the last of the whole session iff it is the last set of
    /// its exercise (`setNumber >= exercise.sets`, matching the manager's
    /// set-number-based rule) AND that exercise is the last in the day. Matched on
    /// the exercise's stable `id` so a duplicated name never confuses the check.
    static func computeIsLastSetOfSession(
        exercise: PlannedExercise,
        setNumber: Int,
        trainingDay: TrainingDay
    ) -> Bool {
        guard setNumber >= exercise.sets else { return false }
        return trainingDay.exercises.last?.id == exercise.id
    }

    /// Hero weight token: "BW" at/under zero, no trailing ".0" otherwise, " kg"
    /// pencil unit applied by the view. Returns the bare number+unit string.
    static func weightText(weightKg: Double) -> String {
        if weightKg <= 0 { return "BW" }
        if weightKg.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f kg", weightKg)
        }
        return String(format: "%.1f kg", weightKg)
    }

    /// "m:ss" rest digits, clamped at zero. Pencil register applied by the view.
    static func restDigits(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - LiveLoopView

/// The thin SwiftUI shell over `LiveLoopModel`. Owns the in-flight/morph guards
/// (state the model can't see), the card morph animation, and the Done tap → log.
///
/// DORMANT: instantiate-only. Nothing in the live shell presents this yet (#350).
struct LiveLoopView: View {

    @Bindable var viewModel: WorkoutViewModel

    /// Read-only training day — supplies the "last set of the whole session" fact
    /// the actor keeps private. Never mutated here.
    let trainingDay: TrainingDay

    @Environment(\.apexTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Local guard: true from Done touch-up until the morph settles, so a second
    /// tap can't double-log and a brush during the morph is rejected (§3).
    @State private var isMorphing = false

    private var model: LiveLoopModel {
        LiveLoopModel(
            sessionState: viewModel.sessionState,
            prescription: viewModel.currentPrescription,
            restSecondsRemaining: viewModel.restSecondsRemaining,
            trainingDay: trainingDay
        )
    }

    /// The Done slab is tappable only when the model says a set is loggable AND no
    /// log is in flight AND no morph is animating (§3 disabled-while-morphing).
    private var doneEnabled: Bool {
        model.doneEnabled && !viewModel.isCompletingSet && !isMorphing
    }

    private var morphAnimation: Animation {
        reduceMotion ? Motion.reduceMotionCrossfade : Motion.cardMorph
    }

    var body: some View {
        ZStack {
            theme.paper.color.ignoresSafeArea()

            // The card content morphs between set and rest in place — no modal,
            // no new screen (§4). The two states share the container; the morph is
            // a crossfade-with-transform driven by `Motion.cardMorph`.
            Group {
                switch model.phase {
                case .set:  setCard
                case .rest: restCard
                case .other: Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(morphAnimation, value: model.phase)

            // The Done slab is pooled at the bottom of the world all session (§3).
            VStack {
                Spacer()
                if model.phase == .set {
                    doneSlab
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(morphAnimation, value: model.phase)
        }
        // STUB (§4 Q13 / #351): the full ink-flood entrance is deferred. The
        // dormant screen uses a plain crossfade on appear as the placeholder.
        .transition(.opacity)
        // Drop the local morph guard once the FSM has advanced past the logged set,
        // so the rest card becomes interactive. The guard only bridges the window
        // between Done-commit and the VM's state-pull.
        .onChange(of: model.phase) { _, newPhase in
            if newPhase != .set { isMorphing = false }
        }
    }

    // MARK: Set card — the hero lockup (§3)

    private var setCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Exercise line — glance tier 1.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.exerciseName)
                    .apexFont(.title)
                    .foregroundStyle(theme.ink.color)
                Text(model.setPositionText)
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
            }
            .accessibilityElement(children: .combine)

            // The prescription — the hero lockup. Weight is ink (work), the
            // × glyph and reps are pencil (the × is connective tissue, §3).
            Text("\(Text(model.heroWeightText).foregroundStyle(theme.ink.color))\(Text(model.heroRepsText).foregroundStyle(theme.inkMuted.color))")
                .apexFont(.heroNum)
                .accessibilityElement()
                .accessibilityLabel("\(model.heroWeightText) \(model.heroRepsText)")

            // TODO(#351): "Why this?", Adjust (tap-the-number steppers), last-time
            // anchor, plate-math dimension callout, AMRAP target — all deferred.
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }

    // MARK: Rest card — pencil countdown as the temporary hero (§4)

    private var restCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Rest countdown — pencil register (time is pencil, §1 / §4.2).
            Text(model.restDigitsText)
                .apexFont(.heroNum)
                .foregroundStyle(theme.inkMuted.color)
                .accessibilityLabel("Rest \(model.restDigitsText)")

            // Next-set preview (§4.5). Furniture; no travel.
            Text(model.nextPreviewText)
                .apexFont(.body)
                .foregroundStyle(theme.inkMuted.color)

            // TODO(#351): feel pill (Easy | Solid | Grind), depleting drafting
            // rule, ±15s / Skip controls, ledger row — deferred to the rest slice.
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }

    // MARK: Done slab — the bottom of the world (§3)

    private var doneSlab: some View {
        Button(action: handleDoneTap) {
            Text(model.doneLabel)
                .apexFont(.title)
                .foregroundStyle(theme.onAccent.color)
                .frame(maxWidth: .infinity)
                .frame(height: 96, alignment: .top)
                .padding(.top, 18)
                .background(theme.accentFill)
                .overlay(alignment: .top) {
                    // 1px accent-press top rule (§3).
                    Rectangle()
                        .fill(theme.accentPress)
                        .frame(height: 1)
                }
        }
        .buttonStyle(.plain)
        // touch-up-inside with small-movement tolerance — a drag past the slab
        // doesn't fire (§3 stray-brush guard). SwiftUI's Button already cancels on
        // drag-out; `.plain` keeps the slab's own hit region as the tolerance zone.
        .disabled(!doneEnabled)
        .accessibilityLabel(model.doneLabel)
        .accessibilityHint(model.isLastSetOfSession ? "Finish the session" : "Log this set as prescribed")
    }

    // MARK: Done tap — one tap logs the set as prescribed (§3)

    private func handleDoneTap() {
        // Re-check the guard at commit time: a queued tap that lands after a morph
        // started must be rejected (no double-log).
        guard doneEnabled, let rx = viewModel.currentPrescription else { return }

        // commit-time haptic — the plate-thud fires at commit, not touch-down (§3).
        Haptics.setLogged()

        // Begin the morph guard immediately so a second tap is dead until the FSM
        // advances. Cleared when the state leaves .active (the morph has happened).
        isMorphing = true

        // One tap = logged as prescribed: reps at the prescription's reps, intent
        // at the prescription's intent. This is the deliberate NEW behaviour vs the
        // legacy multi-field confirmation sheet (PR behaviour-parity note).
        viewModel.onSetComplete(
            actualReps: rx.reps,
            rpeFelt: nil,
            intent: rx.intent ?? .top,
            completionFlags: []
        )

        // The VM flips isCompletingSet and re-pulls state; once it advances out of
        // .active, drop the local morph guard so the rest card becomes interactive.
        // Driven off the model's phase via .task(id:) below.
    }
}

#if DEBUG
import Foundation

// MARK: - Previews (dormant; not a live route)

#Preview("Live loop — set state (light)") {
    LiveLoopView(
        viewModel: .mockActive(),
        trainingDay: LiveLoopPreviewData.day
    )
    .apexThemeRoot()
}

#Preview("Live loop — rest state (dim)") {
    LiveLoopView(
        viewModel: .mockResting(),
        trainingDay: LiveLoopPreviewData.day
    )
    .environment(\.apexTheme, .dim)
}

private enum LiveLoopPreviewData {
    static let day = TrainingDay(
        id: UUID(),
        dayOfWeek: 1,
        dayLabel: "Push_A",
        exercises: [
            PlannedExercise(
                id: UUID(),
                exerciseId: "barbell_bench_press",
                name: "Barbell Bench Press",
                primaryMuscle: "pectoralis_major",
                synergists: [],
                equipmentRequired: .barbell,
                sets: 4,
                repRange: RepRange(min: 6, max: 10),
                tempo: "3-1-1-0",
                restSeconds: 150,
                rirTarget: 2,
                coachingCues: []
            )
        ],
        sessionNotes: nil
    )
}
#endif
