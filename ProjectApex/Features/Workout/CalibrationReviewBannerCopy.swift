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

    /// Banner title — first calibration vs a re-calibration (#269, #305). A
    /// re-calibration celebrates the level-up; the first calibration introduces
    /// the targets.
    static func title(isRecalibration: Bool) -> String {
        isRecalibration ? "You've leveled up" : "Your starting targets are ready"
    }

    /// Banner body for a calibration-review signal. For a re-calibration (#305)
    /// it names the patterns that outgrew their targets and frames it as
    /// SUSTAINED progress (the trigger is the recent-window median, not a single
    /// PR). For a first calibration (#269) it introduces the new targets. Both
    /// name up to 3 patterns via `MovementPattern.displayName`, collapsing the
    /// remainder to "and more" beyond 3.
    static func body(for signal: CalibrationReviewSignal) -> String {
        if signal.isRecalibration {
            let patterns = signal.recalibratedPatterns
            let named = patterns.prefix(3).map(\.displayName)
            let listed = patterns.count > 3
                ? named.joined(separator: ", ") + ", and more"
                : naturalJoin(named)
            let target = patterns.count > 1 ? "targets" : "target"
            return "You've consistently climbed past your \(listed) \(target) — here's a higher one."
        }
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
