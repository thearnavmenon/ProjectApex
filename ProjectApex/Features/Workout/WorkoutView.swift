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
// Uses a ZStack state machine (not NavigationStack) to prevent
// back-gesture interruptions during a live set. Per TDD §3.4.

import SwiftUI

// MARK: - WorkoutView

struct WorkoutView: View {

    @Environment(AppDependencies.self) private var deps

    // ViewModel is owned here and passed down to child views.
    @State private var viewModel: WorkoutViewModel?
    @State private var streak: StreakResult = .neutral

    // The training day to start — set when user picks a day from the program.
    // For Phase 3 MVP this defaults to the first day of the active mesocycle.
    let trainingDay: TrainingDay
    let programId: UUID

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
        }
    }

    // MARK: - State Router

    @ViewBuilder
    private func contentForState(_ vm: WorkoutViewModel) -> some View {
        switch vm.sessionState {

        case .idle, .preflight:
            NavigationStack {
                PreWorkoutView(
                    viewModel: vm,
                    trainingDay: trainingDay,
                    programId: programId,
                    streak: streak
                )
            }

        case .active(let exercise, let setNumber):
            ActiveSetView(
                viewModel: vm,
                exercise: exercise,
                setNumber: setNumber,
                streak: streak
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
                onDone: { vm.resetSession() }
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
