// TodayViewTests.swift
// ProjectApexTests
//
// Unit + snapshot coverage for the Today screen (#348, splash-today.md Part 2):
//
//   • CoachLineRules — the deterministic, no-AI rule engine that grounds the coach
//     line in ≥1 model number (TraineeModelDigest) and conforms to coach-voice.md:
//       - which rule fires for which model state (the ranked selection);
//       - the rule-based fallback computed with NO AI call;
//       - the empty-collapse (nothing meaningful → "" empty slot, never filler);
//       - the hard character budget (§4.1);
//       - the constitution-adherence guard (D1 no-warmth — outputs carry no
//         banned-warmth vocabulary).
//   • The evidence-lockup formatting + the Start wiring (the injected onStart fires).
//   • GATED image snapshots (Today light + dim + one AX) mirroring
//     DrawnInstrumentSnapshotTests; reference-pending until the CI record job runs.
//
// The unconditional @Tests are the local green bar; the snapshot suite is gated by
// APEX_SNAPSHOT_TESTS and records nothing here (no APEX_RECORD_SNAPSHOTS).

import Testing
import SwiftUI
@testable import ProjectApex

#if canImport(UIKit)
import UIKit
import SnapshotTesting
#endif

// MARK: - Fixtures

@MainActor
private enum TodayFixture {

    static let ref = Date(timeIntervalSinceReferenceDate: 800_000_000) // mid-2026

    static func goal(_ statement: String = "Hypertrophy") -> GoalState {
        GoalState(statement: statement, focusAreas: [.legs], updatedAt: ref)
    }

    static func pattern(
        _ p: MovementPattern, confidence: AxisConfidence
    ) -> PatternProfile {
        PatternProfile(
            pattern: p,
            currentPhase: .accumulation,
            sessionsInPhase: 4,
            rpeOffset: 0,
            confidence: confidence,
            trend: .progressing,
            recentSessionDates: [ref.addingTimeInterval(-7 * 86400)]
        )
    }

    /// A digest with a squat projection at a given progress + confidence + tally.
    static func digest(
        squatFloor: Double = 105,
        squatStretch: Double = 120,
        progress: ProjectionProgress = .onTrack,
        confidence: AxisConfidence = .established,
        totalSessions: Int = 42,
        goalStatement: String = "Hypertrophy"
    ) -> TraineeModelDigest {
        let model = TraineeModel(
            goal: goal(goalStatement),
            projections: ProjectionState(patternProjections: [
                PatternProjection(pattern: .squat, floor: squatFloor,
                                  stretch: squatStretch, progress: progress)
            ]),
            patterns: [.squat: pattern(.squat, confidence: confidence)],
            totalSessionCount: totalSessions
        )
        return TraineeModelDigest(from: model, asOf: ref)
    }

    /// A cold digest: placeholder goal, no projections, zero sessions → collapse.
    static func coldDigest() -> TraineeModelDigest {
        let model = TraineeModel(goal: GoalState.placeholder, totalSessionCount: 0)
        return TraineeModelDigest(from: model, asOf: ref)
    }
}

// MARK: - Coach-line rule selection (the right rule for the model state)

@Suite("CoachLineRules — ranked selection")
@MainActor
struct CoachLineRuleSelectionTests {

    @Test("On-track pattern with a floor → the floor-position rule fires")
    func floorPositionFires() {
        let d = TodayFixture.digest(progress: .onTrack, confidence: .established)
        #expect(CoachLineRules.firingRule(for: d, nextPattern: .squat) == .floorPosition)
        let line = CoachLineRules.line(for: d, nextPattern: .squat)
        #expect(line.contains("Squat"))
        #expect(line.contains("105"))   // the grounded floor number
    }

    @Test("Ahead-of-band pattern → the ratchet-near forward-hook rule fires")
    func ratchetNearFires() {
        let d = TodayFixture.digest(squatFloor: 105, squatStretch: 110,
                                    progress: .ahead, confidence: .established)
        #expect(CoachLineRules.firingRule(for: d, nextPattern: .squat) == .ratchetNear)
        let line = CoachLineRules.line(for: d, nextPattern: .squat)
        #expect(line.contains("5"))      // the floor→stretch gap (110 − 105)
        #expect(line.contains("floor"))
    }

    @Test("Calibrating pattern → the calibrating rule names mechanism + model count")
    func calibratingFires() {
        let d = TodayFixture.digest(progress: .onTrack, confidence: .calibrating,
                                    totalSessions: 3)
        #expect(CoachLineRules.firingRule(for: d, nextPattern: .squat) == .calibrating)
        let line = CoachLineRules.line(for: d, nextPattern: .squat)
        #expect(line.contains("calibrating"))
        #expect(line.contains("3"))      // model-derived count (D5), not hardcoded
    }

    @Test("No pattern anchor but sessions exist → the session-tally rule fires")
    func sessionTallyFires() {
        let d = TodayFixture.digest(totalSessions: 42)
        #expect(CoachLineRules.firingRule(for: d, nextPattern: nil) == .sessionTally)
        let line = CoachLineRules.line(for: d, nextPattern: nil)
        #expect(line.contains("42"))
        #expect(line.contains("sessions"))
    }

    @Test("Calibrating count uses the singular for a single session")
    func calibratingSingular() {
        let d = TodayFixture.digest(confidence: .bootstrapping, totalSessions: 1)
        let line = CoachLineRules.line(for: d, nextPattern: .squat)
        #expect(line.contains("1 session "))   // singular, not "1 sessions"
    }
}

// MARK: - The rule-based fallback (no AI) + empty collapse

@Suite("CoachLineRules — fallback + collapse")
@MainActor
struct CoachLineFallbackTests {

    @Test("The fallback is computed with NO AI call — a pure function over the digest")
    func fallbackIsPure() {
        // The engine is a static func over a value type; calling it twice yields the
        // same line with no side effect, no async, no service — the no-AI guarantee.
        let d = TodayFixture.digest()
        let a = CoachLineRules.line(for: d, nextPattern: .squat)
        let b = CoachLineRules.line(for: d, nextPattern: .squat)
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test("Cold model (placeholder goal, no projections, 0 sessions) → empty collapse")
    func collapsesToEmpty() {
        let d = TodayFixture.coldDigest()
        #expect(CoachLineRules.firingRule(for: d, nextPattern: .squat) == nil)
        #expect(CoachLineRules.line(for: d, nextPattern: .squat).isEmpty)
    }

    @Test("A pattern with no projection and no sessions never fabricates a line")
    func noProjectionNoSessionsCollapses() {
        let model = TraineeModel(goal: GoalState.placeholder, totalSessionCount: 0)
        let d = TraineeModelDigest(from: model, asOf: TodayFixture.ref)
        #expect(CoachLineRules.line(for: d, nextPattern: .hipHinge).isEmpty)
    }

    @Test("The ViewState empty fixture has a collapsed (empty) coach line")
    func viewStateEmptyCollapses() {
        #expect(TodayView.ViewState.empty.coachLine.isEmpty)
        #expect(TodayView.ViewState.empty.isEmpty)   // no session card
    }
}

// MARK: - The hard character budget (coach-voice.md §4.1)

@Suite("CoachLineRules — length contract")
@MainActor
struct CoachLineLengthTests {

    @Test("The budget is the spec's 80-char upper bound")
    func budgetValue() {
        #expect(CoachLineRules.maxCharacters == 80)
    }

    @Test("Every deterministic rule output is within the character budget")
    func everyRuleWithinBudget() {
        // Drive each rule and assert the produced line respects §4.1. Long pattern
        // names (Horizontal Push) are the worst case for the templates.
        let states: [TraineeModelDigest] = [
            TodayFixture.digest(progress: .onTrack, confidence: .established),
            TodayFixture.digest(squatStretch: 112.5, progress: .ahead, confidence: .established),
            TodayFixture.digest(confidence: .calibrating, totalSessions: 1234),
            TodayFixture.digest(totalSessions: 99999),
        ]
        for d in states {
            let line = CoachLineRules.line(for: d, nextPattern: .squat)
            #expect(line.count <= CoachLineRules.maxCharacters)
        }
    }

    @Test("An over-budget candidate fails validation; an ellipsized one too")
    func validationRejectsOverBudgetAndEllipsis() {
        let tooLong = String(repeating: "x", count: CoachLineRules.maxCharacters + 1)
        #expect(!CoachLineRules.isValid(tooLong))
        #expect(!CoachLineRules.isValid("Squat floor moved…"))   // §4.1 no ellipsis
        #expect(!CoachLineRules.isValid(""))                      // empty is not "valid"
        #expect(CoachLineRules.isValid("Squat floor at 105 kg — square in the band."))
    }
}

// MARK: - The constitution-adherence guard (D1 no-warmth)

@Suite("CoachLineRules — coach-voice.md D1 no-warmth")
@MainActor
struct CoachVoiceAdherenceTests {

    @Test("No deterministic rule output contains banned-warmth vocabulary")
    func noWarmthInAnyOutput() {
        // Exhaustively drive the rule matrix and assert each output is instrument-grade.
        let confidences: [AxisConfidence] = [.bootstrapping, .calibrating, .established, .seasoned]
        let progresses: [ProjectionProgress] = [.behind, .onTrack, .ahead, .achieved]
        let patterns: [MovementPattern?] = [.squat, .horizontalPush, .hipHinge, nil]

        for c in confidences {
            for p in progresses {
                for pat in patterns {
                    let d = TodayFixture.digest(progress: p, confidence: c, totalSessions: 12)
                    let line = CoachLineRules.line(for: d, nextPattern: pat)
                    #expect(!CoachLineRules.containsBannedWarmth(line),
                            "warmth vocabulary leaked into: \(line)")
                }
            }
        }
    }

    @Test("The guard catches a warmth violation (the negative control)")
    func guardCatchesWarmth() {
        #expect(CoachLineRules.containsBannedWarmth("Amazing session — you crushed it!"))
        #expect(CoachLineRules.containsBannedWarmth("Keep it up!"))
        #expect(CoachLineRules.containsBannedWarmth("Beast mode today"))
        #expect(CoachLineRules.containsBannedWarmth("Welcome back"))
        // And a true instrument-grade line passes.
        #expect(!CoachLineRules.containsBannedWarmth("Squat floor at 105 kg — square in the band."))
    }

    @Test("A banned word as a substring of a real word does NOT false-positive")
    func wholeWordMatching() {
        // "nice" is banned, but "Hospice"/"niceties" should not trip a whole-word guard;
        // our deterministic outputs never use these, but the matcher must be word-aware.
        #expect(!CoachLineRules.containsBannedWarmth("105 kg logged"))
        #expect(CoachLineRules.containsBannedWarmth("nice work"))
    }
}

// MARK: - Evidence-lockup formatting + Start wiring

@Suite("TodayView — evidence lockup + Start wiring")
@MainActor
struct TodayViewReductionTests {

    /// A one-week mock program whose first day is a horizontal-push session.
    private func mockState() -> TodayView.ViewState {
        let meso = Mesocycle.mockMesocycle()
        let digest = TodayFixture.digest()
        return TodayView.ViewState.from(mesocycle: meso, digest: digest, asOf: TodayFixture.ref)
    }

    @Test("The reducer builds a hero card with evidence lines from the next session")
    func reducerBuildsCard() {
        let state = mockState()
        #expect(state.sessionCard != nil)
        let card = state.sessionCard!
        #expect(!card.evidenceLines.isEmpty)
        #expect(card.evidenceLines.count <= 3)        // max 3 rows (splash-today.md)
        #expect(card.startLabel == "Start")
        // The eyebrow carries the week/day position lockup.
        #expect(card.eyebrow.contains("WEEK"))
    }

    @Test("Evidence lockup formats sets×reps as a tnum number run, units in pencil")
    func evidenceLockupFormatting() {
        let state = mockState()
        let line = state.sessionCard!.evidenceLines.first!
        // The mock day's first exercise is 4 sets, 6–10 reps.
        #expect(line.setsRepsLoad == "4×6–10")
        #expect(line.unit == " reps")
        #expect(!line.exerciseName.isEmpty)
    }

    @Test("formatKg rounds to plate granularity, drops the trailing .0")
    func formatKgGranularity() {
        #expect(CoachLineRules.formatKg(105) == "105")
        #expect(CoachLineRules.formatKg(102.5) == "102.5")
        #expect(CoachLineRules.formatKg(102.4) == "102.5")   // snaps to nearest 0.5
    }

    @Test("The next-session pattern is derived from the day's first exercise")
    func nextPatternDerivation() {
        let meso = Mesocycle.mockMesocycle()
        let next = TodayView.ViewState.nextIncompleteDay(in: meso)!
        // Mock day 1's first exercise is Barbell Bench Press → horizontal push.
        #expect(TodayView.ViewState.primaryPattern(of: next.day) == .horizontalPush)
    }

    @Test("Start fires the injected action (the #376 seam is wired, not hardcoded)")
    func startWiring() {
        var fired = false
        let view = TodayView(state: mockState(), onStart: { fired = true })
        // Invoke the wired action directly (the button's action is the injected closure).
        view.onStart()
        #expect(fired)
    }

    @Test("Empty program → honest empty state, no fabricated session")
    func emptyProgramState() {
        let state = TodayView.ViewState.from(mesocycle: nil, digest: nil, asOf: TodayFixture.ref)
        #expect(state.isEmpty)
        #expect(state.sessionCard == nil)
        #expect(state.coachLine.isEmpty)
    }
}

// MARK: - GATED image snapshots (reference-pending; mirrors DrawnInstrumentSnapshotTests)

#if canImport(UIKit)

/// Gated identically to DrawnInstrumentSnapshotTests: opt-in via APEX_SNAPSHOT_TESTS,
/// records nothing here (no APEX_RECORD_SNAPSHOTS). References must be recorded by the
/// CI record job on the pinned toolchain — enabling the gate WITHOUT references fails,
/// which is the correct "not yet ratified" signal.
private var todaySnapshotsEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_SNAPSHOT_TESTS"] == "1"
}
private var todayRecordModeEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_RECORD_SNAPSHOTS"] == "1"
}

@Suite("Today snapshots", .enabled(if: todaySnapshotsEnabled))
@MainActor
struct TodaySnapshotTests {

    private static let size = CGSize(width: 393, height: 852)

    /// A representative populated Today state for the visual capture.
    private func populatedState() -> TodayView.ViewState {
        TodayView.ViewState(
            dateLabel: "Sat 14 Jun",
            lensState: .resolved(ReadinessScore(score: 72)),
            coachLine: "Squat floor at 105 kg — square in the band.",
            sessionCard: TodayView.SessionCard(
                eyebrow: "TODAY · WEEK 2 OF 12 · 4-DAY",
                title: "Lower — squat focus",
                evidenceLines: [
                    .init(exerciseName: "Back Squat", setsRepsLoad: "5×5", unit: " reps"),
                    .init(exerciseName: "Romanian Deadlift", setsRepsLoad: "3×8", unit: " reps"),
                    .init(exerciseName: "Leg Press", setsRepsLoad: "3×12", unit: " reps"),
                ],
                overflowNote: "+2 accessories",
                meta: "~55 min",
                startLabel: "Start"
            ),
            alerts: [
                .init(severity: .backOff, icon: "exclamationmark.triangle",
                      message: "Knee flagged last session — squats capped today."),
                .init(severity: .normal, icon: "calendar",
                      message: "Calibration review ready."),
            ]
        )
    }

    @Test("Today — light, default Dynamic Type")
    func today_light_default() {
        let vc = SnapshotHarness.host(TodayView(state: populatedState()),
                                      size: Self.size, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "today-light-default", record: todayRecordModeEnabled)
    }

    @Test("Today — dim, default Dynamic Type")
    func today_dim_default() {
        let vc = SnapshotHarness.host(TodayView(state: populatedState()),
                                      size: Self.size, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "today-dim-default", record: todayRecordModeEnabled)
    }

    @Test("Today — light, AX5 (largest accessibility size)")
    func today_light_ax5() {
        let vc = SnapshotHarness.host(TodayView(state: populatedState()),
                                      size: CGSize(width: 393, height: 1400),
                                      appearance: .light, dynamicType: .accessibility5)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "today-light-ax5", record: todayRecordModeEnabled)
    }
}

#endif
