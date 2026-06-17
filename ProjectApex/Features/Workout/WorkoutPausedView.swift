// Features/Workout/WorkoutPausedView.swift
// ProjectApex — #461
//
// The deliberate "Workout paused" screen. Shown when the Workout tab is opened and a
// paused sentinel matches the hosted day (actor .idle + matching PausedSessionState).
// Replaces the old auto-resume-on-appearance behaviour: resuming is now a tap on the
// Resume button, which calls the same #441 single resume function via `onResume`.
//
// Honest data only — the screen reads from the durable sentinel, which carries position
// (exerciseIndex / currentSetNumber), the day type, and the pause timestamp. It does NOT
// show a completed-set count or an elapsed-duration timer (those only exist after the
// network merge inside resume), so the timing line is "Paused at <time>", not a counter.
//
// Copy is neutral ("Workout paused") because the single sentinel cannot distinguish a
// user pause from an app-kill mid-session — both funnel here and both require a tap.

import SwiftUI

struct WorkoutPausedView: View {

    let pausedState: PausedSessionState
    let trainingDay: TrainingDay
    /// Deliberate resume — calls the #441 single resume function in the host.
    let onResume: () -> Void
    /// Discard the paused session (abandons it and clears the sentinel in the host).
    let onDiscard: () -> Void
    /// Open the read-only plan sheet for today's day.
    let onViewPlan: () -> Void

    private static let amber = Color(red: 1.0, green: 0.65, blue: 0.0)
    private static let accent = Color(red: 0.25, green: 0.72, blue: 1.0)

    /// Short time-of-day ("4:15 PM"), no date — mirrors ContentView.crashRecoveryMessage.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var dayName: String {
        trainingDay.dayLabel.replacingOccurrences(of: "_", with: " ")
    }

    private var exerciseProgress: String {
        let total = trainingDay.exercises.count
        let current = min(pausedState.exerciseIndex + 1, max(total, 1))
        return "Exercise \(current) of \(total)"
    }

    var body: some View {
        ZStack {
            // Base background with a subtle amber wash to read as "paused".
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [Self.amber.opacity(0.14), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.12),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(Self.amber)

                    Text("Workout paused")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)

                    Text(dayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }

                // Where you left off — position only (honest from the sentinel).
                VStack(spacing: 10) {
                    progressRow(icon: "figure.strengthtraining.traditional", text: exerciseProgress)
                    progressRow(icon: "number", text: "Set \(pausedState.currentSetNumber)")
                    progressRow(
                        icon: "clock",
                        text: "Paused at \(Self.timeFormatter.string(from: pausedState.pausedAt))"
                    )
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(
                    .white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                )
                .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 14) {
                    // Primary — Resume.
                    Button(action: onResume) {
                        Text("Resume workout")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.06))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(Self.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .accessibilityLabel("Resume workout")
                    .accessibilityHint("Picks up your paused session where you left off")

                    // Secondary — View today's plan.
                    Button(action: onViewPlan) {
                        Text("View today's plan")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
                            )
                    }
                    .accessibilityLabel("View today's plan")
                    .accessibilityHint("Opens the exercise plan without resuming")

                    // Tertiary — Discard, destructive.
                    Button(role: .destructive, action: onDiscard) {
                        Text("Discard workout")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.38))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .accessibilityLabel("Discard workout")
                    .accessibilityHint("Ends the paused session without saving its remaining sets")
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
    }

    private func progressRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22)
            Text(text)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.90))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
