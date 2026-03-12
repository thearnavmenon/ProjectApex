// ContentView.swift
// ProjectApex
//
// Root entry point. Three-tab navigation flow (per TDD §3.4):
//   • Tab 0 — Program   — 12-week mesocycle calendar (ProgramOverviewView)
//   • Tab 1 — Workout   — Active workout loop (placeholder until Phase 3)
//   • Tab 2 — Settings  — API keys, gym scanner, developer tools
//
// The gym scanner flow lives inside Settings tab so the Program tab can be
// the app's primary entry point once a profile is confirmed.

import SwiftUI

struct ContentView: View {

    @Environment(AppDependencies.self) private var deps

    /// Stores the confirmed GymProfile once the scanner flow completes.
    @State private var confirmedProfile: GymProfile?

    /// When true, a ScannerView sheet is presented over the Settings tab.
    @State private var isRescanning = false

    /// Controls which tab is visible.
    @State private var selectedTab: Int = 0

    /// Shared view model for the Program tab — owned here so SettingsView
    /// can trigger a regeneration that updates ProgramOverviewView.
    @State private var programViewModel: ProgramViewModel?

    /// Non-nil when a regeneration error should be shown in SettingsView.
    @State private var regenerateErrorMessage: String?

    var body: some View {
        TabView(selection: $selectedTab) {

            // ── Tab 0: Program ─────────────────────────────────────────────
            NavigationStack {
                if let vm = programViewModel {
                    ProgramOverviewView(
                        viewModel: vm,
                        gymProfile: confirmedProfile
                    )
                } else {
                    loadingPlaceholder
                }
            }
            .tabItem {
                Label("Program", systemImage: "calendar")
            }
            .tag(0)

            // ── Tab 1: Workout (placeholder — Phase 3) ─────────────────────
            NavigationStack {
                workoutPlaceholderView
            }
            .tabItem {
                Label("Workout", systemImage: "figure.strengthtraining.traditional")
            }
            .tag(1)

            // ── Tab 2: Settings ────────────────────────────────────────────
            NavigationStack {
                settingsRootView
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(2)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isRescanning) {
            NavigationStack {
                ScannerView { newProfile in
                    confirmedProfile = newProfile
                    isRescanning = false
                }
            }
            .preferredColorScheme(.dark)
        }
        .task {
            // Lazily create the ProgramViewModel once deps are available.
            if programViewModel == nil {
                programViewModel = ProgramViewModel(
                    supabaseClient: deps.supabaseClient,
                    programGenerationService: deps.programGenerationService
                )
            }
        }
    }

    // MARK: - Loading Placeholder

    private var loadingPlaceholder: some View {
        Color(red: 0.04, green: 0.04, blue: 0.06)
            .ignoresSafeArea()
    }

    // MARK: - Workout Placeholder

    private var workoutPlaceholderView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 72))
                .foregroundStyle(.white.opacity(0.25))
            VStack(spacing: 8) {
                Text("Workout Coming Soon")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Active workout session will be available in a future update.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.50))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea())
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Settings Root

    private var settingsRootView: some View {
        let isRegenerating = programViewModel?.viewState == .generating

        return SettingsView(
            hasExistingProfile: confirmedProfile != nil,
            onRescan: {
                isRescanning = true
            },
            onScanFirst: {
                isRescanning = true
            },
            confirmedProfile: confirmedProfile,
            onRegenerateProgram: {
                guard let profile = confirmedProfile else { return }
                regenerateErrorMessage = nil
                Task {
                    await regenerateProgram(gymProfile: profile)
                }
            },
            isRegenerating: isRegenerating,
            regenerateErrorMessage: regenerateErrorMessage
        )
    }

    // MARK: - Regenerate Program

    /// Triggers program regeneration, captures errors for display in SettingsView.
    @MainActor
    private func regenerateProgram(gymProfile: GymProfile) async {
        guard let vm = programViewModel else { return }
        regenerateErrorMessage = nil
        await vm.regenerateProgram(gymProfile: gymProfile)

        // Detect error state after generation completes
        if case .error(let message) = vm.viewState {
            regenerateErrorMessage = message
            // Restore loaded state or empty state so Program tab isn't stuck on error
            await vm.loadProgram()
        } else {
            // Success — switch to Program tab so user sees the new program
            selectedTab = 0
        }
    }
}

#Preview {
    ContentView()
        .environment(AppDependencies())
}
