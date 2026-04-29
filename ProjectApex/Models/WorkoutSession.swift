// Models/WorkoutSession.swift
// ProjectApex
//
// Data models for the active workout session feature (Phase 3).
//
// WorkoutSession    — top-level session record (maps to workout_sessions table)
// SetLog            — individual set completion record (maps to set_logs table)
// SessionNote       — voice/text note within a session (maps to session_notes table)
// SessionSummary    — post-session aggregate (stored as JSONB in workout_sessions.summary)
// PersonalRecord    — PR detected during a session
//
// All types are Codable + Sendable for safe transfer across actor boundaries
// and persistence to Supabase via SupabaseClient.

import Foundation

// MARK: - WorkoutSession

/// Top-level record for a single workout session. Mirrors the `workout_sessions` table.
nonisolated struct WorkoutSession: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let programId: UUID
    let sessionDate: Date
    let weekNumber: Int
    /// E.g. "Push A", "Pull B" — maps to TrainingDay.label.
    let dayType: String
    var completed: Bool
    /// Lifecycle status string: "active", "paused", or "completed".
    /// Nil for rows created before this field was added (backward-compatible).
    var status: String?
    var setLogs: [SetLog]
    var sessionNotes: [SessionNote]
    var summary: SessionSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case userId          = "user_id"
        case programId       = "program_id"
        case sessionDate     = "session_date"
        case weekNumber      = "week_number"
        case dayType         = "day_type"
        case completed
        case status
        case setLogs         = "set_logs"
        case sessionNotes    = "session_notes"
        case summary
    }

    // Explicit memberwise initialiser — required because defining init(from:) below
    // suppresses the compiler-synthesized one.
    nonisolated init(
        id: UUID,
        userId: UUID,
        programId: UUID,
        sessionDate: Date,
        weekNumber: Int,
        dayType: String,
        completed: Bool,
        status: String? = nil,
        setLogs: [SetLog] = [],
        sessionNotes: [SessionNote] = [],
        summary: SessionSummary? = nil
    ) {
        self.id           = id
        self.userId       = userId
        self.programId    = programId
        self.sessionDate  = sessionDate
        self.weekNumber   = weekNumber
        self.dayType      = dayType
        self.completed    = completed
        self.status       = status
        self.setLogs      = setLogs
        self.sessionNotes = sessionNotes
        self.summary      = summary
    }

    // Custom decoder so that set_logs, session_notes, and summary are treated as
    // optional when fetching with a narrow select column list (e.g. in ProgressViewModel
    // and the stagnation hook, where we omit nested arrays to reduce payload size).
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,    forKey: .id)
        userId       = try c.decode(UUID.self,    forKey: .userId)
        programId    = try c.decode(UUID.self,    forKey: .programId)
        sessionDate  = try c.decode(Date.self,    forKey: .sessionDate)
        weekNumber   = try c.decode(Int.self,     forKey: .weekNumber)
        dayType      = try c.decode(String.self,  forKey: .dayType)
        completed    = try c.decode(Bool.self,    forKey: .completed)
        status       = try c.decodeIfPresent(String.self,         forKey: .status)
        setLogs      = try c.decodeIfPresent([SetLog].self,       forKey: .setLogs)       ?? []
        sessionNotes = try c.decodeIfPresent([SessionNote].self,  forKey: .sessionNotes)  ?? []
        summary      = try c.decodeIfPresent(SessionSummary.self, forKey: .summary)
    }
}

// MARK: - SetLog

/// A single completed set. Mirrors the `set_logs` table.
nonisolated struct SetLog: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID
    /// Canonical exercise identifier matching PlannedExercise.id.
    let exerciseId: String
    let setNumber: Int
    let weightKg: Double
    let repsCompleted: Int
    let rpeFelt: Int?
    let rirEstimated: Int?
    /// The AI prescription that was shown when this set was initiated.
    /// Optional and absent from older rows — decoded with decodeIfPresent.
    let aiPrescribed: SetPrescription?
    let loggedAt: Date
    /// Coarse primary muscle group for this set (e.g. "chest", "back").
    /// Populated from ExerciseLibrary at write time. Nullable for rows that
    /// pre-date the column or use non-canonical exercise IDs.
    let primaryMuscle: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId       = "session_id"
        case exerciseId      = "exercise_id"
        case setNumber       = "set_number"
        case weightKg        = "weight_kg"
        case repsCompleted   = "reps_completed"
        case rpeFelt         = "rpe_felt"
        case rirEstimated    = "rir_estimated"
        case aiPrescribed    = "ai_prescribed"
        case loggedAt        = "logged_at"
        case primaryMuscle   = "primary_muscle"
    }

    // Memberwise initialiser — used by WorkoutSessionManager, ManualSessionLogView, etc.
    nonisolated init(
        id: UUID,
        sessionId: UUID,
        exerciseId: String,
        setNumber: Int,
        weightKg: Double,
        repsCompleted: Int,
        rpeFelt: Int?,
        rirEstimated: Int?,
        aiPrescribed: SetPrescription?,
        loggedAt: Date,
        primaryMuscle: String? = nil
    ) {
        self.id            = id
        self.sessionId     = sessionId
        self.exerciseId    = exerciseId
        self.setNumber     = setNumber
        self.weightKg      = weightKg
        self.repsCompleted = repsCompleted
        self.rpeFelt       = rpeFelt
        self.rirEstimated  = rirEstimated
        self.aiPrescribed  = aiPrescribed
        self.loggedAt      = loggedAt
        self.primaryMuscle = primaryMuscle
    }

    // Custom decoder so that optional columns (absent from older rows) decode
    // to nil rather than throwing keyNotFound.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,   forKey: .id)
        sessionId      = try c.decode(UUID.self,   forKey: .sessionId)
        exerciseId     = try c.decode(String.self, forKey: .exerciseId)
        setNumber      = try c.decode(Int.self,    forKey: .setNumber)
        weightKg       = try c.decode(Double.self, forKey: .weightKg)
        repsCompleted  = try c.decode(Int.self,    forKey: .repsCompleted)
        rpeFelt        = try c.decodeIfPresent(Int.self,             forKey: .rpeFelt)
        rirEstimated   = try c.decodeIfPresent(Int.self,             forKey: .rirEstimated)
        aiPrescribed   = try c.decodeIfPresent(SetPrescription.self, forKey: .aiPrescribed)
        loggedAt       = try c.decode(Date.self,   forKey: .loggedAt)
        primaryMuscle  = try c.decodeIfPresent(String.self,          forKey: .primaryMuscle)
    }
}

// MARK: - SessionNote

/// A voice or text note logged during a session. Mirrors the `session_notes` table.
nonisolated struct SessionNote: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID
    /// The exercise the note relates to, if known.
    let exerciseId: String?
    let rawTranscript: String
    let tags: [String]
    let loggedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId       = "session_id"
        case exerciseId      = "exercise_id"
        case rawTranscript   = "raw_transcript"
        case tags
        case loggedAt        = "logged_at"
    }
}

// MARK: - SwapRecord

/// Records a single mid-session exercise substitution (P3-T10).
nonisolated struct SwapRecord: Codable, Sendable {
    let originalExerciseId: String
    let originalExerciseName: String
    let newExerciseId: String
    let newExerciseName: String
    let reason: String
    let setsCompletedBeforeSwap: Int
    let swappedAt: Date

    enum CodingKeys: String, CodingKey {
        case originalExerciseId   = "original_exercise_id"
        case originalExerciseName = "original_exercise_name"
        case newExerciseId        = "new_exercise_id"
        case newExerciseName      = "new_exercise_name"
        case reason
        case setsCompletedBeforeSwap = "sets_completed_before_swap"
        case swappedAt            = "swapped_at"
    }
}

// MARK: - SessionSummary

/// Post-session aggregate written to `workout_sessions.summary` as JSONB.
nonisolated struct SessionSummary: Codable, Sendable {
    let totalVolumeKg: Double
    let setsCompleted: Int
    /// Total sets planned across all exercises for this training day.
    let setsPlanned: Int
    let personalRecords: [PersonalRecord]
    let aiAdjustmentCount: Int
    let notableNotes: [String]
    /// Non-nil when the session was ended early (P3-T09).
    let earlyExitReason: String?
    /// Duration of the session in seconds.
    let durationSeconds: Int
    /// Exercises swapped during this session. Nil when no swaps occurred.
    let swappedExercises: [SwapRecord]?

    enum CodingKeys: String, CodingKey {
        case totalVolumeKg       = "total_volume_kg"
        case setsCompleted       = "sets_completed"
        case setsPlanned         = "sets_planned"
        case personalRecords     = "personal_records"
        case aiAdjustmentCount   = "ai_adjustment_count"
        case notableNotes        = "notable_notes"
        case earlyExitReason     = "early_exit_reason"
        case durationSeconds     = "duration_seconds"
        case swappedExercises    = "swapped_exercises"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalVolumeKg     = try c.decode(Double.self, forKey: .totalVolumeKg)
        setsCompleted     = try c.decode(Int.self, forKey: .setsCompleted)
        setsPlanned       = try c.decode(Int.self, forKey: .setsPlanned)
        personalRecords   = try c.decode([PersonalRecord].self, forKey: .personalRecords)
        aiAdjustmentCount = try c.decode(Int.self, forKey: .aiAdjustmentCount)
        notableNotes      = try c.decode([String].self, forKey: .notableNotes)
        earlyExitReason   = try c.decodeIfPresent(String.self, forKey: .earlyExitReason)
        durationSeconds   = try c.decode(Int.self, forKey: .durationSeconds)
        swappedExercises  = try c.decodeIfPresent([SwapRecord].self, forKey: .swappedExercises)
    }

    nonisolated init(
        totalVolumeKg: Double,
        setsCompleted: Int,
        setsPlanned: Int,
        personalRecords: [PersonalRecord],
        aiAdjustmentCount: Int,
        notableNotes: [String],
        earlyExitReason: String?,
        durationSeconds: Int,
        swappedExercises: [SwapRecord]? = nil
    ) {
        self.totalVolumeKg     = totalVolumeKg
        self.setsCompleted     = setsCompleted
        self.setsPlanned       = setsPlanned
        self.personalRecords   = personalRecords
        self.aiAdjustmentCount = aiAdjustmentCount
        self.notableNotes      = notableNotes
        self.earlyExitReason   = earlyExitReason
        self.durationSeconds   = durationSeconds
        self.swappedExercises  = swappedExercises
    }
}

// MARK: - PersonalRecord

nonisolated struct PersonalRecord: Codable, Sendable {
    let exerciseId: String
    let exerciseName: String
    let previousBest: Double
    let newBest: Double
    let metric: PRMetric

    enum CodingKeys: String, CodingKey {
        case exerciseId      = "exercise_id"
        case exerciseName    = "exercise_name"
        case previousBest    = "previous_best"
        case newBest         = "new_best"
        case metric
    }
}

// MARK: - PRMetric

nonisolated enum PRMetric: String, Codable, Sendable {
    case estimatedOneRM  = "estimated_one_rm"
    case topSetWeight    = "top_set_weight"
    case totalVolume     = "total_volume"
}

// MARK: - PausedSessionState

/// Minimal snapshot of a paused session saved to UserDefaults.
/// Written by `WorkoutSessionManager.pauseSession()` and updated after every set.
/// Read by the resume path to restore the session without re-starting from scratch.
///
/// Key versioning:
///   v2 key (current):   "com.projectapex.pausedSessionState_v2"
///   legacy key (< 3.1): "com.projectapex.pausedSessionState"
///
/// On load, the v2 key is tried first. If absent, the legacy key is tried and
/// migrated on success. If both keys hold corrupt/undecodable data, `repairPending`
/// is set to true so the caller can trigger `attemptSupabaseRepair(userId:supabase:)`.
nonisolated struct PausedSessionState: Codable, Sendable {
    let sessionId: UUID
    let trainingDayId: UUID
    let weekId: UUID
    let weekNumber: Int
    let exerciseIndex: Int
    let currentSetNumber: Int
    let dayType: String
    let programId: UUID
    let userId: UUID
    let pausedAt: Date

    // Custom decoder: weekNumber was added after initial release, so old UserDefaults
    // snapshots won't have it. Fall back to 1 rather than failing to decode entirely.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId      = try c.decode(UUID.self,   forKey: .sessionId)
        trainingDayId  = try c.decode(UUID.self,   forKey: .trainingDayId)
        weekId         = try c.decode(UUID.self,   forKey: .weekId)
        weekNumber     = try c.decodeIfPresent(Int.self, forKey: .weekNumber) ?? 1
        exerciseIndex  = try c.decode(Int.self,    forKey: .exerciseIndex)
        currentSetNumber = try c.decode(Int.self,  forKey: .currentSetNumber)
        dayType        = try c.decode(String.self, forKey: .dayType)
        programId      = try c.decode(UUID.self,   forKey: .programId)
        userId         = try c.decode(UUID.self,   forKey: .userId)
        pausedAt       = try c.decode(Date.self,   forKey: .pausedAt)
    }

    nonisolated init(
        sessionId: UUID,
        trainingDayId: UUID,
        weekId: UUID,
        weekNumber: Int,
        exerciseIndex: Int,
        currentSetNumber: Int,
        dayType: String,
        programId: UUID,
        userId: UUID,
        pausedAt: Date
    ) {
        self.sessionId       = sessionId
        self.trainingDayId   = trainingDayId
        self.weekId          = weekId
        self.weekNumber      = weekNumber
        self.exerciseIndex   = exerciseIndex
        self.currentSetNumber = currentSetNumber
        self.dayType         = dayType
        self.programId       = programId
        self.userId          = userId
        self.pausedAt        = pausedAt
    }

    static let legacyPersistenceKey = "com.projectapex.pausedSessionState"
    static let v2PersistenceKey     = "com.projectapex.pausedSessionState_v2"

    /// True when both the v2 and legacy UserDefaults entries held data that could not
    /// be decoded. ContentView's startup task should call `attemptSupabaseRepair` when
    /// this is true.
    static private(set) var repairPending: Bool = false

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: PausedSessionState.v2PersistenceKey)
    }

    static func load() -> PausedSessionState? {
        let ud = UserDefaults.standard

        // Try the current v2 key first.
        if let data = ud.data(forKey: v2PersistenceKey) {
            if let state = try? JSONDecoder().decode(PausedSessionState.self, from: data) {
                repairPending = false
                return state
            }
            // Data present but undecodable — flag for Supabase repair.
            repairPending = true
            return nil
        }

        // Fall back to the legacy key — migrate on success.
        if let data = ud.data(forKey: legacyPersistenceKey) {
            if let state = try? JSONDecoder().decode(PausedSessionState.self, from: data) {
                if let v2Data = try? JSONEncoder().encode(state) {
                    ud.set(v2Data, forKey: v2PersistenceKey)
                }
                ud.removeObject(forKey: legacyPersistenceKey)
                repairPending = false
                return state
            }
            // Legacy data present but undecodable — flag for Supabase repair.
            repairPending = true
            return nil
        }

        // Both keys absent — no paused session exists, normal state.
        return nil
    }

    static func clear() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: v2PersistenceKey)
        ud.removeObject(forKey: legacyPersistenceKey)
        repairPending = false
    }

    /// Queries Supabase for a paused session row when local UserDefaults data is
    /// corrupt (i.e. `repairPending == true`). Reconstructs a best-effort
    /// `PausedSessionState` — runtime fields (`trainingDayId`, `weekId`,
    /// `exerciseIndex`) are zeroed, so ContentView's mismatch path fires and
    /// offers the user an Abandon option. Clears `repairPending` on exit.
    static func attemptSupabaseRepair(userId: UUID, supabase: SupabaseClient) async {
        defer { repairPending = false }

        struct PausedRow: Decodable {
            let id: UUID
            let programId: UUID
            let weekNumber: Int
            let dayType: String
            enum CodingKeys: String, CodingKey {
                case id
                case programId  = "program_id"
                case weekNumber = "week_number"
                case dayType    = "day_type"
            }
        }

        guard let row = try? await supabase.fetch(
            PausedRow.self,
            table: "workout_sessions",
            filters: [
                Filter(column: "user_id", op: .eq, value: userId.uuidString),
                Filter(column: "status",  op: .eq, value: "paused")
            ],
            order: "session_date.desc",
            limit: 1
        ).first else { return }

        // Use a random trainingDayId so the ContentView mismatch path fires,
        // giving the user the option to Abandon the orphaned session cleanly.
        let state = PausedSessionState(
            sessionId:        row.id,
            trainingDayId:    UUID(),
            weekId:           UUID(),
            weekNumber:       row.weekNumber,
            exerciseIndex:    0,
            currentSetNumber: 1,
            dayType:          row.dayType,
            programId:        row.programId,
            userId:           userId,
            pausedAt:         Date()
        )
        state.save()
    }
}
