// Features/Workout/BannerDismissals.swift
// ProjectApex — #318 (finding J-F7, fix-now parts)
//
// Durable, event-fingerprinted dismissal state for the pre-workout banners.
//
// Before #318 the welcome-back, heavy-reassessment, and calibration banners
// were dismissed via transient @State Bool flags: dismissal was forgotten on
// every view rebuild, and a dismissal didn't track WHICH event it dismissed.
//
// This helper stores, per banner, the fingerprint of the event that was
// dismissed (UserDefaults-backed). A banner shows only when its current event
// fingerprint differs from the stored dismissed one; dismissing writes the
// current fingerprint. Fingerprints are STABLE keys (date strings / session
// counts — never formatting-unstable floats), so:
//
//   • welcome-back re-arms when a NEW last-session date produces a gap,
//   • heavy-reassessment re-arms when a NEW global-phase-advance fires
//     (new triggeringSessionCount),
//   • calibration re-arms when the watermark pair moves — i.e. on
//     re-calibration (#305 semantics).
//
// The X (dismiss) writes NO durable server-side ack — sheet-save remains the
// only durable-ack path. The full banner-queue redesign is deferred to #327.

import Foundation

struct BannerDismissals {

    /// The three pre-workout banners with locally-dismissable X buttons.
    /// (The first-session banner has no X and is not tracked here.)
    enum Banner: String, CaseIterable {
        case welcomeBack       = "banner_dismissed_welcome_back"
        case heavyReassessment = "banner_dismissed_heavy_reassessment"
        case calibrationReview = "banner_dismissed_calibration_review"
    }

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests run against an ephemeral suite and
    /// never pollute `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True when the banner should show: no dismissal stored yet, or the
    /// current event fingerprint differs from the dismissed one.
    func shouldShow(_ banner: Banner, fingerprint: String) -> Bool {
        defaults.string(forKey: banner.rawValue) != fingerprint
    }

    /// Records that the user dismissed the banner for the given event.
    func dismiss(_ banner: Banner, fingerprint: String) {
        defaults.set(fingerprint, forKey: banner.rawValue)
    }

    // MARK: - Fingerprint builders (pure; stable keys only)

    /// Keyed on the last-session date that produced the gap — the raw
    /// `workout_sessions.session_date` string ("yyyy-MM-dd") of the most
    /// recent completed session. A newer last session ⇒ a new fingerprint ⇒
    /// a later ≥14-day gap re-arms the banner.
    static func welcomeBackFingerprint(lastSessionDateKey: String) -> String {
        "last_session:\(lastSessionDateKey)"
    }

    /// Keyed on `HeavyReassessmentSignal.triggeringSessionCount` (equal to
    /// `TraineeModel.lastGlobalPhaseAdvanceFiredAtSessionCount`) — stable, and
    /// it mirrors how the durable ack is keyed in
    /// `acknowledgedTriggeringSessionCounts`. A later GPA fire carries a new
    /// count ⇒ the banner re-arms.
    static func heavyReassessmentFingerprint(triggeringSessionCount: Int) -> String {
        "gpa_fired_at:\(triggeringSessionCount)"
    }

    /// Keyed on the existing watermark pair
    /// (`ProjectionState.calibrationReviewFiredAt`,
    /// `ProjectionState.lastRecalibratedAtSessionCount`). The date is reduced
    /// to whole epoch seconds (Int) — never a formatted float — and the
    /// floor/stretch target values are deliberately NOT part of the key.
    /// Re-calibration moves the watermark ⇒ the banner re-arms (#305).
    static func calibrationFingerprint(
        calibrationReviewFiredAt: Date?,
        lastRecalibratedAtSessionCount: Int?
    ) -> String {
        let firedAt = calibrationReviewFiredAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let recalAt = lastRecalibratedAtSessionCount.map(String.init) ?? "none"
        return "calibration_fired_at:\(firedAt)|recalibrated_at:\(recalAt)"
    }
}
