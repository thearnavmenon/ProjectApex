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

    var body: some Scene {
        WindowGroup {
            Group {
                // Honest launch gate (#329 / O-F1, #369 slice 2): when either required
                // key is missing — neither in the Keychain nor bundled into the build —
                // show the "needs setup" screen instead of letting onboarding start and
                // die mid-gym-scan or mid-Supabase call.
                if AppLaunchGate.isSatisfied(hasAIKey: deps.hasResolvableAIKey, hasSupabaseKey: deps.hasResolvableSupabaseKey) {
                    ContentView()
                } else {
                    NeedsSetupView()
                }
            }
            .environment(deps)
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
