// SessionPlanService.swift
// ProjectApex — Services
//
// FB-008: Part 2 of the dynamic programme architecture.
//
// SCOPE (post-ADR-0030, #581): the from-scratch LLM session generator
// (`generateSession` and its RAG/lift-history/trend helpers) was removed once the
// deterministic engine took over session instantiation (`SessionAutoregulator`,
// #564). What remains here is the payload→TrainingDay mapping seam:
//   • `buildTrainingDay(...)` — day_label normalization (ADR-0017) + TrainingDay assembly.
//   • `enforceEquipment(...)` — the SAFE drop-the-violator equipment rule.
// The `SessionPlanPayload`/`SessionPlanWrapper` DTOs + `SystemPrompt_SessionPlan.txt`
// are retained: they back the digest→prompt contract tests and the mapping seam.
//
// ISOLATION NOTE: All DTO types are `nonisolated` (target: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

import Foundation

// MARK: - TemporalContext

/// Gap-awareness context for the LLM, describing how long it has been since the user
/// last trained overall and per movement pattern. Per-pattern phase state lives on
/// `TraineeModelDigest.perPatternSummary` (B3 / #88), not on this struct.
///
/// Assembly: computed in `ProgramViewModel.generateDaySession` from:
///   • recent session metadata (Supabase query for last 7 days, any type)
///   • deep lift history set logs (Supabase query for last 10 sessions of this day type)
///   • local mesocycle skipped day state (from UserDefaults cache)
nonisolated struct TemporalContext: Codable, Sendable {
    /// Days since the most recently completed session of any type.
    /// Nil when no sessions have ever been completed (first-ever session).
    let daysSinceLastSession: Int?
    /// Days since the most recent set was logged for each movement pattern.
    /// Keys are movement_pattern strings from ExerciseLibrary (e.g. "horizontal_push", "squat").
    /// A pattern absent from this dictionary has never been trained.
    let daysSinceLastTrainedByPattern: [String: Int]
    /// Number of sessions explicitly skipped by the user in the last 30 days.
    let skippedSessionCountLast30Days: Int

    /// True when daysSinceLastSession >= 28 — signals a significant return-to-training gap.
    /// When true the LLM ignores the pattern phase label and generates a reduced-volume
    /// accumulation baseline session instead.
    let requiresReturnPhaseOverride: Bool

    enum CodingKeys: String, CodingKey {
        case daysSinceLastSession             = "days_since_last_session"
        case daysSinceLastTrainedByPattern    = "days_since_last_trained_by_pattern"
        case skippedSessionCountLast30Days    = "skipped_session_count_last_30_days"
        case requiresReturnPhaseOverride      = "requires_return_phase_override"
    }

    /// Custom encoder: `daysSinceLastSession` encodes as JSON `null` (not absent)
    /// when nil so the LLM can distinguish "first-ever session" from "field
    /// missing from payload". (#561: the global calendar phase/week fields are
    /// gone — the per-pattern engine is the sole clock.)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(daysSinceLastSession, forKey: .daysSinceLastSession)
        try container.encode(daysSinceLastTrainedByPattern, forKey: .daysSinceLastTrainedByPattern)
        try container.encode(skippedSessionCountLast30Days, forKey: .skippedSessionCountLast30Days)
        try container.encode(requiresReturnPhaseOverride, forKey: .requiresReturnPhaseOverride)
    }

    /// Custom decoder: uses decodeIfPresent for optional fields so pre-Phase-2
    /// serialised payloads (missing the keys) still decode without error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daysSinceLastSession          = try c.decodeIfPresent(Int.self, forKey: .daysSinceLastSession)
        daysSinceLastTrainedByPattern = try c.decode([String: Int].self, forKey: .daysSinceLastTrainedByPattern)
        skippedSessionCountLast30Days = try c.decode(Int.self, forKey: .skippedSessionCountLast30Days)
        requiresReturnPhaseOverride   = try c.decodeIfPresent(Bool.self, forKey: .requiresReturnPhaseOverride) ?? false
    }

    /// Memberwise init (required because we define init(from:) above).
    init(
        daysSinceLastSession: Int?,
        daysSinceLastTrainedByPattern: [String: Int],
        skippedSessionCountLast30Days: Int,
        requiresReturnPhaseOverride: Bool = false
    ) {
        self.daysSinceLastSession           = daysSinceLastSession
        self.daysSinceLastTrainedByPattern  = daysSinceLastTrainedByPattern
        self.skippedSessionCountLast30Days  = skippedSessionCountLast30Days
        self.requiresReturnPhaseOverride    = requiresReturnPhaseOverride
    }
}

// MARK: - SessionPlanResponse DTOs

nonisolated struct SessionPlanExercise: Codable, Sendable {
    let exerciseId: String
    let name: String
    let primaryMuscle: String
    let synergists: [String]
    let equipmentRequired: EquipmentType
    let sets: Int
    let repRange: RepRange
    let tempo: String
    let restSeconds: Int
    let rirTarget: Int
    let coachingCues: [String]

    enum CodingKeys: String, CodingKey {
        case exerciseId        = "exercise_id"
        case name
        case primaryMuscle     = "primary_muscle"
        case synergists
        case equipmentRequired = "equipment_required"
        case sets
        case repRange          = "rep_range"
        case tempo
        case restSeconds       = "rest_seconds"
        case rirTarget         = "rir_target"
        case coachingCues      = "coaching_cues"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseId    = try c.decode(String.self, forKey: .exerciseId)
        name          = try c.decode(String.self, forKey: .name)
        primaryMuscle = try c.decode(String.self, forKey: .primaryMuscle)
        synergists    = try c.decode([String].self, forKey: .synergists)
        sets          = try c.decode(Int.self, forKey: .sets)
        repRange      = try c.decode(RepRange.self, forKey: .repRange)
        tempo         = try c.decode(String.self, forKey: .tempo)
        restSeconds   = try c.decode(Int.self, forKey: .restSeconds)
        rirTarget     = try c.decode(Int.self, forKey: .rirTarget)
        coachingCues  = try c.decode([String].self, forKey: .coachingCues)

        if let typeKey = try? c.decode(String.self, forKey: .equipmentRequired) {
            equipmentRequired = EquipmentType(typeKey: typeKey)
        } else {
            equipmentRequired = try c.decode(EquipmentType.self, forKey: .equipmentRequired)
        }
    }
}

nonisolated struct SessionPlanWrapper: Codable, Sendable {
    let sessionPlan: SessionPlanPayload

    enum CodingKeys: String, CodingKey {
        case sessionPlan = "session_plan"
    }
}

nonisolated struct SessionPlanPayload: Codable, Sendable {
    let dayLabel: String
    let sessionNotes: String?
    let isDeload: Bool
    let isFatigueManagementDay: Bool
    let exercises: [SessionPlanExercise]

    enum CodingKeys: String, CodingKey {
        case dayLabel              = "day_label"
        case sessionNotes          = "session_notes"
        case isDeload              = "is_deload"
        case isFatigueManagementDay = "is_fatigue_management_day"
        case exercises
    }
}

// MARK: - SessionPlanService

/// Generates a complete TrainingDay on-demand before each workout.
///
/// Called from `ProgramDayDetailView` when the user taps "Start Workout" on a
/// `.pending` day. Runs during the "Preparing your session…" loading screen.
///
/// Inputs:
///   • Macro skeleton context (phase, week intent, day-focus)
///   • Full lift history for relevant exercises from Supabase set_logs
///   • Within-week fatigue signals (RPE, rep rate, miss count)
///   • RAG memory snippets for the muscle groups being trained
///   • User profile (bodyweight, training age, goal)
///
/// If fatigue management or deload triggers have fired, the prompt instructs
/// the AI to reduce volume and weight accordingly.
actor SessionPlanService {

    private let provider: any LLMProvider
    private let memoryService: MemoryService
    private let supabaseClient: SupabaseClient
    private let traineeModelService: TraineeModelService?
    private(set) var isGenerating: Bool = false

    init(
        provider: any LLMProvider,
        memoryService: MemoryService,
        supabaseClient: SupabaseClient,
        traineeModelService: TraineeModelService? = nil
    ) {
        self.provider = provider
        self.memoryService = memoryService
        self.supabaseClient = supabaseClient
        self.traineeModelService = traineeModelService
    }

    // MARK: - Private: Build TrainingDay

    // #246: relaxed from `private` to internal so SessionPlanServiceTests can drive the
    // payload→TrainingDay mapping directly (the day_label normalization seam). Nothing else touched.
    //
    // #527 S6: `ownedEquipmentKeys` (defaulted nil for the day_label-normalization
    // tests that don't care about equipment) enables hard equipment enforcement —
    // see `enforceEquipment(...)` for the SAFE drop-the-violator rule that never
    // empties a session.
    func buildTrainingDay(
        from payload: SessionPlanPayload,
        stub: TrainingDay,
        fatigue: WeekFatigueSignals,
        ownedEquipmentKeys: Set<String>? = nil
    ) -> TrainingDay {
        // Validate exercise IDs against canonical library — log warnings for non-canonical IDs.
        // The session is not rejected; primaryMuscle will fall back to the LLM's own value.
        for ex in payload.exercises {
            if ExerciseLibrary.lookup(ex.exerciseId) == nil {
                #if DEBUG
                print("[SessionPlanService] ⚠️ Non-canonical exercise_id: '\(ex.exerciseId)' — not in ExerciseLibrary. primary_muscle will use LLM-provided value.")
                #endif
            }
        }

        // #527 S6: HARD equipment enforcement (safety-first). Drop any exercise
        // whose required equipment the user does not own — but NEVER ship an
        // empty session (see enforceEquipment for the rail). Skipped entirely
        // when `ownedEquipmentKeys` is nil (the pure day_label mapping tests).
        let acceptedExercises = Self.enforceEquipment(
            payload.exercises,
            ownedEquipmentKeys: ownedEquipmentKeys
        )

        let exercises = acceptedExercises.map { ex in
            PlannedExercise(
                id: UUID(),
                exerciseId: ex.exerciseId,
                name: ex.name,
                primaryMuscle: ex.primaryMuscle,
                synergists: ex.synergists,
                equipmentRequired: ex.equipmentRequired,
                sets: ex.sets,
                repRange: ex.repRange,
                tempo: ex.tempo,
                restSeconds: ex.restSeconds,
                rirTarget: ex.rirTarget,
                coachingCues: ex.coachingCues
            )
        }

        var notes = payload.sessionNotes
        if payload.isDeload {
            notes = (notes ?? "") + " [DELOAD — Recovery session: 50% normal volume, RPE 5–6 target]"
        } else if payload.isFatigueManagementDay {
            notes = (notes ?? "") + " [Fatigue management: volume reduced 20%]"
        }

        return TrainingDay(
            id: stub.id,
            dayOfWeek: stub.dayOfWeek,
            dayLabel: MacroPlanService.normalizeDayLabel(payload.dayLabel),   // #246: normalize the third (final) mint point
            exercises: exercises,
            sessionNotes: notes?.trimmingCharacters(in: .whitespaces),
            status: .generated
        )
    }

    // MARK: - #527 S6: Equipment enforcement (safety-first)

    /// Drops exercises whose required equipment the user does not own, with a
    /// hard safety rail: it will NEVER return an empty session.
    ///
    /// Rules (mirroring the S5 library pre-filter `bodyweightOnly || owned`):
    ///   • `ownedEquipmentKeys == nil` → no enforcement (returns input unchanged).
    ///     Used by the pure day_label-mapping tests that don't model a gym.
    ///   • Bodyweight exercises ALWAYS pass — identified canonically via the
    ///     library's `bodyweightOnly` flag, or (for non-library IDs) via the
    ///     equipment type's natural bodyweight-only status. No external weight is
    ///     ever prescribed for these, so the nominal equipment tag is irrelevant.
    ///   • A custom `.unknown:<raw>` machine passes when that exact key is owned.
    ///   • Otherwise the exercise passes only if its required `typeKey` is owned.
    ///
    /// Safety rail: if enforcement would drop EVERY exercise (empty result) while
    /// the LLM did return some, we keep the original list and log LOUDLY rather
    /// than ship an empty day. Prescribing equipment the user lacks is bad;
    /// shipping no workout at all is worse (#527 S6 directive).
    static func enforceEquipment(
        _ exercises: [SessionPlanExercise],
        ownedEquipmentKeys: Set<String>?
    ) -> [SessionPlanExercise] {
        guard let owned = ownedEquipmentKeys else { return exercises }

        let accepted = exercises.filter { ex in
            // Bodyweight always passes — same rule S5 used for the library filter.
            let isBodyweight = (ExerciseLibrary.lookup(ex.exerciseId)?.bodyweightOnly ?? false)
                || ex.equipmentRequired.isNaturallyBodyweightOnly
            if isBodyweight { return true }
            // Owned equipment (including a matching custom .unknown:<raw> key) passes.
            return owned.contains(ex.equipmentRequired.typeKey)
        }

        let dropped = exercises.count - accepted.count
        if dropped > 0 {
            let names = exercises
                .filter { ex in !accepted.contains(where: { $0.exerciseId == ex.exerciseId }) }
                .map { "\($0.exerciseId) (\($0.equipmentRequired.typeKey))" }
                .joined(separator: ", ")
            print("[SessionPlanService] ⚠️ Equipment enforcement dropped \(dropped) off-equipment exercise(s): \(names)")
        }

        // Safety rail: never empty a session that the LLM actually populated.
        if accepted.isEmpty && !exercises.isEmpty {
            print("[SessionPlanService] ⚠️⚠️ Equipment enforcement would have EMPTIED the session — keeping the LLM's original \(exercises.count) exercise(s) to avoid shipping an empty day. The gym profile may be missing equipment the user actually has.")
            return exercises
        }
        return accepted
    }

}
