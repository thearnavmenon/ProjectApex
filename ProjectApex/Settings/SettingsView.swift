// SettingsView.swift
// ProjectApex — Settings Feature
//
// Top-level Settings screen accessible from the main tab bar.
// Currently surfaces:
//   • Developer row → DeveloperSettingsView (API key management)
//
// Future rows (app version, about, legal) can be added as additional sections.

import SwiftUI

struct SettingsView: View {

    var body: some View {
        NavigationStack {
            Form {
                developerSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sections

    private var developerSection: some View {
        Section("Developer") {
            NavigationLink(destination: DeveloperSettingsView()) {
                Label("Developer Settings", systemImage: "key.fill")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
}
