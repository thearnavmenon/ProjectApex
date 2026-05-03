// MovementPattern.swift
// ProjectApex — Models
//
// Motion taxonomy used by ExerciseLibrary entries, MovementPatternPhaseState,
// and the trainee model's PatternProfile keying. See ADR-0005 and CONTEXT.md.
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
}
