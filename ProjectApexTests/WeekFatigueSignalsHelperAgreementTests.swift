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

    // MARK: ─── (C) setsPerPrimaryMuscle serializes as JSON object — #369 ─────
    //
    // Swift's synthesized Codable for [Enum: Int] (non-String-keyed) encodes as a
    // flat alternating array `["chest", 4, "back", 6]`. The LLM digest consumer
    // requires a JSON object `{ "chest": 4, "back": 6 }`. The custom encode(to:)
    // added in #369 uses JSONBCodable.encodeEnumKeyedDict to produce the object form.

    @Test("setsPerPrimaryMuscle encodes as a JSON object, not a flat array")
    func setsPerPrimaryMuscleEncodesAsObject() throws {
        let benchLog = makeSetLog(exerciseId: "barbell_bench_press")
        let squatLog = makeSetLog(exerciseId: "barbell_back_squat")
        let signals = WeekFatigueSignals.compute(from: [benchLog, squatLog], sessionCount: 1)

        let data = try JSONEncoder().encode(signals)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // sets_per_primary_muscle must be a [String: Int] object, NOT an array.
        let muscleCounts = json?["sets_per_primary_muscle"] as? [String: Any]
        #expect(muscleCounts != nil,
                "sets_per_primary_muscle must encode as a JSON object { muscleRawValue: count }, not an array")

        // Bench press → chest; back squat → quads. Both raw values must be keys.
        #expect(muscleCounts?["chest"] as? Int == 1, "chest count must be 1")
        #expect(muscleCounts?["quads"] as? Int == 1, "quads count must be 1")
    }

    @Test("setsPerPrimaryMuscle round-trips through JSON encode/decode")
    func setsPerPrimaryMuscleRoundTrips() throws {
        let logs = [
            makeSetLog(exerciseId: "barbell_bench_press"),
            makeSetLog(exerciseId: "barbell_bench_press"),
            makeSetLog(exerciseId: "barbell_back_squat"),
        ]
        let original = WeekFatigueSignals.compute(from: logs, sessionCount: 1)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WeekFatigueSignals.self, from: data)

        #expect(decoded.setsPerPrimaryMuscle == original.setsPerPrimaryMuscle,
                "Round-trip must preserve the setsPerPrimaryMuscle dictionary")
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
