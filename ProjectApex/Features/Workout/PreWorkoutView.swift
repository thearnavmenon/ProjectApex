// Features/Workout/PreWorkoutView.swift
// ProjectApex — P3-T03 / P4-E1
//
// Pre-workout screen shown before a session starts.
// Displays gym streak ring, today's training day summary, and a Start Workout CTA.
//
// Acceptance criteria:
//   ✓ StreakResult ring with consecutive-day count, tier label, tier icon, colour-coded tint
//   ✓ Today's training day: label, exercise count, estimated duration
//   ✓ "Start Workout" → WorkoutSessionManager.startSession() via ViewModel
//   ✓ Preflight state: "Preparing your session…" with spinner
//   ✓ Yesterday's session summary snippet (stub — populated in P4)

import SwiftUI

// MARK: - PreWorkoutView

struct PreWorkoutView: View {

    @Environment(AppDependencies.self) private var deps

    /// The WorkoutViewModel owned by the parent WorkoutView.
    @Bindable var viewModel: WorkoutViewModel

    /// The training day the user is about to do.
    let trainingDay: TrainingDay

    /// The mesocycle this day belongs to.
    let programId: UUID

    /// Streak result from GymStreakService (fetched by WorkoutView).
    let streak: StreakResult

    /// 1-based week number within the mesocycle, written to workout_sessions.week_number.
    var weekNumber: Int = 1
    /// 0-based exercise index to start from (0 = first exercise, N = continue from exercise N+1).
    var startingExerciseIndex: Int = 0
    /// True when the user has never completed a session before (FB-005).
    /// Shows the first-session calibration banner.
    var isFirstSession: Bool = false
    /// Number of completed training days in the current mesocycle (for Day X of Y display).
    var completedDayCount: Int = 0
    /// Total training days in the current mesocycle (for Day X of Y display).
    var totalDayCount: Int = 0
    /// Days since the user's last completed session — nil means first-ever session.
    /// Drives the welcome-back banner when the gap is ≥ 14 days (2.4A).
    var daysSinceLastSession: Int? = nil
    /// Called when the user taps "Skip this session". Defers this day without recording
    /// any session data — the next pending non-skipped day becomes the active session.
    var onSkipSession: (() -> Void)? = nil
    /// Called when the user taps the back button or swipes from the left edge.
    var onBack: (() -> Void)? = nil
    /// Called when the user taps the × close button on the Tab 1 entry path (idle only).
    var onCloseToTab0: (() -> Void)? = nil

    // MARK: - Private state
    @State private var showSkipConfirmation: Bool = false
    @State private var welcomeBackBannerDismissed: Bool = false

    // MARK: - Body

    var body: some View {
        ZStack {
            // Cinematic background with streak tint
            apexBackground

            if viewModel.isPreflight {
                preflightView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 32) {
                        programProgressSection
                        if isFirstSession {
                            firstSessionBanner
                        }
                        if let days = daysSinceLastSession, days >= 14, !welcomeBackBannerDismissed {
                            welcomeBackBanner(days: days)
                        }
                        sessionInfoCard
                        startButton
                        if onSkipSession != nil {
                            skipButton
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 48)
                }
            }
        }
        .gesture(
            DragGesture().onEnded { value in
                guard !viewModel.isPreflight else { return }
                if value.translation.width > 80 {
                    if onBack != nil { onBack?() }
                    else { onCloseToTab0?() }
                }
            }
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !viewModel.isPreflight {
                    if onBack != nil {
                        Button(action: { onBack?() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.80))
                        }
                    } else if onCloseToTab0 != nil {
                        Button(action: { onCloseToTab0?() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.80))
                        }
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Text("Today's Session")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))
            }
        }
    }

    // MARK: - Background

    private var apexBackground: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06)
                .ignoresSafeArea()
            RadialGradient(
                colors: [streak.tintColor.opacity(0.15), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.10),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
        }
    }

    // MARK: - Preflight

    private var preflightView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(streak.tintColor)
                .scaleEffect(1.4)
            Text("Preparing your session\u{2026}")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.60))
            Spacer()
        }
    }

    // MARK: - Programme Progress Section

    private var programProgressSection: some View {
        let progress: CGFloat = totalDayCount > 0 ? CGFloat(completedDayCount) / CGFloat(totalDayCount) : 0

        return VStack(spacing: 20) {
            // Progress ring with Day X of Y inside
            ZStack {
                // Track ring
                Circle()
                    .stroke(streak.tintColor.opacity(0.12), lineWidth: 12)
                    .frame(width: 160, height: 160)

                // Progress arc
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [streak.tintColor.opacity(0.5), streak.tintColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 160, height: 160)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.8), value: completedDayCount)

                // Day count inside ring — hidden until totalDayCount is known
                if totalDayCount > 0 {
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("Day")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Text("\(completedDayCount + 1)")
                                .font(.system(size: 44, weight: .black, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                        Text("of \(totalDayCount)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(streak.tintColor)
                            .tracking(0.5)
                    }
                }
            }
            .padding(.top, 8)

            // Subtitle label
            Text(progressSubtitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.5)
        }
    }

    private var progressSubtitle: String {
        guard totalDayCount > 0 else { return "Programme in progress" }
        let percent = Int(round(Double(completedDayCount) / Double(totalDayCount) * 100))
        return "\(percent)% of programme complete"
    }

    // MARK: - Session Info Card

    private var sessionInfoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trainingDay.dayLabel.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Week \(weekLabel)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(0.3)
                }
                Spacer()
                // Exercise count badge
                Text("\(trainingDay.exercises.count) exercises")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(streak.tintColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(streak.tintColor.opacity(0.12), in: Capsule())
            }
            .padding(20)

            Divider()
                .background(.white.opacity(0.08))

            // Exercise list preview (first 3 + overflow)
            VStack(spacing: 0) {
                let preview = Array(trainingDay.exercises.prefix(3))
                ForEach(Array(preview.enumerated()), id: \.offset) { index, exercise in
                    ExerciseRowPreview(exercise: exercise, tintColor: streak.tintColor)
                    if index < preview.count - 1 {
                        Divider()
                            .background(.white.opacity(0.06))
                            .padding(.leading, 20)
                    }
                }
                if trainingDay.exercises.count > 3 {
                    Text("+ \(trainingDay.exercises.count - 3) more exercises")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                }
            }

            // Duration estimate
            Divider()
                .background(.white.opacity(0.08))
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                Text("~\(estimatedDurationMinutes) min estimated")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    // MARK: - First Session Banner (FB-005)

    private var firstSessionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.20))
            VStack(alignment: .leading, spacing: 3) {
                Text("First session")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("We'll calibrate your starting weights today.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Color(red: 1.0, green: 0.75, blue: 0.20).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(red: 1.0, green: 0.75, blue: 0.20).opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Welcome Back Banner (2.4A)

    private func welcomeBackBanner(days: Int) -> some View {
        let isReturnSession = days >= 28
        let amberColor = Color(red: 1.0, green: 0.65, blue: 0.0)
        let message = isReturnSession
            ? "Welcome back — it's been \(days) days. Today is a recovery session with reduced volume to get you back on track."
            : "Welcome back — it's been \(days) days. We've adjusted today's session to ease back in."
        return HStack(spacing: 12) {
            Image(systemName: isReturnSession ? "arrow.counterclockwise.circle.fill" : "hand.wave.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(amberColor)
            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                welcomeBackBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            amberColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(amberColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            viewModel.startSession(trainingDay: trainingDay, programId: programId, userId: deps.resolvedUserId, weekNumber: weekNumber, startingExerciseIndex: startingExerciseIndex)
        } label: {
            HStack(spacing: 10) {
                if viewModel.isStartingSession {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                Text(viewModel.isStartingSession ? "Loading\u{2026}" : "Start Workout")
                    .font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(
                streak.tintColor.opacity(viewModel.isStartingSession ? 0.40 : 0.85),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.5)
            )
            .animation(.easeInOut(duration: 0.15), value: viewModel.isStartingSession)
        }
        .disabled(viewModel.isStartingSession)
        .padding(.top, 8)
    }

    // MARK: - Skip Button

    private var skipButton: some View {
        Button {
            showSkipConfirmation = true
        } label: {
            Text("Skip this session")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.40))
        }
        .disabled(viewModel.isStartingSession)
        .alert("Skip this session?", isPresented: $showSkipConfirmation) {
            Button("Skip Session", role: .destructive) {
                onSkipSession?()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This session won't be logged and the programme will advance to the next session.")
        }
    }

    // MARK: - Computed helpers

    private var weekLabel: String {
        return "\(weekNumber)"
    }

    private var estimatedDurationMinutes: Int {
        // Rough estimate: 4 sets × 45s work + rest_seconds per exercise
        trainingDay.exercises.reduce(0) { total, exercise in
            let workTime = exercise.sets * 45
            let restTime = exercise.sets * exercise.restSeconds
            return total + (workTime + restTime) / 60
        }
    }
}

// MARK: - ExerciseRowPreview

private struct ExerciseRowPreview: View {
    let exercise: PlannedExercise
    let tintColor: Color

    var body: some View {
        HStack(spacing: 14) {
            // Muscle group colour dot
            Circle()
                .fill(muscleColor(for: exercise.primaryMuscle))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(exercise.sets) sets · \(exercise.repRange.min)–\(exercise.repRange.max) reps")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.40))
            }

            Spacer()

            Text(exercise.equipmentRequired.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.30))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func muscleColor(for muscle: String) -> Color {
        switch muscle {
        case let m where m.contains("pectoral"):  return Color(red: 0.96, green: 0.42, blue: 0.30)
        case let m where m.contains("lat"), let m where m.contains("back"), let m where m.contains("dorsi"):
            return Color(red: 0.30, green: 0.70, blue: 0.96)
        case let m where m.contains("delt"):      return Color(red: 0.70, green: 0.50, blue: 0.96)
        case let m where m.contains("quad"), let m where m.contains("hamstring"), let m where m.contains("glute"):
            return Color(red: 0.30, green: 0.96, blue: 0.60)
        case let m where m.contains("bicep"), let m where m.contains("tricep"):
            return Color(red: 0.96, green: 0.80, blue: 0.30)
        default:                                   return Color.white.opacity(0.40)
        }
    }
}

// MARK: - Preview

#Preview("Pre-Workout — On Fire") {
    let day = Mesocycle.mockMesocycle().weeks[0].trainingDays[0]
    NavigationStack {
        PreWorkoutView(
            viewModel: WorkoutViewModel.mockPreflight(),
            trainingDay: day,
            programId: UUID(),
            streak: StreakResult.compute(currentStreakDays: 12, longestStreak: 14)
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Pre-Workout — Cold") {
    let day = Mesocycle.mockMesocycle().weeks[0].trainingDays[0]
    NavigationStack {
        PreWorkoutView(
            viewModel: WorkoutViewModel.mockPreflight(),
            trainingDay: day,
            programId: UUID(),
            streak: .neutral
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Pre-Workout — First Session") {
    let day = Mesocycle.mockMesocycle().weeks[0].trainingDays[0]
    NavigationStack {
        PreWorkoutView(
            viewModel: WorkoutViewModel.mockPreflight(),
            trainingDay: day,
            programId: UUID(),
            streak: .neutral,
            isFirstSession: true
        )
    }
    .preferredColorScheme(.dark)
}
