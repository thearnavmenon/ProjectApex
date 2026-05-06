// SetCompletionFlag.swift
// ProjectApex — Models
//
// User-reported flags raised on the rep/RPE confirmation sheet
// post-set (Slice 6 / #10). High-signal for AI adaptation — the user
// has the most accurate information about their own state immediately
// after completing the set.
//
// IMPORTANT: this is the USER's output (post-set self-report), distinct
// from `SafetyFlag` (the AI's input — "the AI noted user mentioned pain
// in earlier voice notes"). Different concepts, different fields, both
// kept. The semantic context (which DTO carries them) disambiguates:
//   - SafetyFlag    on SetPrescription (AI → user)
//   - SetCompletionFlag on SetLog       (user → AI)
//
// Persistence: Slice 6 ships these CLIENT-SIDE only (γ pattern, same as
// SetLog.intent). Threaded into the in-memory WorkoutContext so the
// AI's next-set prescription within the same session can react. The
// DB column + cross-session reasoning land in #43.

import Foundation

enum SetCompletionFlag: String, Codable, Sendable, Hashable, CaseIterable {
    /// "Something hurt during this set." High-priority signal — should
    /// reduce load or modify movement next set; consider adding
    /// `painReported` to the next prescription's safety_flags.
    case pain
    /// "Form broke down." User reports their technique degraded under
    /// load. Consider reducing reps or weight to restore quality.
    case formBreakdown = "form_breakdown"
}
