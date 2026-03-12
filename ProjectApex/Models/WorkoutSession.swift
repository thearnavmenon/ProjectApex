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
        case setLogs         = "set_logs"
        case sessionNotes    = "session_notes"
        case summary
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
    let aiPrescribed: SetPrescription?
    let loggedAt: Date

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

    enum CodingKeys: String, CodingKey {
        case totalVolumeKg       = "total_volume_kg"
        case setsCompleted       = "sets_completed"
        case setsPlanned         = "sets_planned"
        case personalRecords     = "personal_records"
        case aiAdjustmentCount   = "ai_adjustment_count"
        case notableNotes        = "notable_notes"
        case earlyExitReason     = "early_exit_reason"
        case durationSeconds     = "duration_seconds"
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
