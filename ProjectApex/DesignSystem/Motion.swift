// Motion.swift
// ProjectApex — DesignSystem
//
// Motion is a first-class identity pillar — but restrained (DESIGN.md §Motion):
// expressive motion is reserved for the ≤4 bookends; routine navigation is fast
// and invisible. Reduce Motion replaces every expressive transition with a 150ms
// crossfade (haptics kept).

import SwiftUI

enum Motion {
    // MARK: Expressive — bookends ONLY (app open, workout start, post-workout
    // reveal, milestone celebration). Nowhere else.

    /// `transition-bookend` — drain-and-rise: colour washes away, the next screen
    /// rises through it.
    static let bookend = Animation.spring(response: 0.5, dampingFraction: 0.85)
    /// `gauge-focus` — iris/aperture segments rotate into alignment, tiny overshoot.
    static let gaugeFocus = Animation.spring(response: 0.5, dampingFraction: 0.7)
    /// `celebrate-ratchet` — the floor line clicks up one notch with a confident
    /// bounce (paired with the milestone haptic).
    static let celebrateRatchet = Animation.spring(response: 0.4, dampingFraction: 0.6)

    // MARK: Workhorse — everything else.

    /// `transition-nav` — routine nav should feel like nothing.
    static let nav = Animation.easeOut(duration: 0.15)
    /// `card-morph` — the live session card reshapes between sets via shared-element,
    /// never a hard cut.
    static let cardMorph = Animation.easeInOut(duration: 0.35)
    /// `log-settle` — one-tap "done" presses down and locks. Crisp, no bounce.
    static let logSettle = Animation.easeOut(duration: 0.2)

    /// Reduce Motion fallback — every expressive transition becomes a 150ms crossfade.
    static let reduceMotionCrossfade = Animation.easeInOut(duration: 0.15)
}
