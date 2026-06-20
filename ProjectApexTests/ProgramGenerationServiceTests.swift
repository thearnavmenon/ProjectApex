// ProgramGenerationServiceTests.swift
// ProjectApexTests — P2-T02
//
// Unit tests for ProgramGenerationService.generate().
//
// Test categories:
//   1. LIVE API (gated): Real Anthropic opus call.
//      Skipped unless APEX_INTEGRATION_TESTS=1 is set in the scheme.
//
//   2. Mock-provider paths (always run):
//      a. Valid JSON response → returns decoded Mesocycle with correct shape.
//      b. Malformed JSON → throws ProgramGenerationError.decodingFailed.
//      c. Missing mesocycle key → throws ProgramGenerationError.decodingFailed.
//      d. LLM provider throws → throws ProgramGenerationError.llmProviderError.
//      e. Markdown-fenced response → fences stripped, decodes successfully.
//      f. isGenerating flag transitions correctly (false → true → false).

import XCTest
import Testing
@testable import ProjectApex

// MARK: - Mock providers

/// Returns a fixed string response — does not make any network calls.
private struct MockLLMProvider: LLMProvider {
    let response: String
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        response
    }
}

/// Always throws a network error.
private struct ThrowingLLMProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - Valid mock JSON (template format)

/// Minimal valid mesocycle_template JSON that satisfies the two-stage decoder.
/// Contains all 4 phase templates, each with 1 day and 1 exercise.
private let validMesocycleJSON = """
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
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 3,
                "rep_range": { "min": 8, "max": 12 },
                "tempo": "3-1-2-0",
                "rest_seconds": 90,
                "rir_target": 3,
                "coaching_cues": ["Retract scapula", "Control the descent"]
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
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 3,
                "rep_range": { "min": 6, "max": 10 },
                "tempo": "3-1-2-0",
                "rest_seconds": 120,
                "rir_target": 2,
                "coaching_cues": ["Retract scapula", "Control the descent"]
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
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 3,
                "rep_range": { "min": 4, "max": 8 },
                "tempo": "3-1-2-0",
                "rest_seconds": 150,
                "rir_target": 1,
                "coaching_cues": ["Retract scapula", "Maximal intent"]
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
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 2,
                "rep_range": { "min": 10, "max": 15 },
                "tempo": "2-1-2-0",
                "rest_seconds": 60,
                "rir_target": 4,
                "coaching_cues": ["Easy effort", "Focus on form"]
              }
            ]
          }
        ]
      }
    ]
  }
}
"""

/// JSON that is syntactically valid but missing the "mesocycle" wrapper key.
private let missingWrapperKeyJSON = """
{
  "program": {
    "id": "DDDDDDDD-0000-0000-0000-000000000001"
  }
}
"""

/// Completely unparsable JSON.
private let malformedJSON = "{ this is not json }"

// MARK: - ProgramGenerationServiceTests

final class ProgramGenerationServiceTests: XCTestCase {

    // MARK: - Helpers

    private func requireLiveAPI() throws {
        let flag = ProcessInfo.processInfo.environment["APEX_INTEGRATION_TESTS"]
        guard flag == "1" else {
            throw XCTSkip(
                "Live API test skipped. Set APEX_INTEGRATION_TESTS=1 to enable."
            )
        }
    }

    private func requireAnthropicKey() throws -> String {
        guard let key = try KeychainService.shared.retrieve(.anthropicAPIKey),
              !key.isEmpty else {
            throw XCTSkip(
                "No Anthropic API key in Keychain. " +
                "Add one via Settings → Developer Settings before running live tests."
            )
        }
        return key
    }

    // MARK: ─── 1. Live API test ───────────────────────────────────────────────

    /// Calls generate() against the real Anthropic opus API.
    /// Asserts the returned Mesocycle has 12 weeks with the correct phase structure.
    func test_liveAPI_generate_returns12WeekMesocycle() async throws {
        try requireLiveAPI()
        let apiKey = try requireAnthropicKey()

        let service = ProgramGenerationService(
            provider: AnthropicProvider.forProgramGeneration(apiKey: apiKey)
        )

        let userProfile = UserProfile(
            userId: UUID().uuidString,
            experienceLevel: "intermediate",
            goals: ["hypertrophy"],
            bodyweightKg: 80.0,
            ageYears: 28
        )
        let gymProfile = GymProfile.mockProfile()

        let mesocycle = try await service.generate(
            userProfile: userProfile,
            gymProfile: gymProfile
        )

        // Template is expanded client-side to exactly 12 weeks
        XCTAssertEqual(mesocycle.totalWeeks, 12)
        XCTAssertEqual(mesocycle.weeks.count, 12,
                       "Template expansion must produce exactly 12 weeks.")

        // Verify phase structure
        let phases = mesocycle.weeks.map { $0.phase }
        // Weeks 1–4: accumulation
        XCTAssertTrue(phases[0..<4].allSatisfy { $0 == .accumulation },
                      "Weeks 1–4 must be accumulation phase.")
        // Weeks 5–8: intensification
        XCTAssertTrue(phases[4..<8].allSatisfy { $0 == .intensification },
                      "Weeks 5–8 must be intensification phase.")
        // Weeks 9–11: peaking
        XCTAssertTrue(phases[8..<11].allSatisfy { $0 == .peaking },
                      "Weeks 9–11 must be peaking phase.")
        // Week 12: deload
        XCTAssertEqual(mesocycle.weeks[11].phase, .deload,
                       "Week 12 must be deload phase.")
        XCTAssertTrue(mesocycle.weeks[11].isDeload,
                      "Week 12 isDeload must be true.")

        // Every week must have at least one training day
        for week in mesocycle.weeks {
            XCTAssertFalse(week.trainingDays.isEmpty,
                           "Week \(week.weekNumber) must have at least one training day.")
        }

        // Every training day must have at least one exercise
        for week in mesocycle.weeks {
            for day in week.trainingDays {
                XCTAssertFalse(day.exercises.isEmpty,
                               "Day '\(day.dayLabel)' in week \(week.weekNumber) must have exercises.")
            }
        }

        // All exercises must use equipment present in mockProfile
        let availableEquipment = Set(GymProfile.mockProfile().equipment.map { $0.equipmentType })
        for week in mesocycle.weeks {
            for day in week.trainingDays {
                for exercise in day.exercises {
                    // unknown() equipment types are allowed (LLM may use future types)
                    if case .unknown = exercise.equipmentRequired { continue }
                    XCTAssertTrue(
                        availableEquipment.contains(exercise.equipmentRequired),
                        "Exercise '\(exercise.name)' requires \(exercise.equipmentRequired) " +
                        "which is not in the mock gym profile."
                    )
                }
            }
        }
    }

    // MARK: ─── 1b. Live API — dumbbell-only gym ──────────────────────────────────

    /// Calls generate() with a single dumbbell_set gym profile.
    /// Verifies all 12 weeks decode, expand correctly, and only use dumbbell_set.
    func test_liveAPI_dumbbellOnly_generate_returns12WeekMesocycle() async throws {
        try requireLiveAPI()
        let apiKey = try requireAnthropicKey()

        let service = ProgramGenerationService(
            provider: AnthropicProvider.forProgramGeneration(apiKey: apiKey)
        )

        let userProfile = UserProfile(
            userId: UUID().uuidString,
            experienceLevel: "intermediate",
            goals: ["hypertrophy"],
            bodyweightKg: 75.0,
            ageYears: 26
        )

        // Dumbbell-only gym profile
        let dumbbellGymProfile = GymProfile(
            id: UUID(),
            scanSessionId: "test_dumbbell_only",
            createdAt: Date(),
            lastUpdatedAt: Date(),
            equipment: [
                EquipmentItem(
                    id: UUID(),
                    equipmentType: .dumbbellSet,
                    count: 1,
                    notes: nil,
                    detectedByVision: false
                )
            ],
            isActive: true
        )

        let mesocycle = try await service.generate(
            userProfile: userProfile,
            gymProfile: dumbbellGymProfile
        )

        // Shape checks
        XCTAssertEqual(mesocycle.totalWeeks, 12)
        XCTAssertEqual(mesocycle.weeks.count, 12, "Must expand to exactly 12 weeks.")

        // Phase structure
        XCTAssertTrue(mesocycle.weeks[0..<4].allSatisfy { $0.phase == MesocyclePhase.accumulation },
                      "Weeks 1–4 must be accumulation.")
        XCTAssertTrue(mesocycle.weeks[4..<8].allSatisfy { $0.phase == MesocyclePhase.intensification },
                      "Weeks 5–8 must be intensification.")
        XCTAssertTrue(mesocycle.weeks[8..<11].allSatisfy { $0.phase == MesocyclePhase.peaking },
                      "Weeks 9–11 must be peaking.")
        XCTAssertEqual(mesocycle.weeks[11].phase, MesocyclePhase.deload, "Week 12 must be deload.")

        // Every week has training days with exercises
        for week in mesocycle.weeks {
            XCTAssertFalse(week.trainingDays.isEmpty,
                           "Week \(week.weekNumber) must have training days.")
            for day in week.trainingDays {
                XCTAssertFalse(day.exercises.isEmpty,
                               "Day '\(day.dayLabel)' in week \(week.weekNumber) must have exercises.")
            }
        }

        // Equipment constraint: every exercise must use dumbbell_set
        for week in mesocycle.weeks {
            for day in week.trainingDays {
                for exercise in day.exercises {
                    if case .unknown = exercise.equipmentRequired { continue }
                    XCTAssertEqual(
                        exercise.equipmentRequired, EquipmentType.dumbbellSet,
                        "Exercise '\(exercise.name)' (week \(week.weekNumber)) must use dumbbell_set, " +
                        "got \(exercise.equipmentRequired.typeKey)."
                    )
                }
            }
        }
    }

    // MARK: ─── 2. Valid JSON response decodes + expands correctly ───────────────

    func test_generate_validJSON_returnsMesocycle() async throws {
        let service = ProgramGenerationService(
            provider: MockLLMProvider(response: validMesocycleJSON)
        )

        let mesocycle = try await service.generate(
            userProfile: UserProfile(
                userId: "test-user",
                experienceLevel: "intermediate",
                goals: ["hypertrophy"],
                bodyweightKg: nil,
                ageYears: nil
            ),
            gymProfile: GymProfile.mockProfile()
        )

        // Template is expanded to 12 weeks client-side
        XCTAssertEqual(mesocycle.totalWeeks, 12)
        XCTAssertEqual(mesocycle.weeks.count, 12)
        XCTAssertTrue(mesocycle.isActive)
        XCTAssertEqual(mesocycle.periodizationModel, "linear_periodization")

        // Phase structure
        XCTAssertTrue(mesocycle.weeks[0..<4].allSatisfy { $0.phase == .accumulation })
        XCTAssertTrue(mesocycle.weeks[4..<8].allSatisfy { $0.phase == .intensification })
        XCTAssertTrue(mesocycle.weeks[8..<11].allSatisfy { $0.phase == .peaking })
        XCTAssertEqual(mesocycle.weeks[11].phase, .deload)

        // Each week has 1 day (mirrors the single-day template)
        for week in mesocycle.weeks {
            XCTAssertEqual(week.trainingDays.count, 1)
        }

        // Progressive overload: accumulation week 3 (index 2) should have +1 set vs template
        let accumulationWeek1 = mesocycle.weeks[0].trainingDays[0].exercises[0]
        let accumulationWeek3 = mesocycle.weeks[2].trainingDays[0].exercises[0]
        XCTAssertEqual(accumulationWeek1.sets, 3) // baseline
        XCTAssertEqual(accumulationWeek3.sets, 4) // +1 set at weekInPhase=2

        // Equipment is dumbbell_set throughout
        for week in mesocycle.weeks {
            for day in week.trainingDays {
                for exercise in day.exercises {
                    XCTAssertEqual(exercise.equipmentRequired, .dumbbellSet,
                                   "All exercises must use dumbbell_set in this test template.")
                }
            }
        }
    }

    // MARK: ─── 3. Missing wrapper key → decodingFailed ────────────────────────

    func test_generate_missingMesocycleKey_throwsDecodingFailed() async {
        let service = ProgramGenerationService(
            provider: MockLLMProvider(response: missingWrapperKeyJSON)
        )

        do {
            _ = try await service.generate(
                userProfile: UserProfile(
                    userId: "test-user",
                    experienceLevel: "beginner",
                    goals: [],
                    bodyweightKg: nil,
                    ageYears: nil
                ),
                gymProfile: GymProfile.mockProfile()
            )
            XCTFail("Expected ProgramGenerationError.decodingFailed to be thrown.")
        } catch let error as ProgramGenerationError {
            guard case .decodingFailed(let detail) = error else {
                return XCTFail("Expected .decodingFailed, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty,
                           "decodingFailed detail string must not be empty.")
            // Detail should mention what went wrong
            XCTAssertTrue(
                detail.lowercased().contains("decode") || detail.lowercased().contains("json"),
                "decodingFailed detail must mention decode or JSON. Got: \(detail)"
            )
        } catch {
            XCTFail("Expected ProgramGenerationError but got: \(error)")
        }
    }

    // MARK: ─── 4. Malformed JSON → decodingFailed ─────────────────────────────

    func test_generate_malformedJSON_throwsDecodingFailed() async {
        let service = ProgramGenerationService(
            provider: MockLLMProvider(response: malformedJSON)
        )

        do {
            _ = try await service.generate(
                userProfile: UserProfile(
                    userId: "test-user",
                    experienceLevel: "intermediate",
                    goals: ["strength"],
                    bodyweightKg: 90.0,
                    ageYears: 30
                ),
                gymProfile: GymProfile.mockProfile()
            )
            XCTFail("Expected ProgramGenerationError.decodingFailed to be thrown.")
        } catch let error as ProgramGenerationError {
            guard case .decodingFailed = error else {
                return XCTFail("Expected .decodingFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected ProgramGenerationError but got: \(error)")
        }
    }

    // MARK: ─── 5. Provider throws → llmProviderError ─────────────────────────

    func test_generate_providerThrows_throwsLLMProviderError() async {
        let service = ProgramGenerationService(
            provider: ThrowingLLMProvider()
        )

        do {
            _ = try await service.generate(
                userProfile: UserProfile(
                    userId: "test-user",
                    experienceLevel: "intermediate",
                    goals: ["hypertrophy"],
                    bodyweightKg: nil,
                    ageYears: nil
                ),
                gymProfile: GymProfile.mockProfile()
            )
            XCTFail("Expected ProgramGenerationError.llmProviderError to be thrown.")
        } catch let error as ProgramGenerationError {
            guard case .llmProviderError(let message) = error else {
                return XCTFail("Expected .llmProviderError, got \(error)")
            }
            XCTAssertFalse(message.isEmpty,
                           "llmProviderError message must not be empty.")
        } catch {
            XCTFail("Expected ProgramGenerationError but got: \(error)")
        }
    }

    // MARK: ─── 6. Markdown-fenced response stripped and decoded ───────────────

    func test_generate_markdownFencedResponse_strippedAndDecoded() async throws {
        let fenced = "```json\n\(validMesocycleJSON)\n```"
        let service = ProgramGenerationService(
            provider: MockLLMProvider(response: fenced)
        )

        let mesocycle = try await service.generate(
            userProfile: UserProfile(
                userId: "test-user",
                experienceLevel: "intermediate",
                goals: ["hypertrophy"],
                bodyweightKg: nil,
                ageYears: nil
            ),
            gymProfile: GymProfile.mockProfile()
        )

        XCTAssertEqual(mesocycle.totalWeeks, 12,
                       "Markdown-fenced response must be stripped and decoded successfully.")
    }

    // MARK: ─── 7. MacroProgramRequest encodes correctly ───────────────────────

    func test_macroProgramRequest_encodesAllFields() throws {
        let userProfile = UserProfile(
            userId: "abc-123",
            experienceLevel: "advanced",
            goals: ["hypertrophy", "strength"],
            bodyweightKg: 85.0,
            ageYears: 32
        )
        let gymProfile = GymProfile.mockProfile()
        let request = MacroProgramRequest(
            userProfile: userProfile,
            gymProfile: GymProfilePayload(from: gymProfile),
            programmingConstraints: .default
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNotNil(json["user_profile"])
        XCTAssertNotNil(json["gym_profile"])
        XCTAssertNotNil(json["programming_constraints"])

        let constraints = try XCTUnwrap(json["programming_constraints"] as? [String: Any])
        XCTAssertEqual(constraints["total_weeks"] as? Int, 12)
        XCTAssertEqual(constraints["training_days_per_week"] as? Int, 4)
        XCTAssertEqual(constraints["periodization_model"] as? String, "linear_periodization")

        let gymPayload = try XCTUnwrap(json["gym_profile"] as? [String: Any])
        let available = try XCTUnwrap(gymPayload["available_equipment"] as? [[String: Any]])
        XCTAssertFalse(available.isEmpty,
                       "GymProfilePayload must list at least one equipment type.")
        // Each entry now carries BOTH the canonical key and the display name.
        let barbell = available.first { $0["key"] as? String == "barbell" }
        XCTAssertNotNil(barbell,
                        "GymProfilePayload must include barbell from mockProfile.")
        XCTAssertEqual(barbell?["name"] as? String, "Barbell",
                       "available_equipment entries must carry the display name.")
    }

    // MARK: ─── 8. GymProfilePayload maps equipment type keys ─────────────────

    func test_gymProfilePayload_mapsEquipmentTypeKeys() {
        let gymProfile = GymProfile.mockProfile()
        let payload = GymProfilePayload(from: gymProfile)

        XCTAssertEqual(
            payload.availableEquipment.count,
            gymProfile.equipment.count,
            "GymProfilePayload must have one entry per EquipmentItem."
        )

        for item in gymProfile.equipment {
            let ref = payload.availableEquipment.first { $0.key == item.equipmentType.typeKey }
            XCTAssertNotNil(
                ref,
                "GymProfilePayload must contain type key '\(item.equipmentType.typeKey)'."
            )
            XCTAssertEqual(
                ref?.name, item.equipmentType.displayName,
                "GymProfilePayload entry must carry the display name."
            )
        }
    }
}

// MARK: - #192 sibling: day_label normalization in the legacy static path

/// Variant of `validMesocycleJSON` whose accumulation phase carries free-text
/// day labels with special characters ("Arms & Shoulders", "Chest/Back"). The
/// legacy static `generate()` path mints `TrainingDay.dayLabel` in
/// `ProgramGenerationService.buildTrainingDay`; before the #192 sibling fix
/// (issue #243) it passed `template.dayLabel` through unnormalized, detaching the
/// day from history (the #172 / ADR-0017 concern) and reintroducing the exact
/// drift #192 fixed in the macro-skeleton path (PR #229).
private let specialCharDayLabelJSON = """
{
  "mesocycle_template": {
    "periodization_model": "linear_periodization",
    "phase_templates": [
      {
        "phase": "accumulation",
        "training_days": [
          {
            "day_of_week": 1,
            "day_label": "Arms & Shoulders",
            "session_notes": null,
            "exercises": [
              {
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 3,
                "rep_range": { "min": 8, "max": 12 },
                "tempo": "3-1-2-0",
                "rest_seconds": 90,
                "rir_target": 3,
                "coaching_cues": ["Retract scapula", "Control the descent"]
              }
            ]
          },
          {
            "day_of_week": 2,
            "day_label": "Chest/Back",
            "session_notes": null,
            "exercises": [
              {
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 3,
                "rep_range": { "min": 8, "max": 12 },
                "tempo": "3-1-2-0",
                "rest_seconds": 90,
                "rir_target": 3,
                "coaching_cues": ["Retract scapula", "Control the descent"]
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
            "day_label": "Arms & Shoulders",
            "session_notes": null,
            "exercises": [
              {
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 3,
                "rep_range": { "min": 6, "max": 10 },
                "tempo": "3-1-2-0",
                "rest_seconds": 120,
                "rir_target": 2,
                "coaching_cues": ["Retract scapula", "Control the descent"]
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
            "day_label": "Arms & Shoulders",
            "session_notes": null,
            "exercises": [
              {
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 3,
                "rep_range": { "min": 4, "max": 8 },
                "tempo": "3-1-2-0",
                "rest_seconds": 150,
                "rir_target": 1,
                "coaching_cues": ["Retract scapula", "Maximal intent"]
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
            "day_label": "Arms & Shoulders",
            "session_notes": null,
            "exercises": [
              {
                "exercise_id": "dumbbell_bench_press",
                "name": "Dumbbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": "dumbbell_set",
                "sets": 2,
                "rep_range": { "min": 10, "max": 15 },
                "tempo": "2-1-2-0",
                "rest_seconds": 60,
                "rir_target": 4,
                "coaching_cues": ["Easy effort", "Focus on form"]
              }
            ]
          }
        ]
      }
    ]
  }
}
"""

/// Mirrors `MacroPlanServiceDayLabelNormalizationTests` for the sibling mint
/// point in the legacy static `ProgramGenerationService.generate()` path
/// (issue #243). Asserts PARITY with the canonical `MacroPlanService.normalizeDayLabel`
/// rather than re-deriving the algorithm, plus one explicit literal example.
@Suite("ProgramGenerationService — day_label normalization (#192 sibling, #243)")
struct ProgramGenerationServiceDayLabelNormalizationTests {

    private func makeUserProfile() -> UserProfile {
        UserProfile(
            userId: "test-user",
            experienceLevel: "intermediate",
            goals: ["hypertrophy"],
            bodyweightKg: nil,
            ageYears: nil
        )
    }

    @Test("generate normalizes free-text day_label through the legacy static expansion path")
    func normalizesDayLabelOnExpansion() async throws {
        let service = ProgramGenerationService(
            provider: MockLLMProvider(response: specialCharDayLabelJSON)
        )

        let meso = try await service.generate(
            userProfile: makeUserProfile(),
            gymProfile: GymProfile.mockProfile()
        )

        let labels = meso.weeks[0].trainingDays.map(\.dayLabel)
        try #require(labels.count == 2, "accumulation week must expand to its two template days")

        // Parity with the canonical normalizer — do not hardcode the algorithm here.
        #expect(labels[0] == MacroPlanService.normalizeDayLabel("Arms & Shoulders"))
        #expect(labels[1] == MacroPlanService.normalizeDayLabel("Chest/Back"))

        // Plus one explicit literal example (before the fix this was "Arms & Shoulders").
        #expect(labels[0] == "Arms_Shoulders")

        // Every minted label must be snake_case-safe across all 12 expanded weeks.
        for week in meso.weeks {
            for label in week.trainingDays.map(\.dayLabel) {
                #expect(
                    label.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
                    "day label must be snake_case-safe, got \(label)"
                )
            }
        }
    }
}
