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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(deps)
        }
    }
}
