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

// MARK: - #527 S6 — hard equipment enforcement (safety-first)

@Suite("SessionPlanService — equipment enforcement (#527 S6)")
struct SessionPlanServiceEquipmentEnforcementTests {

    /// Decodes a full session payload from a list of (id, name, equipmentKey)
    /// tuples so each exercise flows through the real Codable path
    /// (SessionPlanExercise has no memberwise init).
    private func decodeExercises(
        _ specs: [(id: String, name: String, equipment: String)]
    ) throws -> [SessionPlanExercise] {
        let exerciseJSON = specs.map { spec in
            """
            {
              "exercise_id": "\(spec.id)",
              "name": "\(spec.name)",
              "primary_muscle": "chest",
              "synergists": [],
              "equipment_required": "\(spec.equipment)",
              "sets": 3,
              "rep_range": { "min": 8, "max": 12 },
              "tempo": "3-1-1-0",
              "rest_seconds": 120,
              "rir_target": 2,
              "coaching_cues": []
            }
            """
        }.joined(separator: ",\n")

        let json = """
        {
          "session_plan": {
            "day_label": "Test_Day",
            "session_notes": null,
            "is_deload": false,
            "is_fatigue_management_day": false,
            "exercises": [\(exerciseJSON)]
          }
        }
        """
        return try JSONDecoder()
            .decode(SessionPlanWrapper.self, from: Data(json.utf8))
            .sessionPlan.exercises
    }

    @Test("nil owned set skips enforcement entirely (back-compat)")
    func nilOwnedSkipsEnforcement() throws {
        let exercises = try decodeExercises([
            ("barbell_bench_press", "Barbell Bench Press", "barbell"),
            ("cable_row", "Cable Row", "cable_machine_single"),
        ])
        let result = SessionPlanService.enforceEquipment(exercises, ownedEquipmentKeys: nil)
        #expect(result.count == 2, "nil owned set must not drop anything")
    }

    @Test("Drops off-equipment exercise but keeps owned + bodyweight ones")
    func dropsOffEquipmentKeepsOwnedAndBodyweight() throws {
        // Owned: barbell only.
        let owned: Set<String> = ["barbell"]
        let exercises = try decodeExercises([
            ("barbell_bench_press", "Barbell Bench Press", "barbell"),               // owned → keep
            ("cable_row", "Cable Row", "cable_machine_single"),                       // NOT owned → drop
            ("push_ups", "Push-Ups", "flat_bench"),                                   // bodyweight (library) → keep
        ])
        let result = SessionPlanService.enforceEquipment(exercises, ownedEquipmentKeys: owned)
        let ids = Set(result.map(\.exerciseId))
        #expect(ids.contains("barbell_bench_press"))
        #expect(ids.contains("push_ups"), "Bodyweight exercise must survive even though its nominal equipment is unowned")
        #expect(!ids.contains("cable_row"), "Off-equipment exercise must be dropped")
        #expect(result.count == 2)
    }

    @Test("Custom .unknown machine matching an owned key is allowed")
    func unknownMachineMatchingOwnedKeyAllowed() throws {
        let owned: Set<String> = ["unknown:Belt squat machine"]
        let exercises = try decodeExercises([
            ("belt_squat", "Belt Squat", "unknown:Belt squat machine"),  // owned custom → keep
            ("cable_row", "Cable Row", "cable_machine_single"),          // NOT owned → drop
        ])
        let result = SessionPlanService.enforceEquipment(exercises, ownedEquipmentKeys: owned)
        let ids = Set(result.map(\.exerciseId))
        #expect(ids.contains("belt_squat"), "A custom .unknown machine whose key is owned must pass")
        #expect(!ids.contains("cable_row"))
    }

    @Test("SAFETY RAIL: never empties a populated session")
    func neverEmptiesSession() throws {
        // Gym owns NOTHING that matches, and none of the exercises are bodyweight.
        let owned: Set<String> = ["dumbbell_set"]
        let exercises = try decodeExercises([
            ("barbell_bench_press", "Barbell Bench Press", "barbell"),
            ("cable_row", "Cable Row", "cable_machine_single"),
        ])
        let result = SessionPlanService.enforceEquipment(exercises, ownedEquipmentKeys: owned)
        // All would be dropped → the rail keeps the original list rather than ship empty.
        #expect(result.count == 2, "Enforcement must NEVER return an empty session")
        #expect(Set(result.map(\.exerciseId)) == Set(["barbell_bench_press", "cable_row"]))
    }

    @Test("Empty input stays empty (no rail trigger when nothing to keep)")
    func emptyInputStaysEmpty() {
        let result = SessionPlanService.enforceEquipment([], ownedEquipmentKeys: ["barbell"])
        #expect(result.isEmpty)
    }

    @Test("buildTrainingDay end-to-end drops off-equipment, keeps the rest, non-empty")
    @MainActor
    func buildTrainingDayEnforcesEquipment() async throws {
        let fakeURL = URL(string: "https://localhost")!
        let supabase = SupabaseClient(supabaseURL: fakeURL, anonKey: "test")
        let service = SessionPlanService(
            provider: NeverCalledProvider(),
            memoryService: MemoryService(supabase: supabase, embeddingAPIKey: "test"),
            supabaseClient: supabase
        )
        let exercises = try decodeExercises([
            ("barbell_bench_press", "Barbell Bench Press", "barbell"),         // keep
            ("cable_row", "Cable Row", "cable_machine_single"),                // drop (unowned)
            ("push_ups", "Push-Ups", "flat_bench"),                            // keep (bodyweight)
        ])
        let payload = SessionPlanPayload(
            dayLabel: "Test_Day",
            sessionNotes: nil,
            isDeload: false,
            isFatigueManagementDay: false,
            exercises: exercises
        )
        let stub = TrainingDay(
            id: UUID(), dayOfWeek: 1, dayLabel: "Push_A",
            exercises: [], sessionNotes: nil, status: .pending
        )
        let fatigue = WeekFatigueSignals.compute(from: [], sessionCount: 0)

        let day = await service.buildTrainingDay(
            from: payload,
            stub: stub,
            fatigue: fatigue,
            ownedEquipmentKeys: ["barbell"]
        )
        let ids = Set(day.exercises.map(\.exerciseId))
        #expect(ids == Set(["barbell_bench_press", "push_ups"]))
        #expect(!day.exercises.isEmpty)
    }
}

// MARK: - #564: SessionAutoregulator (deterministic instantiation)

@Suite("SessionAutoregulator — deterministic instantiation (#564)")
struct SessionAutoregulatorTests {

    @Test("no deltas → frozen accumulation baseline (4 sets, RIR 3)")
    func noDeltas() {
        let p = SessionAutoregulator.prescription(
            phase: .accumulation, trend: .progressing, volumeDeficit: 0, requiresReturnOverride: false)
        #expect(p.sets == 4)
        #expect(p.rir == 3)
    }

    @Test("deload phase → ~50% volume (2 sets) + high RIR")
    func deload() {
        let p = SessionAutoregulator.prescription(
            phase: .deload, trend: .progressing, volumeDeficit: 0, requiresReturnOverride: false)
        #expect(p.sets == 2)  // 4 → 2 = -50%
        #expect(p.rir == 4)
    }

    @Test("declining trend (fatigue/regression) → back off one set + RIR +1")
    func decliningBacksOff() {
        let base = SessionAutoregulator.prescription(
            phase: .accumulation, trend: .progressing, volumeDeficit: 0, requiresReturnOverride: false)
        let p = SessionAutoregulator.prescription(
            phase: .accumulation, trend: .declining, volumeDeficit: 0, requiresReturnOverride: false)
        #expect(p.sets == base.sets - 1)
        #expect(p.rir == base.rir + 1)
    }

    @Test("volume-deficit → +1 working set (top-up)")
    func volumeDeficitTopUp() {
        let base = SessionAutoregulator.prescription(
            phase: .accumulation, trend: .progressing, volumeDeficit: 0, requiresReturnOverride: false)
        let p = SessionAutoregulator.prescription(
            phase: .accumulation, trend: .progressing, volumeDeficit: 6, requiresReturnOverride: false)
        #expect(p.sets == base.sets + 1)
    }

    @Test("return-to-training → reduced volume + RIR +1")
    func returnReduced() {
        let base = SessionAutoregulator.prescription(
            phase: .accumulation, trend: .progressing, volumeDeficit: 0, requiresReturnOverride: false)
        let p = SessionAutoregulator.prescription(
            phase: .accumulation, trend: .progressing, volumeDeficit: 0, requiresReturnOverride: true)
        #expect(p.sets == base.sets - 1)
        #expect(p.rir == base.rir + 1)
    }

    @Test("deltas clamp: sets ≥ 1, RIR ≤ 5")
    func clamps() {
        // deload (2,4) + return (-1,+1) + declining (-1,+1) → pre-clamp (0,6) → (1,5).
        let p = SessionAutoregulator.prescription(
            phase: .deload, trend: .declining, volumeDeficit: 0, requiresReturnOverride: true)
        #expect(p.sets >= 1)
        #expect(p.rir <= 5)
    }

    @Test("instantiate keeps frozen identity + rep-range; no digest → accumulation baseline; status .generated")
    func instantiatePreservesFrozenSlot() {
        let committed = PlannedExercise(
            id: UUID(), exerciseId: "barbell_bench_press", name: "Bench",
            primaryMuscle: "chest", synergists: [], equipmentRequired: .barbell,
            sets: 99, repRange: RepRange(min: 5, max: 8), tempo: "", restSeconds: 120,
            rirTarget: 99, coachingCues: []
        )
        let day = TrainingDay(
            id: UUID(), dayOfWeek: 1, dayLabel: "Push_A",
            exercises: [committed], sessionNotes: nil, status: .pending)

        let out = SessionAutoregulator.instantiate(day: day, digest: nil, requiresReturnOverride: false)
        let ex = out.exercises[0]
        #expect(ex.exerciseId == "barbell_bench_press")   // frozen identity
        #expect(ex.repRange == RepRange(min: 5, max: 8))   // frozen rep-range
        #expect(ex.sets == 4)                              // deterministic accumulation baseline
        #expect(ex.rirTarget == 3)
        #expect(out.status == .generated)
    }
}
