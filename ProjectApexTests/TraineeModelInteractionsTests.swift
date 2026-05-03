// TraineeModelInteractionsTests.swift
// ProjectApexTests
//
// Round-trip tests for limitation/interaction types plus FatigueInteraction's
// derived properties (consistencyFactor, countFactor, confidence).

import Testing
import Foundation
@testable import ProjectApex

@Suite("ActiveLimitation")
struct ActiveLimitationTests {
    @Test("Round-trip preserves all fields including LimitationSubject")
    func roundTrip() throws {
        let original = ActiveLimitation(
            subject: .joint(.shoulder),
            severity: .mild,
            onsetDate: Date(timeIntervalSince1970: 1_750_000_000),
            evidenceCount: 3,
            userConfirmed: false,
            notes: "Anterior delt tightness on bench"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActiveLimitation.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("ClearedLimitation")
struct ClearedLimitationTests {
    @Test("Round-trip with cleared date")
    func roundTrip() throws {
        let original = ClearedLimitation(
            subject: .pattern(.horizontalPush),
            severity: .moderate,
            onsetDate: Date(timeIntervalSince1970: 1_700_000_000),
            clearedDate: Date(timeIntervalSince1970: 1_750_000_000),
            notes: nil
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ClearedLimitation.self, from: data) == original)
    }
}

@Suite("FatigueInteraction")
struct FatigueInteractionTests {
    @Test("countFactor caps at 0.5 below 15 observations")
    func countFactorBelow15() {
        let interaction = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: [-0.05, -0.04, -0.06], totalCount: 14
        )
        #expect(interaction.countFactor == 0.5)
    }

    @Test("countFactor reaches 1.0 at 15 observations")
    func countFactorAt15() {
        let interaction = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: Array(repeating: -0.05, count: 10), totalCount: 15
        )
        #expect(interaction.countFactor == 1.0)
    }

    @Test("Perfectly consistent observations yield consistencyFactor 1.0")
    func consistencyFactorPerfect() {
        let interaction = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: Array(repeating: -0.05, count: 10),
            totalCount: 20
        )
        #expect(interaction.consistencyFactor == 1.0)
    }

    @Test("consistencyFactor is 0 with fewer than 2 observations")
    func consistencyFactorTooFew() {
        let zero = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: [], totalCount: 0
        )
        #expect(zero.consistencyFactor == 0)
        let one = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: [-0.05], totalCount: 1
        )
        #expect(one.consistencyFactor == 0)
    }

    @Test("Mean-guard prevents divide-by-zero when observations average ~0")
    func consistencyFactorMeanGuard() {
        // Observations sum to 0; without mean-guard we'd divide stddev/0.
        let interaction = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: [0.05, -0.05, 0.05, -0.05],
            totalCount: 20
        )
        // With mean-guard 0.001, stddev/absMean is huge → clamped to 0.
        #expect(interaction.consistencyFactor == 0)
    }

    @Test("confidence = consistencyFactor × countFactor")
    func confidenceProduct() {
        let interaction = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: Array(repeating: -0.05, count: 10),
            totalCount: 10  // below 15 → countFactor 0.5
        )
        #expect(interaction.confidence == interaction.consistencyFactor * 0.5)
        #expect(interaction.confidence == 0.5)  // 1.0 × 0.5
    }

    @Test("Codable round-trip preserves observations and totalCount")
    func roundTrip() throws {
        let original = FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: [-0.04, -0.05, -0.06, -0.05],
            totalCount: 25
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FatigueInteraction.self, from: data) == original)
    }
}

@Suite("PrescriptionAccuracy")
struct PrescriptionAccuracyTests {
    @Test("Round-trip")
    func roundTrip() throws {
        let original = PrescriptionAccuracy(
            pattern: .horizontalPush, intent: .top,
            bias: -0.025, rmse: 0.04, sampleCount: 18
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PrescriptionAccuracy.self, from: data) == original)
    }
}

@Suite("PrescriptionIntentMismatch")
struct PrescriptionIntentMismatchTests {
    @Test("Round-trip")
    func roundTrip() throws {
        let original = PrescriptionIntentMismatch(
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            exerciseId: "barbell_bench_press",
            pattern: .horizontalPush,
            prescribedIntent: .top,
            loggedIntent: .backoff
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PrescriptionIntentMismatch.self, from: data) == original)
    }
}

@Suite("ExerciseTransfer")
struct ExerciseTransferTests {
    @Test("Round-trip with R² and observation count")
    func roundTrip() throws {
        let original = ExerciseTransfer(
            fromExerciseId: "barbell_bench_press",
            toExerciseId: "overhead_press",
            coefficient: 0.62,
            rSquared: 0.71,
            pairedObservations: 12
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ExerciseTransfer.self, from: data) == original)
    }
}

@Suite("BodyweightHistory")
struct BodyweightHistoryTests {
    @Test("Default init yields empty entries")
    func defaultEmpty() {
        #expect(BodyweightHistory().entries.isEmpty)
    }

    @Test("Round-trip preserves entry order")
    func roundTrip() throws {
        let original = BodyweightHistory(entries: [
            BodyweightEntry(localDate: "2026-05-01", weightKg: 82.4),
            BodyweightEntry(localDate: "2026-05-04", weightKg: 82.6),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BodyweightHistory.self, from: data)
        #expect(decoded == original)
        #expect(decoded.entries.map(\.localDate) == ["2026-05-01", "2026-05-04"])
    }
}
