// SkipFeatureTests.swift
// ProjectApexTests
//
// Tests for Phase 1: Skip Feature + Training-Time Model Refactor
//
// Coverage:
//   1. TrainingDayStatus.skipped — new case encodes as "skipped", decodes correctly
//   2. TrainingDay.skippedAt — Codable round-trip preserves skippedAt timestamp
//   3. TemporalContext — Codable round-trip: all three fields survive JSON encode/decode
//   4. currentWeekIndex — training-time logic: skips terminal days, not calendar-driven
//   5. nextIncompleteDay — skips both .completed and .skipped days
//   6. markDaySkipped — sets .skipped + non-nil skippedAt, persists via UserDefaults fast path
//   7. Golden prompt — SystemPrompt_SessionPlan.txt contains all temporal_context field names
//   8. TemporalContext round-trip — remaining temporal fields; no global calendar phase/week (#561)

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Minimal mock LLM provider for service construction

private struct AlwaysThrowingProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - ProgramViewModel factory

/// Creates a ProgramViewModel backed by no-op services.
/// Only pure computation methods (currentWeekIndex, nextIncompleteDay, markDaySkipped)
/// are exercised — no network calls are made.
@MainActor
private func makeViewModel() -> ProgramViewModel {
    let fakeURL = URL(string: "https://localhost")!
    let supabase = SupabaseClient(supabaseURL: fakeURL, anonKey: "test")
    let provider: any LLMProvider = AlwaysThrowingProvider()
    let memory = MemoryService(supabase: supabase, embeddingAPIKey: "test")
    return ProgramViewModel(
        supabaseClient: supabase,
        macroPlanService: MacroPlanService(provider: provider),
        sessionPlanService: SessionPlanService(
            provider: provider,
            memoryService: memory,
            supabaseClient: supabase
        ),
        userId: UUID(),
        resolveOwner: { UUID() }
    )
}

// MARK: - Mesocycle fixture helpers

/// Builds a minimal 2-week mesocycle where each week has 3 training days.
private func makeMesocycle(
    week1Statuses: [TrainingDayStatus] = [.generated, .generated, .generated],
    week2Statuses: [TrainingDayStatus] = [.generated, .generated, .generated]
) -> Mesocycle {
    func makeDays(_ statuses: [TrainingDayStatus]) -> [TrainingDay] {
        statuses.enumerated().map { idx, status in
            TrainingDay(
                id: UUID(),
                dayOfWeek: idx + 1,
                dayLabel: "Day \(idx + 1)",
                exercises: [],
                sessionNotes: nil,
                status: status
            )
        }
    }
    let week1 = TrainingWeek(
        id: UUID(),
        weekNumber: 1,
        phase: .accumulation,
        trainingDays: makeDays(week1Statuses)
    )
    let week2 = TrainingWeek(
        id: UUID(),
        weekNumber: 2,
        phase: .accumulation,
        trainingDays: makeDays(week2Statuses)
    )
    return Mesocycle(
        id: UUID(),
        userId: UUID(),
        createdAt: Date(),
        isActive: true,
        weeks: [week1, week2],
        totalWeeks: 2,
        periodizationModel: "linear_periodization"
    )
}

// MARK: - Test Suite

@Suite("Skip Feature — Phase 1")
struct SkipFeatureTests {

    // MARK: 1. TrainingDayStatus.skipped encodes correctly

    @Test("TrainingDayStatus.skipped encodes to \"skipped\"")
    func skippedStatusEncodesCorrectly() throws {
        let data = try JSONEncoder().encode(TrainingDayStatus.skipped)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "\"skipped\"")
    }

    @Test("TrainingDayStatus decodes \"skipped\" string")
    func skippedStatusDecodesCorrectly() throws {
        let data = Data("\"skipped\"".utf8)
        let decoded = try JSONDecoder().decode(TrainingDayStatus.self, from: data)
        #expect(decoded == .skipped)
    }

    // MARK: 2. TrainingDay.skippedAt Codable round-trip

    @Test("TrainingDay.skippedAt survives JSON encode/decode round-trip")
    func trainingDaySkippedAtRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var day = TrainingDay(
            id: UUID(),
            dayOfWeek: 1,
            dayLabel: "Leg Day",
            exercises: [],
            sessionNotes: nil,
            status: .skipped
        )
        day.skippedAt = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(day)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrainingDay.self, from: data)

        #expect(decoded.status == .skipped)
        #expect(decoded.skippedAt != nil)
        let diff = abs((decoded.skippedAt ?? .distantPast).timeIntervalSince(now))
        #expect(diff < 1.0, "skippedAt timestamp should survive ISO8601 round-trip within 1 second")
    }

    @Test("TrainingDay.skippedAt is nil when not set")
    func trainingDaySkippedAtNilDefault() throws {
        let day = TrainingDay(
            id: UUID(),
            dayOfWeek: 2,
            dayLabel: "Pull Day",
            exercises: [],
            sessionNotes: nil,
            status: .generated
        )
        #expect(day.skippedAt == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(day)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrainingDay.self, from: data)
        #expect(decoded.skippedAt == nil)
    }

    // MARK: 3. TemporalContext Codable round-trip

    @Test("TemporalContext survives JSON encode/decode round-trip")
    func temporalContextRoundTrip() throws {
        let ctx = TemporalContext(
            daysSinceLastSession: 5,
            daysSinceLastTrainedByPattern: ["horizontal_push": 5, "squat": 12],
            skippedSessionCountLast30Days: 2
        )
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(TemporalContext.self, from: data)

        #expect(decoded.daysSinceLastSession == 5)
        #expect(decoded.daysSinceLastTrainedByPattern["horizontal_push"] == 5)
        #expect(decoded.daysSinceLastTrainedByPattern["squat"] == 12)
        #expect(decoded.skippedSessionCountLast30Days == 2)
    }

    @Test("TemporalContext encodes nil daysSinceLastSession as JSON null")
    func temporalContextNullSessionField() throws {
        let ctx = TemporalContext(
            daysSinceLastSession: nil,
            daysSinceLastTrainedByPattern: [:],
            skippedSessionCountLast30Days: 0
        )
        let data = try JSONEncoder().encode(ctx)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"days_since_last_session\":null"))
    }

    @Test("TemporalContext uses snake_case CodingKeys")
    func temporalContextSnakeCaseKeys() throws {
        let ctx = TemporalContext(
            daysSinceLastSession: 3,
            daysSinceLastTrainedByPattern: ["hinge": 7],
            skippedSessionCountLast30Days: 1
        )
        let data = try JSONEncoder().encode(ctx)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"days_since_last_session\""))
        #expect(json.contains("\"days_since_last_trained_by_pattern\""))
        #expect(json.contains("\"skipped_session_count_last_30_days\""))
    }

    // MARK: 4. currentWeekIndex — training-time (not calendar)

    @MainActor
    @Test("currentWeekIndex returns 0 when week 0 has non-terminal days")
    func currentWeekIndexAllPending() {
        let vm = makeViewModel()
        let meso = makeMesocycle()
        #expect(vm.currentWeekIndex(in: meso) == 0)
    }

    @MainActor
    @Test("currentWeekIndex advances to 1 when all week 0 days are completed")
    func currentWeekIndexAdvancesOnCompletion() {
        let vm = makeViewModel()
        let meso = makeMesocycle(
            week1Statuses: [.completed, .completed, .completed],
            week2Statuses: [.generated, .generated, .generated]
        )
        #expect(vm.currentWeekIndex(in: meso) == 1)
    }

    @MainActor
    @Test("currentWeekIndex counts .skipped days as terminal — advances week")
    func currentWeekIndexTreatsSkippedAsTerminal() {
        let vm = makeViewModel()
        let meso = makeMesocycle(
            week1Statuses: [.completed, .skipped, .skipped],
            week2Statuses: [.generated, .generated, .generated]
        )
        #expect(vm.currentWeekIndex(in: meso) == 1)
    }

    @MainActor
    @Test("currentWeekIndex clamps to last week when all days are terminal")
    func currentWeekIndexAllTerminal() {
        let vm = makeViewModel()
        let meso = makeMesocycle(
            week1Statuses: [.completed, .completed, .completed],
            week2Statuses: [.completed, .skipped, .completed]
        )
        #expect(vm.currentWeekIndex(in: meso) == 1)
    }

    // MARK: 5. nextIncompleteDay — skips terminal days

    @MainActor
    @Test("nextIncompleteDay returns first non-terminal day")
    func nextIncompleteDayReturnsPending() {
        let vm = makeViewModel()
        let meso = makeMesocycle(
            week1Statuses: [.completed, .generated, .generated],
            week2Statuses: [.generated, .generated, .generated]
        )
        let result = vm.nextIncompleteDay(in: meso)
        #expect(result != nil)
        #expect(result?.day.dayLabel == "Day 2")
    }

    @MainActor
    @Test("nextIncompleteDay skips .skipped days")
    func nextIncompleteDaySkipsSkipped() {
        let vm = makeViewModel()
        let meso = makeMesocycle(
            week1Statuses: [.skipped, .skipped, .generated],
            week2Statuses: [.generated, .generated, .generated]
        )
        let result = vm.nextIncompleteDay(in: meso)
        #expect(result != nil)
        #expect(result?.day.dayLabel == "Day 3")
    }

    @MainActor
    @Test("nextIncompleteDay returns nil when all days are terminal")
    func nextIncompleteDayAllTerminal() {
        let vm = makeViewModel()
        let meso = makeMesocycle(
            week1Statuses: [.completed, .skipped, .completed],
            week2Statuses: [.skipped, .completed, .skipped]
        )
        let result = vm.nextIncompleteDay(in: meso)
        #expect(result == nil)
    }

    // MARK: 6. markDaySkipped — direct injection (currentMesocycle is internal)
    // currentMesocycle has no private(set) restriction, so tests inject directly
    // without going through the UserDefaults fast-path in loadProgram().

    @MainActor
    @Test("markDaySkipped sets day.status to .skipped and records skippedAt")
    func markDaySkippedSetsStatusAndTimestamp() {
        let meso = makeMesocycle()
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        let targetDay = meso.weeks[0].trainingDays[1]
        let targetWeekId = meso.weeks[0].id
        let beforeCall = Date()

        vm.markDaySkipped(dayId: targetDay.id, weekId: targetWeekId)

        guard case .loaded(let updated) = vm.viewState else {
            Issue.record("Expected .loaded state after markDaySkipped")
            return
        }
        let updatedDay = updated.weeks[0].trainingDays[1]
        #expect(updatedDay.status == .skipped)
        #expect(updatedDay.skippedAt != nil)
        let skippedAt = updatedDay.skippedAt ?? .distantPast
        #expect(skippedAt >= beforeCall)
    }

    @MainActor
    @Test("markDaySkipped persists .skipped status to UserDefaults")
    func markDaySkippedPersistsToUserDefaults() {
        let meso = makeMesocycle()
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        let targetDay = meso.weeks[0].trainingDays[0]
        vm.markDaySkipped(dayId: targetDay.id, weekId: meso.weeks[0].id)

        // Verify the skip was written to UserDefaults by loading a fresh copy.
        guard let persisted = Mesocycle.loadFromUserDefaults() else {
            Issue.record("Mesocycle should be in UserDefaults after markDaySkipped")
            return
        }
        let day = persisted.weeks[0].trainingDays[0]
        #expect(day.status == .skipped)
    }

    @MainActor
    @Test("markDaySkipped advances nextIncompleteDay past the skipped day")
    func markDaySkippedAdvancesNextDay() {
        let meso = makeMesocycle()
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        let firstDay = meso.weeks[0].trainingDays[0]
        vm.markDaySkipped(dayId: firstDay.id, weekId: meso.weeks[0].id)

        guard case .loaded(let updated) = vm.viewState else {
            Issue.record("Expected .loaded state after skip")
            return
        }
        let next = vm.nextIncompleteDay(in: updated)
        #expect(next?.day.dayLabel == "Day 2")
    }

    // MARK: 7. Golden prompt — SystemPrompt_SessionPlan.txt

    @Test("SystemPrompt_SessionPlan.txt contains all temporal_context field names")
    func goldenPromptContainsTemporalContextFields() throws {
        // Derive path relative to this source file.
        let thisFile = URL(fileURLWithPath: #file)
        let promptURL = thisFile
            .deletingLastPathComponent()   // ProjectApexTests/
            .deletingLastPathComponent()   // workspace root
            .appendingPathComponent("ProjectApex")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Prompts")
            .appendingPathComponent("SystemPrompt_SessionPlan.txt")

        let content = try String(contentsOf: promptURL, encoding: .utf8)

        #expect(content.contains("temporal_context"),                   "Missing temporal_context section")
        #expect(content.contains("days_since_last_session"),            "Missing days_since_last_session field")
        #expect(content.contains("days_since_last_trained_by_pattern"), "Missing days_since_last_trained_by_pattern field")
        #expect(content.contains("skipped_session_count_last_30_days"), "Missing skipped_session_count_last_30_days field")
        #expect(content.contains("TEMPORAL CONTEXT"),                   "Missing TEMPORAL CONTEXT section header")
        // Phrase-level: confirm specific guidance text survives prompt edits
        #expect(content.contains("1-week"),          "Missing 1-week gap guidance (treat as deload/neutral)")
        #expect(content.contains("reintroduction"),  "Missing reintroduction guidance for 3+ week movement-pattern gaps")
        // Phase 2 / B3: per-pattern phase state directives — sourced from digest, not temporal_context.
        #expect(content.contains("PER-PATTERN PHASE STATE"), "Missing PER-PATTERN PHASE STATE section header (B3 / #88)")
        #expect(content.contains("per_pattern_summary"),      "Missing per_pattern_summary digest path reference")
        #expect(content.contains("current_phase"),            "Missing current_phase key in pattern phase schema")
    }

    // MARK: 8. TemporalContext round-trip (#561: global calendar phase/week removed)

    @Test("TemporalContext survives JSON round-trip; carries no global calendar phase/week (#561)")
    func temporalContextRoundTrip_noGlobalCalendarFields() throws {
        let ctx = TemporalContext(
            daysSinceLastSession: 4,
            daysSinceLastTrainedByPattern: ["horizontal_push": 4, "squat": 7],
            skippedSessionCountLast30Days: 0,
            requiresReturnPhaseOverride: true
        )
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(TemporalContext.self, from: data)

        #expect(decoded.daysSinceLastSession == 4)
        #expect(decoded.daysSinceLastTrainedByPattern["horizontal_push"] == 4)
        #expect(decoded.daysSinceLastTrainedByPattern["squat"] == 7)
        #expect(decoded.requiresReturnPhaseOverride == true)
        // #561: the killed global calendar phase/week keys must be gone from the wire.
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("global_programme_phase"))
        #expect(!json.contains("global_programme_week"))
    }

    // MARK: 9. resetDayToPending — regenerate-session eligibility (#318 U4)

    /// Minimal planned exercise so tests can assert exercises are cleared.
    private func makeExercise() -> PlannedExercise {
        PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: [],
            equipmentRequired: EquipmentType(typeKey: "barbell"),
            sets: 3,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 120,
            rirTarget: 2,
            coachingCues: []
        )
    }

    @MainActor
    @Test("resetDayToPending resets a .generated day to .pending, clears exercises, preserves the day id")
    func resetDayToPendingResetsGeneratedDay() {
        var meso = makeMesocycle()
        meso.weeks[0].trainingDays[0].exercises = [makeExercise()]
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        let targetDayId = meso.weeks[0].trainingDays[0].id
        vm.resetDayToPending(dayId: targetDayId, weekId: meso.weeks[0].id)

        let updated = vm.currentMesocycle?.weeks[0].trainingDays[0]
        #expect(updated?.status == .pending)
        #expect(updated?.exercises.isEmpty == true)
        #expect(updated?.id == targetDayId, "day id must be PRESERVED so sentinel matching still holds")

        // Persisted via the same UserDefaults path other mutations use.
        let persisted = Mesocycle.loadFromUserDefaults()?.weeks[0].trainingDays[0]
        #expect(persisted?.status == .pending)
        #expect(persisted?.exercises.isEmpty == true)
    }

    @MainActor
    @Test("resetDayToPending refuses a .completed day (no-op)")
    func resetDayToPendingRefusesCompletedDay() {
        var meso = makeMesocycle(week1Statuses: [.completed, .generated, .generated])
        meso.weeks[0].trainingDays[0].exercises = [makeExercise()]
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        vm.resetDayToPending(dayId: meso.weeks[0].trainingDays[0].id, weekId: meso.weeks[0].id)

        let day = vm.currentMesocycle?.weeks[0].trainingDays[0]
        #expect(day?.status == .completed, "completed days are historical records — must refuse")
        #expect(day?.exercises.count == 1, "exercises must be untouched on refusal")
    }

    @MainActor
    @Test("resetDayToPending refuses a .paused day (no-op)")
    func resetDayToPendingRefusesPausedDay() {
        var meso = makeMesocycle(week1Statuses: [.paused, .generated, .generated])
        meso.weeks[0].trainingDays[0].exercises = [makeExercise()]
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        vm.resetDayToPending(dayId: meso.weeks[0].trainingDays[0].id, weekId: meso.weeks[0].id)

        let day = vm.currentMesocycle?.weeks[0].trainingDays[0]
        #expect(day?.status == .paused, "paused days have a live session underneath — must refuse")
        #expect(day?.exercises.count == 1, "exercises must be untouched on refusal")
    }

    @MainActor
    @Test("resetDayToPending refuses a .generated day whose session sentinel matches (no-op)")
    func resetDayToPendingRefusesSentinelMatchingDay() {
        var meso = makeMesocycle()
        meso.weeks[0].trainingDays[0].exercises = [makeExercise()]
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer {
            Mesocycle.clearUserDefaults()
            PausedSessionState.clear()
        }

        let targetDay = meso.weeks[0].trainingDays[0]
        // Sentinel written at session start and updated every set — a match
        // means a live/paused session with logged work exists for this day.
        PausedSessionState(
            sessionId: UUID(),
            trainingDayId: targetDay.id,
            weekId: meso.weeks[0].id,
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: targetDay.dayLabel,
            programId: meso.id,
            userId: meso.userId,
            pausedAt: Date()
        ).save()

        vm.resetDayToPending(dayId: targetDay.id, weekId: meso.weeks[0].id)

        let day = vm.currentMesocycle?.weeks[0].trainingDays[0]
        #expect(day?.status == .generated, "a sentinel-matching day must refuse the reset")
        #expect(day?.exercises.count == 1, "exercises must be untouched on refusal")
    }
}
