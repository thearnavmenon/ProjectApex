// EquipmentConstraintValidationTests.swift
// ProjectApexTests — P2-T03
//
// Unit tests for equipment constraint validation in ProgramGenerationService.
//
// Test categories:
//   1. validateEquipmentConstraints() — pure static function, no LLM calls.
//      a. Zero violations when all equipment is present.
//      b. One violation detected when required equipment is absent.
//      c. Multiple violations across multiple weeks.
//      d. .unknown() equipment type is always skipped (cannot be validated).
//
//   2. generate() with mock provider — corrective re-prompt path.
//      a. Mock returns valid program (0 violations) → proceeds, no re-prompt.
//      b. Mock returns violating program on first call, valid on second →
//         re-prompt triggered, result is the corrected program.
//      c. Mock always returns violating program → throws
//         ProgramGenerationError.equipmentConstraintViolation.

import XCTest
@testable import ProjectApex

// MARK: - Test fixtures

/// A gym profile containing only barbell + dumbbell_set + adjustable_bench.
private let limitedGymProfile: GymProfile = {
    GymProfile(
        id: UUID(),
        scanSessionId: "test-limited",
        equipment: [
            EquipmentItem(
                id: UUID(),
                equipmentType: .barbell,
                count: 1,
                detectedByVision: false
            ),
            EquipmentItem(
                id: UUID(),
                equipmentType: .dumbbellSet,
                count: 1,
                detectedByVision: false
            ),
            EquipmentItem(
                id: UUID(),
                equipmentType: .adjustableBench,
                count: 1,
                detectedByVision: false
            )
        ],
        isActive: true
    )
}()

/// Builds a minimal one-week mesocycle with a single exercise using the given equipment type.
private func singleExerciseMesocycle(equipment: EquipmentType, weekNumber: Int = 1) -> Mesocycle {
    let exercise = PlannedExercise(
        id: UUID(),
        exerciseId: "test_exercise",
        name: "Test Exercise",
        primaryMuscle: "pectoralis_major",
        synergists: [],
        equipmentRequired: equipment,
        sets: 3,
        repRange: RepRange(min: 8, max: 12),
        tempo: "3-1-1-0",
        restSeconds: 120,
        rirTarget: 2,
        coachingCues: []
    )
    let day = TrainingDay(
        id: UUID(),
        dayOfWeek: 1,
        dayLabel: "Test_Day",
        exercises: [exercise],
        sessionNotes: nil
    )
    let week = TrainingWeek(
        id: UUID(),
        weekNumber: weekNumber,
        phase: .accumulation,
        trainingDays: [day]
    )
    return Mesocycle(
        id: UUID(),
        userId: UUID(),
        createdAt: Date(),
        isActive: true,
        weeks: [week],
        totalWeeks: 12,
        periodizationModel: "linear_periodization"
    )
}

// MARK: - Mock LLM providers

/// Always returns a fixed string, counting calls.
private final class CallCountingProvider: LLMProvider, @unchecked Sendable {
    private let responses: [String]
    private(set) var callCount = 0

    init(responses: [String]) {
        self.responses = responses
    }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        defer { callCount += 1 }
        let index = min(callCount, responses.count - 1)
        return responses[index]
    }
}

/// Builds a minimal valid MesocycleWrapper JSON for a mesocycle that uses only barbell.
private func barbellOnlyMesocycleJSON(userId: String = "AAAAAAAA-0000-0000-0000-000000000001") -> String {
    """
    {
      "mesocycle": {
        "id": "DDDDDDDD-0000-0000-0000-000000000099",
        "user_id": "\(userId)",
        "created_at": "2026-03-15T00:00:00Z",
        "is_active": true,
        "total_weeks": 12,
        "periodization_model": "linear_periodization",
        "weeks": [
          {
            "id": "AAAAAAAA-1111-0000-0000-000000000099",
            "week_number": 1,
            "phase": "accumulation",
            "training_days": [
              {
                "id": "BBBBBBBB-0000-0000-0000-000000000099",
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "id": "CCCCCCCC-0000-0000-0000-000000000099",
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": { "type": "barbell" },
                    "sets": 4,
                    "rep_range": { "min": 8, "max": 12 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 150,
                    "rir_target": 3,
                    "coaching_cues": ["Retract scapula"]
                  }
                ]
              }
            ]
          }
        ]
      }
    }
    """
}

/// Builds a mesocycle JSON that contains a cable machine exercise (not in limitedGymProfile).
private func cableMachineViolationJSON() -> String {
    """
    {
      "mesocycle": {
        "id": "DDDDDDDD-0000-0000-0000-000000000077",
        "user_id": "AAAAAAAA-0000-0000-0000-000000000001",
        "created_at": "2026-03-15T00:00:00Z",
        "is_active": true,
        "total_weeks": 12,
        "periodization_model": "linear_periodization",
        "weeks": [
          {
            "id": "AAAAAAAA-1111-0000-0000-000000000077",
            "week_number": 1,
            "phase": "accumulation",
            "training_days": [
              {
                "id": "BBBBBBBB-0000-0000-0000-000000000077",
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "id": "CCCCCCCC-0000-0000-0000-000000000077",
                    "exercise_id": "cable_fly",
                    "name": "Cable Fly",
                    "primary_muscle": "pectoralis_major",
                    "synergists": [],
                    "equipment_required": { "type": "cable_machine_single" },
                    "sets": 3,
                    "rep_range": { "min": 12, "max": 15 },
                    "tempo": "2-1-1-0",
                    "rest_seconds": 90,
                    "rir_target": 3,
                    "coaching_cues": []
                  }
                ]
              }
            ]
          }
        ]
      }
    }
    """
}

// MARK: - EquipmentConstraintValidationTests

final class EquipmentConstraintValidationTests: XCTestCase {

    // MARK: ─── validateEquipmentConstraints() — pure static tests ────────────

    func test_validate_noViolations_whenAllEquipmentPresent() {
        let mesocycle = singleExerciseMesocycle(equipment: .barbell)
        let violations = ProgramGenerationService.validateEquipmentConstraints(
            mesocycle: mesocycle,
            gymProfile: limitedGymProfile
        )
        XCTAssertTrue(violations.isEmpty,
                      "No violations expected when barbell is in limitedGymProfile.")
    }

    func test_validate_oneViolation_whenEquipmentAbsent() {
        // Cable machine is NOT in limitedGymProfile
        let mesocycle = singleExerciseMesocycle(equipment: .cableMachine)
        let violations = ProgramGenerationService.validateEquipmentConstraints(
            mesocycle: mesocycle,
            gymProfile: limitedGymProfile
        )
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations[0].exerciseId, "test_exercise")
        XCTAssertEqual(violations[0].weekNumber, 1)
        XCTAssertEqual(violations[0].requiredEquipment, .cableMachine)
    }

    func test_validate_multipleViolations_acrossWeeks() {
        // Build a mesocycle with two weeks, each containing a cable exercise
        func makeWeek(_ n: Int, equipment: EquipmentType) -> TrainingWeek {
            let ex = PlannedExercise(
                id: UUID(),
                exerciseId: "ex_week_\(n)",
                name: "Exercise Week \(n)",
                primaryMuscle: "pectoralis_major",
                synergists: [],
                equipmentRequired: equipment,
                sets: 3,
                repRange: RepRange(min: 8, max: 12),
                tempo: "3-1-1-0",
                restSeconds: 90,
                rirTarget: 2,
                coachingCues: []
            )
            let day = TrainingDay(
                id: UUID(), dayOfWeek: 1, dayLabel: "Day",
                exercises: [ex], sessionNotes: nil
            )
            return TrainingWeek(
                id: UUID(), weekNumber: n, phase: .accumulation, trainingDays: [day]
            )
        }

        var mock = Mesocycle.mockMesocycle()
        mock = Mesocycle(
            id: mock.id,
            userId: mock.userId,
            createdAt: mock.createdAt,
            isActive: true,
            weeks: [
                makeWeek(1, equipment: .cableMachine),   // violation
                makeWeek(2, equipment: .barbell),          // ok
                makeWeek(3, equipment: .latPulldown)       // violation
            ],
            totalWeeks: 12,
            periodizationModel: "linear_periodization"
        )

        let violations = ProgramGenerationService.validateEquipmentConstraints(
            mesocycle: mock,
            gymProfile: limitedGymProfile
        )
        XCTAssertEqual(violations.count, 2,
                       "Two violations expected (cable machine + lat pulldown).")
        let weekNumbers = violations.map { $0.weekNumber }.sorted()
        XCTAssertEqual(weekNumbers, [1, 3])
    }

    func test_validate_unknownEquipment_isSkipped() {
        // .unknown() cannot be looked up in the gym profile — must be skipped
        let mesocycle = singleExerciseMesocycle(equipment: .unknown("future_machine_xyz"))
        let violations = ProgramGenerationService.validateEquipmentConstraints(
            mesocycle: mesocycle,
            gymProfile: limitedGymProfile
        )
        XCTAssertTrue(violations.isEmpty,
                      ".unknown() equipment must be skipped in validation.")
    }

    func test_validate_allKnownEquipmentInMockProfile_passesValidation() {
        // Every equipment type in GymProfile.mockProfile() should pass with that profile
        let gymProfile = GymProfile.mockProfile()
        let mock = Mesocycle.mockMesocycle()
        // mockMesocycle uses: .barbell, .cableMachine, .latPulldown, .seatedRow
        // mockProfile has: .dumbbellSet, .barbell, .adjustableBench, .cableMachine, .pullUpBar
        // latPulldown and seatedRow are NOT in mockProfile — those would be violations.
        // This test just confirms the function doesn't crash and returns a coherent result.
        let violations = ProgramGenerationService.validateEquipmentConstraints(
            mesocycle: mock,
            gymProfile: gymProfile
        )
        // Violations may or may not exist; just confirm they reference real exercise IDs.
        for v in violations {
            XCTAssertFalse(v.exerciseId.isEmpty)
            XCTAssertFalse(v.exerciseName.isEmpty)
            XCTAssertGreaterThan(v.weekNumber, 0)
        }
    }

    func test_violationStruct_fields() {
        let v = EquipmentViolation(
            exerciseId: "cable_fly",
            exerciseName: "Cable Fly",
            weekNumber: 3,
            requiredEquipment: .cableMachine
        )
        XCTAssertEqual(v.exerciseId, "cable_fly")
        XCTAssertEqual(v.exerciseName, "Cable Fly")
        XCTAssertEqual(v.weekNumber, 3)
        XCTAssertEqual(v.requiredEquipment, .cableMachine)
    }

    // MARK: ─── generate() with mock provider ─────────────────────────────────

    func test_generate_noViolations_noRePrompt() async throws {
        // First and only call returns a barbell-only program — no violations with limitedGymProfile
        let provider = CallCountingProvider(responses: [barbellOnlyMesocycleJSON()])
        let service = ProgramGenerationService(provider: provider)

        let mesocycle = try await service.generate(
            userProfile: UserProfile(
                userId: "AAAAAAAA-0000-0000-0000-000000000001",
                experienceLevel: "intermediate",
                goals: ["hypertrophy"],
                bodyweightKg: nil,
                ageYears: nil
            ),
            gymProfile: limitedGymProfile
        )

        // Only one LLM call should have been made (no corrective re-prompt)
        XCTAssertEqual(provider.callCount, 1,
                       "Only 1 LLM call expected when program has no violations.")
        XCTAssertEqual(mesocycle.weeks[0].trainingDays[0].exercises[0].equipmentRequired, .barbell)
    }

    func test_generate_violationOnFirstCall_correctOnSecond_triggersRePrompt() async throws {
        // First call returns a cable-machine violation; second call returns corrected barbell program
        let provider = CallCountingProvider(responses: [
            cableMachineViolationJSON(),    // first call — has violation
            barbellOnlyMesocycleJSON()      // second call (corrective re-prompt) — clean
        ])
        let service = ProgramGenerationService(provider: provider)

        let mesocycle = try await service.generate(
            userProfile: UserProfile(
                userId: "AAAAAAAA-0000-0000-0000-000000000001",
                experienceLevel: "intermediate",
                goals: ["hypertrophy"],
                bodyweightKg: nil,
                ageYears: nil
            ),
            gymProfile: limitedGymProfile
        )

        XCTAssertEqual(provider.callCount, 2,
                       "2 LLM calls expected: initial generation + corrective re-prompt.")
        // The returned mesocycle should be the corrected one (barbell only)
        XCTAssertEqual(
            mesocycle.weeks[0].trainingDays[0].exercises[0].equipmentRequired,
            .barbell,
            "Returned mesocycle must be the corrected version."
        )
    }

    func test_generate_violationPersistsAfterRePrompt_throwsEquipmentConstraintViolation() async {
        // Both calls return the cable-machine violation program
        let provider = CallCountingProvider(responses: [
            cableMachineViolationJSON(),
            cableMachineViolationJSON()
        ])
        let service = ProgramGenerationService(provider: provider)

        do {
            _ = try await service.generate(
                userProfile: UserProfile(
                    userId: "AAAAAAAA-0000-0000-0000-000000000001",
                    experienceLevel: "intermediate",
                    goals: ["hypertrophy"],
                    bodyweightKg: nil,
                    ageYears: nil
                ),
                gymProfile: limitedGymProfile
            )
            XCTFail("Expected ProgramGenerationError.equipmentConstraintViolation to be thrown.")
        } catch let error as ProgramGenerationError {
            guard case .equipmentConstraintViolation(let violations) = error else {
                return XCTFail("Expected .equipmentConstraintViolation, got \(error)")
            }
            XCTAssertEqual(provider.callCount, 2,
                           "Exactly 2 LLM calls: initial + 1 corrective re-prompt.")
            XCTAssertFalse(violations.isEmpty,
                           "Violation list must be non-empty.")
            XCTAssertEqual(violations[0].exerciseId, "cable_fly")
            XCTAssertEqual(violations[0].requiredEquipment, .cableMachine)
        } catch {
            XCTFail("Expected ProgramGenerationError but got: \(error)")
        }
    }

    func test_generate_violationPersists_errorDescriptionIsHelpful() async {
        let provider = CallCountingProvider(responses: [
            cableMachineViolationJSON(),
            cableMachineViolationJSON()
        ])
        let service = ProgramGenerationService(provider: provider)

        do {
            _ = try await service.generate(
                userProfile: UserProfile(
                    userId: "test",
                    experienceLevel: "intermediate",
                    goals: [],
                    bodyweightKg: nil,
                    ageYears: nil
                ),
                gymProfile: limitedGymProfile
            )
            XCTFail("Expected error.")
        } catch let error as ProgramGenerationError {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty)
            XCTAssertTrue(
                description.contains("Cable Fly") || description.contains("cable_fly"),
                "Error description must mention the violating exercise. Got: \(description)"
            )
        } catch {
            XCTFail("Expected ProgramGenerationError but got: \(error)")
        }
    }
}
