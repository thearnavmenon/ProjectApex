// ProgramDayDetailView.swift
// ProjectApex — Features/Program
//
// Drill-in view for a single training day. Shows the full exercise list
// with sets, rep ranges, tempo, rest, and coaching cues.
// Satisfies P2-T06 (stub) and is the NavigationLink destination from ProgramOverviewView.

import SwiftUI

struct ProgramDayDetailView: View {

    let day: TrainingDay
    let week: TrainingWeek

    var body: some View {
        ZStack {
            // Background
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 12) {
                    // Phase + day header
                    dayHeaderSection

                    // Exercise list
                    ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                        ExerciseDetailCard(exercise: exercise, index: index + 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle(day.dayLabel.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Day Header

    private var dayHeaderSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Week \(week.weekNumber) · \(week.phase.displayTitle)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)
                    .kerning(0.8)

                Text("\(day.exercises.count) exercises")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer()

            // Phase badge
            Text(week.phase.displayTitle)
                .font(.caption2.bold())
                .foregroundStyle(week.phase.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(week.phase.accentColor.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - ExerciseDetailCard

private struct ExerciseDetailCard: View {

    let exercise: PlannedExercise
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .top, spacing: 12) {
                // Exercise number badge
                Text("\(index)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    // Muscle chip
                    Text(exercise.primaryMuscle.formattedMuscleName)
                        .font(.caption2.bold())
                        .foregroundStyle(muscleColor(for: exercise.primaryMuscle))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(muscleColor(for: exercise.primaryMuscle).opacity(0.15), in: Capsule())
                }

                Spacer()

                // Equipment chip
                Text(exercise.equipmentRequired.displayName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.08))

            // Prescription grid
            prescriptionGrid
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            // Coaching cues (if any)
            if !exercise.coachingCues.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.08))
                coachingCueSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Prescription Grid

    private var prescriptionGrid: some View {
        HStack(spacing: 0) {
            prescriptionCell(
                label: "SETS",
                value: "\(exercise.sets)"
            )

            prescriptionDivider

            prescriptionCell(
                label: "REPS",
                value: "\(exercise.repRange.min)–\(exercise.repRange.max)"
            )

            prescriptionDivider

            prescriptionCell(
                label: "TEMPO",
                value: exercise.tempo
            )

            prescriptionDivider

            prescriptionCell(
                label: "REST",
                value: restLabel(seconds: exercise.restSeconds)
            )

            prescriptionDivider

            prescriptionCell(
                label: "RIR",
                value: "\(exercise.rirTarget)"
            )
        }
    }

    private func prescriptionCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(0.6)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var prescriptionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 32)
    }

    // MARK: Coaching Cues

    private var coachingCueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COACHING CUES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(0.6)

            ForEach(exercise.coachingCues, id: \.self) { cue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 2)
                    Text(cue)
                        .font(.system(size: 14, weight: .regular).italic())
                        .foregroundStyle(.white.opacity(0.70))
                }
            }
        }
    }

    // MARK: Helpers

    private func muscleColor(for muscle: String) -> Color {
        let lower = muscle.lowercased()
        if lower.contains("pector") || lower.contains("chest") { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if lower.contains("lat") || lower.contains("back") || lower.contains("rhom") { return Color(red: 0.30, green: 0.70, blue: 0.96) }
        if lower.contains("delt") || lower.contains("shoulder") { return Color(red: 0.70, green: 0.50, blue: 0.96) }
        if lower.contains("quad") || lower.contains("hamstr") || lower.contains("glut") || lower.contains("calf") { return Color(red: 0.30, green: 0.96, blue: 0.60) }
        if lower.contains("bicep") || lower.contains("tricep") { return Color(red: 0.96, green: 0.80, blue: 0.30) }
        if lower.contains("core") || lower.contains("abdom") { return Color(red: 0.96, green: 0.60, blue: 0.30) }
        return Color(red: 0.78, green: 0.82, blue: 0.88) // apexChrome fallback
    }

    private func restLabel(seconds: Int) -> String {
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s > 0 ? "\(m):\(String(format: "%02d", s))" : "\(m)m"
        }
        return "\(seconds)s"
    }
}

// MARK: - MesocyclePhase display helpers

extension MesocyclePhase {
    var displayTitle: String {
        switch self {
        case .accumulation:    return "Accumulation"
        case .intensification: return "Intensification"
        case .peaking:         return "Peaking"
        case .deload:          return "Deload"
        }
    }

    var accentColor: Color {
        switch self {
        case .accumulation:    return Color(red: 0.30, green: 0.96, blue: 0.60)  // green
        case .intensification: return Color(red: 0.23, green: 0.56, blue: 1.00)  // blue
        case .peaking:         return Color(red: 0.96, green: 0.42, blue: 0.30)  // orange-red
        case .deload:          return Color(red: 0.54, green: 0.60, blue: 0.69)  // grey-silver
        }
    }
}

// MARK: - String helper

private extension String {
    /// Converts snake_case muscle names to Title Case for display.
    var formattedMuscleName: String {
        self.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

#Preview {
    NavigationStack {
        ProgramDayDetailView(
            day: Mesocycle.mockMesocycle().weeks[0].trainingDays[0],
            week: Mesocycle.mockMesocycle().weeks[0]
        )
    }
}
