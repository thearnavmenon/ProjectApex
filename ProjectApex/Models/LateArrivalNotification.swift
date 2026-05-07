// Models/LateArrivalNotification.swift
// ProjectApex — Phase 2 / Slice A3 / issue #74
//
// Soft post-session notification surfaced to the user when the Edge
// Function refuses a session-completion event because its `loggedAt`
// is earlier than the trainee model's last-applied watermark
// (ADR-0008 §"Late arrival"). The notification's existence on the
// post-session summary is the alpha cohort's signal channel for
// whether late-arrival is a real problem; the user's training history
// is preserved either way.
//
// Lifecycle: enqueued by `TraineeModelUpdateJob` on `late_arrival:true`
// HTTP responses, dequeued by `PostWorkoutSummaryView` on appearance,
// dismissed-on-tap.
//
// Forward-compat: `sessionId`, `incomingLoggedAt`, and `watermark` are
// optional. A3-shipped notifications populate only `id`, `message`, and
// `receiptDate`; A12 will populate the optional fields when the richer
// Edge Function response shape ships. Locking the struct schema now
// avoids an awkward UserDefaults-data migration later.

import Foundation

// MARK: - LateArrivalNotification

/// Codable record of a single late-arrival event for post-session UI.
struct LateArrivalNotification: Codable, Equatable, Identifiable {
    /// Per-notification identifier — distinct from `sessionId` so that the
    /// UI can dismiss one without disturbing other queued notifications.
    let id: UUID

    /// User-facing copy. Locked verbatim to ADR-0008; see `lockedMessage`.
    let message: String

    /// Wall-clock receipt time on the client. Used so the UI can display
    /// "Logged X minutes ago" detail if desired.
    let receiptDate: Date

    /// Refused session's identifier. Populated when A12's richer response
    /// shape ships; nil for A3-built notifications.
    let sessionId: UUID?

    /// `loggedAt` of the refused session. Populated when A12's richer
    /// response shape ships; nil for A3-built notifications.
    let incomingLoggedAt: Date?

    /// Watermark the refused session was compared against. Populated when
    /// A12's richer response shape ships; nil for A3-built notifications.
    let watermark: Date?
}

extension LateArrivalNotification {
    /// User-facing copy locked verbatim by ADR-0008 §"Decision". Any change
    /// to this string MUST come back through ADR-0008 — paraphrases are a
    /// regression. The corresponding test in `TraineeModelUpdateJobTests`
    /// hard-codes the same literal so drift is caught at CI time.
    static let lockedMessage =
        "This session was logged after later sessions and won't update your training profile, but the history is preserved."
}
