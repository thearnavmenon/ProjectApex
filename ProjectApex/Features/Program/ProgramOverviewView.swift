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

    @Environment(AppDependencies.self) private var deps

    @Bindable var viewModel: ProgramViewModel
    /// The confirmed gym profile passed in from ContentView.
    let gymProfile: GymProfile?

    /// Controls the collapsed/expanded state of the pattern progress section.
    @State private var isPatternProgressExpanded = false
    /// The training day ID that has an active live session, nil when idle.
    @State private var liveTrainingDayId: UUID? = nil
    /// Aggregated set progress for the live session, updated every poll cycle.
    @State private var liveSetSummary: LiveSetSummary? = nil

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

            case .generatingSession:
                // FB-008: A day session is being generated — keep showing the calendar
                // The individual ProgramDayDetailView shows its own loading screen.
                if let mesocycle = viewModel.currentMesocycle {
                    loadedView(mesocycle: mesocycle)
                } else {
                    generatingView
                }

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
        .task {
            // Poll the actor every 2 seconds so the live-session card highlight
            // and set-progress numbers update without requiring view navigation.
            while !Task.isCancelled {
                let activeId = await deps.workoutSessionManager.currentTrainingDayId
                let state    = await deps.workoutSessionManager.sessionState
                let isLive: Bool
                switch state {
                case .idle, .sessionComplete, .error: isLive = false
                default: isLive = true
                }
                liveTrainingDayId = isLive ? activeId : nil
                if isLive {
                    let sets = await deps.workoutSessionManager.completedSets
                    let last = sets.max(by: { $0.loggedAt < $1.loggedAt })
                    liveSetSummary = LiveSetSummary(
                        setsCompleted: sets.count,
                        lastWeightKg: last?.weightKg,
                        lastRepsCompleted: last?.repsCompleted
                    )
                } else {
                    liveSetSummary = nil
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
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
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Phase progress bar header
                    phaseProgressBar(mesocycle: mesocycle, currentWeekIndex: currentWeekIndex)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                        .id("header")

                    // Per-pattern phase tracking — collapsed by default
                    patternProgressSection

                    // Phase ranges (0-based week indices), matching phaseProgressBar above.
                    let phaseRanges: [(phase: MesocyclePhase, range: ClosedRange<Int>)] = [
                        (.accumulation,    0...3),
                        (.intensification, 4...7),
                        (.peaking,         8...10),
                        (.deload,          11...11)
                    ]

                    // Week rows
                    ForEach(Array(mesocycle.weeks.enumerated()), id: \.element.id) { index, week in
                        // Compute phase-relative week position for the row label
                        let phaseInfo = phaseRanges.first { $0.range.contains(index) }
                        let phaseStart     = phaseInfo?.range.lowerBound ?? 0
                        let phaseEnd       = phaseInfo?.range.upperBound ?? 0
                        let phaseWeekNum   = index - phaseStart + 1
                        let phaseWeekTot   = phaseEnd - phaseStart + 1

                        WeekRowView(
                            week: week,
                            isCurrent: index == currentWeekIndex,
                            weekIndex: index,
                            mesocycleCreatedAt: mesocycle.createdAt,
                            mesocycleId: mesocycle.id,
                            viewModel: viewModel,
                            gymProfile: gymProfile,
                            phaseWeekNumber: phaseWeekNum,
                            phaseWeekTotal: phaseWeekTot,
                            liveTrainingDayId: liveTrainingDayId,
                            liveSetSummary: liveSetSummary
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .id(week.id)
                    }
                }
                .padding(.bottom, 32)
            }
            .onAppear {
                scrollToCurrentWeek(proxy: proxy, mesocycle: mesocycle, currentWeekIndex: currentWeekIndex)
            }
            .onChange(of: viewModel.scrollToCurrentWeekTrigger) { _, _ in
                withAnimation(.easeInOut(duration: 0.5)) {
                    scrollToCurrentWeek(proxy: proxy, mesocycle: mesocycle, currentWeekIndex: currentWeekIndex)
                }
            }
        }
    }

    private func scrollToCurrentWeek(proxy: ScrollViewProxy, mesocycle: Mesocycle, currentWeekIndex: Int) {
        guard currentWeekIndex < mesocycle.weeks.count else { return }
        let targetWeek = mesocycle.weeks[currentWeekIndex]
        proxy.scrollTo(targetWeek.id, anchor: .top)
    }

    // MARK: - Pattern Progress Section

    /// Collapsible section showing per-movement-pattern phase state.
    /// Only renders when PatternPhaseService has tracked data.
    @ViewBuilder
    private var patternProgressSection: some View {
        let states = PatternPhaseService.load()
        if !states.isEmpty {
            VStack(spacing: 0) {
                // Collapse/expand header
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isPatternProgressExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text("PATTERN PROGRESS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .kerning(0.6)
                        Spacer()
                        Image(systemName: isPatternProgressExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.30))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if isPatternProgressExpanded {
                    VStack(spacing: 6) {
                        ForEach(states) { state in
                            patternPhaseRow(state)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Color.white.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func patternPhaseRow(_ state: MovementPatternPhaseState) -> some View {
        let progress: Double = state.sessionsRequiredForPhase > 0
            ? min(Double(state.sessionsCompletedInPhase) / Double(state.sessionsRequiredForPhase), 1.0)
            : 1.0
        return HStack(spacing: 10) {
            // Human-readable pattern name (e.g. "Horizontal Push")
            Text(formatPatternName(state.pattern))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Phase badge
            Text(shortPhaseName(state.phase))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(state.phase.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(state.phase.accentColor.opacity(0.15), in: Capsule())

            // Session counter: N/M
            Text("\(state.sessionsCompletedInPhase)/\(state.sessionsRequiredForPhase)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.40))
                .frame(width: 36, alignment: .trailing)

            // Mini progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(state.phase.accentColor.opacity(0.70))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(width: 48, height: 4)
        }
    }

    private func shortPhaseName(_ phase: MesocyclePhase) -> String {
        switch phase {
        case .accumulation:    return "ACCUM"
        case .intensification: return "INTENS"
        case .peaking:         return "PEAK"
        case .deload:          return "DELOAD"
        }
    }

    private func formatPatternName(_ pattern: String) -> String {
        pattern.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    // MARK: - Phase Progress Bar

    private func phaseProgressBar(mesocycle: Mesocycle, currentWeekIndex: Int) -> some View {
        let phases: [(phase: MesocyclePhase, weeks: ClosedRange<Int>)] = [
            (.accumulation, 0...3),
            (.intensification, 4...7),
            (.peaking, 8...10),
            (.deload, 11...11)
        ]

        // Count completed+skipped sessions across all days for the progress label.
        // Skipped sessions advance the programme pointer, so they count toward progress.
        let allDays = mesocycle.weeks.flatMap { $0.trainingDays }
        let completedCount = allDays.filter { $0.status == .completed || $0.status == .skipped }.count
        let totalDays = allDays.count
        // Session-based completion fraction — updates immediately when a day is marked done.
        let sessionProgress = totalDays > 0 ? Double(completedCount) / Double(totalDays) : 0.0

        return VStack(alignment: .leading, spacing: 8) {
            // Phase segments
            HStack(spacing: 3) {
                ForEach(phases, id: \.phase) { item in
                    let isActive = item.weeks.contains(currentWeekIndex)
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
                // Show sessions completed / total; percentage updates live as days complete.
                Text("\(completedCount) of \(totalDays) sessions · \(Int(sessionProgress * 100))%")
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
    let mesocycleCreatedAt: Date
    let mesocycleId: UUID
    let viewModel: ProgramViewModel
    let gymProfile: GymProfile?
    /// 1-based position of this week within its phase (e.g. 2 for the 2nd accumulation week).
    let phaseWeekNumber: Int
    /// Total weeks in this week's phase (e.g. 4 for accumulation).
    let phaseWeekTotal: Int
    /// The training day ID that currently has a live session, nil when idle.
    var liveTrainingDayId: UUID? = nil
    /// Aggregated set progress for the live session (nil when no session active).
    var liveSetSummary: LiveSetSummary? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Week header
            HStack(spacing: 8) {
                Text("W\(week.weekNumber)")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isCurrent ? week.phase.accentColor : .white.opacity(0.45))
                    .frame(width: 28, alignment: .leading)

                // FB-008: Show weekLabel if available, else fall back to phase title
                Text((week.weekLabel ?? week.phase.displayTitle).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(week.phase.accentColor.opacity(isCurrent ? 1.0 : 0.55))
                    .kerning(0.8)
                    .lineLimit(1)

                if isCurrent {
                    Text("CURRENT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(week.phase.accentColor, in: Capsule())
                }

                Spacer()

                // Phase-relative progress: "Week 2 of 4"
                Text("Week \(phaseWeekNumber) of \(phaseWeekTotal)")
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
                            ProgramDayDetailView(
                                day: day,
                                week: week,
                                mesocycleCreatedAt: mesocycleCreatedAt,
                                programId: mesocycleId,
                                viewModel: viewModel,
                                gymProfile: gymProfile
                            )
                        } label: {
                            DayCardView(
                                day: day,
                                week: week,
                                isCurrentWeek: isCurrent,
                                isLive: day.id == liveTrainingDayId,
                                liveSetSummary: day.id == liveTrainingDayId ? liveSetSummary : nil
                            )
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

// MARK: - LiveSetSummary

/// Snapshot of live session progress passed from ProgramOverviewView down to DayCardView.
struct LiveSetSummary: Equatable, Sendable {
    let setsCompleted: Int
    let lastWeightKg: Double?
    let lastRepsCompleted: Int?
}

// MARK: - DayCardView

private struct DayCardView: View {

    let day: TrainingDay
    let week: TrainingWeek
    let isCurrentWeek: Bool
    var isLive: Bool = false
    /// Aggregated progress for the current live session. Non-nil only when isLive == true.
    var liveSetSummary: LiveSetSummary? = nil

    @State private var livePulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPending: Bool   { day.status == .pending }
    private var isCompleted: Bool { day.status == .completed }
    private var isPaused: Bool    { day.status == .paused }
    private var isSkipped: Bool   { day.status == .skipped }

    // Green used for completed day styling
    private let completedGreen = Color(red: 0.24, green: 0.82, blue: 0.46)
    private let pausedAmber    = Color(red: 1.00, green: 0.70, blue: 0.10)
    private let skippedGrey    = Color(red: 0.55, green: 0.58, blue: 0.63)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Weekday + day label row
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(weekdayLabel(dayOfWeek: day.dayOfWeek))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isCompleted ? completedGreen.opacity(0.6) : .white.opacity(0.35))
                        .kerning(0.5)

                    Text(day.dayLabel.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(isPending ? .white.opacity(0.55) : isCompleted ? completedGreen : isPaused ? pausedAmber : isSkipped ? skippedGrey : .white)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Status icon — record for live, checkmark for completed, pause for paused, xmark for skipped
                if isLive {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(week.phase.accentColor)
                        .opacity(reduceMotion ? 0.6 : (livePulse ? 1.0 : 0.4))
                        .accessibilityLabel("Session in progress")
                } else if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(completedGreen)
                        .accessibilityLabel("Session completed")
                } else if isPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(pausedAmber)
                        .accessibilityLabel("Session paused")
                } else if isSkipped {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(skippedGrey)
                        .accessibilityLabel("Session skipped")
                }
            }

            if isLive {
                // Live session — set progress (if any sets logged) then pulsing LIVE badge
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    if let s = liveSetSummary, s.setsCompleted > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.setsCompleted) set\(s.setsCompleted == 1 ? "" : "s") done")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.70))
                            if let kg = s.lastWeightKg, let reps = s.lastRepsCompleted {
                                Text("\(formatWeight(kg))kg · \(reps) reps")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(week.phase.accentColor)
                            .frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.6 : (livePulse ? 1.0 : 0.2))
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(week.phase.accentColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(week.phase.accentColor.opacity(0.14), in: Capsule())
                }
            } else if isPending {
                // FB-008: Session pending indicator
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Session\npending")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(2)
                }
            } else if isCompleted {
                // Completed: show "Done" label in green
                Spacer(minLength: 0)
                Text("DONE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(completedGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(completedGreen.opacity(0.14), in: Capsule())
            } else if isPaused {
                // Paused: show "PAUSED" capsule in amber
                Spacer(minLength: 0)
                Text("PAUSED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(pausedAmber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pausedAmber.opacity(0.14), in: Capsule())
            } else if isSkipped {
                // Skipped: show "SKIPPED" capsule in grey
                Spacer(minLength: 0)
                Text("SKIPPED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(skippedGrey)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(skippedGrey.opacity(0.14), in: Capsule())
            } else {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 110, height: 120, alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                livePulse = true
            }
        }
        .onChange(of: isLive) { _, live in
            if live {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    livePulse = true
                }
            } else {
                livePulse = false
            }
        }
        .onChange(of: reduceMotion) { _, nowReduced in
            if nowReduced { livePulse = false }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isLive {
            // Live session — brighter phase-tinted background
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(week.phase.accentColor.opacity(0.15))
        } else if isCompleted {
            // Completed days get a subtle green tint
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(completedGreen.opacity(0.08))
        } else if isPaused {
            // Paused days get a subtle amber tint
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(pausedAmber.opacity(0.08))
        } else if isSkipped {
            // Skipped days get a muted grey tint
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(skippedGrey.opacity(0.07))
        } else if week.isDeload {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.54, green: 0.60, blue: 0.69).opacity(0.10))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        if isLive {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(week.phase.accentColor.opacity(0.65), lineWidth: 1.5)
        } else if isCompleted {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(completedGreen.opacity(0.30), lineWidth: 1)
        } else if isPaused {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(pausedAmber.opacity(0.30), lineWidth: 1)
        } else if isSkipped {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(skippedGrey.opacity(0.25), lineWidth: 1)
        } else if isCurrentWeek {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(week.phase.accentColor.opacity(0.35), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: Helpers

    private func formatWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
    }

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
    let supabase = SupabaseClient(supabaseURL: URL(string: "https://example.supabase.co")!, anonKey: "")
    let provider = AnthropicProvider(apiKey: "")
    NavigationStack {
        ProgramOverviewView(
            viewModel: ProgramViewModel(
                supabaseClient: supabase,
                programGenerationService: ProgramGenerationService(provider: provider),
                macroPlanService: MacroPlanService(provider: provider),
                sessionPlanService: SessionPlanService(
                    provider: provider,
                    memoryService: MemoryService(supabase: supabase, embeddingAPIKey: ""),
                    supabaseClient: supabase
                ),
                userId: AppDependencies.placeholderUserId
            ),
            gymProfile: nil
        )
    }
}
