// AppShellRouteTests.swift
// ProjectApexTests
//
// The legacy raw-Int `switchToTab` contract (frozen ContentView: 0 = Program,
// 1 = Workout, 2 = Progress, 3 = Settings) is preserved across the new 3-tab
// shell by a pure translation layer, `ShellRoute` (#343 / ADR-0026). In the app a
// wrong mapping is a silent mis-route, not a crash — so the bridge is pinned here:
// the two live feature-view call sites (`switchToTab(1)` "Continue Workout" and
// `switchToTab(3)` "Settings") and the remaining indices each resolve to their
// intended shell action.

import Testing
@testable import ProjectApex

@Suite("AppShell legacy switchToTab bridge")
struct AppShellRouteTests {

    @Test("Workout (1) → the live-loop entry — the 'Continue Workout' call site")
    func workoutRoutesToLiveLoop() {
        #expect(ShellRoute.from(legacyTab: 1) == .presentLiveLoop)
    }

    @Test("Settings (3) → the settings corner sheet — the second live call site")
    func settingsRoutesToSheet() {
        #expect(ShellRoute.from(legacyTab: 3) == .presentSettings)
    }

    @Test("Program (0) → Train — the program surface's home in the new nav")
    func programRoutesToTrain() {
        #expect(ShellRoute.from(legacyTab: 0) == .select(.train))
    }

    @Test("Progress (2) → Progress")
    func progressRoutesToProgress() {
        #expect(ShellRoute.from(legacyTab: 2) == .select(.progress))
    }

    @Test("An unknown index falls back to Today and never traps")
    func unknownRoutesToToday() {
        #expect(ShellRoute.from(legacyTab: 99) == .select(.today))
        #expect(ShellRoute.from(legacyTab: -1) == .select(.today))
    }
}
