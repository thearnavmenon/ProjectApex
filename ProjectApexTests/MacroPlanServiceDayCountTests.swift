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

/// Returns a fixed response (for asserting on the committed-split decode + rail).
private final class StaticMockProvider: LLMProvider, @unchecked Sendable {
    private(set) var lastUserPayload: String = ""
    private let response: String
    init(response: String) { self.response = response }
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        lastUserPayload = userPayload
        return response
    }
}

// MARK: - JSON factory

/// Builds a minimal valid block-commit response (#563) with exactly `daysPerWeek`
/// committed slots, each with a couple of owned-equipment exercises + frozen
/// rep-ranges. The day-count threading tests only assert on the captured REQUEST,
/// so the response just needs to decode into the program.split shape.
private func makeMockSkeletonJSON(daysPerWeek: Int) -> String {
    let dayLabels: [Int: [String]] = [
        3: ["Full Body A", "Full Body B", "Full Body C"],
        4: ["Upper Push", "Lower", "Upper Pull", "Full Body"],
        5: ["Push", "Pull", "Legs", "Upper", "Lower"],
        6: ["Push A", "Pull A", "Legs A", "Push B", "Pull B", "Legs B"]
    ]
    let labels = dayLabels[daysPerWeek] ?? Array(repeating: "Training Day", count: daysPerWeek)

    let slots = labels.map { label in
        """
          {
            "day_label": "\(label)",
            "exercises": [
              { "exercise_id": "barbell_bench_press", "name": "Barbell Bench Press", "primary_muscle": "chest", "equipment_required": "barbell", "rep_min": 5, "rep_max": 8 },
              { "exercise_id": "barbell_back_squat", "name": "Barbell Back Squat", "primary_muscle": "quads", "equipment_required": "barbell", "rep_min": 6, "rep_max": 10 }
            ]
          }
        """
    }

    return """
    {
      "program": {
        "periodization_model": "undulating",
        "training_days_per_week": \(daysPerWeek),
        "split": [
    \(slots.joined(separator: ",\n"))
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
}

// MARK: - #192 day_type normalization

@Suite("MacroPlanService — day_type normalization (#192)")
struct MacroPlanServiceDayLabelNormalizationTests {

    @Test("buildPendingMesocycle normalizes free-text focus into snake_case day labels")
    func normalizesDayFocusLabels() {
        let userId = UUID()
        let skeleton = MesocycleSkeleton(
            id: UUID(),
            userId: userId,
            createdAt: Date(timeIntervalSince1970: 0),
            isActive: false,
            trainingDaysPerWeek: 3,
            periodizationModel: "linear_periodization",
            weekIntents: [
                WeekIntent(
                    weekLabel: "Week 1",
                    dayFocus: ["Arms & Shoulders", "Chest/Back", "Legs"],
                    volumeLandmark: 0.5
                )
            ]
        )

        let meso = MacroPlanService.buildPendingMesocycle(from: skeleton, userId: userId)
        let labels = meso.weeks[0].trainingDays.map(\.dayLabel)

        // Before #192 the space-only substitution produced "Arms_&_Shoulders"
        // and left the "/" intact ("Chest/Back").
        #expect(labels[0] == "Arms_Shoulders")
        #expect(labels[1] == "Chest_Back")
        #expect(labels[2] == "Legs")
        for label in labels {
            #expect(
                label.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
                "day label must be snake_case-safe, got \(label)"
            )
        }
    }

    @Test("normalizeDayLabel collapses runs of non-alphanumerics and trims")
    func normalizerEdgeCases() {
        #expect(MacroPlanService.normalizeDayLabel("Arms & Shoulders") == "Arms_Shoulders")
        #expect(MacroPlanService.normalizeDayLabel("Chest/Shoulders/Triceps") == "Chest_Shoulders_Triceps")
        #expect(MacroPlanService.normalizeDayLabel("Upper Push") == "Upper_Push")
        #expect(MacroPlanService.normalizeDayLabel("  Legs  ") == "Legs")
        #expect(MacroPlanService.normalizeDayLabel("Push_A") == "Push_A")
    }
}

// MARK: - Historical day-label continuity (#172)

private func parseMacroPlanPayload(_ json: String) throws -> [String: Any] {
    let data = try #require(json.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// #172: a regen must carry the user's established day-label convention into the
/// macro-plan LLM payload so it reuses those labels instead of inventing a fresh
/// convention that detaches lift history (#141). The threading is asserted at the
/// payload boundary (same altitude as the training_days_per_week tests above).
@Suite("MacroPlanService — historical day-label continuity (#172)")
struct MacroPlanServiceHistoricalLabelsTests {

    @Test("generateSkeleton threads historicalDayLabels into history.recent_day_labels verbatim")
    func threadsHistoricalLabels() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 4)
        let service = MacroPlanService(provider: provider)
        let historical = ["Push_A", "Pull_A", "Push_B", "Pull_B"]

        _ = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 4,
            historicalDayLabels: historical
        )

        let root = try parseMacroPlanPayload(provider.lastUserPayload)
        let history = try #require(root["history"] as? [String: Any],
                                   "payload must include a history block when labels are supplied")
        let labels = try #require(history["recent_day_labels"] as? [String])
        #expect(labels == historical,
                "history.recent_day_labels must carry the user's labels verbatim, got \(labels)")
    }

    @Test("generateSkeleton omits the history block for a user with no training history")
    func omitsHistoryWhenEmpty() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 4)
        let service = MacroPlanService(provider: provider)

        _ = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 4
            // historicalDayLabels defaults to [] — first program, no history.
        )

        let root = try parseMacroPlanPayload(provider.lastUserPayload)
        #expect(root["history"] == nil,
                "history must be omitted (not null) when the user has no established labels")
    }
}

// MARK: - #563 block-commit

@Suite("MacroPlanService — block-commit (#563)")
struct MacroPlanBlockCommitTests {

    @Test("#563: the user's limitations are sent in the block-commit request payload")
    func blockCommit_sendsLimitations() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 4)
        let service = MacroPlanService(provider: provider)
        _ = try await service.generateSkeleton(
            userId: UUID(),
            gymProfile: makeGymProfile(),
            trainingDaysPerWeek: 4,
            limitations: ["left knee pain"]
        )
        #expect(provider.lastUserPayload.contains("left knee pain"),
                "request must carry limitations for hard-exclusion")
        #expect(provider.lastUserPayload.contains("limitations"))
    }

    @Test("#563: committed exercises flow into the mesocycle with frozen per-exercise rep-ranges, repeated across the block")
    func blockCommit_committedExercisesIntoMesocycle() async throws {
        let provider = CapturingMockProvider(daysPerWeek: 4)
        let service = MacroPlanService(provider: provider)
        let userId = UUID()
        let skeleton = try await service.generateSkeleton(
            userId: userId, gymProfile: makeGymProfile(), trainingDaysPerWeek: 4
        )
        #expect(skeleton.committedSlots.count == 4, "one committed slot per distinct day")

        let meso = MacroPlanService.buildPendingMesocycle(from: skeleton, userId: userId)
        let firstDay = meso.weeks[0].trainingDays[0]
        #expect(!firstDay.exercises.isEmpty, "committed exercises fill the day")
        #expect(firstDay.exercises.first?.repRange == RepRange(min: 5, max: 8),
                "rep-range is frozen per exercise from the block-commit")
        // Frozen identity: the same committed exercises repeat across the block's weeks.
        #expect(meso.weeks[0].trainingDays[0].exercises.map(\.exerciseId)
            == meso.weeks[5].trainingDays[0].exercises.map(\.exerciseId))
    }

    @Test("#563: equipment safety rail drops a committed exercise the user can't equip")
    func blockCommit_equipmentRailDropsUnowned() async throws {
        // Commit a barbell lift (owned) + a cable lift (the test gym has no cable).
        let json = """
        { "program": { "periodization_model": "undulating", "training_days_per_week": 1,
          "split": [ { "day_label": "Full_Body", "exercises": [
            { "exercise_id": "barbell_bench_press", "name": "Bench", "primary_muscle": "chest", "equipment_required": "barbell", "rep_min": 5, "rep_max": 8 },
            { "exercise_id": "cable_tricep_pushdown", "name": "Pushdown", "primary_muscle": "triceps", "equipment_required": "cable_machine", "rep_min": 12, "rep_max": 15 }
          ] } ] } }
        """
        let service = MacroPlanService(provider: StaticMockProvider(response: json))
        let skeleton = try await service.generateSkeleton(
            userId: UUID(), gymProfile: makeGymProfile(), trainingDaysPerWeek: 1
        )
        let ids = skeleton.committedSlots.first?.exercises.map(\.exerciseId) ?? []
        #expect(ids.contains("barbell_bench_press"), "owned-equipment exercise kept")
        #expect(!ids.contains("cable_tricep_pushdown"), "unowned cable exercise dropped by the rail")
    }
}
