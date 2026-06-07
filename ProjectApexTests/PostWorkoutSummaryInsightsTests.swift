// PostWorkoutSummaryInsightsTests.swift
// ProjectApexTests — #242
//
// Fail-loud contract for PostWorkoutSummaryView's AI insights (ADR-0007 §3,
// foreground tier: "Never silently degrade … the user MUST see that the AI
// didn't run").
//
//   .failed  ⇒ a visible "AI didn't run" notice is surfaced to the user
//   .loaded  ⇒ no notice (AI succeeded)
//   .loading ⇒ no notice (still running)
//
// Locks the single source of truth for the fallback-notice copy so the
// `.failed` render branch can never again render byte-identically to `.loaded`.

import XCTest
@testable import ProjectApex

final class PostWorkoutSummaryInsightsTests: XCTestCase {

    func test_failedState_surfacesFailLoudNotice() {
        let notice = PostWorkoutSummaryView.insightsFallbackNotice(
            for: .failed(["Total session volume: 4200kg across 12 sets."])
        )
        XCTAssertNotNil(notice, ".failed must surface a fail-loud notice (ADR-0007 §3)")
        XCTAssertTrue(
            notice?.contains("Couldn't generate AI insights") ?? false,
            "Notice must tell the user AI insights couldn't be generated; got: \(String(describing: notice))"
        )
    }

    func test_loadedState_hasNoNotice() {
        let notice = PostWorkoutSummaryView.insightsFallbackNotice(
            for: .loaded(["Bench Press up 5kg from last Push A."])
        )
        XCTAssertNil(notice, ".loaded means the AI succeeded — no fail-loud notice")
    }

    func test_loadingState_hasNoNotice() {
        let notice = PostWorkoutSummaryView.insightsFallbackNotice(for: .loading)
        XCTAssertNil(notice, ".loading is not a failure — no notice")
    }
}
