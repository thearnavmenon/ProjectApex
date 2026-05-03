// WeekFatigueSignalsHelperAgreementTests.swift
// ProjectApexTests
//
// Slice 1.8 regression guard: WeekFatigueSignals.compute aggregates each
// canonical exercise into the same PrimaryMuscle bucket that ExerciseLibrary
// reports for that exercise's primaryMuscle field. The internal helper
// (`primaryMuscle(for:)`) is private; testing through the public surface
// (compute → setsPerPrimaryMuscle dictionary keys) ensures any future drift
// where the helper bypasses the library lookup is caught.

import Testing
import Foundation
@testable import ProjectApex

@Suite("WeekFatigueSignals helper / ExerciseLibrary agreement")
struct WeekFatigueSignalsHelperAgreementTests {

    @Test("Every canonical exercise aggregates to its ExerciseDefinition.primaryMuscle bucket")
    func everyCanonicalExerciseAgrees() {
        var disagreements: [String] = []

        for exercise in ExerciseLibrary.all {
            let log = makeSetLog(exerciseId: exercise.id)
            let signals = WeekFatigueSignals.compute(from: [log], sessionCount: 1)
            let bucketed = signals.setsPerPrimaryMuscle.first?.key

            if bucketed != exercise.primaryMuscle {
                disagreements.append(
                    "\(exercise.id): library says .\(exercise.primaryMuscle.rawValue), " +
                    "helper bucketed as \(bucketed.map { ".\($0.rawValue)" } ?? "nil")"
                )
            }
        }

        #expect(disagreements.isEmpty,
                "Helper / ExerciseLibrary disagreement on canonical lifts:\n\(disagreements.joined(separator: "\n"))")
    }
}

// MARK: - Helpers

private func makeSetLog(exerciseId: String) -> SetLog {
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
        primaryMuscle: nil
    )
}
