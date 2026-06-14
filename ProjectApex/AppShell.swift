// AppShell.swift
// ProjectApex
//
// The Phase 3 UI-overhaul shell: the locked 3-tab navigation — Today / Train /
// Progress — with settings in a corner, not a tab (ui-overhaul-spec.md §2).
//
// A strangler-fig sibling root to the frozen `ContentView` (ADR-0026), selected by
// one compile-time constant in `ProjectApexApp`. As of #376 (commit 1/2, the
// "machinery-lift") this shell carries faithful COPIES of the machinery that the
// frozen `ContentView` still owns and runs: the `ProgramViewModel` lifecycle, the
// onboarding gate, the crash-recovery alert chain (the #318 ordering, moved
// verbatim), the paused-session resume (the three Resume branches), and the
// settings root coupled to the view model. `useNewShell` STAYS `false` in this
// commit — `ContentView` is still the live root and is untouched — so this
// machinery is exercised only by the unit tests until the flip (commit 2/2).
//
// Each surface is a code-as-switch `@ViewBuilder`; a per-surface slice swaps in its
// real screen later. The legacy raw-Int `switchToTab` contract is preserved by a
// pure translation layer (`ShellRoute`) so the existing feature-view call sites stay
// byte-identical.
//
// All chrome reads #341 design tokens (ADR-0024) — no hardcoded colors here.

import SwiftUI

// MARK: - Tabs

/// The three locked tabs (ui-overhaul-spec.md §2), in bar order. Settings is
/// deliberately *not* a case — it lives in a corner affordance, not the tab bar.
enum ApexTab: CaseIterable, Identifiable {
    case today, train, progress

    var id: Self { self }

    /// Tab-bar label — also the VoiceOver name.
    var title: String {
        switch self {
        case .today: "Today"
        case .train: "Train"
        case .progress: "Progress"
        }
    }

    /// SF Symbol base name. The bar applies the *filled* variant to the selected
    /// tab (DESIGN.md §Iconography: "Filled variant only for the selected tab").
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .train: "dumbbell"
        case .progress: "chart.line.uptrend.xyaxis"
        }
    }
}

// MARK: - Legacy switchToTab bridge

/// Translation of the frozen `ContentView` raw-Int `switchToTab` contract
/// (0 = Program, 1 = Workout, 2 = Progress, 3 = Settings) into a shell action.
///
/// ADR-0026 keeps the Int contract so the two live feature-view call sites
/// (`switchToTab(1)` "Continue Workout" → live loop, `switchToTab(3)` → Settings)
/// stay byte-identical. The mapping is pure, so a wrong route is a caught test
/// failure, not a silent in-app mis-navigation. (Migrating the callers to a typed
/// `ApexTab` is the close-out move, deferred to #363.)
enum ShellRoute: Equatable {
    /// Switch the bar to a tab.
    case select(ApexTab)
    /// The live-loop entry — a pushed/covered surface, not a tab
    /// (ADR-0026 / splash-today.md: the loop "rises through" Start, off-tab).
    case presentLiveLoop
    /// The settings corner sheet.
    case presentSettings

    static func from(legacyTab index: Int) -> ShellRoute {
        switch index {
        case 0: .select(.train)      // Program → Train owns the program/calendar now
        case 1: .presentLiveLoop     // Workout → the live-loop entry
        case 2: .select(.progress)   // Progress → Progress
        case 3: .presentSettings     // Settings → the corner sheet
        default: .select(.today)     // unknown index → home (the safe no-op-spirited default)
        }
    }
}

// MARK: - Crash-recovery resume decision (pure, testable)

/// The outcome of the crash-recovery "Resume" choice — the exact branch logic that
/// the frozen `ContentView` runs inline inside its `.alert` Resume button (the three
/// Resume branches + the orphaned fallback). Lifted out as a PURE enum so the
/// decision is unit-testable against `AppShell` without driving a live SwiftUI alert
/// (the codebase tests reducers, not view closures). The branch CONDITIONS are
/// identical to ContentView's; only the place they live changed.
///
/// Not `Equatable` — its associated `PausedSessionState` / `TrainingDay` are not
/// Equatable, and tests pattern-match the case + assert on the carried ids instead.
enum ResumeOutcome {
    /// Programme not loaded yet — fall through to the live loop's own Path B resume
    /// (WorkoutView's `trainingDayId == trainingDay.id` guard). No explicit state passed.
    case fallbackToLoop
    /// Path A: the paused day IS `nextIncompleteDay` — pass `saved` as the explicit
    /// resumeState so Path A fires reliably.
    case pathA(resumeState: PausedSessionState)
    /// Path B (elsewhere): the paused day was found in the mesocycle but is NOT
    /// `nextIncompleteDay` — pass both the resume state and the correct training day so
    /// WorkoutView renders the right exercise list.
    case pathBElsewhere(resumeState: PausedSessionState, day: TrainingDay)
    /// The paused day cannot be found anywhere in the mesocycle — show the orphaned
    /// recovery dialog instead of entering the loop.
    case orphaned

    /// Decide the resume outcome from the saved sentinel + the loaded mesocycle.
    /// Mirrors ContentView's inline Resume-button branch conditions exactly.
    static func decide(
        saved: PausedSessionState?,
        viewState: ProgramViewState,
        nextIncompleteDay: () -> (day: TrainingDay, week: TrainingWeek)?,
        findTrainingDay: (UUID) -> (day: TrainingDay, week: TrainingWeek)?
    ) -> ResumeOutcome {
        guard let saved, case .loaded = viewState else {
            // Programme not loaded yet — fall back to Path B in WorkoutView.
            return .fallbackToLoop
        }
        let nextDay = nextIncompleteDay()?.day
        if nextDay?.id == saved.trainingDayId {
            // Normal case: pass as explicit resumeState so Path A fires reliably.
            return .pathA(resumeState: saved)
        } else if let foundResult = findTrainingDay(saved.trainingDayId) {
            // Paused day found elsewhere — pass both the correct training day and the
            // resume state so WorkoutView uses the right exercise list.
            return .pathBElsewhere(resumeState: saved, day: foundResult.day)
        } else {
            // Paused day not found anywhere — can't properly resume.
            return .orphaned
        }
    }
}

// MARK: - Shell

struct AppShell: View {

    @Environment(\.apexTheme) private var theme
    @Environment(AppDependencies.self) private var deps

    @State private var selection: ApexTab = .today
    @State private var showSettings = false

    // ── Live-loop presentation (the loop "rises through" Start, off-tab). ──
    /// True when the workout loop is presented over the current surface — the
    /// faithful translation of the frozen ContentView's `selectedTab = 1` loop entry.
    @State private var showLiveLoop = false

    // ── Lifted machinery (faithful copies of ContentView's; #376 commit 1/2). ──

    /// Stores the confirmed GymProfile. Seeded from UserDefaults cache on launch
    /// so the profile is available immediately without waiting for a network fetch.
    @State private var confirmedProfile: GymProfile? = GymProfile.loadFromUserDefaults()

    /// When true, a ScannerView sheet is presented over the Settings sheet.
    @State private var isRescanning = false

    /// Shared view model for the program — owned here so settings can trigger a
    /// regeneration that updates the program surfaces.
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
    @State private var showTrainingTimeMigrationNotice: Bool = false

    /// Confirms "Start Your Next Programme" before triggering regeneration.
    @State private var showNextProgrammeConfirmation: Bool = false

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

    // MARK: - Paused-session banner navigation

    /// True when the user taps "Resume" on PausedSessionBannerView — pushes
    /// ProgramDayDetailView for the paused day within the loop's NavigationStack.
    @State private var navigateToPausedDayDetail: Bool = false

    var body: some View {
        // Active surface — code-as-switch routing (ADR-0026 (a)).
        surface(for: selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.paper.color.ignoresSafeArea())
            // The bar reserves its own space and propagates a bottom inset into
            // child scroll views, so surface content never renders behind it.
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            // Settings leaves the tab bar for a corner gear (ADR-0026 (b)).
            .overlay(alignment: .topTrailing) { settingsButton }
            .sheet(isPresented: $showSettings) { settingsSheet }
            // The live loop "rises through" Start — an off-tab covered surface
            // presenting the OLD in-session chrome (WorkoutView → ActiveSetView /
            // RestTimerView). The new LiveLoopView core (#350) activates at #351.
            .fullScreenCover(isPresented: $showLiveLoop) {
                liveLoopCover
            }
            .preferredColorScheme(.dark)
            // Preserve the frozen raw-Int `switchToTab` contract via the pure bridge,
            // so the existing feature-view call sites need no edit (ADR-0026 (c)).
            .environment(\.switchToTab) { legacyTab in
                switch ShellRoute.from(legacyTab: legacyTab) {
                case .select(let tab): selection = tab
                // The live-loop entry: present the OLD in-session chrome over the
                // current surface (machinery lifted in #376; flips live at commit 2/2).
                case .presentLiveLoop: showLiveLoop = true
                case .presentSettings: showSettings = true
                }
            }
            // ── Onboarding gate (lifted from ContentView). ──
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView { completedProfile in
                    // Persist the scanned profile so settings / program surfaces see it.
                    if let p = completedProfile {
                        confirmedProfile = p
                    }
                    // Surface the program after onboarding (Train owns the program in the shell).
                    selection = .train
                    showOnboarding = false
                    // Recreate ProgramViewModel with the userId now written to Keychain
                    // during onboarding, then load the freshly generated program.
                    programViewModel = ProgramViewModel(
                        supabaseClient: deps.supabaseClient,
                        programGenerationService: deps.programGenerationService,
                        macroPlanService: deps.macroPlanService,
                        sessionPlanService: deps.sessionPlanService,
                        userId: deps.resolvedUserId,
                        traineeModelService: deps.traineeModelService
                    )
                    Task {
                        await programViewModel?.loadProgram()
                    }
                }
                .environment(deps)
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
                if AppShell.migrationNoticeShouldArm(
                    showOnboarding: showOnboarding,
                    crashAlertArmed: crashAlertArmed,
                    migrationAlreadyShown: UserDefaults.standard.bool(forKey: migrationKey)
                ) {
                    UserDefaults.standard.set(true, forKey: migrationKey)
                    showTrainingTimeMigrationNotice = true
                }
            }
            .alert("Unfinished Workout", isPresented: $showCrashRecoveryAlert) {
                Button("Resume") {
                    guard let vm = programViewModel else {
                        // Programme view model not ready — fall back to Path B in WorkoutView.
                        showLiveLoop = true
                        return
                    }
                    let outcome = ResumeOutcome.decide(
                        saved: crashRecoveryState,
                        viewState: vm.viewState,
                        nextIncompleteDay: {
                            guard case .loaded(let mesocycle) = vm.viewState else { return nil }
                            return vm.nextIncompleteDay(in: mesocycle)
                        },
                        findTrainingDay: { id in
                            guard case .loaded(let mesocycle) = vm.viewState else { return nil }
                            return vm.findTrainingDay(byId: id, in: mesocycle)
                        }
                    )
                    switch outcome {
                    case .fallbackToLoop:
                        showLiveLoop = true
                    case .pathA(let resumeState):
                        crashResumeToPass = resumeState
                        showLiveLoop = true
                    case .pathBElsewhere(let resumeState, let day):
                        crashResumeToPass = resumeState
                        crashResumeDay = day
                        showLiveLoop = true
                    case .orphaned:
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

    // MARK: Routing — code-as-switch

    /// "Is this surface built?" is the literal presence of its real view's
    /// constructor here (ADR-0026 (a)). Today (#348), Progress (#354), and Train
    /// (#357) re-home their real roots now — each reads its data through `deps`,
    /// with the `ProgramViewModel` lifecycle still lifted later (#376, machinery-last).
    @ViewBuilder
    private func surface(for tab: ApexTab) -> some View {
        switch tab {
        case .today:
            // #348: new Today root — the coach/home surface (splash-today.md Part 2).
            // ContentView is preserved for the live app; only this dormant AppShell
            // branch changes. The host owns the data boundary; the ProgramViewModel
            // lifecycle + live Start path are lifted here in #376 (machinery-last).
            TodayRootHost()
        case .train:
            // #357: new Train root — the program day-spine (train.md §3).
            // ProgramOverviewView is preserved for the live ContentView; only this
            // dormant AppShell branch changes. The host owns the data boundary; the
            // ProgramViewModel lifecycle is lifted here in #376 (machinery-last).
            TrainProgramRootHost()
        case .progress:
            // #354: new Progress root — the capability ledger (progress.md §3).
            // ProgressTabView is preserved for the live ContentView; only this
            // dormant AppShell branch changes.
            ProgressRootLedgerHost()
        }
    }

    // MARK: Tab bar (DESIGN.md §Iconography — ink default, accent-ink + filled when selected)

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ApexTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.top, Spacing.sm)
        .background(alignment: .top) {
            theme.surface.color
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    theme.hairline.color.frame(height: 1)   // full-bleed top rule
                }
        }
    }

    private func tabButton(_ tab: ApexTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            VStack(spacing: Spacing.xs) {
                Image(systemName: tab.symbol)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 22, weight: .medium))   // §Iconography medium weight
                Text(tab.title)
                    .apexFont(.label)
            }
            .foregroundStyle(isSelected ? theme.accentInk.color : theme.ink.color)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Settings corner

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accentInk.color)   // interactive → accent-ink
                .padding(Spacing.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    /// The settings corner sheet — the real settings root lifted from ContentView
    /// (#376). Coupled to `programViewModel` for regenerate / reset / rescan.
    private var settingsSheet: some View {
        NavigationStack {
            settingsRootView
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Live loop (the off-tab covered surface — old in-session chrome)

    /// The covered live-loop surface — the faithful copy of ContentView's `workoutTab`
    /// machinery (WorkoutView with its OLD in-session chrome: ActiveSetView /
    /// RestTimerView). Presented over the current surface when the loop "rises through"
    /// Start. The new LiveLoopView core (#350) activates at #351, not here.
    @ViewBuilder
    private var liveLoopCover: some View {
        workoutLoop
            .preferredColorScheme(.dark)
            .environment(\.switchToTab) { legacyTab in
                // Within the covered loop, the legacy contract still routes; a "close
                // to program" (tab 0) or settings request dismisses the cover first.
                switch ShellRoute.from(legacyTab: legacyTab) {
                case .select(let tab):
                    showLiveLoop = false
                    selection = tab
                case .presentLiveLoop:
                    break  // already in the loop
                case .presentSettings:
                    showLiveLoop = false
                    showSettings = true
                }
            }
    }

    // MARK: - Workout Loop (faithful copy of ContentView.workoutTab)

    /// Resolves the mesocycle to render in the loop. Uses the loaded state's mesocycle
    /// normally; while a day's session is generating in place, falls back to
    /// `currentMesocycle` so the loop stays on the workout surface rather than
    /// collapsing to "No Program Yet".
    private func workoutLoopMesocycle(for vm: ProgramViewModel) -> Mesocycle? {
        switch vm.viewState {
        case .loaded(let mesocycle):
            return mesocycle
        case .generatingSession:
            return vm.currentMesocycle
        default:
            return nil
        }
    }

    /// The workout loop body. Routes to `WorkoutView` with the first non-completed day
    /// in the mesocycle. Shows a programme-complete state when all days are done,
    /// or a no-program state when no mesocycle is loaded.
    @ViewBuilder
    private var workoutLoop: some View {
        // Render the workout surface for a loaded programme OR while a single day's
        // session is generating in place — the latter keeps currentMesocycle populated,
        // so the loop must not collapse to "No Program Yet" mid-generation.
        if let vm = programViewModel,
           let mesocycle = workoutLoopMesocycle(for: vm) {
            let isGeneratingSession: Bool = {
                if case .generatingSession = vm.viewState { return true }
                return false
            }()
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
                            // mesocycle before returning to the program so the calendar shows
                            // correctly. The covered loop dismisses back to Train.
                            Task { @MainActor in
                                await programViewModel?.loadProgram()
                                showLiveLoop = false
                                selection = .train
                                crashResumeToPass = nil
                                crashResumeDay = nil
                                programViewModel?.scrollToCurrentWeekTrigger += 1
                            }
                        },
                        resumeState: crashResumeToPass,
                        onSkipSession: {
                            // Persistent skip — advances programme_day_index, records skippedAt.
                            // Resolve via crashResumeDay like the completed/paused siblings above
                            // so a crash-resumed day skips THAT day, not nextIncompleteDay's.
                            if let resumeDay = crashResumeDay,
                               let found = vm.findTrainingDay(byId: resumeDay.id, in: mesocycle) {
                                programViewModel?.markDaySkipped(dayId: found.day.id, weekId: found.week.id)
                            } else {
                                programViewModel?.markDaySkipped(dayId: day.id, weekId: week.id)
                            }
                        },
                        isGeneratingSession: isGeneratingSession,
                        onGenerateSession: ((crashResumeDay ?? day).status == .pending && confirmedProfile != nil)
                            ? {
                                // Generate this not-yet-generated day's session in place.
                                // Resolve day+week like the completed/paused/skip siblings:
                                // crashResumeDay takes precedence (matching the render target),
                                // falling back to nextIncompleteDay's (day, week) pair.
                                let targetDay: TrainingDay
                                let targetWeek: TrainingWeek
                                if let resumeDay = crashResumeDay,
                                   let found = vm.findTrainingDay(byId: resumeDay.id, in: mesocycle) {
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
                        onCloseToTab0: {
                            showLiveLoop = false
                            selection = .train
                        },
                        onResumeStateConsumed: {
                            // One-shot — clear so subsequent loop entries don't re-apply
                            // the same paused state on top of the now-live (or post-error)
                            // session. crashResumeDay stays valid until the session ends
                            // (cleared in onSessionDismissed above) because workoutLoop still
                            // needs it to select the correct trainingDay parameter.
                            crashResumeToPass = nil
                        }
                    )
                    // Paused-session banner — shown when a different day is paused and no
                    // session is currently live (i.e. user is on the PreWorkoutView screen).
                    .safeAreaInset(edge: .top) {
                        if !deps.liveSessionWatcher.isLive,
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
                    Text("Generate a program in the Train tab to start working out.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Button {
                    showLiveLoop = false
                    selection = .train
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

    /// Shown in the loop when every day in the mesocycle is `.completed`.
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
                    showLiveLoop = false
                    showSettings = true
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
        }
    }

    // MARK: - Settings Root (faithful copy of ContentView.settingsRootView)

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
                        print("[AppShell] GymProfile synced to Supabase — \(updatedProfile.equipment.count) items")
                    } catch {
                        // Non-fatal — UserDefaults is the local source of truth.
                        print("[AppShell] GymProfile Supabase sync failed: \(error.localizedDescription)")
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

    // MARK: - #318 alert-collision gate (pure, testable)

    /// The one-time training-time migration notice arms ONLY when no crash-recovery
    /// alert won this launch (J-F7 / #318): two alerts arming in the same `.task` pass
    /// collide and SwiftUI silently drops one. The crash check runs FIRST in the
    /// `.task` and sets `crashAlertArmed`; this predicate is the migration gate that
    /// reads it. Extracted as a pure function so the #318 regression is unit-testable
    /// against `AppShell` (the `.task` ORDERING itself is copied verbatim from
    /// ContentView; only this final gating boolean is named here).
    static func migrationNoticeShouldArm(
        showOnboarding: Bool,
        crashAlertArmed: Bool,
        migrationAlreadyShown: Bool
    ) -> Bool {
        !showOnboarding && !crashAlertArmed && !migrationAlreadyShown
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
            // Restore loaded state or empty state so the program surface isn't stuck on error
            await vm.loadProgram()
        } else {
            // Success — surface the program (Train owns the program in the shell).
            selection = .train
        }
    }
}
