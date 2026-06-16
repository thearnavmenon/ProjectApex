//
//  AppLaunchGateTests.swift
//  ProjectApexTests
//
//  Pins the launch/setup gate to the PRODUCTION predicate. The gate lives in
//  `ProjectApexApp.body`: the app shows `NeedsSetupView` when EITHER required key is
//  unresolvable, and the real root otherwise. These tests call the production
//  `AppLaunchGate.isSatisfied` directly — not a hand-copied re-implementation — so a
//  change to the gate condition is caught here automatically (#329 / #369 / #421).
//
//  Re-homed from AppShellMachineryTests when the Phase-3 shell was removed; the gate
//  predicate it pins is unchanged production code.
//

import Testing
@testable import ProjectApex

struct AppLaunchGateTests {

    @Test("Launch gate: missing AI key → NeedsSetupView (gate is false)")
    func launchGateMissingAIKey() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: false, hasSupabaseKey: true) == false)
    }

    @Test("Launch gate: missing Supabase key → NeedsSetupView (gate is false)")
    func launchGateMissingSupabaseKey() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: true, hasSupabaseKey: false) == false)
    }

    @Test("Launch gate: both keys missing → NeedsSetupView (gate is false)")
    func launchGateBothMissing() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: false, hasSupabaseKey: false) == false)
    }

    @Test("Launch gate: both keys present → the real root (gate is true)")
    func launchGateBothPresent() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: true, hasSupabaseKey: true) == true)
    }
}
