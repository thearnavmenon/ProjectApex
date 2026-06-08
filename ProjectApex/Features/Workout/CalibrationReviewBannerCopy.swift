// Features/Workout/CalibrationReviewBannerCopy.swift
// ProjectApex — #269
//
// Pure copy logic for the pre-workout calibration-review banner. The SwiftUI
// body isn't unit-testable, so the copy lives here and is exercised directly
// by CalibrationReviewBannerCopyTests.
//
// The banner is a one-time affordance: constant title + tone, naming the
// patterns the calibration review set targets for, and offering a "Review
// targets" CTA into the read-only projection screen.

import Foundation

enum CalibrationReviewBannerCopy {

    /// Constant banner title — tone is fixed here (#269).
    static let title = "Your starting targets are ready"

    /// Banner body for a calibration-review signal (#269). Names up to 3
    /// patterns via `MovementPattern.displayName`, collapsing the remainder to
    /// "and more" beyond 3. Returns a generic fallback when the projection list
    /// is empty (defensive — the signal isn't produced when empty).
    static func body(for signal: CalibrationReviewSignal) -> String {
        let patterns = signal.projections.map(\.pattern)
        guard !patterns.isEmpty else {
            return "We've set your starting targets — take a look."
        }
        let named = patterns.prefix(3).map(\.displayName)
        let listed = patterns.count > 3
            ? named.joined(separator: ", ") + ", and more"
            : naturalJoin(named)
        return "We've set floor and stretch targets for your \(listed) — take a look."
    }

    /// Joins names with commas and a final "and": ["a"] → "a";
    /// ["a","b"] → "a and b"; ["a","b","c"] → "a, b, and c" (Oxford comma at 3+).
    private static func naturalJoin(_ names: [String]) -> String {
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head), and \(names[names.count - 1])"
        }
    }
}
