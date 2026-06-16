//
//  AppLaunchGate.swift
//  ProjectApex
//
//  Shared pure predicate for the launch/setup gate (#329 / #369 / #421).
//  Both `ProjectApexApp.body` and `AppLaunchGateTests` call this so the test
//  pins the PRODUCTION condition, not a hand-copied re-implementation.
//

enum AppLaunchGate {
    /// Returns `true` when the app may show the real root view.
    /// Returns `false` when either required key is unresolvable — the caller
    /// must show `NeedsSetupView` instead.
    static func isSatisfied(hasAIKey: Bool, hasSupabaseKey: Bool) -> Bool {
        hasAIKey && hasSupabaseKey
    }
}
