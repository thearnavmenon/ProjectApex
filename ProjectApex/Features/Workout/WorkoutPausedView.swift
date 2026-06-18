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
//
// Visual layer restyled to the Brutalist Athletic identity (#473): pure-black surface,
// an amber "Workout paused" hero (amber is the paused token), an `apexCard` context card
// with position/day/time, a dominant lime Resume, an amber-tinted ghost Discard, and a
// quiet "View today's plan" action. Behaviour, bindings, and accessibility are unchanged.

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
            // Pure-black Brutalist backdrop.
            Apex.bg.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                pausedHero

                contextCard
                    .padding(.horizontal, Apex.pad)

                Spacer()

                actions
                    .padding(.horizontal, Apex.pad)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Hero

    private var pausedHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Apex.amber.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: "pause.fill")
                    .font(.system(size: 38, weight: .black))
                    .foregroundStyle(Apex.amber)
            }

            Text("Workout paused")
                .font(.system(size: 30, weight: .heavy))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .foregroundStyle(Apex.amber)

            Text(dayName)
                .font(.system(size: 15, weight: .medium))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textDim)
        }
    }

    // MARK: - Context card (position / day / time — honest from the sentinel)

    private var contextCard: some View {
        VStack(spacing: 14) {
            contextRow(label: "Position", value: exerciseProgress)
            Rectangle().fill(Apex.hairline).frame(height: 1)
            contextRow(label: "Set", value: "\(pausedState.currentSetNumber)")
            Rectangle().fill(Apex.hairline).frame(height: 1)
            contextRow(
                label: "Paused at",
                value: Self.timeFormatter.string(from: pausedState.pausedAt)
            )
        }
        .padding(18)
        .apexCard()
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack {
            ApexSectionLabel(text: label, color: Apex.textFaint)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 14) {
            // Primary — Resume. Dominant volt-lime action.
            Button(action: onResume) {
                ApexButton(title: "Resume workout", icon: "play.fill")
            }
            .accessibilityLabel("Resume workout")
            .accessibilityHint("Picks up your paused session where you left off")

            // Secondary — Discard, destructive. Amber-tinted ghost — recessive.
            Button(role: .destructive, action: onDiscard) {
                ApexButton(title: "Discard workout", kind: .ghost, tint: Apex.amber)
            }
            .accessibilityLabel("Discard workout")
            .accessibilityHint("Ends the paused session without saving its remaining sets")

            // Tertiary — View today's plan. Quiet, recessive text action.
            Button(action: onViewPlan) {
                Text("View today's plan")
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(Apex.textDim)
                    .padding(.vertical, 6)
            }
            .accessibilityLabel("View today's plan")
            .accessibilityHint("Opens the exercise plan without resuming")
        }
    }
}
