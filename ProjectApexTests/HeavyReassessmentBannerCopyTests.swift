// HeavyReassessmentBannerCopyTests.swift
// ProjectApexTests
//
// Verifies the pure copy helper for the pre-workout heavy-reassessment banner
// (#258, Slice D+E1). The SwiftUI body isn't unit-testable, so the copy logic
// lives in HeavyReassessmentBannerCopy and is exercised here.

import Testing
import Foundation
@testable import ProjectApex

@Suite("HeavyReassessmentBannerCopy")
struct HeavyReassessmentBannerCopyTests {

    /// HeavyReassessmentSignal is a simple struct — construct it directly.
    private func signal(_ patterns: [MovementPattern]) -> HeavyReassessmentSignal {
        HeavyReassessmentSignal(
            triggeringSessionCount: 18,
            sessionsSinceTriggered: 2,
            recentlyAdvancedPatterns: patterns
        )
    }

    @Test("names up to three patterns via displayName — no raw snake_case tokens leak")
    func threePatternsUseDisplayNames() {
        let body = HeavyReassessmentBannerCopy.body(
            for: signal([.squat, .horizontalPush, .hipHinge])
        )
        #expect(body.contains("Squat"))
        #expect(body.contains("Horizontal Push"))
        #expect(body.contains("Hip Hinge"))
        #expect(!body.contains("_"), "body leaked a raw machine token: \(body)")
    }

    @Test("caps at three named patterns then collapses the remainder to \"and more\"")
    func fourOrMorePatternsCapAtThree() {
        let body = HeavyReassessmentBannerCopy.body(
            for: signal([.squat, .horizontalPush, .hipHinge, .lunge])
        )
        #expect(body.contains("and more"))
        // The fourth pattern's display name must NOT be spelled out.
        #expect(!body.contains("Lunge"), "fourth pattern should be folded into \"and more\": \(body)")
    }

    @Test("empty pattern list returns the generic fallback — no names, no \", and\" artifacts")
    func emptyPatternsUseGenericFallback() {
        let body = HeavyReassessmentBannerCopy.body(for: signal([]))
        #expect(body == "You've made broad progress lately — a good moment to revisit your goal.")
        #expect(!body.contains(", and"), "fallback must not contain empty-join artifacts: \(body)")
        // Defensive: the generic line should name no pattern.
        for pattern in MovementPattern.allCases {
            #expect(
                !body.contains(pattern.displayName),
                "fallback should name no patterns, found \(pattern.displayName): \(body)"
            )
        }
    }

    @Test("title is a constant, tone-stable affordance")
    func titleIsConstant() {
        #expect(HeavyReassessmentBannerCopy.title == "Your training has leveled up")
    }
}

// MARK: - Welcome-back banner copy (#318 U3)

/// Verifies PreWorkoutView.welcomeBackMessage — the pure copy helper for the
/// welcome-back banner. Pending days may claim break-aware adjustment (the
/// session hasn't been generated yet); already-generated days must not.
@Suite("WelcomeBackBannerCopy")
struct WelcomeBackBannerCopyTests {

    @Test("pending day under 28 days claims the session will account for the break")
    func pendingUnder28Days() {
        let message = PreWorkoutView.welcomeBackMessage(days: 15, status: .pending)
        #expect(message.contains("Today's session will account for the break."))
        #expect(message.contains("15 days"))
    }

    @Test("pending day at 28+ days keeps the stronger recovery-session variant")
    func pendingAtLeast28Days() {
        let message = PreWorkoutView.welcomeBackMessage(days: 30, status: .pending)
        #expect(message.contains("Today is a recovery session with reduced volume"))
    }

    @Test("generated day claims no break-aware adjustment — session predates the break")
    func generatedClaimsNoAdjustment() {
        let message = PreWorkoutView.welcomeBackMessage(days: 30, status: .generated)
        #expect(message.contains("This session was planned before your break — take it easy out there."))
        #expect(!message.contains("account for the break"))
        #expect(!message.contains("recovery session"))
        #expect(!message.contains("adjusted"))
    }
}

// MARK: - Banner dismissal semantics (#318 U8 / J-F7)

/// Verifies BannerDismissals — the durable, event-fingerprinted dismissal
/// store behind the pre-workout banners' X buttons. Every case runs against
/// an ephemeral injected UserDefaults suite; `.standard` is never touched.
@Suite("BannerDismissals")
struct BannerDismissalsTests {

    /// Runs `body` against a uniquely-named UserDefaults suite, then wipes it.
    private func withEphemeralDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "BannerDismissalsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    // MARK: Welcome-back (keyed on the last-session date that produced the gap)

    @Test("welcome-back: shows with no stored dismissal, hides after dismissing the same last-session date")
    func welcomeBackDismissalSticks() {
        withEphemeralDefaults { defaults in
            let store = BannerDismissals(defaults: defaults)
            let fp = BannerDismissals.welcomeBackFingerprint(lastSessionDateKey: "2026-05-20")
            #expect(store.shouldShow(.welcomeBack, fingerprint: fp))
            store.dismiss(.welcomeBack, fingerprint: fp)
            #expect(!store.shouldShow(.welcomeBack, fingerprint: fp))
        }
    }

    @Test("welcome-back: re-arms when a NEW last-session date produces the gap")
    func welcomeBackReArmsOnNewLastSessionDate() {
        withEphemeralDefaults { defaults in
            let store = BannerDismissals(defaults: defaults)
            store.dismiss(
                .welcomeBack,
                fingerprint: BannerDismissals.welcomeBackFingerprint(lastSessionDateKey: "2026-05-20")
            )
            let newGap = BannerDismissals.welcomeBackFingerprint(lastSessionDateKey: "2026-06-10")
            #expect(store.shouldShow(.welcomeBack, fingerprint: newGap))
        }
    }

    // MARK: Heavy reassessment (keyed on triggeringSessionCount)

    @Test("heavy-reassessment: hides after dismissal, re-arms on a NEW triggeringSessionCount")
    func heavyReassessmentReArmsOnNewTrigger() {
        withEphemeralDefaults { defaults in
            let store = BannerDismissals(defaults: defaults)
            let fired18 = BannerDismissals.heavyReassessmentFingerprint(triggeringSessionCount: 18)
            #expect(store.shouldShow(.heavyReassessment, fingerprint: fired18))
            store.dismiss(.heavyReassessment, fingerprint: fired18)
            #expect(!store.shouldShow(.heavyReassessment, fingerprint: fired18))
            // A later GPA fire carries a new triggering count → banner re-arms.
            let fired24 = BannerDismissals.heavyReassessmentFingerprint(triggeringSessionCount: 24)
            #expect(store.shouldShow(.heavyReassessment, fingerprint: fired24))
        }
    }

    // MARK: Calibration (keyed on the watermark pair, #305 semantics)

    @Test("calibration: hides after dismissal, re-arms when the watermark pair moves (re-calibration)")
    func calibrationReArmsOnWatermarkMove() {
        withEphemeralDefaults { defaults in
            let store = BannerDismissals(defaults: defaults)
            let firedAt = Date(timeIntervalSince1970: 1_780_000_000)
            let firstCalibration = BannerDismissals.calibrationFingerprint(
                calibrationReviewFiredAt: firedAt,
                lastRecalibratedAtSessionCount: nil
            )
            #expect(store.shouldShow(.calibrationReview, fingerprint: firstCalibration))
            store.dismiss(.calibrationReview, fingerprint: firstCalibration)
            #expect(!store.shouldShow(.calibrationReview, fingerprint: firstCalibration))
            // Re-calibration moves the watermark (same firedAt, new recal count) → re-arms.
            let recalibrated = BannerDismissals.calibrationFingerprint(
                calibrationReviewFiredAt: firedAt,
                lastRecalibratedAtSessionCount: 24
            )
            #expect(store.shouldShow(.calibrationReview, fingerprint: recalibrated))
        }
    }

    @Test("calibration fingerprint is a stable function of the watermark pair — nil components stay distinct")
    func calibrationFingerprintIsStable() {
        let firedAt = Date(timeIntervalSince1970: 1_780_000_000)
        // Same inputs → same fingerprint (deterministic key, no unstable formatting).
        #expect(
            BannerDismissals.calibrationFingerprint(calibrationReviewFiredAt: firedAt, lastRecalibratedAtSessionCount: 12)
                == BannerDismissals.calibrationFingerprint(calibrationReviewFiredAt: firedAt, lastRecalibratedAtSessionCount: 12)
        )
        // Each component of the pair moving changes the fingerprint.
        let base = BannerDismissals.calibrationFingerprint(calibrationReviewFiredAt: firedAt, lastRecalibratedAtSessionCount: nil)
        #expect(base != BannerDismissals.calibrationFingerprint(calibrationReviewFiredAt: nil, lastRecalibratedAtSessionCount: nil))
        #expect(base != BannerDismissals.calibrationFingerprint(calibrationReviewFiredAt: firedAt, lastRecalibratedAtSessionCount: 12))
    }

    // MARK: Independence

    @Test("dismissing one banner never hides another")
    func bannersDismissIndependently() {
        withEphemeralDefaults { defaults in
            let store = BannerDismissals(defaults: defaults)
            store.dismiss(
                .welcomeBack,
                fingerprint: BannerDismissals.welcomeBackFingerprint(lastSessionDateKey: "2026-05-20")
            )
            #expect(store.shouldShow(
                .heavyReassessment,
                fingerprint: BannerDismissals.heavyReassessmentFingerprint(triggeringSessionCount: 18)
            ))
            #expect(store.shouldShow(
                .calibrationReview,
                fingerprint: BannerDismissals.calibrationFingerprint(
                    calibrationReviewFiredAt: Date(timeIntervalSince1970: 1_780_000_000),
                    lastRecalibratedAtSessionCount: nil
                )
            ))
        }
    }
}
