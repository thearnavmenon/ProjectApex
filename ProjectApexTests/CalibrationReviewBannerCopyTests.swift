// CalibrationReviewBannerCopyTests.swift
// ProjectApexTests
//
// Verifies the pure copy helper for the pre-workout calibration-review banner
// (#269). The SwiftUI body isn't unit-testable, so the copy logic lives in
// CalibrationReviewBannerCopy and is exercised here.

import Testing
import Foundation
@testable import ProjectApex

@Suite("CalibrationReviewBannerCopy")
struct CalibrationReviewBannerCopyTests {

    /// Builds a signal naming the given patterns (floor/stretch values are
    /// irrelevant to the copy — only the pattern displayNames are surfaced).
    private func signal(_ patterns: [MovementPattern]) -> CalibrationReviewSignal {
        CalibrationReviewSignal(
            projections: patterns.map {
                PatternProjection(pattern: $0, floor: 100, stretch: 110, progress: .onTrack)
            }
        )
    }

    /// A re-calibration signal (#305): the given patterns just outgrew their band.
    private func recalSignal(_ patterns: [MovementPattern]) -> CalibrationReviewSignal {
        CalibrationReviewSignal(
            projections: patterns.map {
                PatternProjection(pattern: $0, floor: 100, stretch: 110, progress: .onTrack)
            },
            recalibratedPatterns: patterns
        )
    }

    @Test("names a single pattern via displayName — no raw snake_case tokens leak")
    func onePatternUsesDisplayName() {
        let body = CalibrationReviewBannerCopy.body(for: signal([.horizontalPush]))
        #expect(body.contains("Horizontal Push"))
        #expect(!body.contains("_"), "body leaked a raw machine token: \(body)")
    }

    @Test("names up to three patterns via displayName — no raw snake_case tokens leak")
    func threePatternsUseDisplayNames() {
        let body = CalibrationReviewBannerCopy.body(
            for: signal([.squat, .horizontalPush, .hipHinge])
        )
        #expect(body.contains("Squat"))
        #expect(body.contains("Horizontal Push"))
        #expect(body.contains("Hip Hinge"))
        #expect(!body.contains("_"), "body leaked a raw machine token: \(body)")
    }

    @Test("caps at three named patterns then collapses the remainder to \"and more\"")
    func fourOrMorePatternsCapAtThree() {
        let body = CalibrationReviewBannerCopy.body(
            for: signal([.squat, .horizontalPush, .hipHinge, .lunge])
        )
        #expect(body.contains("and more"))
        // The fourth pattern's display name must NOT be spelled out.
        #expect(!body.contains("Lunge"), "fourth pattern should be folded into \"and more\": \(body)")
    }

    @Test("first-calibration title introduces the targets")
    func firstCalibrationTitle() {
        #expect(CalibrationReviewBannerCopy.title(isRecalibration: false) == "Your starting targets are ready")
    }

    @Test("re-calibration title celebrates the level-up (#305)")
    func recalibrationTitle() {
        #expect(CalibrationReviewBannerCopy.title(isRecalibration: true) == "You've leveled up")
    }

    @Test("re-calibration body names the outgrown patterns + frames it as sustained progress (#305)")
    func recalibrationBodyNamesOutgrownPatterns() {
        let body = CalibrationReviewBannerCopy.body(for: recalSignal([.squat, .horizontalPush]))
        #expect(body.contains("Squat"))
        #expect(body.contains("Horizontal Push"))
        // "consistently climbed past" — the median trigger, not a one-day PR.
        #expect(body.contains("consistently"))
        #expect(!body.contains("starting"), "re-calibration must not call these 'starting' targets: \(body)")
        #expect(!body.contains("_"), "body leaked a raw machine token: \(body)")
    }

    @Test("re-calibration body names only the outgrown patterns, not all projections (#305)")
    func recalibrationBodyNamesOnlyOutgrown() {
        // Projections cover squat + bench, but only squat outgrew its band.
        let signal = CalibrationReviewSignal(
            projections: [
                PatternProjection(pattern: .squat, floor: 100, stretch: 110, progress: .onTrack),
                PatternProjection(pattern: .horizontalPush, floor: 80, stretch: 90, progress: .ahead),
            ],
            recalibratedPatterns: [.squat]
        )
        let body = CalibrationReviewBannerCopy.body(for: signal)
        #expect(body.contains("Squat"))
        #expect(!body.contains("Horizontal Push"), "only the outgrown pattern should be named: \(body)")
    }
}
