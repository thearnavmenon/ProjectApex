// MuscleColorUtility.swift
// ProjectApex — Features/Progress
//
// Single source of truth for muscle group → Color mapping used across the
// Progress tab. Does not replace the copy-pasted versions in other files;
// new Progress-tab code references this instead.

import SwiftUI

nonisolated enum MuscleColor {

    /// Returns the accent Color for a coarse muscle group string.
    /// Matches the vocabulary used by ExerciseLibrary.primaryMuscle (typed
    /// PrimaryMuscle as of Slice 1) and set_logs.primary_muscle (still a
    /// String column at the persistence boundary). Unknown values — including
    /// "core" (excluded from the locked-six taxonomy per ADR-0005) — return
    /// the default grey.
    static func color(for muscle: String) -> Color {
        guard let primary = PrimaryMuscle(rawValue: muscle.lowercased()) else {
            return Color(white: 0.55)
        }
        return color(for: primary)
    }

    /// Typed-switch overload — preferred for new call sites.
    static func color(for muscle: PrimaryMuscle) -> Color {
        switch muscle {
        case .chest:       return Color(red: 0.96, green: 0.36, blue: 0.36)
        case .back:        return Color(red: 0.30, green: 0.60, blue: 0.96)
        case .shoulders:   return Color(red: 0.96, green: 0.60, blue: 0.20)
        case .quads:       return Color(red: 0.30, green: 0.80, blue: 0.40)
        case .hamstrings:  return Color(red: 0.20, green: 0.70, blue: 0.65)
        case .glutes:      return Color(red: 0.90, green: 0.45, blue: 0.70)
        case .biceps:      return Color(red: 0.65, green: 0.40, blue: 0.90)
        case .triceps:     return Color(red: 0.96, green: 0.80, blue: 0.20)
        case .calves:      return Color(red: 0.40, green: 0.45, blue: 0.90)
        }
    }
}
