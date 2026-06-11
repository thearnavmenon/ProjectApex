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

    init() {
        // Register the embedded design-system fonts at launch (ADR-0024 — runtime
        // Core Text registration, not the Info.plist UIAppFonts build-setting key).
        _ = AppFont.register
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
