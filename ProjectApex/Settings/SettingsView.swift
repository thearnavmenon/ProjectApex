// SettingsView.swift
// ProjectApex — Settings Feature
//
// Top-level Settings screen accessible from the main tab bar.
// Surfaces:
//   • Gym section → "Re-scan Gym" (P1-T06): confirmation alert before starting a fresh scan
//   • Developer row → DeveloperSettingsView (API key management)

import SwiftUI

struct SettingsView: View {

    /// Set to true when the user has an existing GymProfile. Controls
    /// whether the "Re-scan Gym" row is visible.
    var hasExistingProfile: Bool = false

    /// Called when the user confirms they want to start a fresh scan.
    /// The parent is responsible for navigating to ScannerView.
    var onRescan: (() -> Void)? = nil

    @State private var showingRescanAlert = false

    var body: some View {
        NavigationStack {
            Form {
                if hasExistingProfile {
                    gymSection
                }
                developerSection
                aboutSection
            }
            .navigationTitle("Settings")
            .alert("Re-scan Gym?", isPresented: $showingRescanAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Re-scan", role: .destructive) {
                    onRescan?()
                }
            } message: {
                Text("This will replace your current equipment profile. Are you sure?")
            }
        }
    }

    // MARK: - Sections

    /// Gym management section — only shown when a profile exists (P1-T06).
    private var gymSection: some View {
        Section("Gym") {
            Button {
                showingRescanAlert = true
            } label: {
                Label("Re-scan Gym", systemImage: "camera.viewfinder")
                    .foregroundStyle(.primary)
            }
        }
    }

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

#Preview("With profile") {
    SettingsView(hasExistingProfile: true, onRescan: { })
        .preferredColorScheme(.dark)
}

#Preview("No profile") {
    SettingsView()
        .preferredColorScheme(.dark)
}
