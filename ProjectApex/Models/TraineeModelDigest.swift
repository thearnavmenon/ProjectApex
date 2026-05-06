// TraineeModelDigest.swift
// ProjectApex — Models
//
// Request-time projection of the trainee model for inference and
// session-generation prompts (Phase 1 / Slice 10, issue #11).
//
// Per ADR-0005: "WorkoutContext payload becomes a TraineeModelDigest — a
// request-time projection of relevant trainee-model fields, narrower than
// the full model (token economics)."
//
// Phase 1 ships the shape and the assembly fn. Phase 2 wires the digest
// into prompt construction; the per-context filter on prescription
// accuracy lands at that point — the slice 10 issue's "(relevant patterns
// only)" qualifier is intentionally deferred because the request-context
// type does not yet exist. The digest emitted here carries every entry
// from the source model's prescriptionAccuracy map, flattened into a list.
//
// Filtering rules implemented now (per ADR-0005 / issue #11):
//   • activeFatigueInteractions: only entries with confidence ≥ 0.7
//     (FatigueInteraction.confidence — derived from consistencyFactor ×
//     countFactor; the 15-paired-observation gate is enforced inside the
//     same confidence value via countFactor).
//
// PatternSummary / MuscleSummary carry only the prompt-relevant fields —
// recoveryProfile, recentSessionDates, and other detail fields are
// dropped. Phase 2 may extend either summary if the prompt warrants it.

import Foundation

// MARK: - TraineeModelDigest

struct TraineeModelDigest: Codable, Sendable, Hashable {
    var goal: GoalState
    var projections: ProjectionState?
    var perPatternSummary: [PatternSummary]
    var perMuscleSummary: [MuscleSummary]
    var activeFatigueInteractions: [FatigueInteraction]
    var activeLimitations: [ActiveLimitation]
    var prescriptionAccuracy: [PrescriptionAccuracy]
    var disruptedPatterns: [MovementPattern]

    /// Threshold below which a fatigue interaction is excluded from
    /// coaching prompts per ADR-0005.
    static let fatigueInteractionConfidenceThreshold: Double = 0.7
}

// MARK: - Assembly

extension TraineeModelDigest {
    init(from model: TraineeModel, asOf reference: Date = Date()) {
        let perPatternSummary = model.patterns
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { PatternSummary(profile: $0.value, asOf: reference) }

        let perMuscleSummary = model.muscles
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { MuscleSummary(profile: $0.value) }

        let activeFatigueInteractions = model.fatigueInteractions.filter {
            $0.confidence >= Self.fatigueInteractionConfidenceThreshold
        }

        let prescriptionAccuracy = model.prescriptionAccuracy
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { (_, byIntent) in
                byIntent
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { $0.value }
            }

        let disruptedPatterns = model.disruptedPatterns(asOf: reference)
            .sorted { $0.rawValue < $1.rawValue }

        self.init(
            goal: model.goal,
            projections: model.projections,
            perPatternSummary: perPatternSummary,
            perMuscleSummary: perMuscleSummary,
            activeFatigueInteractions: activeFatigueInteractions,
            activeLimitations: model.activeLimitations,
            prescriptionAccuracy: prescriptionAccuracy,
            disruptedPatterns: disruptedPatterns
        )
    }
}

// MARK: - PatternSummary

/// Narrow projection of PatternProfile carrying the fields a coaching
/// prompt actually needs. Recovery, RPE-offset history, and the recent-
/// session-date list are dropped; cadence and disruption are pre-derived
/// at the digest level.
struct PatternSummary: Codable, Sendable, Hashable {
    var pattern: MovementPattern
    var currentPhase: MesocyclePhase
    var confidence: AxisConfidence
    var rpeOffset: Double
    var trend: ProgressionTrend
    /// Pre-evaluated against the digest's reference date so the consumer
    /// doesn't need to re-derive transition-mode state at prompt-assembly
    /// time.
    var inTransitionMode: Bool

    init(profile: PatternProfile, asOf reference: Date = Date()) {
        self.pattern         = profile.pattern
        self.currentPhase    = profile.currentPhase
        self.confidence      = profile.confidence
        self.rpeOffset       = profile.rpeOffset
        self.trend           = profile.trend
        self.inTransitionMode = profile.inTransitionMode(asOf: reference)
    }
}

// MARK: - MuscleSummary

/// Narrow projection of MuscleProfile. observedSweetSpot is dropped
/// because it varies with phase (per ADR-0005) and is not stable enough
/// to surface in coaching prompts in Phase 1; it can be added in Phase 2
/// if the prompt strategy benefits.
struct MuscleSummary: Codable, Sendable, Hashable {
    var muscleGroup: MuscleGroup
    var volumeTolerance: Double
    var volumeDeficit: Int
    var focusWeight: Double
    var stagnationStatus: ProgressionTrend
    var confidence: AxisConfidence

    init(profile: MuscleProfile) {
        self.muscleGroup       = profile.muscleGroup
        self.volumeTolerance   = profile.volumeTolerance
        self.volumeDeficit     = profile.volumeDeficit
        self.focusWeight       = profile.focusWeight
        self.stagnationStatus  = profile.stagnationStatus
        self.confidence        = profile.confidence
    }
}
