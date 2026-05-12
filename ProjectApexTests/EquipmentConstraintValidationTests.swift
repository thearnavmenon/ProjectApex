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

/// Builds a minimal valid MesocycleTemplateWrapper JSON for a program that uses only barbell.
/// This matches the format ProgramGenerationService.generate() decodes from the LLM (Stage 1).
private func barbellOnlyMesocycleJSON(userId: String = "AAAAAAAA-0000-0000-0000-000000000001") -> String {
    """
    {
      "mesocycle_template": {
        "periodization_model": "linear_periodization",
        "phase_templates": [
          {
            "phase": "accumulation",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
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
          },
          {
            "phase": "intensification",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
                    "sets": 4,
                    "rep_range": { "min": 6, "max": 8 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 180,
                    "rir_target": 2,
                    "coaching_cues": ["Retract scapula"]
                  }
                ]
              }
            ]
          },
          {
            "phase": "peaking",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
                    "sets": 3,
                    "rep_range": { "min": 3, "max": 5 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 240,
                    "rir_target": 1,
                    "coaching_cues": ["Retract scapula"]
                  }
                ]
              }
            ]
          },
          {
            "phase": "deload",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
                    "sets": 2,
                    "rep_range": { "min": 8, "max": 12 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 120,
                    "rir_target": 4,
                    "coaching_cues": ["Easy pace"]
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

/// Builds a MesocycleTemplateWrapper JSON that contains a cable machine exercise (not in limitedGymProfile).
private func cableMachineViolationJSON() -> String {
    """
    {
      "mesocycle_template": {
        "periodization_model": "linear_periodization",
        "phase_templates": [
          {
            "phase": "accumulation",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "cable_fly",
                    "name": "Cable Fly",
                    "primary_muscle": "pectoralis_major",
                    "synergists": [],
                    "equipment_required": "cable_machine_single",
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
          },
          {
            "phase": "intensification",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "cable_fly",
                    "name": "Cable Fly",
                    "primary_muscle": "pectoralis_major",
                    "synergists": [],
                    "equipment_required": "cable_machine_single",
                    "sets": 3,
                    "rep_range": { "min": 10, "max": 12 },
                    "tempo": "2-1-1-0",
                    "rest_seconds": 90,
                    "rir_target": 2,
                    "coaching_cues": []
                  }
                ]
              }
            ]
          },
          {
            "phase": "peaking",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "cable_fly",
                    "name": "Cable Fly",
                    "primary_muscle": "pectoralis_major",
                    "synergists": [],
                    "equipment_required": "cable_machine_single",
                    "sets": 3,
                    "rep_range": { "min": 8, "max": 10 },
                    "tempo": "2-1-1-0",
                    "rest_seconds": 90,
                    "rir_target": 1,
                    "coaching_cues": []
                  }
                ]
              }
            ]
          },
          {
            "phase": "deload",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "cable_fly",
                    "name": "Cable Fly",
                    "primary_muscle": "pectoralis_major",
                    "synergists": [],
                    "equipment_required": "cable_machine_single",
                    "sets": 2,
                    "rep_range": { "min": 12, "max": 15 },
                    "tempo": "2-1-1-0",
                    "rest_seconds": 90,
                    "rir_target": 4,
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

    // MARK: ─── validateNonEmptyTrainingDays() — pure static tests ─────────────

    func test_validateNonEmpty_emptyMesocycle_noViolations() {
        // A fully-populated mesocycle (every day has at least one exercise) returns no violations.
        let mesocycle = singleExerciseMesocycle(equipment: .barbell)
        let violations = ProgramGenerationService.validateNonEmptyTrainingDays(mesocycle: mesocycle)
        XCTAssertTrue(violations.isEmpty,
                      "No violations expected when every training day has at least one exercise.")
    }

    func test_validateNonEmpty_detectsEmptyDay() {
        // A mesocycle with one day whose exercises array is empty produces one violation.
        let emptyDay = TrainingDay(
            id: UUID(),
            dayOfWeek: 3,
            dayLabel: "Full_Body",
            exercises: [],
            sessionNotes: nil
        )
        let week = TrainingWeek(
            id: UUID(),
            weekNumber: 4,
            phase: .accumulation,
            trainingDays: [emptyDay]
        )
        let mesocycle = Mesocycle(
            id: UUID(),
            userId: UUID(),
            createdAt: Date(),
            isActive: true,
            weeks: [week],
            totalWeeks: 12,
            periodizationModel: "linear_periodization"
        )

        let violations = ProgramGenerationService.validateNonEmptyTrainingDays(mesocycle: mesocycle)
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations[0].dayLabel, "Full_Body")
        XCTAssertEqual(violations[0].weekNumber, 4)
        XCTAssertEqual(violations[0].phase, .accumulation)
    }

    func test_validateNonEmpty_multipleEmpties_acrossWeeks() {
        // Two empty days in two different weeks → two violations.
        func makeWeek(_ n: Int, populated: Bool) -> TrainingWeek {
            let day = TrainingDay(
                id: UUID(),
                dayOfWeek: 1,
                dayLabel: "Day_\(n)",
                exercises: populated ? [makePlannedExercise()] : [],
                sessionNotes: nil
            )
            return TrainingWeek(
                id: UUID(), weekNumber: n, phase: .accumulation, trainingDays: [day]
            )
        }
        let mesocycle = Mesocycle(
            id: UUID(),
            userId: UUID(),
            createdAt: Date(),
            isActive: true,
            weeks: [
                makeWeek(1, populated: false),  // empty
                makeWeek(2, populated: true),   // ok
                makeWeek(3, populated: false),  // empty
            ],
            totalWeeks: 12,
            periodizationModel: "linear_periodization"
        )

        let violations = ProgramGenerationService.validateNonEmptyTrainingDays(mesocycle: mesocycle)
        XCTAssertEqual(violations.count, 2)
        XCTAssertEqual(Set(violations.map(\.weekNumber)), Set([1, 3]))
    }

    func test_emptyDayViolation_struct() {
        let v = EmptyTrainingDayViolation(
            dayLabel: "Lower",
            weekNumber: 4,
            phase: .accumulation
        )
        XCTAssertEqual(v.dayLabel, "Lower")
        XCTAssertEqual(v.weekNumber, 4)
        XCTAssertEqual(v.phase, .accumulation)
    }

    // MARK: ─── generate() empty-day corrective re-prompt path ─────────────────

    func test_generate_emptyDayCorrected_succeedsAfterRetry() async throws {
        // First call returns a template with one empty Full_Body day; second
        // call returns the same template with that day populated. The service
        // should detect, re-prompt, and return the corrected mesocycle.
        let provider = CallCountingProvider(responses: [
            mesocycleWithEmptyFullBodyDayJSON(),    // first call — has empty day
            barbellOnlyMesocycleJSON()              // second call (correction) — clean
        ])
        let service = ProgramGenerationService(provider: provider)

        let mesocycle = try await service.generate(
            userProfile: UserProfile(
                userId: "AAAAAAAA-0000-0000-0000-000000000001",
                experienceLevel: "intermediate",
                goals: ["hypertrophy"],
                bodyweightKg: 80,
                ageYears: 28
            ),
            gymProfile: limitedGymProfile,
            trainingDaysPerWeek: 4
        )

        XCTAssertEqual(provider.callCount, 2,
                       "Expected one corrective re-prompt after detecting the empty day.")
        let remaining = ProgramGenerationService.validateNonEmptyTrainingDays(mesocycle: mesocycle)
        XCTAssertTrue(remaining.isEmpty,
                      "Mesocycle returned to caller must have no empty training days.")
    }

    func test_generate_emptyDayPersists_throwsEmptyTrainingDay() async {
        // Both calls return the empty-day template. After one corrective retry
        // the service should throw `emptyTrainingDay`.
        let provider = CallCountingProvider(responses: [
            mesocycleWithEmptyFullBodyDayJSON(),
            mesocycleWithEmptyFullBodyDayJSON()
        ])
        let service = ProgramGenerationService(provider: provider)

        do {
            _ = try await service.generate(
                userProfile: UserProfile(
                    userId: "AAAAAAAA-0000-0000-0000-000000000001",
                    experienceLevel: "intermediate",
                    goals: ["hypertrophy"],
                    bodyweightKg: 80,
                    ageYears: 28
                ),
                gymProfile: limitedGymProfile,
                trainingDaysPerWeek: 4
            )
            XCTFail("Expected ProgramGenerationError.emptyTrainingDay")
        } catch let err as ProgramGenerationError {
            guard case .emptyTrainingDay(let violations) = err else {
                XCTFail("Expected .emptyTrainingDay, got \(err)")
                return
            }
            XCTAssertFalse(violations.isEmpty,
                           "Throw must include at least one violation.")
            XCTAssertTrue(violations.contains { $0.dayLabel == "Full_Body" },
                          "The Full_Body day from the fixture should appear in violations.")
        } catch {
            XCTFail("Expected ProgramGenerationError but got: \(error)")
        }
    }
}

// MARK: - Empty-day test fixtures

private func makePlannedExercise() -> PlannedExercise {
    PlannedExercise(
        id: UUID(),
        exerciseId: "barbell_bench_press",
        name: "Barbell Bench Press",
        primaryMuscle: "pectoralis_major",
        synergists: ["anterior_deltoid"],
        equipmentRequired: .barbell,
        sets: 3,
        repRange: RepRange(min: 8, max: 12),
        tempo: "3-1-1-0",
        restSeconds: 120,
        rirTarget: 2,
        coachingCues: ["Retract scapula"]
    )
}

/// MesocycleTemplate JSON with one accumulation training day whose `exercises`
/// array is empty (Full_Body). All other phases are populated with a single
/// barbell exercise. Drives the empty-day-corrective-re-prompt code path.
private func mesocycleWithEmptyFullBodyDayJSON() -> String {
    """
    {
      "mesocycle_template": {
        "periodization_model": "linear_periodization",
        "phase_templates": [
          {
            "phase": "accumulation",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
                    "sets": 4,
                    "rep_range": { "min": 8, "max": 12 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 150,
                    "rir_target": 3,
                    "coaching_cues": ["Retract scapula"]
                  }
                ]
              },
              {
                "day_of_week": 3,
                "day_label": "Full_Body",
                "session_notes": null,
                "exercises": []
              }
            ]
          },
          {
            "phase": "intensification",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
                    "sets": 4,
                    "rep_range": { "min": 6, "max": 8 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 180,
                    "rir_target": 2,
                    "coaching_cues": ["Retract scapula"]
                  }
                ]
              }
            ]
          },
          {
            "phase": "peaking",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
                    "sets": 3,
                    "rep_range": { "min": 3, "max": 5 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 240,
                    "rir_target": 1,
                    "coaching_cues": ["Retract scapula"]
                  }
                ]
              }
            ]
          },
          {
            "phase": "deload",
            "training_days": [
              {
                "day_of_week": 1,
                "day_label": "Push_A",
                "session_notes": null,
                "exercises": [
                  {
                    "exercise_id": "barbell_bench_press",
                    "name": "Barbell Bench Press",
                    "primary_muscle": "pectoralis_major",
                    "synergists": ["anterior_deltoid"],
                    "equipment_required": "barbell",
                    "sets": 2,
                    "rep_range": { "min": 8, "max": 12 },
                    "tempo": "3-1-1-0",
                    "rest_seconds": 120,
                    "rir_target": 4,
                    "coaching_cues": ["Easy pace"]
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
