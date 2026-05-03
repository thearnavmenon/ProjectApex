// TraineeModelInteractions.swift
// ProjectApex — Models
//
// Limitation, fatigue-interaction, prescription-accuracy, transfer, and
// bodyweight-history types per ADR-0005.

import Foundation

// MARK: - ActiveLimitation

/// A currently flagged injury / pain state per pattern, muscle, or joint.
/// AI-inferred limitations require ≥2 corroborating evidence and cap at
/// .mild severity until user-confirmed (per ADR-0005).
public struct ActiveLimitation: Codable, Sendable, Hashable {
    public var subject: LimitationSubject
    public var severity: Severity
    public var onsetDate: Date
    public var evidenceCount: Int
    public var userConfirmed: Bool
    public var notes: String?

    public init(
        subject: LimitationSubject,
        severity: Severity,
        onsetDate: Date,
        evidenceCount: Int,
        userConfirmed: Bool,
        notes: String? = nil
    ) {
        self.subject = subject
        self.severity = severity
        self.onsetDate = onsetDate
        self.evidenceCount = evidenceCount
        self.userConfirmed = userConfirmed
        self.notes = notes
    }
}

// MARK: - ClearedLimitation

/// An archived limitation resolved through clean training. Retention is
/// capped at 50 entries / 12 months (enforced at write-side, not in
/// this value type) per ADR-0005.
public struct ClearedLimitation: Codable, Sendable, Hashable {
    public var subject: LimitationSubject
    public var severity: Severity
    public var onsetDate: Date
    public var clearedDate: Date
    public var notes: String?

    public init(
        subject: LimitationSubject,
        severity: Severity,
        onsetDate: Date,
        clearedDate: Date,
        notes: String? = nil
    ) {
        self.subject = subject
        self.severity = severity
        self.onsetDate = onsetDate
        self.clearedDate = clearedDate
        self.notes = notes
    }
}

// MARK: - FatigueInteraction

/// Cross-pattern carryover — surfaces in coaching prompts only at
/// confidence ≥ 0.7 with ≥15 paired observations.
///
/// Per ADR-0005:
///  - consistencyFactor = max(0, min(1, 1 - stddev/|mean|)) over the last
///    10 observations, with a 0.001 mean-guard for delta-percent values.
///  - countFactor caps confidence at 0.5 below 15 observations; full
///    weight at 15+.
///  - confidence = consistencyFactor × countFactor.
public struct FatigueInteraction: Codable, Sendable, Hashable {
    public var fromPattern: MovementPattern
    public var toPattern: MovementPattern
    /// Delta-percent observations (e.g. -0.05 = 5% performance dip).
    /// Newest at the end. Window of last 10 feeds consistencyFactor.
    public var observations: [Double]
    /// Total paired observations seen across history (for the hard-cap rule).
    public var totalCount: Int

    public init(
        fromPattern: MovementPattern,
        toPattern: MovementPattern,
        observations: [Double],
        totalCount: Int
    ) {
        self.fromPattern = fromPattern
        self.toPattern = toPattern
        self.observations = observations
        self.totalCount = totalCount
    }

    public var consistencyFactor: Double {
        let recent = Array(observations.suffix(10))
        guard recent.count >= 2 else { return 0 }
        let mean = recent.reduce(0, +) / Double(recent.count)
        let absMean = max(abs(mean), 0.001)
        let variance = recent.map { pow($0 - mean, 2) }.reduce(0, +) / Double(recent.count)
        let stddev = sqrt(variance)
        let clamped = max(0, min(1, 1 - stddev / absMean))
        if abs(clamped - 1) < 1e-12 { return 1 }
        if abs(clamped)     < 1e-12 { return 0 }
        return clamped
    }

    public var countFactor: Double {
        totalCount >= 15 ? 1.0 : 0.5
    }

    public var confidence: Double {
        consistencyFactor * countFactor
    }
}

// MARK: - PrescriptionAccuracy

/// Per (pattern, intent) bias and RMSE — meta-coaching about the AI's
/// own miscalibration, distinct from a single intent mismatch at log time.
public struct PrescriptionAccuracy: Codable, Sendable, Hashable {
    public var pattern: MovementPattern
    public var intent: SetIntent
    public var bias: Double
    public var rmse: Double
    public var sampleCount: Int

    public init(pattern: MovementPattern, intent: SetIntent, bias: Double, rmse: Double, sampleCount: Int) {
        self.pattern = pattern
        self.intent = intent
        self.bias = bias
        self.rmse = rmse
        self.sampleCount = sampleCount
    }
}

// MARK: - PrescriptionIntentMismatch

/// Diagnostic log for set-intent mismatches at log time. Inspection-only,
/// capped at 50 entries (cap enforced at write-side); not used for rate
/// analytics per ADR-0005.
public struct PrescriptionIntentMismatch: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var exerciseId: String
    public var pattern: MovementPattern
    public var prescribedIntent: SetIntent
    public var loggedIntent: SetIntent

    public init(
        timestamp: Date,
        exerciseId: String,
        pattern: MovementPattern,
        prescribedIntent: SetIntent,
        loggedIntent: SetIntent
    ) {
        self.timestamp = timestamp
        self.exerciseId = exerciseId
        self.pattern = pattern
        self.prescribedIntent = prescribedIntent
        self.loggedIntent = loggedIntent
    }
}

// MARK: - ExerciseTransfer

/// Per-user-learned cross-exercise transfer coefficient with R². Gated
/// on ≥5 paired observations per ADR-0005; first ~30 sessions per pair
/// give no transfer benefit (cold-start).
public struct ExerciseTransfer: Codable, Sendable, Hashable {
    public var fromExerciseId: String
    public var toExerciseId: String
    public var coefficient: Double
    public var rSquared: Double
    public var pairedObservations: Int

    public init(
        fromExerciseId: String,
        toExerciseId: String,
        coefficient: Double,
        rSquared: Double,
        pairedObservations: Int
    ) {
        self.fromExerciseId = fromExerciseId
        self.toExerciseId = toExerciseId
        self.coefficient = coefficient
        self.rSquared = rSquared
        self.pairedObservations = pairedObservations
    }
}

// MARK: - BodyweightHistory

/// Passive-log bodyweight history per ADR-0005.
public struct BodyweightHistory: Codable, Sendable, Hashable {
    public var entries: [BodyweightEntry]

    public init(entries: [BodyweightEntry] = []) {
        self.entries = entries
    }
}
