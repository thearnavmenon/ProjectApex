// Features/Workout/SessionPlanSheet.swift
// ProjectApex
//
// In-workout "today's plan" sheet. Surfaces the prescription for every exercise
// in the live session alongside the sets the user has logged so far, so the
// user gets session context without leaving the Workout tab.

import SwiftUI

struct SessionPlanSheet: View {

    let trainingDay: TrainingDay
    let completedSets: [SetLog]
    /// `exerciseId` of the exercise currently being performed (or rested between),
    /// derived from the session FSM. Used to render a subtle "current" chip.
    let currentExerciseId: String?

    @Environment(\.dismiss) private var dismiss

    private var setsByExerciseId: [String: [SetLog]] {
        Dictionary(grouping: completedSets, by: \.exerciseId)
            .mapValues { $0.sorted(by: { $0.setNumber < $1.setNumber }) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(trainingDay.exercises.enumerated()), id: \.element.id) { index, exercise in
                            exerciseRow(
                                exercise: exercise,
                                index: index + 1,
                                logs: setsByExerciseId[exercise.exerciseId] ?? []
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Today's Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Exercise Row

    @ViewBuilder
    private func exerciseRow(exercise: PlannedExercise, index: Int, logs: [SetLog]) -> some View {
        let isCurrent = exercise.exerciseId == currentExerciseId
        let plannedSets = exercise.sets
        let loggedCount = logs.count
        let accent = Color(red: 0.23, green: 0.56, blue: 1.00)

        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("\(plannedSets) sets · \(exercise.repRange.min)–\(exercise.repRange.max) reps · RIR \(exercise.rirTarget)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Spacer()

                if isCurrent {
                    Text("CURRENT")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.15), in: Capsule())
                }
            }

            // Set grid — one row per planned set, filled if logged
            VStack(spacing: 6) {
                ForEach(1...max(plannedSets, max(loggedCount, 1)), id: \.self) { setN in
                    setRow(
                        setNumber: setN,
                        log: logs.first(where: { $0.setNumber == setN })
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(isCurrent ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isCurrent ? accent.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func setRow(setNumber: Int, log: SetLog?) -> some View {
        HStack(spacing: 10) {
            Text("Set \(setNumber)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(log == nil ? 0.30 : 0.50))
                .frame(width: 48, alignment: .leading)

            if let log {
                Text(formatWeight(log.weightKg))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)

                Text("×")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))

                Text("\(log.repsCompleted) reps")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                if let rpe = log.rpeFelt {
                    Text("· RPE \(rpe)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 0.24, green: 0.82, blue: 0.46))
            } else {
                Text("pending")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.30))
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func formatWeight(_ kg: Double) -> String {
        let rounded = (kg * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))kg"
        }
        return String(format: "%.1fkg", rounded)
    }
}
