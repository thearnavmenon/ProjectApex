// PatternPhaseServiceTests.swift
// ProjectApexTests
//
// Tests for PatternPhaseService — per-movement-pattern phase tracking.
//
// Coverage:
//   1.  sessionsRequired for 4 days/week: accum=8, intens=8, peak=6, deload=3
//   2.  sessionsRequired for 3 days/week: accum=4, intens=4, peak=3, deload=3
//   3.  Reaching accumulation threshold advances to intensification
//   4.  Reaching intensification threshold advances to peaking
//   5.  Reaching peaking threshold advances to deload
//   6.  Deload is terminal — no further advancement
//   7.  Untrained patterns are NOT advanced (skip safety)
//   8.  Migration: correct phases derived from seeded set-log history
//   9.  Migration: empty history produces empty states
//  10.  First-time pattern starts at accumulation with sessionsCompletedInPhase = 1
//  11.  UserDefaults round-trip: persist then load returns identical states
//  12.  clear() removes all persisted state
//  13.  Migration idempotency: computeInitialPhases is deterministic; advancePhases
//       on already-populated states increments (not re-initialises) them

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Helpers

/// Builds a minimal SetLog. Defaults keep call sites short.
private func makeSetLog(
    sessionId: UUID,
    exerciseId: String,
    loggedAt: Date = Date()
) -> SetLog {
    SetLog(
        id: UUID(),
        sessionId: sessionId,
        exerciseId: exerciseId,
        setNumber: 1,
        weightKg: 60,
        repsCompleted: 5,
        rpeFelt: 7,
        rirEstimated: nil,
        aiPrescribed: nil,
        loggedAt: loggedAt,
        primaryMuscle: nil
    )
}

/// Builds `count` set-logs for `exerciseId` across distinct session IDs.
private func makeLogs(exerciseId: String, sessionCount: Int) -> [SetLog] {
    (0..<sessionCount).map { _ in
        makeSetLog(sessionId: UUID(), exerciseId: exerciseId)
    }
}

/// Convenience to make a state already at `sessionsCompletedInPhase` sessions
/// with the correct threshold for 4 days/week.
private func makeState(
    pattern: String,
    phase: MesocyclePhase,
    completed: Int,
    required: Int
) -> MovementPatternPhaseState {
    MovementPatternPhaseState(
        pattern: pattern,
        phase: phase,
        sessionsCompletedInPhase: completed,
        sessionsRequiredForPhase: required
    )
}

// MARK: - Suite

@Suite("PatternPhaseService")
struct PatternPhaseServiceTests {

    // MARK: 1 — sessionsRequired (4 days/week)

    @Test("sessionsRequired: 4 days/week → accum=8, intens=8, peak=6, deload=3")
    func sessionsRequiredFourDays() {
        #expect(PatternPhaseService.sessionsRequired(for: .accumulation,    daysPerWeek: 4) == 8)
        #expect(PatternPhaseService.sessionsRequired(for: .intensification, daysPerWeek: 4) == 8)
        #expect(PatternPhaseService.sessionsRequired(for: .peaking,         daysPerWeek: 4) == 6)
        #expect(PatternPhaseService.sessionsRequired(for: .deload,          daysPerWeek: 4) == 3)
    }

    // MARK: 2 — sessionsRequired (3 days/week)

    @Test("sessionsRequired: 3 days/week → accum=4, intens=4, peak=3, deload=3")
    func sessionsRequiredThreeDays() {
        #expect(PatternPhaseService.sessionsRequired(for: .accumulation,    daysPerWeek: 3) == 4)
        #expect(PatternPhaseService.sessionsRequired(for: .intensification, daysPerWeek: 3) == 4)
        #expect(PatternPhaseService.sessionsRequired(for: .peaking,         daysPerWeek: 3) == 3)
        #expect(PatternPhaseService.sessionsRequired(for: .deload,          daysPerWeek: 3) == 3)
    }

    // MARK: 3 — accumulation → intensification

    @Test("Reaching accumulation threshold advances pattern to intensification")
    func accumulationAdvancesToIntensification() {
        // At threshold: 7 completed, 8 required. One more session pushes it over.
        let current = [makeState(pattern: "horizontal_push", phase: .accumulation, completed: 7, required: 8)]
        let updated = PatternPhaseService.advancePhases(
            current: current,
            trainedPatterns: ["horizontal_push"],
            daysPerWeek: 4
        )
        let state = updated.first { $0.pattern == "horizontal_push" }
        #expect(state?.phase == .intensification)
        #expect(state?.sessionsCompletedInPhase == 0)
        #expect(state?.sessionsRequiredForPhase == 8)
    }

    // MARK: 4 — intensification → peaking

    @Test("Reaching intensification threshold advances pattern to peaking")
    func intensificationAdvancesToPeaking() {
        let current = [makeState(pattern: "horizontal_push", phase: .intensification, completed: 7, required: 8)]
        let updated = PatternPhaseService.advancePhases(
            current: current,
            trainedPatterns: ["horizontal_push"],
            daysPerWeek: 4
        )
        let state = updated.first { $0.pattern == "horizontal_push" }
        #expect(state?.phase == .peaking)
        #expect(state?.sessionsCompletedInPhase == 0)
        #expect(state?.sessionsRequiredForPhase == 6)
    }

    // MARK: 5 — peaking → deload

    @Test("Reaching peaking threshold advances pattern to deload")
    func peakingAdvancesToDeload() {
        let current = [makeState(pattern: "horizontal_push", phase: .peaking, completed: 5, required: 6)]
        let updated = PatternPhaseService.advancePhases(
            current: current,
            trainedPatterns: ["horizontal_push"],
            daysPerWeek: 4
        )
        let state = updated.first { $0.pattern == "horizontal_push" }
        #expect(state?.phase == .deload)
        #expect(state?.sessionsCompletedInPhase == 0)
    }

    // MARK: 6 — deload is terminal

    @Test("Deload phase is terminal — pattern does not advance further")
    func deloadIsTerminal() {
        // Put pattern at the deload threshold (2 of 3 sessions done, then one more).
        let current = [makeState(pattern: "horizontal_push", phase: .deload, completed: 2, required: 3)]
        let updated = PatternPhaseService.advancePhases(
            current: current,
            trainedPatterns: ["horizontal_push"],
            daysPerWeek: 4
        )
        let state = updated.first { $0.pattern == "horizontal_push" }
        // Should remain in deload — no phase beyond it.
        #expect(state?.phase == .deload)
    }

    // MARK: 7 — untrained patterns not advanced

    @Test("Untrained patterns are not advanced when session is recorded for other patterns")
    func untrainedPatternNotAdvanced() {
        let current = [
            makeState(pattern: "horizontal_push", phase: .accumulation, completed: 3, required: 8),
            makeState(pattern: "squat",           phase: .accumulation, completed: 3, required: 8)
        ]
        // Only train horizontal_push today.
        let updated = PatternPhaseService.advancePhases(
            current: current,
            trainedPatterns: ["horizontal_push"],
            daysPerWeek: 4
        )
        let push = updated.first { $0.pattern == "horizontal_push" }
        let squat = updated.first { $0.pattern == "squat" }

        #expect(push?.sessionsCompletedInPhase == 4)  // incremented
        #expect(squat?.sessionsCompletedInPhase == 3) // unchanged
    }

    // MARK: 8 — migration: seeded history

    @Test("Migration derives correct phases from seeded set-log history")
    func migrationDerivesCorrectPhases() {
        // 9 distinct sessions of barbell_bench_press → "horizontal_push"
        // 4 days/week thresholds: accum=8. After 8 sessions consumed, 1 remains.
        // Expected: phase=intensification, sessionsCompletedInPhase=1
        let logs = makeLogs(exerciseId: "barbell_bench_press", sessionCount: 9)
        let states = PatternPhaseService.computeInitialPhases(from: logs, daysPerWeek: 4)

        let push = states.first { $0.pattern == "horizontal_push" }
        #expect(push != nil, "horizontal_push should be present in migration output")
        #expect(push?.phase == .intensification)
        #expect(push?.sessionsCompletedInPhase == 1)
    }

    // MARK: 9 — migration: empty history

    @Test("Migration with empty history produces no states")
    func migrationEmptyHistory() {
        let states = PatternPhaseService.computeInitialPhases(from: [], daysPerWeek: 4)
        #expect(states.isEmpty)
    }

    // MARK: 10 — first-time pattern

    @Test("First-time pattern is created at accumulation with sessionsCompletedInPhase = 1")
    func firstTimePatternCreated() {
        let updated = PatternPhaseService.advancePhases(
            current: [],
            trainedPatterns: ["horizontal_push"],
            daysPerWeek: 4
        )
        let state = updated.first { $0.pattern == "horizontal_push" }
        #expect(state != nil, "New pattern should be inserted")
        #expect(state?.phase == .accumulation)
        #expect(state?.sessionsCompletedInPhase == 1)
        #expect(state?.sessionsRequiredForPhase == 8) // 4 days/week accumulation threshold
    }

    // MARK: 11 — UserDefaults round-trip

    @Test("UserDefaults round-trip: persist then load returns identical states")
    func userDefaultsRoundTrip() {
        let key = "apex.pattern_phase_states"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let states = [
            makeState(pattern: "horizontal_push", phase: .accumulation,    completed: 3, required: 8),
            makeState(pattern: "squat",           phase: .intensification, completed: 5, required: 8)
        ]
        PatternPhaseService.persist(states)
        let loaded = PatternPhaseService.load()

        #expect(loaded.count == states.count)
        let push = loaded.first { $0.pattern == "horizontal_push" }
        #expect(push?.phase == .accumulation)
        #expect(push?.sessionsCompletedInPhase == 3)
        let squat = loaded.first { $0.pattern == "squat" }
        #expect(squat?.phase == .intensification)
        #expect(squat?.sessionsCompletedInPhase == 5)
    }

    // MARK: 12 — clear

    @Test("clear() removes all persisted pattern phase states")
    func clearRemovesPersistedState() {
        let key = "apex.pattern_phase_states"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let states = [makeState(pattern: "horizontal_push", phase: .accumulation, completed: 2, required: 8)]
        PatternPhaseService.persist(states)
        // Verify data was actually written
        #expect(!PatternPhaseService.load().isEmpty)

        PatternPhaseService.clear()
        #expect(PatternPhaseService.load().isEmpty)
    }

    // MARK: 13 — migration idempotency

    @Test("computeInitialPhases is deterministic: same history → same result on repeated calls")
    func migrationIdempotency() {
        // Verifies the service-level invariant that backs the migration gate:
        // running migration twice on the same history produces identical output,
        // confirming that the ProgramViewModel gate (if load().isEmpty) is safe to rely on.
        let logs = makeLogs(exerciseId: "barbell_bench_press", sessionCount: 9)
        let first  = PatternPhaseService.computeInitialPhases(from: logs, daysPerWeek: 4)
        let second = PatternPhaseService.computeInitialPhases(from: logs, daysPerWeek: 4)

        #expect(first.count == second.count)
        let push1 = first.first  { $0.pattern == "horizontal_push" }
        let push2 = second.first { $0.pattern == "horizontal_push" }
        #expect(push1?.phase == push2?.phase)
        #expect(push1?.sessionsCompletedInPhase == push2?.sessionsCompletedInPhase)
    }

    @Test("advancePhases on already-initialised states increments, not re-initialises")
    func advancePhasesIncrementsExistingState() {
        // After migration, the gate prevents re-running computeInitialPhases.
        // This test confirms that calling advancePhases on already-populated states
        // increments sessionsCompletedInPhase rather than resetting it.
        let initial = [makeState(pattern: "horizontal_push", phase: .accumulation, completed: 5, required: 8)]
        let after = PatternPhaseService.advancePhases(
            current: initial,
            trainedPatterns: ["horizontal_push"],
            daysPerWeek: 4
        )
        let state = after.first { $0.pattern == "horizontal_push" }
        // Should be 6, not 1 (which would indicate a re-initialisation)
        #expect(state?.sessionsCompletedInPhase == 6)
        #expect(state?.phase == .accumulation)
    }
}
