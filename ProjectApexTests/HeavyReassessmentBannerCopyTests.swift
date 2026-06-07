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
