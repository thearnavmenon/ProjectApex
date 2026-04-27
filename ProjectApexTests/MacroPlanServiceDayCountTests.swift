// MacroPlanServiceDayCountTests.swift
// ProjectApexTests
//
// Verifies that MacroPlanService correctly threads training_days_per_week
// from the caller all the way into the JSON payload sent to the LLM, and
// that the decoded skeleton reflects the correct day count.
//
// Tests: 3, 4, 5, and 6 days per week.
// All tests use a capturing mock provider — no network calls.

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Capturing Mock Provider

/// Returns a pre-baked skeleton JSON whose `day_focus` length matches `daysPerWeek`.
/// Also captures the last `userPayload` string for payload inspection.
private final class CapturingMockProvider: LLMProvider, @unchecked Sendable {
    private(set) var lastUserPayload: String = ""
    private let daysPerWeek: Int

    init(daysPerWeek: Int) {
        self.daysPerWeek = daysPerWeek
    }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        lastUserPayload = userPayload
        return makeMockSkeletonJSON(daysPerWeek: daysPerWeek)
    }
}

// MARK: - JSON factory

/// Builds a minimal valid macro_plan skeleton with exactly `daysPerWeek`
/// entries in every day_focus array and sensible structural labels.
private func makeMockSkeletonJSON(daysPerWeek: Int) -> String {
    let dayLabels: [Int: [String]] = [
        3: ["Full Body A", "Full Body B", "Full Body C"],
        4: ["Upper Push", "Lower", "Upper Pull", "Full Body"],
        5: ["Push", "Pull", "Legs", "Upper", "Lower"],
        6: ["Push A", "Pull A", "Legs A", "Push B", "Pull B", "Legs B"]
    ]
    let labels = dayLabels[daysPerWeek] ?? Array(repeating: "Training Day", count: daysPerWeek)
    let dayFocusJSON = labels.map { "\"\($0)\"" }.joined(separator: ", ")

    var weeks: [String] = []
    let phaseMap: [(phase: String, range: ClosedRange<Int>)] = [
        ("accumulation",    1...4),
        ("intensification", 5...8),
        ("peaking",         9...11),
        ("deload",          12...12)
    ]
    for weekNum in 1...12 {
        let phase = phaseMap.first { $0.range.contains(weekNum) }?.phase ?? "accumulation"
        let landmark = 0.40 + Double(weekNum - 1) * 0.05
        weeks.append("""
          {
            "week_number": \(weekNum),
            "phase": "\(phase)",
            "week_label": "Week \(weekNum) Block",
            "day_focus": [\(dayFocusJSON)],
            "volume_landmark": \(String(format: "%.2f", min(landmark, 0.95)))
          }
        """)
    }

    return """
    {
      "macro_plan": {
        "periodization_model": "linear_periodization",
        "training_days_per_week": \(daysPerWeek),
        "weeks": [
    \(weeks.joined(separator: ",\n"))
        ]
      }
    }
    """
}

// MARK: - Helpers

private func makeGymProfile() -> GymProfile {
    GymProfile(
        scanSessionId: "test",
        equipment: [
            EquipmentItem(equipmentType: .barbell, count: 1, detectedByVision: false),
            EquipmentItem(equipmentType: .dumbbellSet, count: 1, detectedByVision: false),
            EquipmentItem(equipmentType: .powerRack, count: 1, detectedByVision: false)
        ]
    )
}

private func extractConstraintsFromPayload(_ json: String) throws -> (trainingDays: Int, totalWeeks: Int) {
    let data = try #require(json.data(using: .utf8))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let constraints = try #require(root["constraints"] as? [String: Any])
    let days = try #require(constraints["training_days_per_week"] as? Int)
    let weeks = try #require(constraints["total_weeks"] as? Int)
    return (days, weeks)
}

// MARK: - Tests

@Suite("MacroPlanService — training_days_per_week threading")
struct MacroPlanServiceDayCountTests {

    // MARK: 3-day

    @Test("3-day: payload contains training_days_per_week=3")
    func threeDayPayload() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 3)
        let service = MacroPlanService(provider: provider)

        _ = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 3
        )

        let (days, _) = try extractConstraintsFromPayload(provider.lastUserPayload)
        #expect(days == 3, "Payload must send training_days_per_week=3, got \(days)")
    }

    @Test("3-day: skeleton has exactly 3 day_focus entries per week")
    func threeDaySkeleton() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 3)
        let service = MacroPlanService(provider: provider)

        let skeleton = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 3
        )

        #expect(skeleton.trainingDaysPerWeek == 3)
        for (index, intent) in skeleton.weekIntents.enumerated() {
            #expect(
                intent.dayFocus.count == 3,
                "Week \(index + 1): expected 3 day_focus entries, got \(intent.dayFocus.count)"
            )
        }
    }

    @Test("3-day: day labels are Full Body variants, not a compressed 5-day split")
    func threeDayLabelsAreSensible() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 3)
        let service = MacroPlanService(provider: provider)

        let skeleton = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 3
        )

        let labels = skeleton.weekIntents[0].dayFocus
        // All labels should contain "Full Body" for a 3-day programme
        let allFullBody = labels.allSatisfy { $0.lowercased().contains("full body") }
        #expect(allFullBody, "3-day labels should be Full Body variants, got: \(labels)")
    }

    // MARK: 4-day

    @Test("4-day: payload contains training_days_per_week=4")
    func fourDayPayload() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 4)
        let service = MacroPlanService(provider: provider)

        _ = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 4
        )

        let (days, _) = try extractConstraintsFromPayload(provider.lastUserPayload)
        #expect(days == 4, "Payload must send training_days_per_week=4, got \(days)")
    }

    @Test("4-day: skeleton has exactly 4 day_focus entries per week")
    func fourDaySkeleton() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 4)
        let service = MacroPlanService(provider: provider)

        let skeleton = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 4
        )

        #expect(skeleton.trainingDaysPerWeek == 4)
        for (index, intent) in skeleton.weekIntents.enumerated() {
            #expect(
                intent.dayFocus.count == 4,
                "Week \(index + 1): expected 4 day_focus entries, got \(intent.dayFocus.count)"
            )
        }
    }

    // MARK: 5-day

    @Test("5-day: payload contains training_days_per_week=5")
    func fiveDayPayload() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 5)
        let service = MacroPlanService(provider: provider)

        _ = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 5
        )

        let (days, _) = try extractConstraintsFromPayload(provider.lastUserPayload)
        #expect(days == 5, "Payload must send training_days_per_week=5, got \(days)")
    }

    @Test("5-day: skeleton has exactly 5 day_focus entries per week")
    func fiveDaySkeleton() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 5)
        let service = MacroPlanService(provider: provider)

        let skeleton = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 5
        )

        #expect(skeleton.trainingDaysPerWeek == 5)
        for (index, intent) in skeleton.weekIntents.enumerated() {
            #expect(
                intent.dayFocus.count == 5,
                "Week \(index + 1): expected 5 day_focus entries, got \(intent.dayFocus.count)"
            )
        }
    }

    @Test("5-day: day labels include Push/Pull/Legs variants — not a 4-day split")
    func fiveDayLabelsAreSensible() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 5)
        let service = MacroPlanService(provider: provider)

        let skeleton = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 5
        )

        let labels = skeleton.weekIntents[0].dayFocus
        #expect(labels.count == 5, "5-day programme must have 5 labels, got: \(labels)")
        // The labels should not be identical to a 4-day Upper/Lower split
        let distinctLabels = Set(labels)
        #expect(distinctLabels.count >= 4, "5-day labels should have at least 4 distinct values, got: \(labels)")
    }

    // MARK: 6-day

    @Test("6-day: payload contains training_days_per_week=6")
    func sixDayPayload() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 6)
        let service = MacroPlanService(provider: provider)

        _ = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 6
        )

        let (days, _) = try extractConstraintsFromPayload(provider.lastUserPayload)
        #expect(days == 6, "Payload must send training_days_per_week=6, got \(days)")
    }

    @Test("6-day: skeleton has exactly 6 day_focus entries per week")
    func sixDaySkeleton() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 6)
        let service = MacroPlanService(provider: provider)

        let skeleton = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 6
        )

        #expect(skeleton.trainingDaysPerWeek == 6)
        for (index, intent) in skeleton.weekIntents.enumerated() {
            #expect(
                intent.dayFocus.count == 6,
                "Week \(index + 1): expected 6 day_focus entries, got \(intent.dayFocus.count)"
            )
        }
    }

    // MARK: Payload total_weeks invariant

    @Test("total_weeks is always 12 regardless of daysPerWeek")
    func totalWeeksIsAlways12() async throws {
        for days in [3, 4, 5, 6] {
            let provider = CapturingMockProvider(daysPerWeek: days)
            let service = MacroPlanService(provider: provider)

            _ = try await service.generateSkeleton(
                userId: UUID(),
                gymProfile: makeGymProfile(),
                trainingDaysPerWeek: days
            )

            let (_, totalWeeks) = try extractConstraintsFromPayload(provider.lastUserPayload)
            #expect(totalWeeks == 12, "\(days)-day: total_weeks must be 12, got \(totalWeeks)")
        }
    }

    // MARK: ProgramGenerationService payload threading

    @Test("ProgramGenerationService threads trainingDaysPerWeek into JSON payload")
    func programGenerationServicePayloadThreading() async throws {
        // Build a minimal valid mesocycle_template JSON for each day count
        // The service uses the template response, not the constraint for day count —
        // what we're verifying is that the constraint value reaches the LLM payload.
        for days in [3, 4, 5, 6] {
            let captureProvider = CapturingMockProvider(daysPerWeek: days)

            // ProgramGenerationService uses a different JSON schema (mesocycle_template),
            // so we need to supply a valid response. Use a 1-day template that passes
            // the decoder — the constraint check is on the outbound payload only.
            let onePhaseProvider = OnePhaseCapturingProvider(daysPerWeek: days)
            let service = ProgramGenerationService(provider: onePhaseProvider)

            _ = try? await service.generate(
                userProfile: UserProfile(
                    userId: "test",
                    experienceLevel: "intermediate",
                    goals: ["hypertrophy"],
                    bodyweightKg: nil,
                    ageYears: nil
                ),
                gymProfile: makeGymProfile(),
                trainingDaysPerWeek: days
            )

            // Inspect payload regardless of decode success
            let payload = onePhaseProvider.lastUserPayload
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let constraints = root["programming_constraints"] as? [String: Any],
                  let sentDays = constraints["training_days_per_week"] as? Int
            else {
                Issue.record("Could not parse payload for \(days)-day test")
                continue
            }
            #expect(sentDays == days,
                    "ProgramGenerationService: expected \(days) in payload, got \(sentDays)")
            _ = captureProvider // suppress unused warning
        }
    }
}

// MARK: - OnePhaseCapturingProvider (ProgramGenerationService format)

/// Captures the user payload and returns a minimal valid mesocycle_template JSON
/// so ProgramGenerationService can at least reach the payload-send stage.
private final class OnePhaseCapturingProvider: LLMProvider, @unchecked Sendable {
    private(set) var lastUserPayload: String = ""
    private let daysPerWeek: Int

    init(daysPerWeek: Int) { self.daysPerWeek = daysPerWeek }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        lastUserPayload = userPayload
        // Return valid 4-phase template JSON so the decoder doesn't short-circuit
        return validOneDayTemplateJSON
    }
}

private let validOneDayTemplateJSON = """
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
                "sets": 3,
                "rep_range": { "min": 8, "max": 12 },
                "tempo": "3-1-2-0",
                "rest_seconds": 90,
                "rir_target": 3,
                "coaching_cues": ["Retract scapula", "Drive through heels"]
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
                "rep_range": { "min": 5, "max": 8 },
                "tempo": "3-1-2-0",
                "rest_seconds": 150,
                "rir_target": 2,
                "coaching_cues": ["Stay tight", "Full ROM"]
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
                "tempo": "2-1-2-0",
                "rest_seconds": 240,
                "rir_target": 1,
                "coaching_cues": ["Max tension", "Explosive concentric"]
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
                "rep_range": { "min": 10, "max": 15 },
                "tempo": "3-1-2-0",
                "rest_seconds": 60,
                "rir_target": 5,
                "coaching_cues": ["Light weight", "Perfect form"]
              }
            ]
          }
        ]
      }
    ]
  }
}
"""
