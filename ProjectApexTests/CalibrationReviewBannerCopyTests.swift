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

    @Test("title is a constant affordance")
    func titleIsConstant() {
        #expect(CalibrationReviewBannerCopy.title == "Your starting targets are ready")
    }
}
