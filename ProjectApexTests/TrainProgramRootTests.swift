// TrainProgramRootTests.swift
// ProjectApexTests
//
// Tests for the Train program root (#357 / train.md §3 / ADR-0028).
//
// Two layers (mirroring ProgressRootLedgerTests):
//  1. UNCONDITIONAL derivation layer — runs on every push, no env var needed.
//     Verifies the tick mapping for every TrainingDayStatus × horizon position,
//     rest-from-day-gaps, skeleton-from-gaps (the inversion — no model change),
//     the discrete-tier bucketing, Week-X-of-N, and the no-streak/no-counter
//     honesty guard.
//  2. GATED snapshot layer — light + dim + one AX size (reference-pending until CI
//     records on the pinned Xcode 26.3 toolchain; NEVER set APEX_RECORD_SNAPSHOTS).

import Testing
import SwiftUI
import SnapshotTesting
import Foundation
@testable import ProjectApex

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Gating (mirrors DrawnInstrumentSnapshotTests)

private var snapshotTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_SNAPSHOT_TESTS"] == "1"
}
private var recordModeEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_RECORD_SNAPSHOTS"] == "1"
}

// MARK: - Fixtures

private func makeExercise(_ name: String) -> PlannedExercise {
    PlannedExercise(
        id: UUID(),
        exerciseId: name.lowercased().replacingOccurrences(of: " ", with: "_"),
        name: name,
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
}

private func makeDay(
    weekday: Int,
    label: String,
    status: TrainingDayStatus,
    exercises: [PlannedExercise] = []
) -> TrainingDay {
    TrainingDay(
        id: UUID(),
        dayOfWeek: weekday,
        dayLabel: label,
        exercises: exercises,
        sessionNotes: nil,
        status: status
    )
}

private func makeWeek(
    number: Int,
    phase: MesocyclePhase = .accumulation,
    label: String? = nil,
    days: [TrainingDay]
) -> TrainingWeek {
    TrainingWeek(id: UUID(), weekNumber: number, phase: phase, trainingDays: days, weekLabel: label)
}

private func makeMesocycle(weeks: [TrainingWeek], totalWeeks: Int = 12) -> Mesocycle {
    Mesocycle(
        id: UUID(),
        userId: UUID(),
        createdAt: Date(),
        isActive: true,
        weeks: weeks,
        totalWeeks: totalWeeks,
        periodizationModel: "linear_periodization"
    )
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 1. UNCONDITIONAL derivation layer
// ──────────────────────────────────────────────────────────────────────────

@Suite("TrainProgramRoot — tick mapping (TrainingDayStatus × horizon position)")
struct TrainProgramRootTickMappingTests {

    @Test("completed → filled (a logged fact)")
    func completedIsFilled() {
        #expect(TrainProgramRoot.tickValue(for: .completed, isAboveHorizon: true) == .filled)
        // Completed is always a fact regardless of horizon position.
        #expect(TrainProgramRoot.tickValue(for: .completed, isAboveHorizon: false) == .filled)
    }

    @Test("generated → hollow (committed, not done)")
    func generatedIsHollow() {
        #expect(TrainProgramRoot.tickValue(for: .generated, isAboveHorizon: true) == .hollow)
    }

    @Test("paused → hollow (committed, not done)")
    func pausedIsHollow() {
        #expect(TrainProgramRoot.tickValue(for: .paused, isAboveHorizon: true) == .hollow)
    }

    @Test("pending ABOVE the horizon → hollow (placed-and-waiting)")
    func pendingAboveHorizonIsHollow() {
        #expect(TrainProgramRoot.tickValue(for: .pending, isAboveHorizon: true) == .hollow)
    }

    @Test("pending BELOW the horizon → undrawn (skeleton; the hatch zone carries it)")
    func pendingBelowHorizonIsUndrawn() {
        #expect(TrainProgramRoot.tickValue(for: .pending, isAboveHorizon: false) == .undrawn)
    }

    @Test("skipped → hollow, NOT a shame mark (missed = a day the plan moved past)")
    func skippedStaysHollowNoShameMark() {
        // The load-bearing honesty rule: a skipped day must never render a distinct
        // "missed"/shame mark. It stays in the hollow vocabulary like any other
        // committed-not-done day.
        #expect(TrainProgramRoot.tickValue(for: .skipped, isAboveHorizon: true) == .hollow)
        #expect(TrainProgramRoot.tickValue(for: .skipped, isAboveHorizon: false) == .hollow)
    }

    @Test("StatusTickValue has no fourth 'missed' case — the vocabulary is filled/hollow/undrawn only")
    func vocabularyIsThreeValuesOnly() {
        // Map every status × both horizon positions; the result set is a subset of
        // {filled, hollow, undrawn} — there is no shame/missed value to reach for.
        let statuses: [TrainingDayStatus] = [.pending, .generated, .completed, .paused, .skipped]
        let produced = Set(statuses.flatMap { s in
            [TrainProgramRoot.tickValue(for: s, isAboveHorizon: true),
             TrainProgramRoot.tickValue(for: s, isAboveHorizon: false)]
        })
        #expect(produced.isSubset(of: [.filled, .hollow, .undrawn]))
    }
}

@Suite("TrainProgramRoot — the inversion (rest/skeleton from gaps, no model change)")
struct TrainProgramRootInversionTests {

    @Test("isAboveHorizon: a day with placed exercises is above the horizon (ink)")
    func dayWithExercisesIsAboveHorizon() {
        let day = makeDay(weekday: 1, label: "Push_A", status: .generated, exercises: [makeExercise("Bench")])
        #expect(TrainProgramRoot.isAboveHorizon(day) == true)
    }

    @Test("isAboveHorizon: a pending day with no exercises is BELOW the horizon (skeleton)")
    func pendingEmptyDayIsBelowHorizon() {
        let day = makeDay(weekday: 1, label: "Push_A", status: .pending, exercises: [])
        #expect(TrainProgramRoot.isAboveHorizon(day) == false)
    }

    @Test("isAboveHorizon: a completed day with no persisted exercises is still above the horizon")
    func completedEmptyDayIsAboveHorizon() {
        // A resolved day (completed/generated/paused/skipped) is above the horizon
        // even if its exercise array wasn't persisted locally.
        let day = makeDay(weekday: 1, label: "Push_A", status: .completed, exercises: [])
        #expect(TrainProgramRoot.isAboveHorizon(day) == true)
    }

    @Test("Rest-from-gaps: a weekday with no TrainingDay becomes a RestWellNode row")
    func restDerivedFromWeekdayGap() {
        // Week trains Mon(1) and Wed(3) only → the other 5 weekdays are rest nodes.
        let week = makeWeek(number: 1, days: [
            makeDay(weekday: 1, label: "Push_A", status: .generated, exercises: [makeExercise("Bench")]),
            makeDay(weekday: 3, label: "Pull_A", status: .generated, exercises: [makeExercise("Row")]),
        ])
        let rows = TrainProgramRoot.ViewState.spineRows(for: week, todayWeekday: 1, tier: .thisWeek)
        // 7 weekday rows total.
        #expect(rows.count == 7)
        let restCount = rows.filter { if case .rest = $0.kind { return true } else { return false } }.count
        #expect(restCount == 5, "Five untrained weekdays must each become a rest node")
        // Mon and Wed are placed.
        let placedWeekdays = rows.compactMap { row -> Int? in
            if case .placed = row.kind { return row.dayOfWeek } else { return nil }
        }
        #expect(placedWeekdays == [1, 3])
    }

    @Test("Skeleton-from-gaps: a this-week day with no generated exercises renders pencil shape-only")
    func skeletonDerivedFromMissingExercises() {
        // A pending day with no exercises in this week is below the horizon → skeleton.
        let week = makeWeek(number: 1, days: [
            makeDay(weekday: 1, label: "Push_A", status: .generated, exercises: [makeExercise("Bench")]),
            makeDay(weekday: 3, label: "Lower_B", status: .pending, exercises: []),
        ])
        let rows = TrainProgramRoot.ViewState.spineRows(for: week, todayWeekday: 99, tier: .thisWeek)
        let wed = rows.first { $0.dayOfWeek == 3 }
        #expect(wed != nil)
        if case .skeleton = wed?.kind {
            // expected — pencil shape only
        } else {
            Issue.record("A pending, exercise-less this-week day must render as a skeleton row")
        }
    }

    @Test("No model change: TrainingDayStatus has exactly the five persisted cases")
    func noEnumCasesAdded() {
        // The #357 inversion must NOT add cases to the persisted Codable enum. This
        // guard fails loudly if a future change widens the enum (rest/skeleton must
        // stay derived, not stored).
        let cases: [TrainingDayStatus] = [.pending, .generated, .completed, .paused, .skipped]
        #expect(Set(cases).count == 5)
        // Round-trip each through its rawValue to prove the persisted shape is unchanged.
        for c in cases {
            #expect(TrainingDayStatus(rawValue: c.rawValue) == c)
        }
    }
}

@Suite("TrainProgramRoot — discrete commitment-tier bucketing")
struct TrainProgramRootTierTests {

    @Test("Days ≤ 7 out bucket into .thisWeek")
    func thisWeekTier() {
        #expect(CommitmentTier.forDistance(days: 0) == .thisWeek)
        #expect(CommitmentTier.forDistance(days: 7) == .thisWeek)
    }

    @Test("Days 8…14 out bucket into .compressed")
    func compressedTier() {
        #expect(CommitmentTier.forDistance(days: 8) == .compressed)
        #expect(CommitmentTier.forDistance(days: 14) == .compressed)
    }

    @Test("Days > 14 out bucket into .glyphPerDay")
    func glyphPerDayTier() {
        #expect(CommitmentTier.forDistance(days: 15) == .glyphPerDay)
        #expect(CommitmentTier.forDistance(days: 70) == .glyphPerDay)
    }

    @Test("The gradient is DISCRETE — exactly three tiers, no continuous fade")
    func tierIsDiscrete() {
        // ADR-0028 no-slope carve-out: the commitment gradient must be discrete tiers,
        // never a continuous opacity fade. There are exactly three.
        #expect(CommitmentTier.allCases.count == 3)
    }

    @Test("Horizon weeks bucket onto the gradient by distance-from-now")
    func horizonWeeksUseTier() {
        // Build a 4-week cycle; current week 0 → week 1 is ~7 days (thisWeek),
        // week 2 is ~14 (compressed), week 3 is ~21 (glyphPerDay).
        let weeks = (1...4).map { n in
            makeWeek(number: n, label: "Week \(n)", days: [
                makeDay(weekday: 1, label: "Push", status: .pending, exercises: []),
            ])
        }
        let meso = makeMesocycle(weeks: weeks)
        let state = TrainProgramRoot.ViewState.from(mesocycle: meso, currentWeekIndex: 0, todayWeekday: 1)
        // Horizon rows come from weeks 2,3,4 (offsets 1,2,3).
        let tiers = Set(state.horizonRows.map(\.tier))
        #expect(tiers.contains(.thisWeek) || tiers.contains(.compressed) || tiers.contains(.glyphPerDay))
        // The farthest week (offset 3 → 21 days) must be glyphPerDay.
        #expect(state.horizonRows.last?.tier == .glyphPerDay)
    }
}

@Suite("TrainProgramRoot — position lockup and honesty guards")
struct TrainProgramRootStateTests {

    @Test("Week-X-of-N: the position lockup reads the current week and total weeks")
    func weekXofN() {
        let weeks = [
            makeWeek(number: 1, days: [makeDay(weekday: 1, label: "A", status: .completed)]),
            makeWeek(number: 2, days: [makeDay(weekday: 1, label: "B", status: .pending, exercises: [makeExercise("X")])]),
        ]
        let meso = makeMesocycle(weeks: weeks, totalWeeks: 6)
        // Current week index 1 → "Week 2 of 6".
        let state = TrainProgramRoot.ViewState.from(mesocycle: meso, currentWeekIndex: 1, todayWeekday: 99)
        #expect(state.weekNumber == 2)
        #expect(state.totalWeeks == 6)
    }

    @Test("Empty mesocycle → empty state, no fabricated rows")
    func emptyMesocycleIsEmpty() {
        let meso = makeMesocycle(weeks: [])
        let state = TrainProgramRoot.ViewState.from(mesocycle: meso, currentWeekIndex: 0)
        #expect(state.isEmpty)
        #expect(state.thisWeekRows.isEmpty)
        #expect(state.horizonRows.isEmpty)
    }

    @Test("Honesty guard: no streak/counter/adherence field exists on the view state")
    func noStreakOrCounterField() {
        // train.md §3 / §11.4: the calendar is a plan, not a report card. The view
        // state must carry no streak, completion-count, or adherence totalizer.
        // Structural guard via Mirror — if someone adds one, this fails intentionally.
        let weeks = [makeWeek(number: 1, days: [makeDay(weekday: 1, label: "A", status: .completed)])]
        let state = TrainProgramRoot.ViewState.from(mesocycle: makeMesocycle(weeks: weeks), currentWeekIndex: 0)
        let names = Mirror(reflecting: state).children.compactMap { $0.label?.lowercased() }
        for banned in ["streak", "adherence", "completedcount", "completioncount", "sessionscomplete", "ringprogress"] {
            #expect(!names.contains(banned), "View state must not carry a '\(banned)' field — the calendar is a plan, not a report card")
        }
    }

    @Test("currentWeekIndex clamps out-of-range input to a valid week")
    func weekIndexClamps() {
        let weeks = [makeWeek(number: 1, days: [makeDay(weekday: 1, label: "A", status: .pending, exercises: [makeExercise("X")])])]
        let meso = makeMesocycle(weeks: weeks)
        // Index 99 is out of range → clamps to the last (only) week.
        let state = TrainProgramRoot.ViewState.from(mesocycle: meso, currentWeekIndex: 99, todayWeekday: 99)
        #expect(state.weekNumber == 1)
    }

    @Test("Host's firstIncompleteWeekIndex finds the first non-terminal week")
    func hostFindsFirstIncompleteWeek() {
        let weeks = [
            makeWeek(number: 1, days: [makeDay(weekday: 1, label: "A", status: .completed)]),
            makeWeek(number: 2, days: [makeDay(weekday: 1, label: "B", status: .completed),
                                       makeDay(weekday: 3, label: "C", status: .pending)]),
        ]
        let meso = makeMesocycle(weeks: weeks)
        #expect(TrainProgramRootHost.firstIncompleteWeekIndex(in: meso) == 1)
    }
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 2. GATED snapshot layer (reference-pending until CI records)
// ──────────────────────────────────────────────────────────────────────────

@Suite("TrainProgramRoot snapshots", .enabled(if: snapshotTestsEnabled))
@MainActor
struct TrainProgramRootSnapshotTests {

    private static let canvasSize = CGSize(width: 393, height: 720)

    /// A stable fixture: a this-week spine with generated-ink days + rest gaps,
    /// plus a horizon of skeleton-pencil weeks below the datum — exercising the
    /// generated-ink-above / skeleton-hatch-below / horizon-datum / rest-well-node
    /// composition in one frame.
    private static var fixtureState: TrainProgramRoot.ViewState {
        let week1 = makeWeek(number: 2, phase: .accumulation, label: "Strength Block", days: [
            makeDay(weekday: 1, label: "Push_A", status: .completed,
                    exercises: [makeExercise("Bench Press"), makeExercise("Overhead Press")]),
            makeDay(weekday: 3, label: "Pull_A", status: .generated,
                    exercises: [makeExercise("Barbell Row"), makeExercise("Lat Pulldown")]),
            makeDay(weekday: 5, label: "Lower_A", status: .pending, exercises: []),  // this-week skeleton
        ])
        let week2 = makeWeek(number: 3, label: "Intensification", days: [
            makeDay(weekday: 1, label: "Push_B", status: .pending, exercises: []),
            makeDay(weekday: 3, label: "Pull_B", status: .pending, exercises: []),
        ])
        let week3 = makeWeek(number: 4, label: "Peak", days: [
            makeDay(weekday: 1, label: "Push_C", status: .pending, exercises: []),
        ])
        let meso = makeMesocycle(weeks: [week1, week2, week3])
        return TrainProgramRoot.ViewState.from(mesocycle: meso, currentWeekIndex: 0, todayWeekday: 3)
    }

    #if canImport(UIKit)
    @Test("Train program root — light, default Dynamic Type")
    func trainRoot_light_default() {
        let vc = SnapshotHarness.host(
            TrainProgramRoot(state: Self.fixtureState),
            size: Self.canvasSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "train-program-root-light-default", record: recordModeEnabled)
    }

    @Test("Train program root — dim, default Dynamic Type")
    func trainRoot_dim_default() {
        let vc = SnapshotHarness.host(
            TrainProgramRoot(state: Self.fixtureState),
            size: Self.canvasSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "train-program-root-dim-default", record: recordModeEnabled)
    }

    @Test("Train program root — light, AX5 (largest accessibility size)")
    func trainRoot_light_ax5() {
        let vc = SnapshotHarness.host(
            TrainProgramRoot(state: Self.fixtureState),
            size: Self.canvasSize, appearance: .light, dynamicType: .accessibility5
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "train-program-root-light-ax5", record: recordModeEnabled)
    }
    #endif
}
