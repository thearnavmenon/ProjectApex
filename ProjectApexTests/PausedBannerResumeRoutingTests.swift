// PausedBannerResumeRoutingTests.swift
// ProjectApexTests
//
// #467 — Pause flow: the paused-session banner points straight at the Resume
// owner (WorkoutPausedView on the Workout tab) instead of detouring through a
// pushed ProgramDayDetailView.
//
// The banner's `onResume` no longer flips a `navigateToPausedDayDetail`
// navigation flag; it lands the user directly on the Workout tab (index 1),
// where WorkoutPausedView renders (#465). The routing intent is extracted into
// the pure `ContentView.applyBannerResume(selectedTab:)` seam so it is testable
// without a live SwiftUI view — mirroring the pure `ContentView.hostDay(...)`
// precedent in RunDayRoutingTests.

import XCTest
@testable import ProjectApex

final class PausedBannerResumeRoutingTests: XCTestCase {

    // Banner resume routes to the Workout tab (index 1), where WorkoutPausedView
    // — the single owner of Resume — renders. One hop, pointing at the owner.
    func testBannerResume_landsOnWorkoutTab() {
        var selectedTab = 0
        ContentView.applyBannerResume(selectedTab: &selectedTab)
        XCTAssertEqual(selectedTab, 1,
            "banner Resume must land on the Workout tab (index 1), not detour elsewhere")
    }

    // Idempotent: already on the Workout tab stays on the Workout tab.
    func testBannerResume_isIdempotentWhenAlreadyOnWorkoutTab() {
        var selectedTab = 1
        ContentView.applyBannerResume(selectedTab: &selectedTab)
        XCTAssertEqual(selectedTab, 1)
    }
}
