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
            ContentView()
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
