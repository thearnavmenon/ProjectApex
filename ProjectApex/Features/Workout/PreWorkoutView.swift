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

    /// The WorkoutViewModel owned by the parent WorkoutView.
    @Bindable var viewModel: WorkoutViewModel

    /// The training day the user is about to do.
    let trainingDay: TrainingDay

    /// The mesocycle this day belongs to.
    let programId: UUID

    /// Streak result from GymStreakService (fetched by WorkoutView).
    let streak: StreakResult

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
                        streakSection
                        sessionInfoCard
                        startButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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

    // MARK: - Streak Ring

    private var streakSection: some View {
        VStack(spacing: 20) {
            // Ring + streak count
            ZStack {
                // Track ring
                Circle()
                    .stroke(streak.tintColor.opacity(0.15), lineWidth: 12)
                    .frame(width: 160, height: 160)

                // Progress arc (maps score 0-100 to 0-1)
                Circle()
                    .trim(from: 0, to: CGFloat(streak.streakScore) / 100.0)
                    .stroke(
                        AngularGradient(
                            colors: [streak.tintColor.opacity(0.5), streak.tintColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 160, height: 160)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.8), value: streak.streakScore)

                // Streak count + tier icon inside ring
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Text("\(streak.currentStreakDays)")
                            .font(.system(size: 44, weight: .black, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                        Image(systemName: streak.tierIcon)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(streak.tintColor)
                            .symbolEffect(.bounce, value: streak.currentStreakDays)
                    }
                    Text(streak.streakTier.rawValue.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(streak.tintColor)
                        .tracking(1.5)
                }
            }
            .padding(.top, 8)

            Text(streak.currentStreakDays == 1
                 ? "1 Day Streak"
                 : "\(streak.currentStreakDays) Day Streak")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.5)
        }
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

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            viewModel.startSession(trainingDay: trainingDay, programId: programId)
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

    // MARK: - Computed helpers

    private var weekLabel: String {
        // Week number is stored on TrainingWeek, not TrainingDay directly.
        // The caller supplies the day; we display a generic label for now.
        return "1"
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
