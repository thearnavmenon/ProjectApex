// EquipmentRounderTests.swift
// ProjectApexTests
//
// Unit tests for:
//   • EquipmentRounder   — all three EquipmentDetails strategies
//   • SetPrescription.validate() — all field-level validation rules
//
// Design principles:
//   • No shared mutable state between tests — each test constructs its own
//     GymProfile / SetPrescription from scratch.
//   • Boundary values are tested explicitly (off-by-one, exact midpoint).
//   • XCTAssertThrowsError is used with a type-checked error case wherever
//     the spec mandates a specific PrescriptionValidationError case.

import XCTest
@testable import ProjectApex

// MARK: ─── Shared test helpers ───────────────────────────────────────────────

/// Builds a minimal GymProfile containing exactly one EquipmentItem.
private func makeProfile(
    equipmentType: EquipmentType,
    details: EquipmentDetails
) -> GymProfile {
    let item = EquipmentItem(
        equipmentType: equipmentType,
        count: 1,
        details: details,
        detectedByVision: false
    )
    return GymProfile(
        scanSessionId: "test-session",
        equipment: [item]
    )
}

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

// MARK: ─── Part 1: EquipmentRounderTests ────────────────────────────────────

final class EquipmentRounderTests: XCTestCase {

    // MARK: - Dumbbell / increment-based rounding

    /// When the prescribed weight exactly matches an available increment step,
    /// no rounding should occur and wasAdjusted must be false.
    func test_exactWeightAvailable_returnsUnchanged() {
        // increment 5 kg from 25 → gives available steps 25, 30, 35
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 25.0, maxKg: 35.0, incrementKg: 5.0)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 30.0, for: .dumbbellSet)

        XCTAssertEqual(result.roundedWeightKg, 30.0, accuracy: 0.001)
        XCTAssertFalse(result.wasAdjusted)
        XCTAssertEqual(result.originalWeightKg, 30.0, accuracy: 0.001)
        XCTAssertNil(result.adjustmentNote)
    }

    /// Weight 47.4 with increment 5, lower=45, upper=50.
    /// Midpoint = 45 + 5×0.6 = 48.0. Since 47.4 < 48.0, must round DOWN to 45.
    func test_roundDown_whenBelowSafetyBiasedMidpoint() {
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 45.0, maxKg: 50.0, incrementKg: 5.0)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 47.4, for: .dumbbellSet)

        XCTAssertEqual(result.roundedWeightKg, 45.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
    }

    /// Weight 48.5 with increment 5, lower=45, upper=50.
    /// Midpoint = 48.0. Since 48.5 >= 48.0, must round UP to 50.
    func test_roundUp_whenAboveSafetyBiasedMidpoint() {
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 45.0, maxKg: 50.0, incrementKg: 5.0)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 48.5, for: .dumbbellSet)

        XCTAssertEqual(result.roundedWeightKg, 50.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
    }

    /// Weight exactly at the safety-biased midpoint (48.0) must round DOWN for safety.
    /// The spec says "round up if weight >= midpoint", so 48.0 rounds UP — verify the
    /// implementation's stated contract: midpoint itself is the boundary for rounding UP.
    /// spec: "weight >= midpoint → round up", so 48.0 → rounds UP to 50.
    func test_exactMidpoint_roundsUp_perSpec() {
        // Midpoint = 45 + 5×0.6 = 48.0
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 45.0, maxKg: 50.0, incrementKg: 5.0)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 48.0, for: .dumbbellSet)

        // Implementation: candidate = weight >= midpoint ? upper : lower
        // 48.0 >= 48.0 → upper = 50.0
        XCTAssertEqual(result.roundedWeightKg, 50.0, accuracy: 0.001)
    }

    /// A weight below the minimum must be clamped to minKg.
    func test_weightBelowMinimum_clampsToMin() {
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 5.0, maxKg: 20.0, incrementKg: 2.5)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 2.0, for: .dumbbellSet)

        XCTAssertEqual(result.roundedWeightKg, 5.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
        XCTAssertEqual(result.originalWeightKg, 2.0, accuracy: 0.001)
    }

    /// A weight above the maximum must be clamped to maxKg.
    func test_weightAboveMaximum_clampsToMax() {
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 5.0, maxKg: 20.0, incrementKg: 2.5)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 50.0, for: .dumbbellSet)

        XCTAssertEqual(result.roundedWeightKg, 20.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
        XCTAssertEqual(result.originalWeightKg, 50.0, accuracy: 0.001)
    }

    /// If the equipment type is not present in the profile, the weight should be
    /// returned unchanged with wasAdjusted = false.
    func test_equipmentNotInProfile_returnsOriginalUnchanged() {
        // Profile contains a barbell, but we ask for a cable machine.
        let profile = makeProfile(
            equipmentType: .barbell,
            details: .incrementBased(minKg: 20.0, maxKg: 200.0, incrementKg: 2.5)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 40.0, for: .cableMachine)

        XCTAssertEqual(result.roundedWeightKg, 40.0, accuracy: 0.001)
        XCTAssertFalse(result.wasAdjusted)
        XCTAssertEqual(result.originalWeightKg, 40.0, accuracy: 0.001)
    }

    /// When a weight is adjusted, adjustmentNote must be non-nil and must contain
    /// the rounded weight value.
    func test_adjustmentNotePresent_whenWeightIsAdjusted() {
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 10.0, maxKg: 40.0, incrementKg: 5.0)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 23.0, for: .dumbbellSet)

        // 23 is adjusted (not a 5 kg step from 10), so note must exist.
        XCTAssertTrue(result.wasAdjusted)
        XCTAssertNotNil(result.adjustmentNote)
    }

    /// When no adjustment occurs, adjustmentNote must be nil.
    func test_adjustmentNoteAbsent_whenWeightUnchanged() {
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 10.0, maxKg: 40.0, incrementKg: 5.0)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 25.0, for: .dumbbellSet)

        XCTAssertFalse(result.wasAdjusted)
        XCTAssertNil(result.adjustmentNote)
    }

    // MARK: - Barbell / plate-based rounding

    /// Bar 20 kg + plates [20, 10, 5, 2.5, 1.25] kg.
    /// Prescribe 60 kg → per-side target = (60-20)/2 = 20 kg → one 20 kg plate/side.
    /// Result: 20 + 20×2 = 60. No adjustment.
    func test_barbell_exactLoadAchievable_returnsUnchanged() {
        let profile = makeProfile(
            equipmentType: .barbell,
            details: .plateBased(
                barWeightKg: 20.0,
                availablePlatesKg: [20.0, 10.0, 5.0, 2.5, 1.25]
            )
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 60.0, for: .barbell)

        XCTAssertEqual(result.roundedWeightKg, 60.0, accuracy: 0.001)
        XCTAssertFalse(result.wasAdjusted)
    }

    /// Bar 20 kg + plates [20, 10, 5, 2.5].
    /// Prescribe 57 kg → per-side target = (57-20)/2 = 18.5 kg.
    /// Greedy: 10 (rem=8.5) → 5 (rem=3.5) → 2.5 (rem=1.0) → 2.5 doesn't fit.
    /// Per-side load = 17.5 → total = 20 + 17.5×2 = 55.0.
    func test_barbell_roundsToNearestAchievableLoad() {
        let profile = makeProfile(
            equipmentType: .barbell,
            details: .plateBased(
                barWeightKg: 20.0,
                availablePlatesKg: [20.0, 10.0, 5.0, 2.5]
            )
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 57.0, for: .barbell)

        XCTAssertEqual(result.roundedWeightKg, 55.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
    }

    /// Prescription (15 kg) is below bar weight (20 kg).
    /// Per-side target is clamped to 0, so result is bar weight only: 20 kg.
    func test_barbell_prescriptionBelowBarWeight_returnsBarOnly() {
        let profile = makeProfile(
            equipmentType: .barbell,
            details: .plateBased(
                barWeightKg: 20.0,
                availablePlatesKg: [20.0, 10.0, 5.0, 2.5, 1.25]
            )
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 15.0, for: .barbell)

        XCTAssertEqual(result.roundedWeightKg, 20.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
    }

    /// Bar 20 kg + plates [25, 20, 10] (only 3 denominations).
    /// Max achievable: per-side we can add as many 25 kg plates as we want.
    /// Prescribe 250 kg → per-side = 115 kg → greedy: 4×25=100, 1×10=110, stop (10 < remaining 5).
    /// Actually 4×25=100, then 10 (rem=5), 10 > 5 so stop. Per-side = 110, total = 20+220=240.
    /// The greedy algorithm will try 25 until it can't fit: 4×25=100 (rem=15), 1×10=110 (rem=5) → done.
    /// Total = 20 + 110*2 = 240.
    func test_barbell_prescriptionExceedsMaxLoad_greedyCaps() {
        let profile = makeProfile(
            equipmentType: .barbell,
            details: .plateBased(
                barWeightKg: 20.0,
                availablePlatesKg: [25.0, 10.0]
            )
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        // prescribe 250; per-side = 115; greedy: 4×25=100 (rem=15), 1×10=110 (rem=5); done.
        let result = rounder.round(aiPrescribedWeightKg: 250.0, for: .barbell)

        // Per-side = 110 → total = 20 + 220 = 240
        XCTAssertEqual(result.roundedWeightKg, 240.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
    }

    /// When no plates are available, the result should be bar weight only.
    func test_barbell_noPlates_returnsBarWeightOnly() {
        let profile = makeProfile(
            equipmentType: .barbell,
            details: .plateBased(
                barWeightKg: 20.0,
                availablePlatesKg: []
            )
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 60.0, for: .barbell)

        XCTAssertEqual(result.roundedWeightKg, 20.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
    }

    // MARK: - Bodyweight rounding

    /// Bodyweight equipment must always return 0.0 regardless of prescribed weight.
    func test_bodyweightOnly_alwaysReturnsZero() {
        let profile = makeProfile(
            equipmentType: .pullUpBar,
            details: .bodyweightOnly
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 75.0, for: .pullUpBar)

        XCTAssertEqual(result.roundedWeightKg, 0.0, accuracy: 0.001)
        XCTAssertTrue(result.wasAdjusted)
        XCTAssertNotNil(result.adjustmentNote)
    }

    /// Prescribing 0.0 for bodyweight equipment should not be flagged as adjusted.
    func test_bodyweightOnly_zeroPrescription_notAdjusted() {
        let profile = makeProfile(
            equipmentType: .pullUpBar,
            details: .bodyweightOnly
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 0.0, for: .pullUpBar)

        XCTAssertEqual(result.roundedWeightKg, 0.0, accuracy: 0.001)
        XCTAssertFalse(result.wasAdjusted)
        XCTAssertNil(result.adjustmentNote)
    }

    // MARK: - originalWeightKg preservation

    /// originalWeightKg must always reflect the value passed to round(), not the
    /// rounded result, even when clamping occurs.
    func test_originalWeightKg_alwaysReflectsInputWeight() {
        let profile = makeProfile(
            equipmentType: .dumbbellSet,
            details: .incrementBased(minKg: 5.0, maxKg: 30.0, incrementKg: 2.5)
        )
        let rounder = EquipmentRounder(gymProfile: profile)
        let prescribed: Double = 99.9

        let result = rounder.round(aiPrescribedWeightKg: prescribed, for: .dumbbellSet)

        XCTAssertEqual(result.originalWeightKg, prescribed, accuracy: 0.001)
    }
}

// MARK: ─── Part 2: SetPrescriptionValidationTests ────────────────────────────

final class SetPrescriptionValidationTests: XCTestCase {

    // MARK: - Happy path

    func test_validPrescription_doesNotThrow() {
        XCTAssertNoThrow(try validPrescription().validate())
    }

    // MARK: - weightKg

    func test_weightKgZero_throwsInvalidWeight() {
        var p = validPrescription(); p.weightKg = 0.0
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .invalidWeight(let v) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidWeight, got \(error)")
            }
            XCTAssertEqual(v, 0.0, accuracy: 0.001)
        }
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

    /// Encodes every SafetyFlag case to JSON and decodes it back, verifying that:
    ///   1. The raw string values are stable (no accidental renames).
    ///   2. The round-trip decode produces the correct case.
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
            // Verify raw value matches spec
            XCTAssertEqual(flag.rawValue, expectedRawValues[flag],
                           "Raw value mismatch for \(flag)")

            // Verify encode → decode round-trip
            let data = try encoder.encode(flag)
            let decoded = try decoder.decode(SafetyFlag.self, from: data)
            XCTAssertEqual(decoded, flag, "Round-trip failed for \(flag)")
        }
    }

    /// Verifies that a SetPrescription carrying every SafetyFlag survives a
    /// full Codable round-trip with all flags intact.
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
}
