// MovementPattern.swift
// ProjectApex — Models
//
// Motion taxonomy used by ExerciseLibrary entries and the trainee model's
// PatternProfile keying. See ADR-0005 and CONTEXT.md.
//
// Cases mirror the eight pattern strings present in the codebase prior to
// Slice 1's typed-enum migration. .calves and .core are deliberately absent —
// calves contribute to the .legs MuscleGroup via PrimaryMuscle.muscleGroup,
// and core is excluded from the trainee model entirely.

import Foundation

enum MovementPattern: String, Codable, Sendable, Hashable, CaseIterable {
    case hipHinge       = "hip_hinge"
    case horizontalPull = "horizontal_pull"
    case horizontalPush = "horizontal_push"
    case isolation
    case lunge
    case squat
    case verticalPull   = "vertical_pull"
    case verticalPush   = "vertical_push"

    /// Human-readable label for UI surfaces (e.g. the heavy-reassessment banner, #258).
    /// Title-cased, space-separated — consistent with how SystemPrompt_SessionPlan.txt
    /// already refers to patterns ("horizontal push", "hip hinge").
    var displayName: String {
        switch self {
        case .hipHinge:       return "Hip Hinge"
        case .horizontalPull: return "Horizontal Pull"
        case .horizontalPush: return "Horizontal Push"
        case .isolation:      return "Isolation"
        case .lunge:          return "Lunge"
        case .squat:          return "Squat"
        case .verticalPull:   return "Vertical Pull"
        case .verticalPush:   return "Vertical Push"
        }
    }
}
