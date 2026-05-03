// TraineeModelEnums.swift
// ProjectApex — Models
//
// Supporting enums consumed by the trainee model. See ADR-0005 for the
// schema. Cases that ADR-0005 enumerates explicitly (SetIntent,
// AxisConfidence, StimulusDimension) match the ADR verbatim. Cases that
// the ADR leaves to implementation (BodyJoint, Severity, ProjectionProgress,
// LimitationSubject) use the standard taxonomy noted above each enum.
//
// Note on ProgrammePhase: issue #2 listed `ProgrammePhase` as a supporting
// enum, but the codebase already has `MesocyclePhase` (in WorkoutProgram.swift)
// with the same semantics, and CONTEXT.md uses "Mesocycle phase" as the
// canonical term. Slice 1 reuses MesocyclePhase rather than introducing a
// duplicate.

import Foundation

// MARK: - SetIntent (ADR-0005, explicitly enumerated)

/// The required field on every set; gates which sets contribute to e1RM,
/// volume aggregation, and RPE calibration.
enum SetIntent: String, Codable, Sendable, Hashable, CaseIterable {
    case warmup
    case top
    case backoff
    case technique
    case amrap
}

// MARK: - AxisConfidence (ADR-0005, explicitly enumerated)

/// Per-axis confidence on PatternProfile / MuscleProfile / ExerciseProfile.
/// Replaces the prior global confidence that lied when half the patterns
/// had no data. Calibration review fires when ≥4 of 6 major patterns
/// reach .established.
enum AxisConfidence: String, Codable, Sendable, Hashable, CaseIterable {
    case bootstrapping
    case calibrating
    case established
    case seasoned
}

// MARK: - StimulusDimension (ADR-0005 + CONTEXT.md)

/// Per-set training stimulus classification; drives two-dimensional recovery.
/// Warmup and technique sets classify as nil at the call site (Optional).
enum StimulusDimension: String, Codable, Sendable, Hashable, CaseIterable {
    case neuromuscular
    case metabolic
    case both
}

// MARK: - Severity (standard medical taxonomy; ADR-0005 references .mild)

/// Severity of an active limitation. AI-inferred limitations cap at .mild
/// until the user confirms (per ADR-0005 — corroboration thresholds).
enum Severity: String, Codable, Sendable, Hashable, CaseIterable {
    case mild
    case moderate
    case severe
}

// MARK: - BodyJoint (training-relevant joints)

/// Anatomical joints tracked by ActiveLimitation when the limitation
/// is joint-scoped rather than pattern- or muscle-scoped.
enum BodyJoint: String, Codable, Sendable, Hashable, CaseIterable {
    case shoulder
    case elbow
    case wrist
    case hip
    case knee
    case ankle
    case lowerBack = "lower_back"
    case neck
}

// MARK: - ProjectionProgress (per-pattern projection state)

/// State of progression toward a PatternProjection's floor/stretch targets.
enum ProjectionProgress: String, Codable, Sendable, Hashable, CaseIterable {
    case behind
    case onTrack  = "on_track"
    case ahead
    case achieved
}

// MARK: - ProgressionTrend (PatternProfile.trend, MuscleProfile.stagnationStatus)

/// Capability trajectory used by both pattern-level trend (replacing
/// StagnationService output) and muscle-level stagnation status per
/// ADR-0005's service-supersession notes.
enum ProgressionTrend: String, Codable, Sendable, Hashable, CaseIterable {
    case progressing
    case plateaued
    case declining
}

// MARK: - LimitationSubject (sum type — pattern | muscle | joint)

/// What an ActiveLimitation / ClearedLimitation applies to. Per ADR-0005
/// limitations are scoped per pattern, per muscle, or per joint.
///
/// Codable shape: `{"kind": "pattern", "value": "horizontal_push"}` etc.
enum LimitationSubject: Sendable, Hashable {
    case pattern(MovementPattern)
    case muscle(MuscleGroup)
    case joint(BodyJoint)
}

extension LimitationSubject: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case pattern, muscle, joint }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pattern:
            self = .pattern(try container.decode(MovementPattern.self, forKey: .value))
        case .muscle:
            self = .muscle(try container.decode(MuscleGroup.self, forKey: .value))
        case .joint:
            self = .joint(try container.decode(BodyJoint.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pattern(let p):
            try container.encode(Kind.pattern, forKey: .kind)
            try container.encode(p, forKey: .value)
        case .muscle(let m):
            try container.encode(Kind.muscle, forKey: .kind)
            try container.encode(m, forKey: .value)
        case .joint(let j):
            try container.encode(Kind.joint, forKey: .kind)
            try container.encode(j, forKey: .value)
        }
    }
}
