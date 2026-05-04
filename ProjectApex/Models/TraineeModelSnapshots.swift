// TraineeModelSnapshots.swift
// ProjectApex — Models
//
// Pure-value snapshot / record types referenced by the trainee model.
// All Codable, Sendable, Hashable.
//
// Each `localDate` field is the pre-bucketed local-date string per
// ADR-0005 ("immune to subsequent timezone changes"); typically of the
// form "YYYY-MM-DD" written at session-completion time.

import Foundation

// MARK: - TopSetSnapshot

/// One top-set observation (intent == .top, reps in 3..10) feeding the
/// EWMA window per ADR-0005.
///
/// Carries both `date` (UTC instant — preserved for ordering and display)
/// and `localDate` (pre-bucketed yyyy-MM-dd string in the user's then-local
/// timezone). The UTC instant orders the EWMA window since localDate is
/// day-granular only; the local string is what cadence and disruption
/// derivations operate on.
struct TopSetSnapshot: Codable, Sendable, Hashable {
    var sessionId: UUID
    var date: Date
    var localDate: String
    var weightKg: Double
    var reps: Int
    var e1rm: Double

    /// Private to ensure `make(setLog:loggedInTimezone:)` is the structural
    /// single construction path for new snapshots — no caller can bypass
    /// the timezone pinning by stuffing arbitrary values in directly.
    /// Codable's synthesised `init(from:)` does not depend on this init,
    /// so JSON / SwiftData round-trips remain unaffected.
    private init(sessionId: UUID, date: Date, localDate: String, weightKg: Double, reps: Int, e1rm: Double) {
        self.sessionId = sessionId
        self.date = date
        self.localDate = localDate
        self.weightKg = weightKg
        self.reps = reps
        self.e1rm = e1rm
    }

    /// Phase 1 / Slice 5 — single construction path for new snapshots.
    /// Pre-buckets `localDate` in the supplied timezone at write time so
    /// subsequent timezone changes (Sydney → Tokyo) can't shift the
    /// already-recorded date. See ADR-0005 — "Day boundaries for cadence:
    /// chose pre-bucketed `localDate` string at write time."
    static func make(setLog: SetLog, loggedInTimezone: TimeZone = .current) -> TopSetSnapshot {
        let weight = setLog.weightKg
        let reps   = setLog.repsCompleted
        // Epley: weight × (1 + reps/30). Validity is gated by callers
        // (top sets in 3..10 reps per ADR-0005); the formula itself is
        // pure and applies the same shape to any (weight, reps).
        let e1rm = weight * (1.0 + Double(reps) / 30.0)

        // Locale pinned to en_US_POSIX so the format string yyyy-MM-dd is
        // interpreted as ISO-8601 calendar fields regardless of host locale.
        // Timezone is the explicit parameter — no implicit fallback to
        // TimeZone.current at format time.
        let formatter = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone   = loggedInTimezone
        let localDate = formatter.string(from: setLog.loggedAt)

        return TopSetSnapshot(
            sessionId: setLog.sessionId,
            date: setLog.loggedAt,
            localDate: localDate,
            weightKg: weight,
            reps: reps,
            e1rm: e1rm
        )
    }
}

// MARK: - ExerciseSessionSnapshot

/// Per-session-per-exercise snapshot — captures the heaviest top set
/// of that session (used by transition-mode plain-mean over recent
/// sessions per ADR-0005) plus aggregate counts.
struct ExerciseSessionSnapshot: Codable, Sendable, Hashable {
    var sessionId: UUID
    var localDate: String
    var heaviestTopSet: TopSetSnapshot?
    var topSetCount: Int

    init(sessionId: UUID, localDate: String, heaviestTopSet: TopSetSnapshot?, topSetCount: Int) {
        self.sessionId = sessionId
        self.localDate = localDate
        self.heaviestTopSet = heaviestTopSet
        self.topSetCount = topSetCount
    }
}

// MARK: - BodyweightEntry

/// One passive-log bodyweight observation.
struct BodyweightEntry: Codable, Sendable, Hashable {
    var localDate: String
    var weightKg: Double

    init(localDate: String, weightKg: Double) {
        self.localDate = localDate
        self.weightKg = weightKg
    }
}

// MARK: - LifeContextEvent

/// Disruption / context event — persist-only in v2 per ADR-0005.
struct LifeContextEvent: Codable, Sendable, Hashable {
    var localDate: String
    var kind: String
    var notes: String?

    init(localDate: String, kind: String, notes: String? = nil) {
        self.localDate = localDate
        self.kind = kind
        self.notes = notes
    }
}

// MARK: - ReassessmentRecord

/// Records a heavy reassessment firing — per ADR-0005, fires when ≥4 of
/// 6 major patterns transition phase within a 6-session window.
struct ReassessmentRecord: Codable, Sendable, Hashable {
    var triggeredAt: Date
    var triggeringSessionCount: Int
    var advancedPatterns: [MovementPattern]

    init(triggeredAt: Date, triggeringSessionCount: Int, advancedPatterns: [MovementPattern]) {
        self.triggeredAt = triggeredAt
        self.triggeringSessionCount = triggeringSessionCount
        self.advancedPatterns = advancedPatterns
    }
}

// MARK: - PatternProjection

/// Per-pattern projection set at calibration review (or re-derived on
/// goal renegotiation for the stretch leg). Floor is immovable; stretch
/// is user-adjustable upward only per ADR-0005.
struct PatternProjection: Codable, Sendable, Hashable {
    var pattern: MovementPattern
    var floor: Double
    var stretch: Double
    var progress: ProjectionProgress

    init(pattern: MovementPattern, floor: Double, stretch: Double, progress: ProjectionProgress) {
        self.pattern = pattern
        self.floor = floor
        self.stretch = stretch
        self.progress = progress
    }
}

// MARK: - RecoveryProfile

/// Two-dimensional recovery state per ADR-0005 — separate NM and
/// metabolic axes because heavy 1–3RM and high-rep moderate work tax
/// different systems with different decay curves.
struct RecoveryProfile: Codable, Sendable, Hashable {
    var lastNeuromuscularStimulusAt: Date?
    var lastMetabolicStimulusAt: Date?
    var neuromuscularReadiness: Double
    var metabolicReadiness: Double

    init(
        lastNeuromuscularStimulusAt: Date? = nil,
        lastMetabolicStimulusAt: Date? = nil,
        neuromuscularReadiness: Double = 1.0,
        metabolicReadiness: Double = 1.0
    ) {
        self.lastNeuromuscularStimulusAt = lastNeuromuscularStimulusAt
        self.lastMetabolicStimulusAt = lastMetabolicStimulusAt
        self.neuromuscularReadiness = neuromuscularReadiness
        self.metabolicReadiness = metabolicReadiness
    }
}

// MARK: - GoalState

/// Plain-language goal at onboarding plus optional focus areas. No
/// numerical targets at onboarding — projections are set at calibration
/// review per ADR-0005.
struct GoalState: Codable, Sendable, Hashable {
    var statement: String
    var focusAreas: [MuscleGroup]
    var updatedAt: Date

    init(statement: String, focusAreas: [MuscleGroup] = [], updatedAt: Date) {
        self.statement = statement
        self.focusAreas = focusAreas
        self.updatedAt = updatedAt
    }
}
