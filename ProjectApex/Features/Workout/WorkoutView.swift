// Features/Workout/WorkoutView.swift
// ProjectApex — P3-T02 / P3-T03 / P3-T04 / P3-T05
//
// Root Workout tab view. Owns the WorkoutViewModel and routes between:
//
//   • .idle            → PreWorkoutView (day selection / streak)
//   • .preflight       → PreWorkoutView (with isStartingSession spinner)
//   • .active          → ActiveSetView  (P3-T04)
//   • .resting         → RestTimerView  (P3-T05)
//   • .sessionComplete → PostWorkoutSummaryView (P3-T08, stub for now)
//   • .error           → ErrorView
//
// Uses a ZStack state machine to handle state transitions.
// Navigation (back button, tab bar) is provided by the enclosing NavigationStack
// and TabView — WorkoutView no longer owns a NavigationStack.
//
// DEV-LOG — P4 navigation audit:
//   • WorkoutSessionManager is app-level (AppDependencies). Session state is
//     actor-isolated and outlives any view lifecycle. Navigation away from
//     WorkoutView does NOT affect session state.
//   • WorkoutView owns WorkoutViewModel as @State. If the view is popped and
//     re-created, a new viewModel is created and syncs from the actor via
//     syncFromLiveSession(). Polling restarts automatically.
//   • Rest timer: driven by restTimerTask inside the actor, anchored to
//     restExpiresAt (absolute Date). View navigation has no effect on the timer.

import SwiftUI

// MARK: - WorkoutView

struct WorkoutView: View {

    @Environment(AppDependencies.self) private var deps

    // ViewModel is owned here and passed down to child views.
    @State private var viewModel: WorkoutViewModel?
    @State private var streak: StreakResult = .neutral
    /// True when a crash-recovered PausedSessionState exists but its trainingDayId
    /// does not match the current day (and ContentView hasn't handled it via Path A).
    /// Shows a recovery dialog so the user can choose how to proceed.
    @State private var showMismatchRecoveryAlert = false
    @State private var mismatchSavedState: PausedSessionState? = nil
    /// True when the user has never completed a session (session_count == 0 in UserDefaults).
    /// Drives the first-session calibration banner in PreWorkoutView (FB-005).
    private var isFirstSession: Bool {
        UserDefaults.standard.integer(forKey: UserProfileConstants.sessionCountKey) == 0
    }

    // The training day to start — set when user picks a day from the program.
    // For Phase 3 MVP this defaults to the first day of the active mesocycle.
    let trainingDay: TrainingDay
    let programId: UUID
    /// 1-based week number within the mesocycle, written to workout_sessions.week_number.
    var weekNumber: Int = 1
    /// Number of completed training days in the current mesocycle (for Day X of Y display).
    var completedDayCount: Int = 0
    /// Total training days in the current mesocycle (for Day X of Y display).
    var totalDayCount: Int = 0
    /// Called when the session transitions to .sessionComplete (not early exit).
    /// Used by ProgramDayDetailView to mark the day as completed in the calendar.
    var onSessionCompleted: (() -> Void)? = nil
    /// Called when the session is paused mid-workout.
    /// Used by ProgramDayDetailView to mark the day as paused in the calendar.
    var onSessionPaused: (() -> Void)? = nil
    /// Called after the user dismisses the PostWorkoutSummaryView (taps "Done").
    /// Fires after the reset animation completes so the tab switch is not jarring.
    var onSessionDismissed: (() -> Void)? = nil
    /// When non-nil, the view resumes this paused session instead of starting fresh.
    var resumeState: PausedSessionState? = nil
    /// 0-based exercise index to start from when beginning a new session (0 = first exercise).
    var startingExerciseIndex: Int = 0
    /// Called when the user taps "Skip this session" on the pre-workout screen.
    var onSkipSession: (() -> Void)? = nil
    /// Called when the user taps the back button or swipes on the pre-workout screen.
    var onBack: (() -> Void)? = nil

    // MARK: - Body

    var body: some View {
        ZStack {
            // Base background
            Color(red: 0.04, green: 0.04, blue: 0.06)
                .ignoresSafeArea()

            if let vm = viewModel {
                contentForState(vm)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: stateTag(vm.sessionState))
            } else {
                // ViewModel initialising
                ProgressView()
                    .tint(.white.opacity(0.50))
            }
        }
        .task {
            if viewModel == nil {
                viewModel = WorkoutViewModel(manager: deps.workoutSessionManager)
            }
            // Fetch streak from GymStreakService (non-blocking — neutral fallback on error).
            // userId is a placeholder for MVP; auth is wired in a future phase.
            streak = await deps.gymStreakService.computeStreak(userId: AppDependencies.placeholderUserId)

            guard let vm = viewModel else { return }

            // Always sync actor state on view entry.
            // This handles the case where the user navigated away and back — the session
            // is still live in the actor but the viewModel may have stale/nil state.
            await vm.pullState()
            let isLive = await vm.sessionIsLive()
            if isLive {
                // Session already running (e.g. user returned via back button or tab switch).
                // Restart polling so the view stays up to date, then return early.
                vm.beginStatePolling()
                return
            }

            if let resume = resumeState {
                // Explicit resume path — caller (ProgramDayDetailView) already confirmed the intent.
                vm.resumeSession(
                    pausedState: resume,
                    trainingDay: trainingDay,
                    supabase: deps.supabaseClient
                )
            } else if let saved = PausedSessionState.load() {
                if saved.trainingDayId == trainingDay.id {
                    // Crash recovery path — user accepted the recovery alert in ContentView.
                    // The PausedSessionState is still present (ContentView only clears it on Abandon).
                    // Silently resume so the user lands directly in the active session.
                    let isIdle = await deps.workoutSessionManager.sessionState == .idle
                    if isIdle {
                        vm.resumeSession(
                            pausedState: saved,
                            trainingDay: trainingDay,
                            supabase: deps.supabaseClient
                        )
                    }
                } else {
                    // Mismatch: a paused session exists but doesn't match this training day.
                    // ContentView normally handles this via its routing logic (Path A);
                    // this branch is a safety net for edge cases ContentView didn't catch.
                    mismatchSavedState = saved
                    showMismatchRecoveryAlert = true
                }
            }
        }
        .onChange(of: viewModel?.sessionState) { _, newState in
            if case .sessionComplete = newState {
                onSessionCompleted?()
                // Re-fetch streak after session completion so PostWorkoutSummaryView
                // and the next PreWorkoutView both show the updated value.
                Task {
                    streak = await deps.gymStreakService.computeStreak(
                        userId: AppDependencies.placeholderUserId
                    )
                }
            }
            // Detect pause: session went idle while a PausedSessionState exists
            if case .idle = newState {
                if PausedSessionState.load() != nil {
                    onSessionPaused?()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showInferenceRetrySheet ?? false },
            set: { _ in /* sheet is interactiveDismissDisabled — this is never called by swipe */ }
        )) {
            if let vm = viewModel {
                InferenceRetrySheet(viewModel: vm)
                    .presentationDetents([.medium])
                    .presentationCornerRadius(24)
            }
        }
        .alert("Session Mismatch", isPresented: $showMismatchRecoveryAlert) {
            Button("Start Fresh") {
                // Clear the orphaned sentinel so the user can start a new session.
                PausedSessionState.clear()
                mismatchSavedState = nil
            }
            Button("Discard Session", role: .destructive) {
                if let saved = mismatchSavedState {
                    Task {
                        await deps.workoutSessionManager.abandonSession(sessionId: saved.sessionId)
                    }
                }
                mismatchSavedState = nil
            }
        } message: {
            Text("A previous session was found but doesn't match this training day. Start fresh or discard the old session?")
        }
    }

    // MARK: - State Router

    @ViewBuilder
    private func contentForState(_ vm: WorkoutViewModel) -> some View {
        switch vm.sessionState {

        case .idle, .preflight:
            PreWorkoutView(
                viewModel: vm,
                trainingDay: trainingDay,
                programId: programId,
                streak: streak,
                weekNumber: weekNumber,
                startingExerciseIndex: startingExerciseIndex,
                isFirstSession: isFirstSession,
                completedDayCount: completedDayCount,
                totalDayCount: totalDayCount,
                onSkipSession: onSkipSession,
                onBack: onBack
            )

        case .active(let exercise, let setNumber):
            ActiveSetView(
                viewModel: vm,
                exercise: exercise,
                setNumber: setNumber,
                streak: streak,
                speechService: deps.speechService,
                exerciseSwapService: deps.exerciseSwapService
            )
            .transition(.apexSetComplete)

        case .resting(let nextExercise, let setNumber):
            RestTimerView(
                viewModel: vm,
                nextExercise: nextExercise,
                setNumber: setNumber,
                streak: streak
            )
            .transition(.apexSetComplete)

        case .exerciseComplete:
            // Transient state — briefly shown while transitioning to next exercise
            exerciseCompletePlaceholder(vm: vm)

        case .sessionComplete(let summary):
            PostWorkoutSummaryView(
                summary: summary,
                streak: streak,
                onDone: {
                    vm.resetSession()
                    // Delay the tab switch until after the dismiss animation completes.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000) // 0.35 s
                        onSessionDismissed?()
                    }
                },
                completedSets: vm.completedSets
            )

        case .error(let message):
            errorView(message: message, vm: vm)
        }
    }

    // MARK: - Exercise Complete (transient flash state)

    private func exerciseCompletePlaceholder(vm: WorkoutViewModel) -> some View {
        ZStack {
            apexBackground(tint: streak.tintColor)
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(streak.tintColor)
                Text("Exercise Complete")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Error View

    private func errorView(message: String, vm: WorkoutViewModel) -> some View {
        ZStack {
            apexBackground(tint: .init(red: 0.91, green: 0.28, blue: 0.19))
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0))
                Text("Session Error")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Background helper

    private func apexBackground(tint: Color) -> some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [tint.opacity(0.15), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.10),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
        }
    }

    // MARK: - State identity for animation transitions

    private func stateTag(_ state: SessionState) -> Int {
        switch state {
        case .idle:             return 0
        case .preflight:        return 1
        case .active:           return 2
        case .resting:          return 3
        case .exerciseComplete: return 4
        case .sessionComplete:  return 5
        case .error:            return 6
        }
    }
}

// MARK: - Transition Token

private extension AnyTransition {
    static var apexSetComplete: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal:   .move(edge: .top).combined(with: .opacity)
        )
    }
}

// MARK: - Previews

#Preview("Idle / Pre-Workout") {
    WorkoutView(
        trainingDay: Mesocycle.mockMesocycle().weeks[0].trainingDays[0],
        programId: UUID()
    )
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}

#Preview("Active Set") {
    let _ = WorkoutViewModel.mockActive()
    WorkoutView(
        trainingDay: Mesocycle.mockMesocycle().weeks[0].trainingDays[0],
        programId: UUID()
    )
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}

#Preview("Rest Timer") {
    let _ = WorkoutViewModel.mockResting()
    WorkoutView(
        trainingDay: Mesocycle.mockMesocycle().weeks[0].trainingDays[0],
        programId: UUID()
    )
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}
