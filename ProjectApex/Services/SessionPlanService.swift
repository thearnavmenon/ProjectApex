// SessionPlanService.swift
// ProjectApex — Services
//
// FB-008: Part 2 of the dynamic programme architecture.
//
// SessionPlanService generates the FULL session for one training day,
// called on-demand immediately before the user starts a workout.
//
// Inputs assembled per session:
//   • Macro skeleton: phase context, week intent, day-focus string
//   • Full lift history from RAG memory (last 8 sets per exercise)
//   • Within-week session logs: sets per muscle group, RPE signals
//   • User profile: bodyweight, training age, goal
//
// Fatigue logic (FB-008 ACs):
//   • weekly_avg_rpe > 8.2 across 3+ sessions → reduce next session volume 20%
//   • If any 2 of 3 deload triggers fire across rolling 7-day window → generate deload
//
// Output: a complete TrainingDay with PlannedExercises, coaching cues, and weights.
//
// ISOLATION NOTE: All DTO types are `nonisolated` (target: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

import Foundation

// MARK: - SessionPlanError

nonisolated enum SessionPlanError: LocalizedError {
    case systemPromptNotFound
    case encodingFailed(String)
    case llmProviderError(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .systemPromptNotFound:
            return "SystemPrompt_SessionPlan.txt not found in the app bundle."
        case .encodingFailed(let d):
            return "Failed to encode session plan request: \(d)"
        case .llmProviderError(let d):
            return "LLM provider error during session plan generation: \(d)"
        case .decodingFailed(let d):
            return "Failed to decode generated session plan: \(d)"
        }
    }
}

// MARK: - Fatigue Signals

/// Aggregated fatigue signals derived from completed sessions in the current 7-day window.
nonisolated struct WeekFatigueSignals: Codable, Sendable {
    /// Number of sessions completed this week (Mon–Sun).
    let sessionsCompletedThisWeek: Int
    /// Average RPE across all sets this week. Nil when no sets logged yet.
    let weeklyAvgRPE: Double?
    /// Rep completion rate across all sets this week (repsCompleted / repsTarget).
    let repCompletionRate: Double?
    /// Number of significant compound lift misses this week (< 60% rep completion).
    let significantMissCount: Int
    /// Total sets per muscle group this week, e.g. [.chest: 12, .back: 14].
    /// Slice 1 migrated from [String: Int] to [MuscleGroup: Int] (locked-six
    /// per ADR-0005). Wire-compatible JSON shape: leg subgroups
    /// (quads/hamstrings/glutes/calves) collapse to "legs"; core entries
    /// drop entirely. Behavioral note: this slightly coarsens what the LLM
    /// sees compared to the previous string-keyed shape.
    let setsPerMuscleGroup: [MuscleGroup: Int]
    /// True when cumulative weekly RPE > 8.2 across 3+ sessions.
    let fatigueManagementFlagged: Bool
    /// True when deload triggers fire: ≥2 of [avg_rpe > 8.0, rep_rate < 75%, 3+ misses].
    let deloadTriggered: Bool

    enum CodingKeys: String, CodingKey {
        case sessionsCompletedThisWeek = "sessions_completed_this_week"
        case weeklyAvgRPE              = "weekly_avg_rpe"
        case repCompletionRate         = "rep_completion_rate"
        case significantMissCount      = "significant_miss_count"
        case setsPerMuscleGroup        = "sets_per_muscle_group"
        case fatigueManagementFlagged  = "fatigue_management_flagged"
        case deloadTriggered           = "deload_triggered"
    }

    /// Computes fatigue signals from a list of completed set logs this week.
    static func compute(from setLogs: [SetLog], sessionCount: Int) -> WeekFatigueSignals {
        guard !setLogs.isEmpty else {
            return WeekFatigueSignals(
                sessionsCompletedThisWeek: sessionCount,
                weeklyAvgRPE: nil,
                repCompletionRate: nil,
                significantMissCount: 0,
                setsPerMuscleGroup: [:],
                fatigueManagementFlagged: false,
                deloadTriggered: false
            )
        }

        let rpeValues = setLogs.compactMap { $0.rpeFelt.map { Double($0) } }
        let avgRPE = rpeValues.isEmpty ? nil : rpeValues.reduce(0, +) / Double(rpeValues.count)

        // For rep completion rate we look at AI prescribed vs actual.
        // Where we have aiPrescribed data, compare. Otherwise skip.
        var repCompPairs: [(target: Int, actual: Int)] = []
        var sigMisses = 0
        var muscleSetCounts: [MuscleGroup: Int] = [:]

        for log in setLogs {
            if let prescribed = log.aiPrescribed {
                let target = prescribed.reps
                let actual = log.repsCompleted
                repCompPairs.append((target: target, actual: actual))
                let rate = Double(actual) / Double(max(target, 1))
                if rate < 0.60 { sigMisses += 1 }
            }
            // Muscle group from exerciseId — drops core / other (no
            // representation in the locked-six MuscleGroup taxonomy).
            if let group = muscleGroup(for: log.exerciseId) {
                muscleSetCounts[group, default: 0] += 1
            }
        }

        let repRate: Double?
        if !repCompPairs.isEmpty {
            let totalTarget = repCompPairs.map(\.target).reduce(0, +)
            let totalActual = repCompPairs.map(\.actual).reduce(0, +)
            repRate = Double(totalActual) / Double(max(totalTarget, 1))
        } else {
            repRate = nil
        }

        // Fatigue management: avg RPE > 8.2 across 3+ sessions
        let fatigueManagementFlagged = (avgRPE ?? 0) > 8.2 && sessionCount >= 3

        // Deload trigger: ≥2 of the 3 signals
        var deloadSignals = 0
        if (avgRPE ?? 0) > 8.0 { deloadSignals += 1 }
        if (repRate ?? 1.0) < 0.75 { deloadSignals += 1 }
        if sigMisses >= 3 { deloadSignals += 1 }
        let deloadTriggered = deloadSignals >= 2

        return WeekFatigueSignals(
            sessionsCompletedThisWeek: sessionCount,
            weeklyAvgRPE: avgRPE,
            repCompletionRate: repRate,
            significantMissCount: sigMisses,
            setsPerMuscleGroup: muscleSetCounts,
            fatigueManagementFlagged: fatigueManagementFlagged,
            deloadTriggered: deloadTriggered
        )
    }

    /// Maps an exerciseId to a MuscleGroup. Prefers the canonical
    /// ExerciseLibrary lookup; falls back to string heuristics for
    /// non-canonical IDs. Returns nil for core / unmapped IDs (the
    /// locked-six MuscleGroup taxonomy excludes both per ADR-0005).
    private static func muscleGroup(for exerciseId: String) -> MuscleGroup? {
        if let primary = ExerciseLibrary.primaryMuscle(for: exerciseId) {
            return primary.muscleGroup
        }
        let lower = exerciseId.lowercased()
        if lower.contains("bench") || lower.contains("chest") || lower.contains("pec") { return .chest }
        if lower.contains("row") || lower.contains("pulldown") || lower.contains("pull_up") || lower.contains("lat") { return .back }
        if lower.contains("squat") || lower.contains("leg_press") || lower.contains("quad") || lower.contains("lunge") { return .legs }
        if lower.contains("deadlift") || lower.contains("hamstring") || lower.contains("rdl") { return .legs }
        if lower.contains("glute") || lower.contains("hip_thrust") { return .legs }
        if lower.contains("press") && lower.contains("shoulder") { return .shoulders }
        if lower.contains("overhead") || lower.contains("ohp") { return .shoulders }
        if lower.contains("curl") && !lower.contains("leg") { return .biceps }
        if lower.contains("tricep") || lower.contains("pushdown") { return .triceps }
        if lower.contains("calf") || lower.contains("raise") { return .legs }
        // "ab"/"core" mappings dropped — core is excluded from the locked-six
        // MuscleGroup taxonomy per ADR-0005.
        return nil
    }
}

// MARK: - TemporalContext

/// Gap-awareness context for the LLM, describing how long it has been since the user
/// last trained overall and per movement pattern.
///
/// This struct is intentionally open for extension — Phase 2 will add per-pattern phase
/// state (`phasedByPattern: [String: MesocyclePhase]`) without requiring a rewrite.
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

    // MARK: Phase 2 — Per-pattern phase state
    // All three fields are optional so existing tests and serialised data remain valid.

    /// The programme's global phase at the time of this session (MesocyclePhase raw value).
    /// Nil when not yet available (pre-migration or test contexts).
    let globalProgrammePhase: String?
    /// The programme's global week number (1-based).
    let globalProgrammeWeek: Int?
    /// Per-movement-pattern phase state. Keys are movement pattern strings.
    /// Nil when PatternPhaseService has not yet been initialised for this user.
    let patternPhases: [String: PatternPhaseInfo]?
    /// True when daysSinceLastSession >= 28 — signals a significant return-to-training gap.
    /// When true the LLM ignores the pattern phase label and generates a reduced-volume
    /// accumulation baseline session instead.
    let requiresReturnPhaseOverride: Bool

    enum CodingKeys: String, CodingKey {
        case daysSinceLastSession             = "days_since_last_session"
        case daysSinceLastTrainedByPattern    = "days_since_last_trained_by_pattern"
        case skippedSessionCountLast30Days    = "skipped_session_count_last_30_days"
        case globalProgrammePhase             = "global_programme_phase"
        case globalProgrammeWeek              = "global_programme_week"
        case patternPhases                    = "pattern_phases"
        case requiresReturnPhaseOverride      = "requires_return_phase_override"
    }

    /// Custom encoder:
    /// • `daysSinceLastSession` encodes as JSON `null` (not absent) when nil so the LLM
    ///   can distinguish "first-ever session" from "field missing from payload".
    /// • `globalProgrammePhase` and `globalProgrammeWeek` also encode as null when nil
    ///   so the LLM sees them explicitly rather than treating absence as an unknown.
    /// • `patternPhases` uses encodeIfPresent — absence signals "use global phase".
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(daysSinceLastSession, forKey: .daysSinceLastSession)
        try container.encode(daysSinceLastTrainedByPattern, forKey: .daysSinceLastTrainedByPattern)
        try container.encode(skippedSessionCountLast30Days, forKey: .skippedSessionCountLast30Days)
        try container.encode(globalProgrammePhase, forKey: .globalProgrammePhase)
        try container.encode(globalProgrammeWeek, forKey: .globalProgrammeWeek)
        try container.encodeIfPresent(patternPhases, forKey: .patternPhases)
        try container.encode(requiresReturnPhaseOverride, forKey: .requiresReturnPhaseOverride)
    }

    /// Custom decoder: uses decodeIfPresent for all Phase 2 fields so pre-Phase-2
    /// serialised payloads (missing the new keys) still decode without error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daysSinceLastSession          = try c.decodeIfPresent(Int.self, forKey: .daysSinceLastSession)
        daysSinceLastTrainedByPattern = try c.decode([String: Int].self, forKey: .daysSinceLastTrainedByPattern)
        skippedSessionCountLast30Days = try c.decode(Int.self, forKey: .skippedSessionCountLast30Days)
        globalProgrammePhase          = try c.decodeIfPresent(String.self, forKey: .globalProgrammePhase)
        globalProgrammeWeek           = try c.decodeIfPresent(Int.self, forKey: .globalProgrammeWeek)
        patternPhases                 = try c.decodeIfPresent([String: PatternPhaseInfo].self, forKey: .patternPhases)
        requiresReturnPhaseOverride   = try c.decodeIfPresent(Bool.self, forKey: .requiresReturnPhaseOverride) ?? false
    }

    /// Memberwise init (required because we define init(from:) above).
    init(
        daysSinceLastSession: Int?,
        daysSinceLastTrainedByPattern: [String: Int],
        skippedSessionCountLast30Days: Int,
        globalProgrammePhase: String? = nil,
        globalProgrammeWeek: Int? = nil,
        patternPhases: [String: PatternPhaseInfo]? = nil,
        requiresReturnPhaseOverride: Bool = false
    ) {
        self.daysSinceLastSession           = daysSinceLastSession
        self.daysSinceLastTrainedByPattern  = daysSinceLastTrainedByPattern
        self.skippedSessionCountLast30Days  = skippedSessionCountLast30Days
        self.globalProgrammePhase           = globalProgrammePhase
        self.globalProgrammeWeek            = globalProgrammeWeek
        self.patternPhases                  = patternPhases
        self.requiresReturnPhaseOverride    = requiresReturnPhaseOverride
    }
}

// MARK: - LiftHistoryEntry

/// Performance history for a single exercise — sent to SessionPlanService as context.
nonisolated struct LiftHistoryEntry: Codable, Sendable {
    let exerciseId: String
    let exerciseName: String
    /// Last 8 completed sets across all sessions, most recent first.
    let recentSets: [CompletedSet]
    /// "improving" | "stalling" | "declining"
    let trendDirection: String
    /// Best recent set (highest e1RM proxy: weight × (1 + reps/30)).
    let bestRecentSet: CompletedSet?
    /// Outcome tag from the most recent session: "on_target" | "overloaded" | "underloaded"
    let lastSessionOutcome: String?
    /// Total number of sessions this exercise has been trained.
    let sessionCount: Int

    enum CodingKeys: String, CodingKey {
        case exerciseId        = "exercise_id"
        case exerciseName      = "exercise_name"
        case recentSets        = "recent_sets"
        case trendDirection    = "trend_direction"
        case bestRecentSet     = "best_recent_set"
        case lastSessionOutcome = "last_session_outcome"
        case sessionCount      = "session_count"
    }
}

// MARK: - SessionPlanRequest

nonisolated struct SessionPlanRequest: Codable, Sendable {
    let userId: String
    let weekNumber: Int
    let weekIntent: WeekIntent
    let phase: MesocyclePhase
    let dayFocus: String
    let dayLabel: String
    let trainingDaysPerWeek: Int
    let userProfile: MacroPlanUserProfile
    let gymProfile: MacroPlanGymProfile
    let liftHistory: [LiftHistoryEntry]
    let weekFatigue: WeekFatigueSignals
    let ragMemory: [RAGMemoryItem]
    /// Stagnation signals computed post-session by StagnationService.
    /// Empty array when no stagnation data is available yet.
    let stagnationSignals: [StagnationSignal]
    /// Volume deficit signals for the current mesocycle week.
    /// Empty array when volume is on-track or insufficient data exists.
    let volumeDeficits: [VolumeDeficit]
    /// Phase-1-Skip: gap-awareness context. Nil only if assembly fails unexpectedly;
    /// in practice this is always provided for every session generation call.
    let temporalContext: TemporalContext?

    enum CodingKeys: String, CodingKey {
        case userId              = "user_id"
        case weekNumber          = "week_number"
        case weekIntent          = "week_intent"
        case phase
        case dayFocus            = "day_focus"
        case dayLabel            = "day_label"
        case trainingDaysPerWeek = "training_days_per_week"
        case userProfile         = "user_profile"
        case gymProfile          = "gym_profile"
        case liftHistory         = "lift_history"
        case weekFatigue         = "week_fatigue"
        case ragMemory           = "rag_memory"
        case stagnationSignals   = "stagnation_signals"
        case volumeDeficits      = "volume_deficits"
        case temporalContext     = "temporal_context"
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
    private(set) var isGenerating: Bool = false

    init(
        provider: any LLMProvider,
        memoryService: MemoryService,
        supabaseClient: SupabaseClient
    ) {
        self.provider = provider
        self.memoryService = memoryService
        self.supabaseClient = supabaseClient
    }

    // MARK: - Public API

    /// Generates a complete, exercise-populated TrainingDay for the given skeleton day.
    ///
    /// - Parameters:
    ///   - skeletonDay: The pending TrainingDay stub from the mesocycle.
    ///   - week: The TrainingWeek the day belongs to.
    ///   - userId: Authenticated user UUID.
    ///   - gymProfile: User's gym equipment profile.
    ///   - userProfile: Biometric + training age profile.
    ///   - recentSetLogs: Set logs from the past 7 days — used for fatigue signals only.
    ///   - deepLiftHistory: Set logs for the same day type across the last 10 sessions
    ///     (no date cap) — used for lift history context. Falls back to `recentSetLogs`
    ///     when no previous completed instance of this day exists.
    ///   - weekSessionCount: Number of sessions completed this week.
    ///   - temporalContext: Gap-awareness context (days since last session, per-pattern gaps, skips).
    /// - Returns: A fully populated TrainingDay with status `.generated`.
    func generateSession(
        for skeletonDay: TrainingDay,
        week: TrainingWeek,
        userId: UUID,
        gymProfile: GymProfile,
        userProfile: MacroPlanUserProfile,
        recentSetLogs: [SetLog],
        deepLiftHistory: [SetLog],
        weekSessionCount: Int,
        temporalContext: TemporalContext? = nil
    ) async throws -> TrainingDay {
        isGenerating = true
        defer { isGenerating = false }

        let systemPrompt = try Self.loadSystemPrompt()

        // 1. Compute fatigue signals from the 7-day window (time-sensitive)
        let fatigue = WeekFatigueSignals.compute(
            from: recentSetLogs,
            sessionCount: weekSessionCount
        )

        // 2. Build lift history from the deep per-exercise history (no date cap)
        let liftHistory = buildLiftHistory(from: deepLiftHistory, dayFocus: skeletonDay.dayLabel)

        // 3. Per-exercise RAG retrieval: one query per exercise for precision.
        //    Falls back to the day-label query when no exercise history exists yet.
        let exerciseNames: [String] = {
            let ids = Set(deepLiftHistory.map(\.exerciseId))
            guard !ids.isEmpty else { return [] }
            return ids.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        }()

        let ragMemory: [RAGMemoryItem]
        if exerciseNames.isEmpty {
            let ragQuery = skeletonDay.dayLabel.replacingOccurrences(of: "_", with: " ")
            ragMemory = await memoryService.retrieveMemory(
                queryText: ragQuery,
                userId: userId.uuidString,
                threshold: 0.70,
                count: 5
            )
        } else {
            ragMemory = await withTaskGroup(of: [RAGMemoryItem].self) { group in
                for name in exerciseNames {
                    group.addTask {
                        await self.memoryService.retrieveMemory(
                            queryText: name,
                            userId: userId.uuidString,
                            threshold: 0.70,
                            count: 3
                        )
                    }
                }
                var all: [RAGMemoryItem] = []
                for await items in group {
                    all.append(contentsOf: items)
                }
                return Self.deduplicateRAG(all)
            }
        }

        // 4. Build the request
        let weekIntent = week.weekLabel.map { label in
            WeekIntent(
                weekLabel: label,
                dayFocus: [skeletonDay.dayLabel],
                volumeLandmark: weekVolumeLandmark(for: week.phase, weekNumber: week.weekNumber)
            )
        } ?? WeekIntent(
            weekLabel: "\(week.phase.displayTitle) Week \(week.weekNumber)",
            dayFocus: [skeletonDay.dayLabel],
            volumeLandmark: weekVolumeLandmark(for: week.phase, weekNumber: week.weekNumber)
        )

        // Load persisted signals from UserDefaults (written post-session by WorkoutSessionManager)
        let stagnationSignals = StagnationService.load()
        let volumeDeficits    = VolumeValidationService.load()

        let request = SessionPlanRequest(
            userId: userId.uuidString,
            weekNumber: week.weekNumber,
            weekIntent: weekIntent,
            phase: week.phase,
            dayFocus: skeletonDay.dayLabel.replacingOccurrences(of: "_", with: " "),
            dayLabel: skeletonDay.dayLabel,
            trainingDaysPerWeek: 4,
            userProfile: userProfile,
            gymProfile: MacroPlanGymProfile(from: gymProfile),
            liftHistory: liftHistory,
            weekFatigue: fatigue,
            ragMemory: ragMemory,
            stagnationSignals: stagnationSignals,
            volumeDeficits: volumeDeficits,
            temporalContext: temporalContext
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let requestData = try? encoder.encode(request),
              let requestJSON = String(data: requestData, encoding: .utf8)
        else {
            throw SessionPlanError.encodingFailed("Failed to encode SessionPlanRequest.")
        }

        // 5. LLM call + decode
        let sessionPayload = try await callAndDecodeSession(
            systemPrompt: systemPrompt,
            userPayload: requestJSON
        )

        // 6. Build TrainingDay
        return buildTrainingDay(
            from: sessionPayload,
            stub: skeletonDay,
            fatigue: fatigue
        )
    }

    // MARK: - Private: LLM call + decode

    private func callAndDecodeSession(
        systemPrompt: String,
        userPayload: String
    ) async throws -> SessionPlanPayload {
        let rawResponse: String
        do {
            rawResponse = try await TransientRetryPolicy.execute {
                try await self.provider.complete(
                    systemPrompt: systemPrompt,
                    userPayload: userPayload
                )
            }
        } catch {
            if let llmError = error as? LLMProviderError {
                FallbackLogRecord.from(
                    callSite: FallbackLogRecord.sessionPlanCallSite,
                    error: llmError
                ).emit()
            } else {
                FallbackLogRecord(
                    callSite: FallbackLogRecord.sessionPlanCallSite,
                    reason: error.localizedDescription
                ).emit()
            }
            throw SessionPlanError.llmProviderError(error.localizedDescription)
        }

        let fenceStripped = Self.stripMarkdownFences(rawResponse)
        let extracted = Self.extractOutermostObject(fenceStripped) ?? fenceStripped

        guard let data = extracted.data(using: .utf8) else {
            throw SessionPlanError.decodingFailed("LLM response is not valid UTF-8.")
        }

        do {
            let wrapper = try JSONDecoder().decode(SessionPlanWrapper.self, from: data)
            return wrapper.sessionPlan
        } catch let err {
            print("[SessionPlanService] Decode failure. Raw response:\n\(rawResponse)")
            throw SessionPlanError.decodingFailed(
                "Session plan decode failed: \(err.localizedDescription). Raw: \(String(extracted.prefix(400)))"
            )
        }
    }

    // MARK: - Private: Build TrainingDay

    private func buildTrainingDay(
        from payload: SessionPlanPayload,
        stub: TrainingDay,
        fatigue: WeekFatigueSignals
    ) -> TrainingDay {
        // Validate exercise IDs against canonical library — log warnings for non-canonical IDs.
        // The session is not rejected; primaryMuscle will fall back to the LLM's own value.
        for ex in payload.exercises {
            if ExerciseLibrary.lookup(ex.exerciseId) == nil {
                print("[SessionPlanService] ⚠️ Non-canonical exercise_id: '\(ex.exerciseId)' — not in ExerciseLibrary. primary_muscle will use LLM-provided value.")
            }
        }

        let exercises = payload.exercises.map { ex in
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
            dayLabel: payload.dayLabel,
            exercises: exercises,
            sessionNotes: notes?.trimmingCharacters(in: .whitespaces),
            status: .generated
        )
    }

    // MARK: - Private: Build lift history from set logs

    private func buildLiftHistory(
        from setLogs: [SetLog],
        dayFocus: String
    ) -> [LiftHistoryEntry] {
        // Diagnostic: per-exercise session counts — confirms lookback depth before LLM context assembly.
        // If this prints 0 or 1 sessions for an exercise the user has trained for weeks, the Supabase
        // fetch in ProgramViewModel is still being filtered too aggressively.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        for exerciseId in Set(setLogs.map { $0.exerciseId }).sorted() {
            let logsForEx = setLogs.filter { $0.exerciseId == exerciseId }
            // One representative log per session → get date from its loggedAt
            let sessionDates = Dictionary(grouping: logsForEx) { $0.sessionId }
                .values
                .compactMap { $0.first }
                .map { dateFormatter.string(from: $0.loggedAt) }
                .sorted()
            print("[SessionPlanService] Exercise history for \(exerciseId): \(sessionDates.count) session(s) found, dates: \(sessionDates)")
        }

        // Group set logs by exerciseId
        var grouped: [String: [SetLog]] = [:]
        for log in setLogs {
            grouped[log.exerciseId, default: []].append(log)
        }

        return grouped.compactMap { exerciseId, logs in
            let sorted = logs.sorted { $0.loggedAt > $1.loggedAt }
            let recent = Array(sorted.prefix(8))

            // Build CompletedSet array from recent logs
            let completedSets = recent.map { log in
                CompletedSet(
                    setNumber: log.setNumber,
                    weightKg: log.weightKg,
                    reps: log.repsCompleted,
                    rirActual: log.rirEstimated,
                    rpe: log.rpeFelt.map { Double($0) },
                    tempo: nil,
                    restTakenSeconds: nil,
                    completedAt: log.loggedAt,
                    userCorrectedWeight: nil,
                    daysAgo: Calendar.current.dateComponents([.day], from: log.loggedAt, to: Date()).day
                )
            }

            // Compute trend (simple: compare first half avg vs second half avg e1RM)
            let trend = computeTrend(from: completedSets)

            // Best set by e1RM proxy: weight * (1 + reps/30)
            let best = completedSets.max(by: { a, b in
                let aE1 = a.weightKg * (1 + Double(a.reps) / 30.0)
                let bE1 = b.weightKg * (1 + Double(b.reps) / 30.0)
                return aE1 < bE1
            })

            // Last session outcome from AI-prescribed data
            let lastOutcome = logs.first?.aiPrescribed.flatMap { _ -> String? in
                // We emit outcome events via WorkoutSessionManager — not available here directly.
                // Fall back to simple inference: if last set hit reps, on_target; else overloaded.
                guard let lastLog = logs.sorted(by: { $0.loggedAt > $1.loggedAt }).first,
                      let prescribed = lastLog.aiPrescribed else { return nil }
                let rate = Double(lastLog.repsCompleted) / Double(max(prescribed.reps, 1))
                if rate >= 0.90 { return "on_target" }
                if rate < 0.60 { return "overloaded" }
                return "underloaded"
            }

            return LiftHistoryEntry(
                exerciseId: exerciseId,
                exerciseName: exerciseId.replacingOccurrences(of: "_", with: " ")
                    .capitalized,
                recentSets: completedSets,
                trendDirection: trend,
                bestRecentSet: best,
                lastSessionOutcome: lastOutcome,
                sessionCount: Set(logs.map(\.sessionId)).count
            )
        }
    }

    /// Simple trend: compare second-half e1RM average vs first-half.
    private func computeTrend(from sets: [CompletedSet]) -> String {
        guard sets.count >= 4 else { return "stalling" }
        let e1RM = sets.map { $0.weightKg * (1 + Double($0.reps) / 30.0) }
        let half = e1RM.count / 2
        let older = e1RM.suffix(from: half).reduce(0, +) / Double(e1RM.count - half)
        let newer = e1RM.prefix(half).reduce(0, +) / Double(half)
        if newer > older * 1.03 { return "improving" }
        if newer < older * 0.97 { return "declining" }
        return "stalling"
    }

    /// Rough volume landmark for prompt context (0.0–1.0).
    private func weekVolumeLandmark(for phase: MesocyclePhase, weekNumber: Int) -> Double {
        switch phase {
        case .accumulation:    return 0.4 + Double(weekNumber - 1) * 0.075
        case .intensification: return 0.7 + Double(weekNumber - 5) * 0.05
        case .peaking:         return 0.85 + Double(weekNumber - 9) * 0.05
        case .deload:          return 0.3
        }
    }

    // MARK: - Private: Helpers

    /// Deduplicates RAG memory items by summary text, keeping the highest-relevance
    /// entry when duplicates are found across multiple per-exercise queries.
    private static func deduplicateRAG(_ items: [RAGMemoryItem]) -> [RAGMemoryItem] {
        var seen: [String: RAGMemoryItem] = [:]
        for item in items {
            if let existing = seen[item.summary] {
                if item.relevanceScore > existing.relevanceScore {
                    seen[item.summary] = item
                }
            } else {
                seen[item.summary] = item
            }
        }
        return seen.values.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    private static func loadSystemPrompt() throws -> String {
        if let url = Bundle.main.url(
            forResource: "SystemPrompt_SessionPlan",
            withExtension: "txt",
            subdirectory: "Prompts"
        ) ?? Bundle.main.url(
            forResource: "SystemPrompt_SessionPlan",
            withExtension: "txt"
        ) {
            let base = try String(contentsOf: url, encoding: .utf8)
            return base + ExerciseLibrary.promptReferenceBlock()
        }
        throw SessionPlanError.systemPromptNotFound
    }

    private static func stripMarkdownFences(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractOutermostObject(_ input: String) -> String? {
        guard let start = input.firstIndex(of: "{") else { return nil }
        var depth = 0; var inStr = false; var escaped = false
        var idx = start
        while idx < input.endIndex {
            let ch = input[idx]
            if escaped { escaped = false }
            else if ch == "\\" && inStr { escaped = true }
            else if ch == "\"" { inStr.toggle() }
            else if !inStr {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(input[start...idx]) }
                }
            }
            idx = input.index(after: idx)
        }
        return nil
    }
}
