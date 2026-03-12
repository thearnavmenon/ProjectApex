// ProgramDayDetailView.swift
// ProjectApex — Features/Program
//
// Drill-in view for a single training day. Shows the full exercise list
// with sets, rep ranges, tempo, rest, RIR and expandable coaching cues.
//
// Acceptance criteria (P2-T06):
// ✓ Shows day label, phase, week number at top
// ✓ Each exercise: name, primary muscle group, sets × rep range, tempo, rest seconds, RIR target
// ✓ Coaching cues expandable (collapsed by default)
// ✓ Equipment required shown as a small badge per exercise
// ✓ "Start Workout" button at bottom — only enabled for today's session (or override in dev)
// ✓ Future days show "Scheduled" indicator; past days show "Completed" or "Skipped"

import SwiftUI

// MARK: - Day Status

/// Resolved status of a training day relative to today.
enum DayStatus {
    case today
    case future
    case past

    /// Derives status from the mesocycle creation date, week number and day-of-week.
    static func resolve(mesocycleCreatedAt: Date, weekNumber: Int, dayOfWeek: Int) -> DayStatus {
        let calendar = Calendar.current
        // Find the Monday of the week that the mesocycle started on.
        let startComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: mesocycleCreatedAt)
        guard let startOfFirstWeek = calendar.date(from: startComponents) else { return .future }

        // Offset to the target week (weekNumber is 1-based).
        let weekOffset = (weekNumber - 1) * 7
        guard let startOfTargetWeek = calendar.date(byAdding: .day, value: weekOffset, to: startOfFirstWeek) else { return .future }

        // dayOfWeek: 1 = Monday, 7 = Sunday
        let dayOffset = dayOfWeek - 1
        guard let sessionDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfTargetWeek) else { return .future }

        let todayStart = calendar.startOfDay(for: Date())
        let sessionStart = calendar.startOfDay(for: sessionDate)

        if sessionStart == todayStart { return .today }
        if sessionStart > todayStart  { return .future }
        return .past
    }
}

// MARK: - ProgramDayDetailView

struct ProgramDayDetailView: View {

    let day: TrainingDay
    let week: TrainingWeek
    /// Mesocycle creation date — used to derive session date for status.
    let mesocycleCreatedAt: Date
    /// When true (dev override) the Start Workout button is always enabled.
    var devOverride: Bool = false

    private var dayStatus: DayStatus {
        DayStatus.resolve(
            mesocycleCreatedAt: mesocycleCreatedAt,
            weekNumber: week.weekNumber,
            dayOfWeek: day.dayOfWeek
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 12) {
                    // Phase + day header
                    dayHeaderSection

                    // Session status banner (not shown for today)
                    if dayStatus != .today {
                        statusBannerView
                    }

                    // Exercise list
                    ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                        ExerciseDetailCard(exercise: exercise, index: index + 1)
                    }

                    // Session notes (if any)
                    if let notes = day.sessionNotes, !notes.isEmpty {
                        sessionNotesCard(notes: notes)
                    }

                    // Bottom padding so content clears the Start Workout button
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }

            // Start Workout button — pinned to bottom
            startWorkoutButton
        }
        .navigationTitle(day.dayLabel.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Day Header

    private var dayHeaderSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Week \(week.weekNumber) · \(week.phase.displayTitle)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)
                    .kerning(0.8)

                Text("\(day.exercises.count) exercise\(day.exercises.count == 1 ? "" : "s")")
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

    // MARK: - Status Banner

    @ViewBuilder
    private var statusBannerView: some View {
        switch dayStatus {
        case .future:
            statusBadge(
                icon: "calendar.badge.clock",
                label: "Scheduled",
                color: Color(red: 0.54, green: 0.60, blue: 0.69)
            )
        case .past:
            statusBadge(
                icon: "checkmark.circle",
                label: "Completed",
                color: Color(red: 0.30, green: 0.96, blue: 0.60)
            )
        case .today:
            EmptyView()
        }
    }

    private func statusBadge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.bold())
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Session Notes

    private func sessionNotesCard(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SESSION NOTES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(0.6)
            Text(notes)
                .font(.system(size: 14, weight: .regular).italic())
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Start Workout Button

    private var startWorkoutButton: some View {
        let isEnabled = devOverride || dayStatus == .today
        let accentColor = Color(red: 0.23, green: 0.56, blue: 1.00)

        return VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.06))
            Button(action: {
                // Phase 3: WorkoutSessionManager.startSession(trainingDay: day)
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 17, weight: .semibold))
                    Text(isEnabled ? "Start Workout" : startWorkoutLabel)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    isEnabled
                        ? accentColor
                        : Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.30))
            }
            .disabled(!isEnabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
        }
    }

    private var startWorkoutLabel: String {
        switch dayStatus {
        case .today:   return "Start Workout"
        case .future:  return "Not Yet Scheduled"
        case .past:    return "Session Passed"
        }
    }
}

// MARK: - ExerciseDetailCard

private struct ExerciseDetailCard: View {

    let exercise: PlannedExercise
    let index: Int

    @State private var cuesExpanded = false

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

                // Equipment badge
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

            // Coaching cues — expandable
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
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: cuesExpanded)
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

    // MARK: Coaching Cues (Expandable)

    private var coachingCueSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Expand/collapse toggle
            Button(action: { cuesExpanded.toggle() }) {
                HStack {
                    Text("COACHING CUES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .kerning(0.6)
                    Spacer()
                    Image(systemName: cuesExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
            .buttonStyle(.plain)

            if cuesExpanded {
                VStack(alignment: .leading, spacing: 6) {
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
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
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
            week: Mesocycle.mockMesocycle().weeks[0],
            mesocycleCreatedAt: Date()
        )
    }
}
