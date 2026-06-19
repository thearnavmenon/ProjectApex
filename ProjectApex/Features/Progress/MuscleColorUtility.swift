// MuscleColorUtility.swift
// ProjectApex — Features/Progress
//
// Single source of truth for muscle group → Color mapping used across the
// Progress tab. Does not replace the copy-pasted versions in other files;
// new Progress-tab code references this instead.
//
// Palette tuned for the Brutalist Athletic identity (#524): muted, non-rainbow
// tones that sit inside the pure-black + condensed-slab system. Used only where
// colour carries data (the volume stacked-bar chart + its legend) — chest is
// deliberately NOT lime, since volt-lime is reserved for the screen's accent.

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
        case .chest:       return Color(red: 0.86, green: 0.52, blue: 0.50) // muted coral (NOT lime)
        case .back:        return Color(red: 0.44, green: 0.58, blue: 0.74) // muted blue
        case .shoulders:   return Color(red: 0.70, green: 0.52, blue: 0.74) // muted violet
        case .quads:       return Color(red: 0.85, green: 0.66, blue: 0.30) // muted gold
        case .hamstrings:  return Color(red: 0.40, green: 0.72, blue: 0.66) // muted teal
        case .glutes:      return Color(red: 0.80, green: 0.52, blue: 0.64) // muted rose
        case .biceps:      return Color(red: 0.60, green: 0.56, blue: 0.80) // muted lavender
        case .triceps:     return Color(red: 0.80, green: 0.72, blue: 0.48) // muted sand
        case .calves:      return Color(red: 0.52, green: 0.60, blue: 0.74) // muted slate
        }
    }
}
