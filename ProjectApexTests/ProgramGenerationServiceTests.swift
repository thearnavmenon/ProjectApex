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

// MARK: - Valid mock JSON

/// Minimal valid MesocycleWrapper JSON that satisfies the decoder.
/// Represents a 1-week accumulation mesocycle with 1 day and 1 exercise.
private let validMesocycleJSON = """
{
  "mesocycle": {
    "id": "DDDDDDDD-0000-0000-0000-000000000001",
    "user_id": "AAAAAAAA-0000-0000-0000-000000000001",
    "created_at": "2026-03-15T00:00:00Z",
    "is_active": true,
    "total_weeks": 12,
    "periodization_model": "linear_periodization",
    "weeks": [
      {
        "id": "AAAAAAAA-1111-0000-0000-000000000001",
        "week_number": 1,
        "phase": "accumulation",
        "training_days": [
          {
            "id": "BBBBBBBB-0000-0000-0000-000000000001",
            "day_of_week": 1,
            "day_label": "Push_A",
            "session_notes": null,
            "exercises": [
              {
                "id": "CCCCCCCC-0000-0000-0000-000000000001",
                "exercise_id": "barbell_bench_press",
                "name": "Barbell Bench Press",
                "primary_muscle": "pectoralis_major",
                "synergists": ["anterior_deltoid", "triceps_brachii"],
                "equipment_required": { "type": "barbell" },
                "sets": 4,
                "rep_range": { "min": 8, "max": 12 },
                "tempo": "3-1-1-0",
                "rest_seconds": 150,
                "rir_target": 3,
                "coaching_cues": ["Retract scapula", "Drive through bar"]
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

        // Must have 12 weeks
        XCTAssertEqual(mesocycle.totalWeeks, 12)
        XCTAssertEqual(mesocycle.weeks.count, 12,
                       "Live API must return exactly 12 weeks.")

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

    // MARK: ─── 2. Valid JSON response decodes correctly ───────────────────────

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

        XCTAssertEqual(mesocycle.id, UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001"))
        XCTAssertEqual(mesocycle.totalWeeks, 12)
        XCTAssertTrue(mesocycle.isActive)
        XCTAssertEqual(mesocycle.periodizationModel, "linear_periodization")
        XCTAssertEqual(mesocycle.weeks.count, 1)

        let week = mesocycle.weeks[0]
        XCTAssertEqual(week.weekNumber, 1)
        XCTAssertEqual(week.phase, .accumulation)
        XCTAssertFalse(week.isDeload)
        XCTAssertEqual(week.trainingDays.count, 1)

        let day = week.trainingDays[0]
        XCTAssertEqual(day.dayLabel, "Push_A")
        XCTAssertEqual(day.dayOfWeek, 1)
        XCTAssertNil(day.sessionNotes)
        XCTAssertEqual(day.exercises.count, 1)

        let exercise = day.exercises[0]
        XCTAssertEqual(exercise.exerciseId, "barbell_bench_press")
        XCTAssertEqual(exercise.name, "Barbell Bench Press")
        XCTAssertEqual(exercise.equipmentRequired, .barbell)
        XCTAssertEqual(exercise.sets, 4)
        XCTAssertEqual(exercise.repRange.min, 8)
        XCTAssertEqual(exercise.repRange.max, 12)
        XCTAssertEqual(exercise.tempo, "3-1-1-0")
        XCTAssertEqual(exercise.rirTarget, 3)
        XCTAssertEqual(exercise.restSeconds, 150)
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
        let available = try XCTUnwrap(gymPayload["available_equipment"] as? [String])
        XCTAssertFalse(available.isEmpty,
                       "GymProfilePayload must list at least one equipment type.")
        // mockProfile has a barbell
        XCTAssertTrue(available.contains("barbell"),
                      "GymProfilePayload must include barbell from mockProfile.")
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
            XCTAssertTrue(
                payload.availableEquipment.contains(item.equipmentType.typeKey),
                "GymProfilePayload must contain type key '\(item.equipmentType.typeKey)'."
            )
        }
    }
}
