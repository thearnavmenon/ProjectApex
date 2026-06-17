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

    /// Confirms "Start Your Next Programme" on the programme-complete screen
    /// before triggering regeneration.
    @State private var showNextProgrammeConfirmation: Bool = false

    // MARK: - Crash recovery

    /// Non-nil when a crash-sentinel is found in UserDefaults on launch, indicating an
    /// in-progress session that was never ended. Cleared once the user responds.
    @State private var crashRecoveryState: PausedSessionState? = nil
    /// Controls the crash-recovery alert shown once at app launch when a sentinel exists.
    @State private var showCrashRecoveryAlert: Bool = false
    /// True when crash recovery's paused day cannot be found anywhere in the mesocycle.
    @State private var showOrphanedRecoveryAlert: Bool = false

    // MARK: - Paused-session banner navigation

    /// True when the user taps "Resume" on PausedSessionBannerView — pushes
    /// ProgramDayDetailView for the paused day within the workout tab's NavigationStack.
    @State private var navigateToPausedDayDetail: Bool = false

    var body: some View {
        // Honest launch gate (#329 / O-F1, #369 slice 2): when either required key is
        // missing — neither in the Keychain nor bundled into the build — show the
        // "needs setup" screen instead of letting onboarding start and die mid-gym-scan
        // or mid-Supabase call. No-op when both keys are present: the normal
        // onboarding/app path below is completely untouched.
        if deps.hasResolvableAIKey && deps.hasResolvableSupabaseKey {
            mainContent
        } else {
            NeedsSetupView()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
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

            // ── Tab 2: Progress ────────────────────────────────────────────
            ProgressTabView(
                supabaseClient: deps.supabaseClient,
                userId: deps.resolvedUserId,
                traineeModelService: deps.traineeModelService
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
        .overlay(alignment: .bottom) {
            // #462: "Now Training" pill above the tab bar — replaces the colour-coded
            // tab badge (iOS strips a Text badge's tint). Hidden on the Workout tab
            // itself (tab 1), which already shows the full session / paused screen.
            // .padding(.bottom) clears the tab bar; the exact value needs device QA.
            if selectedTab != 1 {
                NowTrainingBar(
                    state: .resolve(
                        isLive: deps.activeSessionCoordinator.isLive,
                        pausedExists: deps.activeSessionCoordinator.pausedSessionExists
                    ),
                    onTap: { selectedTab = 1 }
                )
                .padding(.bottom, 56)
            }
        }
        .environment(\.switchToTab, { selectedTab = $0 })
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
                    userId: deps.resolvedUserId,
                    resolveOwner: { await deps.resolvedOwnerUserId() },
                    traineeModelService: deps.traineeModelService
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
                    userId: deps.resolvedUserId,
                    resolveOwner: { await deps.resolvedOwnerUserId() },
                    traineeModelService: deps.traineeModelService
                )
            }

            // Crash recovery check — detect sessions that were interrupted by a kill.
            // PausedSessionState is written at session start and updated every set, so
            // if it's present here the session was never properly ended or explicitly paused.
            // Skip during onboarding (no session has ever run).
            // Evaluated FIRST (J-F7 / #318): two alerts arming in the same .task pass
            // collide — SwiftUI silently drops one — so the migration notice below only
            // arms when no crash-recovery alert won this launch.
            var crashAlertArmed = false
            if !showOnboarding {
                if let saved = PausedSessionState.load() {
                    crashRecoveryState = saved
                    showCrashRecoveryAlert = true
                    crashAlertArmed = true
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
                        crashAlertArmed = true
                    }
                }
            }

            // One-time migration notice: show once when an existing user first launches
            // the build that introduced training-time programme progression. Suppressed
            // when the crash-recovery alert won — and the shown-flag is set ONLY when
            // the notice actually presents, so a suppressed notice isn't silently
            // consumed and still shows on the next launch (J-F7 / #318).
            let migrationKey = "training_time_migration_v1_shown"
            if !showOnboarding && !crashAlertArmed && !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                showTrainingTimeMigrationNotice = true
            }
        }
        .alert("Unfinished Workout", isPresented: $showCrashRecoveryAlert) {
            Button("Resume") {
                // #441: Resume no longer seeds sticky overrides. It only adjudicates
                // which alert to show: if the paused sentinel resolves to a real day
                // anywhere in the mesocycle, switch to the Workout tab — which
                // self-resumes via the coordinator-driven host. If it resolves nowhere,
                // show the orphaned-recovery dialog instead.
                guard let saved = crashRecoveryState,
                      let vm = programViewModel,
                      case .loaded(let mesocycle) = vm.viewState else {
                    // Programme not loaded yet — the Workout tab still self-resumes on appear.
                    selectedTab = 1
                    return
                }
                if vm.findTrainingDay(byId: saved.trainingDayId, in: mesocycle) != nil {
                    selectedTab = 1
                } else {
                    // Paused day not found anywhere — can't properly resume.
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
                PausedSessionState.clear()
            }
            Button("Discard", role: .destructive) {
                if let saved = crashRecoveryState {
                    Task {
                        await deps.workoutSessionManager.abandonSession(sessionId: saved.sessionId)
                    }
                }
                crashRecoveryState = nil
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

    // MARK: - Workout Tab

    /// Resolves the mesocycle to render on the Workout tab. Uses the loaded state's
    /// mesocycle normally; while a day's session is generating in place, falls back to
    /// `currentMesocycle` so the tab stays on the workout surface rather than collapsing
    /// to "No Program Yet".
    private func workoutTabMesocycle(for vm: ProgramViewModel) -> Mesocycle? {
        switch vm.viewState {
        case .loaded(let mesocycle):
            return mesocycle
        case .generatingSession:
            return vm.currentMesocycle
        default:
            return nil
        }
    }

    /// Pure render-target resolver for the Workout tab (#441). Sources the hosted
    /// day from the RUN day the coordinator reports (live or paused), never from
    /// sticky view state — so leaving a resumed session without reaching Done can no
    /// longer pin a stale day (the STATE-4 bug). Returns the coordinator's active day
    /// when it is non-nil, differs from `nextIncomplete`, and resolves in the
    /// mesocycle; otherwise falls back to `nextIncomplete`. Self-healing: when the
    /// session ends the coordinator goes `.idle` → `coordinatorActiveDayId` is nil →
    /// this returns `nextIncomplete` again automatically.
    static func hostDay(
        nextIncomplete: TrainingDay,
        coordinatorActiveDayId: UUID?,
        mesocycle: Mesocycle
    ) -> TrainingDay {
        guard let activeId = coordinatorActiveDayId, activeId != nextIncomplete.id else {
            return nextIncomplete
        }
        for week in mesocycle.weeks {
            if let day = week.trainingDays.first(where: { $0.id == activeId }) {
                return day
            }
        }
        return nextIncomplete
    }

    /// The Workout tab. Routes to `WorkoutView` with the first non-completed day
    /// in the mesocycle. Shows a programme-complete state when all days are done,
    /// or a no-program state when no mesocycle is loaded.
    @ViewBuilder
    private var workoutTab: some View {
        // Render the workout surface for a loaded programme OR while a single day's
        // session is generating in place — the latter keeps currentMesocycle populated,
        // so the tab must not collapse to "No Program Yet" mid-generation.
        if let vm = programViewModel,
           let mesocycle = workoutTabMesocycle(for: vm) {
            let isGeneratingSession: Bool = {
                if case .generatingSession = vm.viewState { return true }
                return false
            }()
            if let (day, week) = vm.nextIncompleteDay(in: mesocycle) {
                let allDays = mesocycle.weeks.flatMap { $0.trainingDays }
                // Skipped sessions advance the programme pointer and count toward progress (#445).
                let completedCount = mesocycle.completedDayCount
                // #441: the hosted day comes from the coordinator's RUN day (live or
                // paused), never sticky view state. Self-heals to nextIncompleteDay when
                // the session ends (coordinator → .idle → both ids nil).
                let coordinatorActiveDayId = deps.activeSessionCoordinator.liveTrainingDayId
                    ?? deps.activeSessionCoordinator.pausedTrainingDayId
                let hostedDay = ContentView.hostDay(
                    nextIncomplete: day,
                    coordinatorActiveDayId: coordinatorActiveDayId,
                    mesocycle: mesocycle
                )
                // NavigationStack is required so WorkoutView (and its children) can render
                // their toolbar items and so WorkoutView pushed from ProgramDayDetailView
                // has a consistent navigation context. WorkoutView no longer owns an
                // inner NavigationStack.
                NavigationStack {
                    WorkoutView(
                        trainingDay: hostedDay,
                        programId: mesocycle.id,
                        weekNumber: week.weekNumber,
                        completedDayCount: completedCount,
                        totalDayCount: allDays.count,
                        onSessionCompleted: { runDayId in
                            // #441: route the mark by the RUN day's id — WorkoutView's
                            // #436 guard proves runDayId is the day the actor ran. Resolve
                            // its week via the mesocycle rather than assuming `week`.
                            if let found = vm.findTrainingDay(byId: runDayId, in: mesocycle) {
                                programViewModel?.markDayCompleted(dayId: found.day.id, weekId: found.week.id)
                            }
                        },
                        onSessionPaused: { runDayId in
                            if let found = vm.findTrainingDay(byId: runDayId, in: mesocycle) {
                                programViewModel?.markDayPaused(dayId: found.day.id, weekId: found.week.id)
                            }
                        },
                        onSessionDismissed: {
                            // Sequence: markDayCompleted (from onSessionCompleted above) has
                            // already written its state — loadProgram() now fetches the updated
                            // mesocycle before switching tabs so the calendar shows correctly.
                            Task { @MainActor in
                                await programViewModel?.loadProgram()
                                selectedTab = 0
                                programViewModel?.scrollToCurrentWeekTrigger += 1
                            }
                        },
                        onSkipSession: { runDayId in
                            // Persistent skip — advances programme_day_index, records skippedAt.
                            // Routes to the hosted day's id (skip fires pre-live).
                            if let found = vm.findTrainingDay(byId: runDayId, in: mesocycle) {
                                programViewModel?.markDaySkipped(dayId: found.day.id, weekId: found.week.id)
                            }
                        },
                        isGeneratingSession: isGeneratingSession,
                        onGenerateSession: (hostedDay.status == .pending && confirmedProfile != nil)
                            ? {
                                // Generate this not-yet-generated day's session in place.
                                // Resolve the hosted day's week pair from the mesocycle.
                                let targetDay: TrainingDay
                                let targetWeek: TrainingWeek
                                if let found = vm.findTrainingDay(byId: hostedDay.id, in: mesocycle) {
                                    targetDay = found.day
                                    targetWeek = found.week
                                } else {
                                    targetDay = day
                                    targetWeek = week
                                }
                                Task {
                                    await programViewModel?.generateDaySession(
                                        day: targetDay,
                                        week: targetWeek,
                                        gymProfile: confirmedProfile!
                                    )
                                }
                            }
                            : nil,
                        onCloseToTab0: { selectedTab = 0 }
                    )
                    // Paused-session banner — shown when a different day is paused and no
                    // session is currently live (i.e. user is on the PreWorkoutView screen).
                    .safeAreaInset(edge: .top) {
                        // #440: paused/live identity comes from the coordinator. Its
                        // pausedTrainingDayId is non-nil only when a sentinel exists AND no
                        // live session overrides it (live wins), so the former !isLive guard
                        // is subsumed. Self-suppress when the paused day is the one on screen.
                        if let pausedDayId = deps.activeSessionCoordinator.pausedTrainingDayId,
                           pausedDayId != day.id,
                           let found = vm.findTrainingDay(byId: pausedDayId, in: mesocycle) {
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
                    Text("You've finished every session.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Button {
                    showNextProgrammeConfirmation = true
                } label: {
                    Text("Start Your Next Programme")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(confirmedProfile != nil ? 1.0 : 0.4))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(
                            confirmedProfile != nil
                                ? Color(red: 0.23, green: 0.56, blue: 1.00)
                                : Color.white.opacity(0.08),
                            in: Capsule()
                        )
                }
                .disabled(confirmedProfile == nil)
                .padding(.top, 8)
                if confirmedProfile == nil {
                    Text("Set up your gym in Settings to start a new programme")
                        .font(.footnote)
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
                Spacer()
            }
            .background(Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea())
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Start Your Next Programme?", isPresented: $showNextProgrammeConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Start") {
                    guard let profile = confirmedProfile else { return }
                    Task { await regenerateProgram(gymProfile: profile) }
                }
            } message: {
                Text("Generates a fresh 12-week programme. Your history is preserved.")
            }
            // #439 (Q3 = refuse-and-prompt): regeneration refuses while a paused
            // session sentinel exists; surface the prompt to finish/abandon first.
            .alert(
                "Finish Your Session First",
                isPresented: Binding(
                    get: { regenerateErrorMessage != nil },
                    set: { if !$0 { regenerateErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { regenerateErrorMessage = nil }
            } message: {
                Text(regenerateErrorMessage ?? "")
            }
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

                let client = deps.supabaseClient
                gymProfileSyncTask = Task {
                    guard !Task.isCancelled else { return }
                    // #409 PR-B: resolve-before-stamp — gate the owned write on the
                    // resolved owner so a pre-auth placeholder edit never reaches the
                    // server. nil / placeholder owner skips the write (UserDefaults wins).
                    let owner = await deps.resolvedOwnerUserId()
                    guard !Task.isCancelled else { return }
                    let didSync = await GymProfileSync.syncIfOwnerResolved(updatedProfile, owner: owner, client: client)
                    if didSync {
                        print("[ContentView] GymProfile synced to Supabase — \(updatedProfile.equipment.count) items")
                    } else {
                        // Non-fatal — UserDefaults is the local source of truth.
                        print("[ContentView] GymProfile Supabase sync skipped/failed (owner unresolved or write failed)")
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

        // #439 (Q3 = refuse-and-prompt): regeneration was refused because a paused
        // session sentinel still exists. Surface the prompt and stop — the mesocycle
        // was NOT mutated, so don't switch tabs or reload.
        if vm.regenerationBlockedBySession {
            regenerateErrorMessage = "Finish or abandon your paused session before starting a new programme."
            return
        }

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

// MARK: - GymProfile Sync (#409 PR-B / #369 owner-stamping workstream)

/// Resolve-before-stamp sync for the equipment-edit `gym_profiles` write.
///
/// `onEquipmentChanged` historically captured the SYNC `deps.resolvedUserId`,
/// which can still be the pre-auth placeholder on a fresh launch — so an
/// equipment edit made before auth resolved would deactivate + insert a row the
/// user could not own (the #369 owner-mismatch failure mode). This helper gates
/// the write on the resolved owner: a nil owner (auth unresolved / offline) or
/// the placeholder uid is never written. UserDefaults remains the local source
/// of truth in that case (matches the existing non-fatal behavior).
enum GymProfileSync {
    /// - Returns: `true` iff the server insert succeeded under a real resolved owner.
    @discardableResult
    static func syncIfOwnerResolved(
        _ profile: GymProfile,
        owner: UUID?,
        client: SupabaseClient
    ) async -> Bool {
        // resolve-before-stamp: never sync a row we can't own.
        guard let owner, owner != AppDependencies.placeholderUserId else { return false }
        // Deactivate is best-effort: zero existing active rows (patchNoMatch) is
        // VALID for a first edit, not an error, so it must not block the insert.
        try? await client.deactivateGymProfiles(userId: owner)
        do {
            try await client.insert(GymProfileRow.forInsert(from: profile, userId: owner), table: "gym_profiles")
            return true
        } catch {
            // Non-fatal: UserDefaults remains the source of truth (matches current behavior).
            return false
        }
    }
}

// MARK: - Cross-tab navigation environment

/// Closure that switches the root TabView's selection. Injected by ContentView so
/// any descendant view can request a tab change (e.g. ProgramDayDetailView routing
/// a live-session "Continue Workout" CTA back to Tab 1) without prop-drilling a
/// dedicated callback through every intermediate view. Tab indices follow the
/// declaration order in ContentView (0 = Program, 1 = Workout, 2 = Progress,
/// 3 = Settings). Defaults to a no-op so previews and tests work without setup.
private struct SwitchToTabKey: EnvironmentKey {
    static let defaultValue: (Int) -> Void = { _ in }
}

extension EnvironmentValues {
    var switchToTab: (Int) -> Void {
        get { self[SwitchToTabKey.self] }
        set { self[SwitchToTabKey.self] = newValue }
    }
}

#Preview {
    ContentView()
        .environment(AppDependencies())
}
