// ProgramOverviewView.swift
// ProjectApex — Features/Program
//
// 12-week mesocycle calendar grid. Each row is a training week; columns are
// training days. Deload weeks use a distinct silver-tinted background.
// The current week row is highlighted with an accent border.
// Tapping any day card navigates to ProgramDayDetailView.
//
// Acceptance criteria (P2-T05):
// ✓ Scrollable grid: 12 rows (weeks) × N columns (days per week)
// ✓ Each day cell shows day label, primary muscle group chip, training indicator
// ✓ Deload weeks visually distinct (silver / muted background)
// ✓ Current week highlighted with accent border
// ✓ Tap navigates to ProgramDayDetailView
// ✓ Week header shows phase label
// ✓ Loading state while fetching from Supabase
// ✓ Empty state with "Generate My Program" CTA

import SwiftUI

struct ProgramOverviewView: View {

    @State private var viewModel: ProgramViewModel
    /// The confirmed gym profile passed in from ContentView.
    let gymProfile: GymProfile?

    init(supabaseClient: SupabaseClient,
         programGenerationService: ProgramGenerationService,
         gymProfile: GymProfile?) {
        _viewModel = State(initialValue: ProgramViewModel(
            supabaseClient: supabaseClient,
            programGenerationService: programGenerationService
        ))
        self.gymProfile = gymProfile
    }

    var body: some View {
        ZStack {
            // Base background
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

            switch viewModel.viewState {
            case .loading:
                loadingView

            case .empty:
                emptyView

            case .generating:
                generatingView

            case .loaded(let mesocycle):
                loadedView(mesocycle: mesocycle)

            case .error(let message):
                errorView(message: message)
            }
        }
        .navigationTitle("My Program")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await viewModel.loadProgram()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color(red: 0.78, green: 0.82, blue: 0.88))
                .scaleEffect(1.5)
            Text("Loading program…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(Color(red: 0.78, green: 0.82, blue: 0.88).opacity(0.6))

            VStack(spacing: 10) {
                Text("No Program Yet")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(gymProfile == nil
                     ? "Scan your gym first, then generate a personalised 12-week program."
                     : "Generate a personalised 12-week periodised program for your gym.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if gymProfile != nil {
                Button(action: {
                    guard let profile = gymProfile else { return }
                    Task { await viewModel.generateProgram(gymProfile: profile) }
                }) {
                    Label("Generate My Program", systemImage: "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.23, green: 0.56, blue: 1.00))
                .padding(.horizontal, 32)
            } else {
                Text("Scan your gym in the Scanner tab to get started.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.40))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
    }

    // MARK: - Generating

    private var generatingView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated brain icon
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
                .symbolEffect(.pulse)

            VStack(spacing: 10) {
                Text("Building Your Program")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("The AI coach is crafting a personalised 12-week mesocycle. This may take up to a minute.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color(red: 0.23, green: 0.56, blue: 1.00))
                .scaleEffect(1.2)

            Spacer()
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(red: 0.91, green: 0.63, blue: 0.19))

            VStack(spacing: 10) {
                Text("Generation Failed")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button("Try Again") {
                Task { await viewModel.loadProgram() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.23, green: 0.56, blue: 1.00))

            Spacer()
        }
    }

    // MARK: - Loaded: 12-Week Grid

    private func loadedView(mesocycle: Mesocycle) -> some View {
        let currentWeekIndex = viewModel.currentWeekIndex(in: mesocycle)
        return ScrollView {
            LazyVStack(spacing: 2) {
                // Phase progress bar header
                phaseProgressBar(mesocycle: mesocycle, currentWeekIndex: currentWeekIndex)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                // Week rows
                ForEach(Array(mesocycle.weeks.enumerated()), id: \.element.id) { index, week in
                    WeekRowView(
                        week: week,
                        isCurrent: index == currentWeekIndex,
                        weekIndex: index
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Phase Progress Bar

    private func phaseProgressBar(mesocycle: Mesocycle, currentWeekIndex: Int) -> some View {
        let phases: [(phase: MesocyclePhase, weeks: ClosedRange<Int>)] = [
            (.accumulation, 0...3),
            (.intensification, 4...7),
            (.peaking, 8...10),
            (.deload, 11...11)
        ]
        let progress = Double(currentWeekIndex + 1) / Double(max(mesocycle.weeks.count, 1))

        return VStack(alignment: .leading, spacing: 8) {
            // Phase segments
            HStack(spacing: 3) {
                ForEach(phases, id: \.phase) { item in
                    let isActive = item.weeks.contains(currentWeekIndex)
                    let fraction = Double(item.weeks.count) / 12.0
                    Rectangle()
                        .fill(isActive ? item.phase.accentColor : item.phase.accentColor.opacity(0.25))
                        .frame(height: 4)
                        .cornerRadius(2)
                        .frame(maxWidth: .infinity)
                }
            }

            // Phase labels
            HStack(spacing: 0) {
                Text("Accumulation")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Intensification")
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Peaking")
                    .frame(width: 60, alignment: .leading)
                Text("DL")
                    .frame(width: 30, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
            .kerning(0.4)

            HStack {
                Text("Week \(currentWeekIndex + 1) of \(mesocycle.weeks.count)")
                    .font(.footnote.bold())
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                Text("\(Int(progress * 100))% complete")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.40))
            }
        }
    }
}

// MARK: - WeekRowView

private struct WeekRowView: View {

    let week: TrainingWeek
    let isCurrent: Bool
    let weekIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Week header
            HStack(spacing: 8) {
                Text("W\(week.weekNumber)")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isCurrent ? week.phase.accentColor : .white.opacity(0.45))
                    .frame(width: 28, alignment: .leading)

                Text(week.phase.displayTitle.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(week.phase.accentColor.opacity(isCurrent ? 1.0 : 0.55))
                    .kerning(0.8)

                if isCurrent {
                    Text("CURRENT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(week.phase.accentColor, in: Capsule())
                }

                Spacer()

                Text("\(week.trainingDays.count) days")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.30))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Day cards scroll row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(week.trainingDays) { day in
                        NavigationLink {
                            ProgramDayDetailView(day: day, week: week)
                        } label: {
                            DayCardView(day: day, week: week, isCurrentWeek: isCurrent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(weekBackground)
        .overlay(currentWeekBorder)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var weekBackground: some View {
        if week.isDeload {
            // Deload: muted silver-grey tint
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.54, green: 0.60, blue: 0.69).opacity(0.08))
        } else if isCurrent {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(week.phase.accentColor.opacity(0.06))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        }
    }

    @ViewBuilder
    private var currentWeekBorder: some View {
        if isCurrent {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(week.phase.accentColor.opacity(0.50), lineWidth: 1.5)
        } else if week.isDeload {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(red: 0.54, green: 0.60, blue: 0.69).opacity(0.20), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

// MARK: - DayCardView

private struct DayCardView: View {

    let day: TrainingDay
    let week: TrainingWeek
    let isCurrentWeek: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Weekday + day label
            VStack(alignment: .leading, spacing: 2) {
                Text(weekdayLabel(dayOfWeek: day.dayOfWeek))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .kerning(0.5)

                Text(day.dayLabel.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            // Primary muscles chips (top 2)
            let muscles = uniqueTopMuscles(from: day.exercises)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(muscles.prefix(2), id: \.self) { muscle in
                    Text(muscle)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(muscleColor(for: muscle))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(muscleColor(for: muscle).opacity(0.14), in: Capsule())
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Exercise count indicator
            HStack(spacing: 4) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(day.exercises.count) ex")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.40))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 110, height: 120, alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var cardBackground: some View {
        if week.isDeload {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.54, green: 0.60, blue: 0.69).opacity(0.10))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        if isCurrentWeek {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(week.phase.accentColor.opacity(0.35), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: Helpers

    private func weekdayLabel(dayOfWeek: Int) -> String {
        let days = ["", "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
        guard dayOfWeek >= 1 && dayOfWeek <= 7 else { return "DAY" }
        return days[dayOfWeek]
    }

    /// Returns deduplicated top-muscle labels for the day.
    private func uniqueTopMuscles(from exercises: [PlannedExercise]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for ex in exercises {
            let muscle = ex.primaryMuscle.formattedShortMuscleName
            if seen.insert(muscle).inserted {
                result.append(muscle)
            }
            if result.count >= 3 { break }
        }
        return result
    }

    private func muscleColor(for muscle: String) -> Color {
        let lower = muscle.lowercased()
        if lower.contains("chest") || lower.contains("pect") { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if lower.contains("back") || lower.contains("lat") { return Color(red: 0.30, green: 0.70, blue: 0.96) }
        if lower.contains("shoulder") || lower.contains("delt") { return Color(red: 0.70, green: 0.50, blue: 0.96) }
        if lower.contains("leg") || lower.contains("quad") || lower.contains("glut") || lower.contains("hamstr") { return Color(red: 0.30, green: 0.96, blue: 0.60) }
        if lower.contains("arm") || lower.contains("bicep") || lower.contains("tricep") { return Color(red: 0.96, green: 0.80, blue: 0.30) }
        if lower.contains("core") { return Color(red: 0.96, green: 0.60, blue: 0.30) }
        return Color(red: 0.78, green: 0.82, blue: 0.88)
    }
}

// MARK: - String helpers

private extension String {
    /// Short, display-friendly muscle name from snake_case (e.g. "pectoralis_major" → "Chest").
    var formattedShortMuscleName: String {
        let lower = self.lowercased()
        if lower.contains("pector") { return "Chest" }
        if lower.contains("lat_") || lower == "latissimus_dorsi" { return "Back" }
        if lower.contains("deltoid") || lower.contains("delt") { return "Shoulders" }
        if lower.contains("quadricep") { return "Quads" }
        if lower.contains("hamstr") { return "Hamstrings" }
        if lower.contains("glut") { return "Glutes" }
        if lower.contains("bicep") { return "Biceps" }
        if lower.contains("tricep") { return "Triceps" }
        if lower.contains("calf") || lower.contains("gastro") { return "Calves" }
        if lower.contains("abdom") || lower.contains("core") { return "Core" }
        // Fallback: Title Case the raw string
        return self.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ProgramOverviewView(
            supabaseClient: SupabaseClient(supabaseURL: URL(string: "https://example.supabase.co")!, anonKey: ""),
            programGenerationService: ProgramGenerationService(provider: AnthropicProvider(apiKey: "")),
            gymProfile: nil
        )
    }
}
