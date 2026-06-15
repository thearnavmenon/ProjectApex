//
//  ProjectApexApp.swift
//  ProjectApex
//
//  Created by Arnav Menon on 10/3/2026.
//

import SwiftUI

@main
struct ProjectApexApp: App {

    @State private var deps = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase

    /// Strangler entry seam (ADR-0026): the new 3-tab `AppShell` is selected by a
    /// single compile-time constant. #343 lands it `false` — the shell is built,
    /// wired, and unit-tested but not yet the live root, so the frozen `ContentView`
    /// keeps owning onboarding, crash-recovery, and the paused-session resume
    /// (machinery-last). Flip to `true` once that machinery is lifted (close-out #363).
    private let useNewShell = false

    init() {
        // Register the embedded design-system fonts at launch (ADR-0024 — runtime
        // Core Text registration, not the Info.plist UIAppFonts build-setting key).
        _ = AppFont.register
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // Honest launch gate (#329 / O-F1, #369 slice 2), hoisted here in #376
                // ABOVE the root switch so it guards BOTH roots: when either required
                // key is missing — neither in the Keychain nor bundled into the build —
                // show the "needs setup" screen instead of letting onboarding start and
                // die mid-gym-scan or mid-Supabase call. ContentView keeps its own
                // internal gate (now redundant, harmless — #363 removes it).
                if AppLaunchGate.isSatisfied(hasAIKey: deps.hasResolvableAIKey, hasSupabaseKey: deps.hasResolvableSupabaseKey) {
                    if useNewShell {
                        AppShell()
                    } else {
                        ContentView()
                    }
                } else {
                    NeedsSetupView()
                }
            }
            .environment(deps)
            .apexThemeRoot()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Flush the write-ahead queue on app foreground (P3-T06)
                Task {
                    await deps.writeAheadQueue.flush()
                }
            }
        }
    }
}
