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
public struct TopSetSnapshot: Codable, Sendable, Hashable {
    public var sessionId: UUID
    public var localDate: String
    public var weightKg: Double
    public var reps: Int
    public var e1rm: Double

    public init(sessionId: UUID, localDate: String, weightKg: Double, reps: Int, e1rm: Double) {
        self.sessionId = sessionId
        self.localDate = localDate
        self.weightKg = weightKg
        self.reps = reps
        self.e1rm = e1rm
    }
}

// MARK: - ExerciseSessionSnapshot

/// Per-session-per-exercise snapshot — captures the heaviest top set
/// of that session (used by transition-mode plain-mean over recent
/// sessions per ADR-0005) plus aggregate counts.
public struct ExerciseSessionSnapshot: Codable, Sendable, Hashable {
    public var sessionId: UUID
    public var localDate: String
    public var heaviestTopSet: TopSetSnapshot?
    public var topSetCount: Int

    public init(sessionId: UUID, localDate: String, heaviestTopSet: TopSetSnapshot?, topSetCount: Int) {
        self.sessionId = sessionId
        self.localDate = localDate
        self.heaviestTopSet = heaviestTopSet
        self.topSetCount = topSetCount
    }
}

// MARK: - BodyweightEntry

/// One passive-log bodyweight observation.
public struct BodyweightEntry: Codable, Sendable, Hashable {
    public var localDate: String
    public var weightKg: Double

    public init(localDate: String, weightKg: Double) {
        self.localDate = localDate
        self.weightKg = weightKg
    }
}

// MARK: - LifeContextEvent

/// Disruption / context event — persist-only in v2 per ADR-0005.
public struct LifeContextEvent: Codable, Sendable, Hashable {
    public var localDate: String
    public var kind: String
    public var notes: String?

    public init(localDate: String, kind: String, notes: String? = nil) {
        self.localDate = localDate
        self.kind = kind
        self.notes = notes
    }
}

// MARK: - ReassessmentRecord

/// Records a heavy reassessment firing — per ADR-0005, fires when ≥4 of
/// 6 major patterns transition phase within a 6-session window.
public struct ReassessmentRecord: Codable, Sendable, Hashable {
    public var triggeredAt: Date
    public var triggeringSessionCount: Int
    public var advancedPatterns: [MovementPattern]

    public init(triggeredAt: Date, triggeringSessionCount: Int, advancedPatterns: [MovementPattern]) {
        self.triggeredAt = triggeredAt
        self.triggeringSessionCount = triggeringSessionCount
        self.advancedPatterns = advancedPatterns
    }
}

// MARK: - PatternProjection

/// Per-pattern projection set at calibration review (or re-derived on
/// goal renegotiation for the stretch leg). Floor is immovable; stretch
/// is user-adjustable upward only per ADR-0005.
public struct PatternProjection: Codable, Sendable, Hashable {
    public var pattern: MovementPattern
    public var floor: Double
    public var stretch: Double
    public var progress: ProjectionProgress

    public init(pattern: MovementPattern, floor: Double, stretch: Double, progress: ProjectionProgress) {
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
public struct RecoveryProfile: Codable, Sendable, Hashable {
    public var lastNeuromuscularStimulusAt: Date?
    public var lastMetabolicStimulusAt: Date?
    public var neuromuscularReadiness: Double
    public var metabolicReadiness: Double

    public init(
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
public struct GoalState: Codable, Sendable, Hashable {
    public var statement: String
    public var focusAreas: [MuscleGroup]
    public var updatedAt: Date

    public init(statement: String, focusAreas: [MuscleGroup] = [], updatedAt: Date) {
        self.statement = statement
        self.focusAreas = focusAreas
        self.updatedAt = updatedAt
    }
}
