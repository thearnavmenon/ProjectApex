// Models/ReadinessScore.swift
// ProjectApex
//
// ReadinessScore encapsulates the computed readiness value and its
// derived label and tint colour, per TDD §11.2.
//
// Full computation logic (HRV delta + sleep) is implemented in P4-T01/P4-T02.
// For now this type is used by the stub HealthKitService and PreWorkoutView.

import SwiftUI

// MARK: - ReadinessScore

/// A computed readiness value (0–100) with a label and UI tint colour.
nonisolated struct ReadinessScore: Sendable {

    /// Numeric readiness value in range 0–100.
    let score: Int

    // MARK: - Label

    enum Label: String, Sendable {
        case optimal  = "Optimal"
        case good     = "Good"
        case reduced  = "Reduced"
        case poor     = "Poor"
    }

    var label: Label {
        switch score {
        case 80...: return .optimal
        case 60..<80: return .good
        case 40..<60: return .reduced
        default: return .poor
        }
    }

    // MARK: - Tint Colour (per TDD §UI/UX)

    /// The accent colour that bleeds 15% into the session background.
    var tintColor: Color {
        switch label {
        case .optimal: return Color(red: 0.23, green: 0.56, blue: 1.00)   // #3A8EFF
        case .good:    return Color(red: 0.54, green: 0.60, blue: 0.69)   // #8A9AAF
        case .reduced: return Color(red: 0.91, green: 0.63, blue: 0.19)   // #E8A030
        case .poor:    return Color(red: 0.91, green: 0.28, blue: 0.19)   // #E84830
        }
    }

    // MARK: - Factory

    /// Neutral readiness used when HealthKit data is unavailable.
    /// Scores 50 (Reduced threshold), which applies a warm amber tint.
    static let neutral = ReadinessScore(score: 50)

    /// Constructs a ReadinessScore from a raw 0–100 value, clamped to range.
    init(score: Int) {
        self.score = max(0, min(100, score))
    }
}
