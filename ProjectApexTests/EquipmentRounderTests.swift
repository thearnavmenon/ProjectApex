// SetPrescriptionValidationTests.swift
// ProjectApexTests
//
// Unit tests for SetPrescription.validate() — all field-level validation rules.
//
// NOTE: EquipmentRounder and EquipmentDetails have been removed as part of the
// presence-only scanner architecture (weight correction is now handled by
// GymFactStore + DefaultWeightIncrements). The SetPrescription validation tests
// are retained here as they remain valid.

import XCTest
@testable import ProjectApex

// MARK: ─── Shared test helpers ───────────────────────────────────────────────

/// Returns a SetPrescription that satisfies every validation rule.
private func validPrescription() -> SetPrescription {
    SetPrescription(
        weightKg: 80.0,
        reps: 8,
        tempo: "3-1-1-0",
        rirTarget: 2,
        restSeconds: 120,
        coachingCue: "Drive through the floor on the concentric.",
        reasoning: "Load is within previous session range; slight volume increase.",
        safetyFlags: [],
        confidence: 0.9
    )
}

// MARK: ─── SetPrescriptionValidationTests ────────────────────────────────────

final class SetPrescriptionValidationTests: XCTestCase {

    // MARK: - Happy path

    func test_validPrescription_doesNotThrow() {
        XCTAssertNoThrow(try validPrescription().validate())
    }

    // MARK: - weightKg

    // weightKg represents external/added load on the bar or machine, NOT total
    // system load — the user's bodyweight is a separate field on UserProfile /
    // InferenceContext (`bodyweightKg`). Zero is therefore a legitimate
    // prescription for bodyweight exercises (push-ups, dips, pull-ups), and
    // SystemPrompt_Inference.txt records the migration: "weight_kg response
    // format changed from '> 0' to '>= 0' to allow bodyweight prescriptions."
    // The negative case is covered by test_weightKgNegative_throwsInvalidWeight
    // below; the original test asserting that zero throws was a stale leftover
    // from the pre-migration ">0" rule. Resolves #24.1.
    func test_weightKgZero_doesNotThrow_forBodyweightExercises() {
        var p = validPrescription(); p.weightKg = 0.0
        XCTAssertNoThrow(try p.validate())
    }

    func test_weightKgNegative_throwsInvalidWeight() {
        var p = validPrescription(); p.weightKg = -1.0
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidWeight = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidWeight, got \(error)")
            }
        }
    }

    func test_weightKgExceedsMaximum_throwsInvalidWeight() {
        var p = validPrescription(); p.weightKg = 501.0
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidWeight(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidWeight, got \(error)")
            }
            XCTAssertEqual(v, 501.0, accuracy: 0.001)
        }
    }

    func test_weightKgAtUpperBoundary_doesNotThrow() {
        var p = validPrescription(); p.weightKg = 500.0
        XCTAssertNoThrow(try p.validate())
    }

    func test_weightKgJustAboveZero_doesNotThrow() {
        var p = validPrescription(); p.weightKg = 0.001
        XCTAssertNoThrow(try p.validate())
    }

    // MARK: - reps

    func test_repsZero_throwsInvalidReps() {
        var p = validPrescription(); p.reps = 0
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidReps(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidReps, got \(error)")
            }
            XCTAssertEqual(v, 0)
        }
    }

    func test_repsExceedsMax_throwsInvalidReps() {
        var p = validPrescription(); p.reps = 31
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidReps(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidReps, got \(error)")
            }
            XCTAssertEqual(v, 31)
        }
    }

    func test_repsAtLowerBoundary_doesNotThrow() {
        var p = validPrescription(); p.reps = 1
        XCTAssertNoThrow(try p.validate())
    }

    func test_repsAtUpperBoundary_doesNotThrow() {
        var p = validPrescription(); p.reps = 30
        XCTAssertNoThrow(try p.validate())
    }

    // MARK: - tempo

    func test_tempoEmpty_throwsInvalidTempo() {
        var p = validPrescription(); p.tempo = ""
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidTempo(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidTempo, got \(error)")
            }
            XCTAssertEqual(v, "")
        }
    }

    func test_tempoTooShort_throwsInvalidTempo() {
        var p = validPrescription(); p.tempo = "3-1-2"
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidTempo = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidTempo, got \(error)")
            }
        }
    }

    func test_tempoTooLong_throwsInvalidTempo() {
        var p = validPrescription(); p.tempo = "3-1-2-0-1"
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidTempo = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidTempo, got \(error)")
            }
        }
    }

    func test_tempoNoSeparators_throwsInvalidTempo() {
        var p = validPrescription(); p.tempo = "3120"
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidTempo = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidTempo, got \(error)")
            }
        }
    }

    func test_tempoLetterCharacter_throwsInvalidTempo() {
        var p = validPrescription(); p.tempo = "a-1-2-0"
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidTempo = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidTempo, got \(error)")
            }
        }
    }

    func test_tempoDoubleDigit_throwsInvalidTempo() {
        // Regex is \d-\d-\d-\d so two-digit numbers per slot must fail
        var p = validPrescription(); p.tempo = "10-1-2-0"
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidTempo = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidTempo, got \(error)")
            }
        }
    }

    func test_tempoValidStandard_doesNotThrow() {
        var p = validPrescription(); p.tempo = "3-1-2-0"
        XCTAssertNoThrow(try p.validate())
    }

    func test_tempoAllZeros_doesNotThrow() {
        var p = validPrescription(); p.tempo = "0-0-0-0"
        XCTAssertNoThrow(try p.validate())
    }

    // MARK: - restSeconds

    func test_restSecondsBelowMin_throwsInvalidRestSeconds() {
        var p = validPrescription(); p.restSeconds = 29
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidRestSeconds(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidRestSeconds, got \(error)")
            }
            XCTAssertEqual(v, 29)
        }
    }

    func test_restSecondsAboveMax_throwsInvalidRestSeconds() {
        var p = validPrescription(); p.restSeconds = 601
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidRestSeconds(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidRestSeconds, got \(error)")
            }
            XCTAssertEqual(v, 601)
        }
    }

    func test_restSecondsAtLowerBoundary_doesNotThrow() {
        var p = validPrescription(); p.restSeconds = 30
        XCTAssertNoThrow(try p.validate())
    }

    func test_restSecondsAtUpperBoundary_doesNotThrow() {
        var p = validPrescription(); p.restSeconds = 600
        XCTAssertNoThrow(try p.validate())
    }

    // MARK: - coachingCue

    func test_coachingCueTooLong_throwsInvalidCoachingCue() {
        var p = validPrescription()
        p.coachingCue = String(repeating: "x", count: 101) // 101 chars
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .coachingCueTooLong(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .coachingCueTooLong, got \(error)")
            }
            XCTAssertEqual(v, 101)
        }
    }

    func test_coachingCueAtExactLimit_doesNotThrow() {
        var p = validPrescription()
        p.coachingCue = String(repeating: "x", count: 100) // exactly 100 chars
        XCTAssertNoThrow(try p.validate())
    }

    func test_coachingCueEmpty_doesNotThrow() {
        var p = validPrescription(); p.coachingCue = ""
        XCTAssertNoThrow(try p.validate())
    }

    // MARK: - reasoning

    func test_reasoningTooLong_throwsInvalidReasoning() {
        var p = validPrescription()
        p.reasoning = String(repeating: "y", count: 201) // 201 chars
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .reasoningTooLong(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .reasoningTooLong, got \(error)")
            }
            XCTAssertEqual(v, 201)
        }
    }

    func test_reasoningAtExactLimit_doesNotThrow() {
        var p = validPrescription()
        p.reasoning = String(repeating: "y", count: 200) // exactly 200 chars
        XCTAssertNoThrow(try p.validate())
    }

    // MARK: - confidence

    func test_confidenceNil_doesNotThrow() {
        var p = validPrescription(); p.confidence = nil
        XCTAssertNoThrow(try p.validate())
    }

    func test_confidenceValidMidRange_doesNotThrow() {
        var p = validPrescription(); p.confidence = 0.5
        XCTAssertNoThrow(try p.validate())
    }

    func test_confidenceAtZero_doesNotThrow() {
        var p = validPrescription(); p.confidence = 0.0
        XCTAssertNoThrow(try p.validate())
    }

    func test_confidenceAtOne_doesNotThrow() {
        var p = validPrescription(); p.confidence = 1.0
        XCTAssertNoThrow(try p.validate())
    }

    func test_confidenceBelowZero_throwsInvalidConfidence() {
        var p = validPrescription(); p.confidence = -0.01
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .confidenceOutOfRange(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .confidenceOutOfRange, got \(error)")
            }
            XCTAssertEqual(v, -0.01, accuracy: 0.0001)
        }
    }

    func test_confidenceAboveOne_throwsInvalidConfidence() {
        var p = validPrescription(); p.confidence = 1.001
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .confidenceOutOfRange(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .confidenceOutOfRange, got \(error)")
            }
            XCTAssertEqual(v, 1.001, accuracy: 0.0001)
        }
    }

    // MARK: - SafetyFlag Codable round-trip

    func test_allSafetyFlagCases_roundTripCodable() throws {
        let allFlags: [SafetyFlag] = [
            .shoulderCaution,
            .jointConcern,
            .fatigueHigh,
            .painReported,
            .deloadRecommended
        ]

        let expectedRawValues: [SafetyFlag: String] = [
            .shoulderCaution:   "shoulder_caution",
            .jointConcern:      "joint_concern",
            .fatigueHigh:       "fatigue_high",
            .painReported:      "pain_reported",
            .deloadRecommended: "deload_recommended"
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for flag in allFlags {
            XCTAssertEqual(flag.rawValue, expectedRawValues[flag],
                           "Raw value mismatch for \(flag)")
            let data = try encoder.encode(flag)
            let decoded = try decoder.decode(SafetyFlag.self, from: data)
            XCTAssertEqual(decoded, flag, "Round-trip failed for \(flag)")
        }
    }

    func test_allSafetyFlags_preservedInPrescriptionRoundTrip() throws {
        var p = validPrescription()
        p.safetyFlags = [.shoulderCaution, .jointConcern, .fatigueHigh,
                         .painReported, .deloadRecommended]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(p)
        let decoded = try decoder.decode(SetPrescription.self, from: data)

        XCTAssertEqual(Set(decoded.safetyFlags), Set(p.safetyFlags))
    }

    func test_allSafetyFlagCases_decodedCorrectly() throws {
        let decoder = JSONDecoder()

        let cases: [(String, SafetyFlag)] = [
            ("\"shoulder_caution\"",   .shoulderCaution),
            ("\"joint_concern\"",      .jointConcern),
            ("\"fatigue_high\"",       .fatigueHigh),
            ("\"pain_reported\"",      .painReported),
            ("\"deload_recommended\"", .deloadRecommended),
        ]
        for (jsonString, expected) in cases {
            let data = Data(jsonString.utf8)
            let decoded = try decoder.decode(SafetyFlag.self, from: data)
            XCTAssertEqual(decoded, expected,
                           "Decoding '\(jsonString)' must produce .\(expected)")
        }
    }
}
