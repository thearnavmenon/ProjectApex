// VolumeValidationServiceTests.swift
// ProjectApexTests
//
// Verifies VolumeValidationService.currentWeekDeficits() for:
//   1. All targets met → empty array
//   2. One muscle at 60% completion → deficit with correct percentage
//   3. Multiple muscles below 80% → multiple deficits returned
//   4. No planned days → empty array (no targets to miss)
//   5. Muscle present in logs but absent from plan → not flagged as deficit
//   6. primaryMuscle column used when present, ExerciseLibrary fallback used when nil
//   7. UserDefaults round-trip: persist then load returns identical deficits

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Helpers

private func makePlannedExercise(
    exerciseId: String,
    primaryMuscle: String,
    sets: Int
) -> PlannedExercise {
    PlannedExercise(
        id: UUID(),
        exerciseId: exerciseId,
        name: exerciseId,
        primaryMuscle: primaryMuscle,
        synergists: [],
        equipmentRequired: .barbell,
        sets: sets,
        repRange: RepRange(min: 5, max: 8),
        tempo: "3-1-1-0",
        restSeconds: 120,
        rirTarget: 2,
        coachingCues: []
    )
}

private func makeTrainingDay(exercises: [PlannedExercise]) -> TrainingDay {
    TrainingDay(
        id: UUID(),
        dayOfWeek: 1,
        dayLabel: "Test_Day",
        exercises: exercises,
        sessionNotes: nil
    )
}

private func makeSetLog(exerciseId: String, primaryMuscle: String?) -> SetLog {
    SetLog(
        id: UUID(),
        sessionId: UUID(),
        exerciseId: exerciseId,
        setNumber: 1,
        weightKg: 60,
        repsCompleted: 5,
        rpeFelt: 7,
        rirEstimated: nil,
        aiPrescribed: nil,
        loggedAt: Date(),
        primaryMuscle: primaryMuscle
    )
}

// MARK: - Suite

@Suite("VolumeValidationService")
struct VolumeValidationServiceTests {

    // MARK: 1 — All targets met → empty

    @Test("All targets met → no deficits")
    func allTargetsMet() {
        // Plan: 9 chest sets. Actual: 9 chest sets.
        let plan = makeTrainingDay(exercises: [
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 3),
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 3),
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 3),
        ])
        let logs = (0..<9).map { _ in makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: "chest") }
        let deficits = VolumeValidationService.currentWeekDeficits(
            completedSetLogs: logs,
            plannedDays: [plan]
        )
        #expect(deficits.isEmpty)
    }

    // MARK: 2 — Chest at 60% → single deficit with correct percentage

    @Test("Chest completed at 60% of target → deficit ≈ 0.40")
    func singleMuscleDeficit() {
        // Plan: 10 chest sets. Actual: 6. Deficit = 4/10 = 0.40.
        let plan = makeTrainingDay(exercises: [
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 10),
        ])
        let logs = (0..<6).map { _ in makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: "chest") }
        let deficits = VolumeValidationService.currentWeekDeficits(
            completedSetLogs: logs,
            plannedDays: [plan]
        )
        #expect(deficits.count == 1)
        let d = deficits[0]
        #expect(d.muscleGroup == "chest")
        #expect(d.targetSets == 10)
        #expect(d.actualSets == 6)
        #expect(abs(d.deficitPercent - 0.40) < 0.01)
    }

    // MARK: 3 — Multiple muscles below 80% → multiple deficits

    @Test("Multiple muscles below 80% target → multiple deficits returned")
    func multipleMuscleDeficits() {
        // Plan: 10 chest sets, 10 back sets. Actual: 6 chest, 5 back.
        let plan = makeTrainingDay(exercises: [
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 10),
            makePlannedExercise(exerciseId: "barbell_row", primaryMuscle: "back", sets: 10),
        ])
        let chestLogs = (0..<6).map { _ in makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: "chest") }
        let backLogs  = (0..<5).map { _ in makeSetLog(exerciseId: "barbell_row", primaryMuscle: "back") }
        let deficits = VolumeValidationService.currentWeekDeficits(
            completedSetLogs: chestLogs + backLogs,
            plannedDays: [plan]
        )
        #expect(deficits.count == 2)
        #expect(deficits.contains { $0.muscleGroup == "chest" })
        #expect(deficits.contains { $0.muscleGroup == "back" })
    }

    // MARK: 4 — No planned days → empty

    @Test("No planned days → empty deficit array")
    func noPlannedDays() {
        let logs = [makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: "chest")]
        let deficits = VolumeValidationService.currentWeekDeficits(
            completedSetLogs: logs,
            plannedDays: []
        )
        #expect(deficits.isEmpty)
    }

    // MARK: 5 — Muscle in logs but absent from plan → not flagged

    @Test("Sets logged for a muscle not in the plan are not flagged as a deficit")
    func extraLogsNotFlagged() {
        // Plan: chest only. Logs: chest (met) + shoulders (unplanned).
        let plan = makeTrainingDay(exercises: [
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 4),
        ])
        let chestLogs    = (0..<4).map { _ in makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: "chest") }
        let shoulderLogs = (0..<6).map { _ in makeSetLog(exerciseId: "overhead_press", primaryMuscle: "shoulders") }
        let deficits = VolumeValidationService.currentWeekDeficits(
            completedSetLogs: chestLogs + shoulderLogs,
            plannedDays: [plan]
        )
        // Chest is met; shoulders aren't in the plan so they don't create a deficit
        #expect(deficits.isEmpty)
    }

    // MARK: 6 — primaryMuscle column used; ExerciseLibrary fallback for nil

    @Test("primaryMuscle column used when present; ExerciseLibrary fallback used when nil")
    func primaryMuscleColumnAndFallback() {
        // Plan: 5 chest sets
        let plan = makeTrainingDay(exercises: [
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 5),
        ])
        // 3 logs with primaryMuscle populated, 2 logs with primaryMuscle nil
        // (ExerciseLibrary.primaryMuscle("barbell_bench_press") == "chest")
        let withColumn    = (0..<3).map { _ in makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: "chest") }
        let withoutColumn = (0..<2).map { _ in makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: nil) }
        let deficits = VolumeValidationService.currentWeekDeficits(
            completedSetLogs: withColumn + withoutColumn,
            plannedDays: [plan]
        )
        // 5 actual vs 5 target → no deficit
        #expect(deficits.isEmpty)
    }

    // MARK: 7 — UserDefaults round-trip

    @Test("UserDefaults round-trip: persist then load returns identical deficits")
    func userDefaultsRoundTrip() {
        let key = "apex.volume_deficits"
        UserDefaults.standard.removeObject(forKey: key)

        let plan = makeTrainingDay(exercises: [
            makePlannedExercise(exerciseId: "barbell_bench_press", primaryMuscle: "chest", sets: 10),
        ])
        let logs = (0..<6).map { _ in makeSetLog(exerciseId: "barbell_bench_press", primaryMuscle: "chest") }
        let computed = VolumeValidationService.currentWeekDeficits(
            completedSetLogs: logs,
            plannedDays: [plan]
        )
        VolumeValidationService.persist(computed)
        let loaded = VolumeValidationService.load()

        #expect(loaded.count == computed.count)
        #expect(loaded.first?.muscleGroup == computed.first?.muscleGroup)
        #expect(loaded.first?.targetSets == computed.first?.targetSets)
        #expect(loaded.first?.actualSets == computed.first?.actualSets)

        UserDefaults.standard.removeObject(forKey: key)
    }
}
