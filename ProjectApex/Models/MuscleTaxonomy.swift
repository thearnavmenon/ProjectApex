// MuscleTaxonomy.swift
// ProjectApex — Models
//
// Two-level muscle taxonomy per ADR-0005's "Two-level muscle taxonomy"
// amendment (added in Slice 1):
//
//  - PrimaryMuscle: 9 fine-grained cases used by ExerciseLibrary for
//    AI prescription reasoning at exercise-selection time. Quads,
//    hamstrings, glutes, and calves are first-class so the model can
//    reason about leg-muscle balance.
//
//  - MuscleGroup: locked-six cases used by the trainee model as the
//    aggregation key for capability tracking, EWMA, recovery state,
//    and prescription accuracy. Leg subgroups collapse to .legs via
//    PrimaryMuscle.muscleGroup.
//
// Core is excluded from both — core training stimuli don't fit the
// EWMA-over-top-sets model and the trainee model has no axis to
// track core capability.

import Foundation

enum PrimaryMuscle: String, Codable, Sendable, Hashable, CaseIterable {
    case back, chest, biceps, shoulders, triceps
    case quads, hamstrings, glutes, calves
}

enum MuscleGroup: String, Codable, Sendable, Hashable, CaseIterable {
    case back, chest, biceps, shoulders, triceps, legs
}

extension PrimaryMuscle {
    /// Collapses leg subgroups (quads/hamstrings/glutes/calves) to .legs;
    /// upper-body muscles map 1:1.
    var muscleGroup: MuscleGroup {
        switch self {
        case .back:      return .back
        case .chest:     return .chest
        case .biceps:    return .biceps
        case .shoulders: return .shoulders
        case .triceps:   return .triceps
        case .quads, .hamstrings, .glutes, .calves: return .legs
        }
    }
}
