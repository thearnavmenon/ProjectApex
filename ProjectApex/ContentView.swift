// ContentView.swift
// ProjectApex
//
// Root entry point. Four-tab navigation flow:
//   • Tab 0 — Program   — 12—week mesocycle calendar (ProgramOverviewView)
//   • Tab 1 — Workout   — Active workout loop
//   • Tab 2 — Progress  — Key lifts, trend charts, volume, heatmap
//   • Tab 3 — Settings  — API keys, gym scanner, developer tools
//
// Onboarding gate (P4-T09):
//   On first launch (UserDefaults flag absent), OnboardingView is presented as
//   a full-screen cover. It is dismissed permanently once the user completes or
//   skips through all steps. Subsequent launches skip directly to the Program tab.

import SwiftUI

struct ContentView: View {

    @Environment(AppDependencies.self) private var deps

    /// Stores the confirmed GymProfile. Seeded from UserDefaults cache on launch
    /// so the profile is available immediately without waiting for a network fetch.
    @State private var confirmedProfile: GymProfile? = GymProfile.loadFromUserDefaults()

    /// When true, a ScannerView sheet is presented over the Settings tab.
    @State private var isRescanning = false

    /// Controls which tab is visible.
    @State private var selectedTab: Int = 0

    /// Shared view model for the Program tab — owned here so SettingsView
    /// can trigger a regeneration that updates ProgramOverviewView.
    @State private var programViewModel: ProgramViewModel?

    /// Non-nil when a regeneration error should be shown in SettingsView.
    @State private var regenerateErrorMessage: String?

    /// Tracks the in-flight gym profile Supabase sync task. Cancelled and replaced
    /// on every equipment edit so rapid edits don't leave two active profile rows.
    @State private var gymProfileSyncTask: Task<Void, Never>?

    /// True until onboarding has been completed at least once.
    /// Evaluated once at launch from UserDefaults; does not re-read during runtime.
    @State private var showOnboarding: Bool = !UserDefaults.standard.bool(forKey: OnboardingConstants.onboardingCompletedKey)

    /// One-time migration notice: training-time progression replaces calendar-time.
    /// Shown once to users who already have a mesocycle loaded when updating to this build.
    @State private var showTrainingTimeMigrationNotice: Bool = false

    // MARK: - Crash recovery

    /// Non-nil when a crash-sentinel is found in UserDefaults on launch, indicating an
    /// in-progress session that was never ended. Cleared once the user responds.
    @State private var crashRecoveryState: PausedSessionState? = nil
    /// Controls the crash-recovery alert shown once at app launch when a sentinel exists.
    @State private var showCrashRecoveryAlert: Bool = false
    /// When non-nil, WorkoutView should use this as an explicit resumeState (Path A),
    /// bypassing the brittle trainingDayId == trainingDay.id guard in Path B.
    @State private var crashResumeToPass: PausedSessionState? = nil
    /// When the paused session's trainingDayId resolves to a mesocycle day that is NOT
    /// nextIncompleteDay, this holds the correct matching day so WorkoutView uses the
    /// right exercise list for the resume rather than nextIncompleteDay's list.
    @State private var crashResumeDay: TrainingDay? = nil
    /// True when crash recovery's paused day cannot be found anywhere in the mesocycle.
    @State private var showOrphanedRecoveryAlert: Bool = false

    // MARK: - Tab badge state

    @State private var sessionIsLive: Bool = false
    @State private var pausedSessionExists: Bool = false

    // MARK: - Paused-session banner navigation

    /// True when the user taps "Resume" on PausedSessionBannerView — pushes
    /// ProgramDayDetailView for the paused day within the workout tab's NavigationStack.
    @State private var navigateToPausedDayDetail: Bool = false

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

            // ── Tab 1: Workout ─────────────────────────────────────────────
            workoutTab
            .tabItem {
                Label("Workout", systemImage: "figure.strengthtraining.traditional")
            }
            .tag(1)
            .badge(workoutTabBadge)

            // ── Tab 2: Progress ────────────────────────────────────────────
            ProgressTabView(
                supabaseClient: deps.supabaseClient,
                userId: deps.resolvedUserId
            )
            .tabItem {
                Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
            }
            .tag(2)

            // ── Tab 3: Settings ────────────────────────────────────────────
            NavigationStack {
                settingsRootView
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(3)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { completedProfile in
                // Persist the scanned profile so Settings / Program tabs see it immediately.
                if let p = completedProfile {
                    confirmedProfile = p
                }
                // Switch to Program tab so the newly generated program is visible.
                selectedTab = 0
                showOnboarding = false
                // Recreate ProgramViewModel with the userId now written to Keychain during
                // onboarding, then load the freshly generated program from UserDefaults cache.
                programViewModel = ProgramViewModel(
                    supabaseClient: deps.supabaseClient,
                    programGenerationService: deps.programGenerationService,
                    macroPlanService: deps.macroPlanService,
                    sessionPlanService: deps.sessionPlanService,
                    userId: deps.resolvedUserId
                )
                Task {
                    await programViewModel?.loadProgram()
                }
            }
            .environment(deps)
        }
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
                    programGenerationService: deps.programGenerationService,
                    macroPlanService: deps.macroPlanService,
                    sessionPlanService: deps.sessionPlanService,
                    userId: deps.resolvedUserId
                )
            }

            // One-time migration notice: show once when an existing user first launches
            // the build that introduced training-time programme progression.
            let migrationKey = "training_time_migration_v1_shown"
            if !showOnboarding && !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                showTrainingTimeMigrationNotice = true
            }

            // Crash recovery check — detect sessions that were interrupted by a kill.
            // PausedSessionState is written at session start and updated every set, so
            // if it's present here the session was never properly ended or explicitly paused.
            // Skip during onboarding (no session has ever run).
            if !showOnboarding {
                if let saved = PausedSessionState.load() {
                    crashRecoveryState = saved
                    showCrashRecoveryAlert = true
                } else if PausedSessionState.repairPending {
                    // UserDefaults data was present but corrupt (key migration failure or
                    // incompatible struct change). Query Supabase for a paused row so the
                    // mismatch-recovery path can offer the user an Abandon option.
                    await PausedSessionState.attemptSupabaseRepair(
                        userId: deps.resolvedUserId,
                        supabase: deps.supabaseClient
                    )
                    if let repaired = PausedSessionState.load() {
                        crashRecoveryState = repaired
                        showCrashRecoveryAlert = true
                    }
                }
            }
        }
        // Badge polling — drives the Tab 1 live/paused indicator.
        // Runs as a separate .task so it is never short-circuited by the main setup task's
        // early returns (isLive guard, onboarding skip, etc.).
        .task {
            while true {
                let state = await deps.workoutSessionManager.sessionState
                switch state {
                case .idle, .sessionComplete, .error: sessionIsLive = false
                default: sessionIsLive = true
                }
                pausedSessionExists = UserDefaults.standard.data(forKey: PausedSessionState.v2PersistenceKey) != nil
                    || UserDefaults.standard.data(forKey: PausedSessionState.legacyPersistenceKey) != nil
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        .alert("Unfinished Workout", isPresented: $showCrashRecoveryAlert) {
            Button("Resume") {
                guard let saved = crashRecoveryState,
                      let vm = programViewModel,
                      case .loaded(let mesocycle) = vm.viewState else {
                    // Programme not loaded yet — fall back to Path B in WorkoutView
                    selectedTab = 1
                    return
                }
                let nextDay = vm.nextIncompleteDay(in: mesocycle)?.day
                if nextDay?.id == saved.trainingDayId {
                    // Normal case: pass as explicit resumeState so Path A fires reliably
                    crashResumeToPass = saved
                    selectedTab = 1
                } else if let foundResult = vm.findTrainingDay(byId: saved.trainingDayId, in: mesocycle) {
                    // Paused day found elsewhere in the mesocycle — pass both the correct
                    // training day and the resume state so WorkoutView uses the right exercise list.
                    crashResumeToPass = saved
                    crashResumeDay = foundResult.day
                    selectedTab = 1
                } else {
                    // Paused day not found anywhere — can't properly resume.
                    // Show the orphaned recovery dialog instead of switching tabs.
                    showOrphanedRecoveryAlert = true
                }
            }
            Button("Abandon Session", role: .destructive) {
                if let saved = crashRecoveryState {
                    Task {
                        await deps.workoutSessionManager.abandonSession(sessionId: saved.sessionId)
                    }
                }
                crashRecoveryState = nil
                crashResumeToPass = nil
                crashResumeDay = nil
            }
        } message: {
            Text(crashRecoveryMessage)
        }
        .alert("Session Not Found", isPresented: $showOrphanedRecoveryAlert) {
            Button("Save to History") {
                // Flush WAQ so any pending set_logs reach Supabase, then clear the sentinel.
                // The session row already exists in Supabase; its set_logs are preserved.
                if let saved = crashRecoveryState {
                    Task { await deps.workoutSessionManager.flushWriteAheadQueue() }
                    _ = saved  // acknowledged
                }
                crashRecoveryState = nil
                crashResumeToPass = nil
                PausedSessionState.clear()
            }
            Button("Discard", role: .destructive) {
                if let saved = crashRecoveryState {
                    Task {
                        await deps.workoutSessionManager.abandonSession(sessionId: saved.sessionId)
                    }
                }
                crashRecoveryState = nil
                crashResumeToPass = nil
            }
        } message: {
            Text("Your previous workout couldn't be matched to the current programme. You can preserve the sets that were logged, or discard the session entirely.")
        }
        .alert("Programme Update", isPresented: $showTrainingTimeMigrationNotice) {
            Button("Got it") { }
        } message: {
            Text("Your programme now advances when you complete or skip sessions — not based on calendar dates. Your progress is unchanged.")
        }
    }

    // MARK: - Loading Placeholder

    private var loadingPlaceholder: some View {
        Color(red: 0.04, green: 0.04, blue: 0.06)
            .ignoresSafeArea()
    }

    // MARK: - Tab Badge

    /// Returns a coloured dot badge for Tab 1 when a session is live or paused.
    /// Live sessions use the phase-accent blue; paused-only sessions use amber.
    /// Returns nil (no badge) when idle. SwiftUI renders foregroundStyle on Text badges
    /// on iOS 16+; if the tint does not render the badge defaults to the system colour.
    private var workoutTabBadge: Text? {
        if sessionIsLive {
            return Text("●").foregroundStyle(Color(red: 0.25, green: 0.72, blue: 1.0))
        } else if pausedSessionExists {
            return Text("●").foregroundStyle(Color(red: 1.0, green: 0.65, blue: 0.0))
        }
        return nil
    }

    // MARK: - Workout Tab

    /// The Workout tab. Routes to `WorkoutView` with the first non-completed day
    /// in the mesocycle. Shows a programme-complete state when all days are done,
    /// or a no-program state when no mesocycle is loaded.
    @ViewBuilder
    private var workoutTab: some View {
        if let vm = programViewModel, case .loaded(let mesocycle) = vm.viewState {
            if let (day, week) = vm.nextIncompleteDay(in: mesocycle) {
                let allDays = mesocycle.weeks.flatMap { $0.trainingDays }
                // Skipped sessions advance the programme pointer and count toward progress.
                let completedCount = allDays.filter { $0.status == .completed || $0.status == .skipped }.count
                // NavigationStack is required so WorkoutView (and its children) can render
                // their toolbar items and so WorkoutView pushed from ProgramDayDetailView
                // has a consistent navigation context. WorkoutView no longer owns an
                // inner NavigationStack.
                NavigationStack {
                    WorkoutView(
                        trainingDay: crashResumeDay ?? day,
                        programId: mesocycle.id,
                        weekNumber: week.weekNumber,
                        completedDayCount: completedCount,
                        totalDayCount: allDays.count,
                        onSessionCompleted: {
                            // Crash-resume path: the resumed day may differ from `day` —
                            // find its week via the mesocycle rather than assuming `week`.
                            if let resumeDay = crashResumeDay,
                               let found = vm.findTrainingDay(byId: resumeDay.id, in: mesocycle) {
                                programViewModel?.markDayCompleted(dayId: found.day.id, weekId: found.week.id)
                            } else {
                                programViewModel?.markDayCompleted(dayId: day.id, weekId: week.id)
                            }
                        },
                        onSessionPaused: {
                            if let resumeDay = crashResumeDay,
                               let found = vm.findTrainingDay(byId: resumeDay.id, in: mesocycle) {
                                programViewModel?.markDayPaused(dayId: found.day.id, weekId: found.week.id)
                            } else {
                                programViewModel?.markDayPaused(dayId: day.id, weekId: week.id)
                            }
                        },
                        onSessionDismissed: {
                            // Sequence: markDayCompleted (from onSessionCompleted above) has
                            // already written its state — loadProgram() now fetches the updated
                            // mesocycle before switching tabs so the calendar shows correctly.
                            Task { @MainActor in
                                await programViewModel?.loadProgram()
                                selectedTab = 0
                                crashResumeToPass = nil
                                crashResumeDay = nil
                                programViewModel?.scrollToCurrentWeekTrigger += 1
                            }
                        },
                        resumeState: crashResumeToPass,
                        onSkipSession: {
                            // Persistent skip — advances programme_day_index, records skippedAt.
                            programViewModel?.markDaySkipped(dayId: day.id, weekId: week.id)
                        },
                        onCloseToTab0: { selectedTab = 0 }
                    )
                    // Paused-session banner — shown when a different day is paused and no
                    // session is currently live (i.e. user is on the PreWorkoutView screen).
                    .safeAreaInset(edge: .top) {
                        if !sessionIsLive,
                           let saved = PausedSessionState.load(),
                           saved.trainingDayId != day.id,
                           let found = vm.findTrainingDay(byId: saved.trainingDayId, in: mesocycle) {
                            PausedSessionBannerView(
                                dayLabel: found.day.dayLabel,
                                weekNumber: found.week.weekNumber,
                                onResume: { navigateToPausedDayDetail = true }
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        }
                    }
                    // Navigation destination for the paused day's detail view
                    .navigationDestination(isPresented: $navigateToPausedDayDetail) {
                        if let saved = PausedSessionState.load(),
                           let found = vm.findTrainingDay(byId: saved.trainingDayId, in: mesocycle) {
                            ProgramDayDetailView(
                                day: found.day,
                                week: found.week,
                                mesocycleCreatedAt: mesocycle.createdAt,
                                programId: mesocycle.id,
                                viewModel: vm,
                                gymProfile: confirmedProfile
                            )
                            .environment(deps)
                        }
                    }
                }
            } else {
                programCompleteView
            }
        } else {
            noWorkoutView
        }
    }

    private var noWorkoutView: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.20))
                VStack(spacing: 8) {
                    Text("No Program Yet")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Generate a program in the Program tab to start working out.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Button {
                    selectedTab = 0
                } label: {
                    Text("Go to Program")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .padding(.top, 8)
                Spacer()
            }
            .background(Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea())
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// Shown on the Workout tab when every day in the mesocycle is `.completed`.
    private var programCompleteView: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "trophy.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.0))
                VStack(spacing: 8) {
                    Text("Programme Complete")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("You've finished every session. Head to Settings to regenerate a new programme.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Button {
                    selectedTab = 3
                } label: {
                    Text("Go to Settings")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .padding(.top, 8)
                Spacer()
            }
            .background(Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea())
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
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
            onEquipmentChanged: { updatedProfile in
                // Persist to UserDefaults immediately — always fast, always wins.
                confirmedProfile = updatedProfile
                updatedProfile.saveToUserDefaults()

                // Cancel any in-flight Supabase sync so rapid edits don't produce
                // two concurrent (deactivate + insert) pairs that could interleave
                // and leave a duplicate active row.
                gymProfileSyncTask?.cancel()

                let userId = deps.resolvedUserId
                let client = deps.supabaseClient
                gymProfileSyncTask = Task {
                    guard !Task.isCancelled else { return }
                    do {
                        // Deactivate old row, then insert updated one (scanner pattern).
                        // These are sequential awaits within a single Task — no race window.
                        try await client.deactivateGymProfiles(userId: userId)
                        guard !Task.isCancelled else { return }
                        let row = GymProfileRow.forInsert(from: updatedProfile, userId: userId)
                        try await client.insert(row, table: "gym_profiles")
                        print("[ContentView] GymProfile synced to Supabase — \(updatedProfile.equipment.count) items")
                    } catch {
                        // Non-fatal — UserDefaults is the local source of truth.
                        print("[ContentView] GymProfile Supabase sync failed: \(error.localizedDescription)")
                    }
                }
            },
            isRegenerating: isRegenerating,
            regenerateErrorMessage: regenerateErrorMessage,
            onResetAll: {
                // Clear in-memory state so the UI reflects the wipe immediately
                confirmedProfile = nil
                programViewModel = nil
                showOnboarding = true
            },
            programViewModel: programViewModel
        )
    }

    // MARK: - Crash Recovery Helpers

    private var crashRecoveryMessage: String {
        guard let saved = crashRecoveryState else {
            return "You have an unfinished session. Resume it or abandon it?"
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "You have an unfinished session from \(formatter.string(from: saved.pausedAt)). Resume it or abandon it?"
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
