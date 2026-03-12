// ContentView.swift
// ProjectApex
//
// Root entry point. Hosts a two-tab navigation flow:
//   • Scanner tab  — FR-001 gym scanner → GymProfile flow
//   • Settings tab — Settings → Developer Settings (API key management)
//
// The Settings tab satisfies the P0-T02 acceptance criterion:
// "Accessible from Settings tab, behind a 'Developer' row."

import SwiftUI

struct ContentView: View {

    /// Stores the confirmed GymProfile once the scanner flow completes.
    @State private var confirmedProfile: GymProfile?

    /// When true, the Scanner tab shows ScannerView in re-scan mode
    /// (triggered from Settings). The existing profile stays active until
    /// a new profile is confirmed — no partial state (P1-T06).
    @State private var isRescanning = false

    /// Controls which tab is visible — lets Settings trigger a tab switch.
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // ── Scanner tab ──────────────────────────────────────────────────
            NavigationStack {
                if let profile = confirmedProfile, !isRescanning {
                    // Post-scan placeholder; replace with FR-002 in V2.
                    profileSummaryView(profile: profile)
                } else {
                    ScannerView { newProfile in
                        // New profile replaces old only after user confirms.
                        confirmedProfile = newProfile
                        isRescanning = false
                    }
                }
            }
            .tabItem {
                Label("Scanner", systemImage: "camera.fill")
            }
            .tag(0)

            // ── Settings tab ─────────────────────────────────────────────────
            SettingsView(
                hasExistingProfile: confirmedProfile != nil,
                onRescan: {
                    // Existing profile stays untouched until new one is confirmed.
                    isRescanning = true
                    selectedTab = 0  // Navigate to Scanner tab automatically.
                }
            )
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(1)
        }
        .preferredColorScheme(.dark)
    }

    // ---------------------------------------------------------------------------
    // MARK: Post-Scan Summary (placeholder for FR-002 trigger)
    // ---------------------------------------------------------------------------

    private func profileSummaryView(profile: GymProfile) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "dumbbell.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                Text("Gym Profile Active")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("\(profile.equipment.count) items · Session \(profile.scanSessionId.prefix(8))")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Equipment chips
            FlowLayout(spacing: 8) {
                ForEach(profile.equipment) { item in
                    Text(item.equipmentType.displayName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            Button("Re-scan Gym") {
                confirmedProfile = nil
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Project Apex")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - FlowLayout

/// A simple flow layout that wraps chips onto new lines (for the equipment summary).
/// Pure SwiftUI — no UIKit dependency.
struct FlowLayout: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > containerWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: containerWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    ContentView()
}
