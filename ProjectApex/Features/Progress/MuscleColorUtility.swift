// MuscleColorUtility.swift
// ProjectApex — Features/Progress
//
// Single source of truth for muscle group → Color mapping used across the
// Progress tab. Does not replace the copy-pasted versions in other files;
// new Progress-tab code references this instead.

import SwiftUI

nonisolated enum MuscleColor {

    /// Returns the accent Color for a coarse muscle group string.
    /// Matches the vocabulary used by ExerciseLibrary.primaryMuscle and set_logs.primary_muscle.
    static func color(for muscle: String) -> Color {
        switch muscle.lowercased() {
        case "chest":       return Color(red: 0.96, green: 0.36, blue: 0.36)
        case "back":        return Color(red: 0.30, green: 0.60, blue: 0.96)
        case "shoulders":   return Color(red: 0.96, green: 0.60, blue: 0.20)
        case "quads":       return Color(red: 0.30, green: 0.80, blue: 0.40)
        case "hamstrings":  return Color(red: 0.20, green: 0.70, blue: 0.65)
        case "glutes":      return Color(red: 0.90, green: 0.45, blue: 0.70)
        case "biceps":      return Color(red: 0.65, green: 0.40, blue: 0.90)
        case "triceps":     return Color(red: 0.96, green: 0.80, blue: 0.20)
        case "calves":      return Color(red: 0.40, green: 0.45, blue: 0.90)
        case "core":        return Color(red: 0.25, green: 0.80, blue: 0.70)
        default:            return Color(white: 0.55)
        }
    }
}
