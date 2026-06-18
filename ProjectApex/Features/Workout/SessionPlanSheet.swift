// Features/Workout/SessionPlanSheet.swift
// ProjectApex
//
// In-workout "today's plan" sheet. Surfaces the prescription for every exercise
// in the live session alongside the sets the user has logged so far, so the
// user gets session context without leaving the Workout tab.
//
// Restyled to the Brutalist Athletic identity (#473): pure-black surface,
// `apexCard` exercise cards, tabular `ApexNumeral` counts, and a single
// volt-lime "NOW" chip on the current exercise.

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
                Apex.bg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Apex.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("TODAY'S PLAN")
                        .font(.system(size: 12, weight: .semibold))
                        .fontWidth(.condensed)
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .foregroundStyle(Apex.textDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Apex.textDim)
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

        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                ApexNumeral(text: String(format: "%02d", index), size: 15, color: Apex.textFaint)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.system(size: 16, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)

                    HStack(spacing: 8) {
                        ApexSectionLabel(text: humanizedMuscle(exercise.primaryMuscle), color: Apex.textFaint)
                        Text("·")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Apex.textFaint)
                        ApexSectionLabel(
                            text: "\(exercise.repRange.min)–\(exercise.repRange.max) reps · RIR \(exercise.rirTarget)",
                            color: Apex.textFaint
                        )
                    }
                }

                Spacer()

                if isCurrent {
                    Text("Now")
                        .font(.system(size: 11, weight: .black))
                        .textCase(.uppercase)
                        .tracking(1.0)
                        .foregroundStyle(Apex.onAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Apex.accent))
                } else {
                    // Logged / planned set count — tabular so it never reflows.
                    // (The current exercise conveys this via its expanded grid.)
                    HStack(spacing: 0) {
                        ApexNumeral(
                            text: "\(loggedCount)",
                            size: 15,
                            color: loggedCount >= plannedSets ? Apex.accent : Apex.text
                        )
                        ApexNumeral(text: " / \(plannedSets)", size: 15, color: Apex.textDim)
                    }
                }
            }

            // Set grid — one row per planned set, filled if logged.
            Rectangle().fill(Apex.hairline).frame(height: 1)
            VStack(spacing: 6) {
                ForEach(1...max(plannedSets, max(loggedCount, 1)), id: \.self) { setN in
                    setRow(
                        setNumber: setN,
                        log: logs.first(where: { $0.setNumber == setN })
                    )
                }
            }
        }
        .padding(16)
        .apexCard(emphasized: isCurrent)
    }

    @ViewBuilder
    private func setRow(setNumber: Int, log: SetLog?) -> some View {
        HStack(spacing: 12) {
            Text("Set \(setNumber)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(log == nil ? Apex.textFaint : Apex.textDim)
                .frame(width: 46, alignment: .leading)

            if let log {
                HStack(spacing: 6) {
                    ApexNumeral(text: formatWeight(log.weightKg), size: 17)
                    Text("kg")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Apex.textFaint)
                    Text("×")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Apex.textFaint)
                    ApexNumeral(text: "\(log.repsCompleted)", size: 17)
                }

                Spacer()

                if let rpe = log.rpeFelt {
                    Text("RPE \(rpe)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Apex.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Apex.accent.opacity(0.15)))
                }
            } else {
                Text("Pending")
                    .font(.system(size: 12, weight: .semibold))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(Apex.textFaint)
                Spacer()
            }
        }
    }

    // MARK: - Formatting

    /// "142.5" → "142.5", "80.0" → "80". Tabular numerals keep the slot stable.
    private func formatWeight(_ kg: Double) -> String {
        let rounded = (kg * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }

    /// snake_case muscle id (e.g. "pectoralis_major") → "Pectoralis Major".
    private func humanizedMuscle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
