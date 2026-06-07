// Features/Workout/HeavyReassessmentBannerCopy.swift
// ProjectApex — P5-D06 (#258)
//
// Pure copy logic for the pre-workout heavy-reassessment banner. The SwiftUI
// body isn't unit-testable, so the copy lives here and is exercised directly
// by HeavyReassessmentBannerCopyTests.
//
// The banner is a stable affordance: constant title + tone, NO per-
// sessionsSinceTriggered calibration (the LLM prompt handles tone per ADR-0005;
// the banner just names what advanced and offers a goal-review CTA).

import Foundation

enum HeavyReassessmentBannerCopy {

    /// Constant banner title — tone is fixed here; calibration lives in the LLM
    /// prompt, not the banner (#258).
    static let title = "Your training has leveled up"

    /// Banner body for a heavy-reassessment signal (#258). Names up to 3
    /// recently-advanced patterns via `MovementPattern.displayName`, collapsing
    /// the remainder to "and more" beyond 3. Returns a generic fallback when the
    /// pattern list is empty (the normal case late in the cooldown window).
    static func body(for signal: HeavyReassessmentSignal) -> String {
        let patterns = signal.recentlyAdvancedPatterns
        guard !patterns.isEmpty else {
            return "You've made broad progress lately — a good moment to revisit your goal."
        }
        let named = patterns.prefix(3).map(\.displayName)
        let listed = patterns.count > 3
            ? named.joined(separator: ", ") + ", and more"
            : naturalJoin(named)
        return "Your \(listed) have all moved up lately — a good moment to revisit your goal."
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
