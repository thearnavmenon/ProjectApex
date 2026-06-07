// SessionPlanServiceTests.swift
// ProjectApexTests
//
// Mirrors `MacroPlanServiceDayLabelNormalizationTests` (#192/#229) and
// `ProgramGenerationServiceDayLabelNormalizationTests` (#243/#245) for the THIRD
// and final day_label mint point: the decoded-payload → TrainingDay mapping in
// `SessionPlanService.buildTrainingDay` (#246). A raw LLM label like
// "Arms & Shoulders" must be normalized so the day stays a stable per-user key
// (ADR-0017). Asserts PARITY with the canonical `MacroPlanService.normalizeDayLabel`
// rather than re-deriving the algorithm, plus one explicit literal example.

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Minimal no-op LLM provider for service construction

private struct NeverCalledProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

@Suite("SessionPlanService — day_label normalization (#192/#243 sibling, #246)")
struct SessionPlanServiceDayLabelNormalizationTests {

    /// Builds a SessionPlanService backed by no-op dependencies. Only the pure
    /// `buildTrainingDay` mapping is exercised — no network or LLM call is made.
    @MainActor
    private func makeService() -> SessionPlanService {
        let fakeURL = URL(string: "https://localhost")!
        let supabase = SupabaseClient(supabaseURL: fakeURL, anonKey: "test")
        let provider: any LLMProvider = NeverCalledProvider()
        let memory = MemoryService(supabase: supabase, embeddingAPIKey: "test")
        return SessionPlanService(
            provider: provider,
            memoryService: memory,
            supabaseClient: supabase
        )
    }

    /// Decodes a session-plan payload exactly as `callAndDecodeSession` would,
    /// so the fixture flows through the real `SessionPlanWrapper`/`SessionPlanPayload`
    /// Codable path with the given raw `day_label`.
    private func decodePayload(rawDayLabel: String) throws -> SessionPlanPayload {
        let json = """
        {
          "session_plan": {
            "day_label": "\(rawDayLabel)",
            "session_notes": null,
            "is_deload": false,
            "is_fatigue_management_day": false,
            "exercises": []
          }
        }
        """
        let data = Data(json.utf8)
        return try JSONDecoder().decode(SessionPlanWrapper.self, from: data).sessionPlan
    }

    private func makeStub(dayLabel: String) -> TrainingDay {
        TrainingDay(
            id: UUID(),
            dayOfWeek: 1,
            dayLabel: dayLabel,
            exercises: [],
            sessionNotes: nil,
            status: .pending
        )
    }

    @Test("buildTrainingDay normalizes a free-text day_label from the decoded payload")
    @MainActor
    func normalizesDayLabelFromPayload() async throws {
        let service = makeService()
        let fatigue = WeekFatigueSignals.compute(from: [], sessionCount: 0)

        // Special-char label straight from the LLM payload.
        let payload = try decodePayload(rawDayLabel: "Arms & Shoulders")
        let stub = makeStub(dayLabel: "Push_A")

        let day = await service.buildTrainingDay(from: payload, stub: stub, fatigue: fatigue)

        // Parity with the canonical normalizer — do not hardcode the algorithm here.
        #expect(day.dayLabel == MacroPlanService.normalizeDayLabel("Arms & Shoulders"))
        // Plus one explicit literal example (before the fix this was "Arms & Shoulders").
        #expect(day.dayLabel == "Arms_Shoulders")
        // The minted label must be snake_case-safe.
        #expect(
            day.dayLabel.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
            "day label must be snake_case-safe, got \(day.dayLabel)"
        )
    }

    @Test("buildTrainingDay normalizes slash-delimited day_label with parity")
    @MainActor
    func normalizesSlashDelimitedDayLabel() async throws {
        let service = makeService()
        let fatigue = WeekFatigueSignals.compute(from: [], sessionCount: 0)

        let payload = try decodePayload(rawDayLabel: "Chest/Back")
        let stub = makeStub(dayLabel: "Pull_A")

        let day = await service.buildTrainingDay(from: payload, stub: stub, fatigue: fatigue)

        #expect(day.dayLabel == MacroPlanService.normalizeDayLabel("Chest/Back"))
        #expect(day.dayLabel == "Chest_Back")
    }
}
