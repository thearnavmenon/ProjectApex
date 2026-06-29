// ProgramOverviewView.swift
// ProjectApex — Features/Program
//
// 12-week mesocycle calendar grid. Each row is a training week; columns are
// training days. Deload weeks use a distinct dashed-silver treatment.
// The current week row is highlighted with a volt-lime border.
// Tapping any day card navigates to ProgramDayDetailView.
//
// Brutalist Athletic restyle (#507): pure-black surface, condensed-black
// numerals + headlines, sharp 4pt corners, the single volt-lime accent reserved
// for the live/current/primary action and amber for paused. Phase
// differentiation stays monochrome (condensed labels + a segmented bar whose
// active segment is the one lime accent). Visual layer only — all behaviour,
// state, bindings, navigation and accessibility are unchanged.
//
// Acceptance criteria (P2-T05):
// ✓ Scrollable grid: 12 rows (weeks) × N columns (days per week)
// ✓ Each day cell shows day label, primary muscle group chip, training indicator
// ✓ Deload weeks visually distinct (dashed-silver treatment)
// ✓ Current week highlighted with accent border
// ✓ Tap navigates to ProgramDayDetailView
// ✓ Week header shows phase label
// ✓ Loading state while fetching from Supabase
// ✓ Empty state with "Generate My Program" CTA

import SwiftUI

struct ProgramOverviewView: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(\.switchToTab) private var switchToTab

    @Bindable var viewModel: ProgramViewModel
    /// The confirmed gym profile passed in from ContentView.
    let gymProfile: GymProfile?

    /// Controls the collapsed/expanded state of the pattern progress section.
    @State private var isPatternProgressExpanded = false

    var body: some View {
        ZStack {
            // Pure-black Brutalist backdrop.
            Apex.bg.ignoresSafeArea()

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
        .toolbarBackground(Apex.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await viewModel.loadProgram()
        }
        // Live-session highlight + set-progress now come from
        // deps.activeSessionCoordinator (a single 500ms poll owned by AppDependencies)
        // so this view no longer runs its own loop against the manager actor.
        // #188: Non-blocking sync-error banner — shown while program remains usable.
        .overlay(alignment: .top) {
            if let message = viewModel.persistError {
                syncErrorBanner(message: message)
            }
        }
    }

    // MARK: - Sync error banner (#188)

    private func syncErrorBanner(message: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Apex.amber)

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.text.opacity(0.85))
                    .lineLimit(2)

                Spacer()

                if viewModel.persistRetryAction != nil {
                    Button {
                        Task { await viewModel.persistRetryAction?() }
                    } label: {
                        Text("Retry")
                            .font(.system(size: 13, weight: .bold))
                            .fontWidth(.condensed)
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(Apex.accent)
                    }
                }

                Button {
                    viewModel.dismissPersistError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Apex.textFaint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .fill(Apex.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(Apex.amber.opacity(0.45), lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: viewModel.persistError)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Apex.accent)
                .scaleEffect(1.5)
            Text("Loading program\u{2026}")
                .font(.system(size: 13, weight: .medium))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(Apex.textDim)
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Apex.textFaint)

            VStack(spacing: 12) {
                Text("No Program Yet")
                    .font(.system(size: 30, weight: .black))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .foregroundStyle(Apex.text)

                Text(gymProfile == nil
                     ? "Scan your gym first, then generate a personalised 12-week program."
                     : "Generate a personalised 12-week periodised program for your gym.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Apex.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if gymProfile != nil {
                Button {
                    guard let profile = gymProfile else { return }
                    Task { await viewModel.generateMacroSkeleton(gymProfile: profile) }
                } label: {
                    ApexButton(title: "Generate My Program", icon: "wand.and.stars")
                }
                .padding(.horizontal, 32)
                .padding(.top, 4)
            } else {
                Button(action: { switchToTab(3) }) {
                    Text("Set up your gym in Settings")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Apex.accent)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Apex.pad)
    }

    // MARK: - Generating

    private var generatingView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated brain icon
            Image(systemName: "brain.head.profile")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(Apex.accent)
                .symbolEffect(.pulse)

            VStack(spacing: 12) {
                Text("Building Your Program")
                    .font(.system(size: 26, weight: .black))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .foregroundStyle(Apex.text)

                Text("The AI coach is crafting a personalised 12-week mesocycle. This may take up to a minute.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Apex.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            ProgressView()
                .progressViewStyle(.circular)
                .tint(Apex.accent)
                .scaleEffect(1.2)

            Spacer()
        }
        .padding(.horizontal, Apex.pad)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Apex.amber)

            VStack(spacing: 12) {
                Text("Generation Failed")
                    .font(.system(size: 24, weight: .black))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .foregroundStyle(Apex.text)

                Text(message)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Apex.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                Task {
                    if let profile = gymProfile {
                        await viewModel.generateMacroSkeleton(gymProfile: profile)
                    } else {
                        await viewModel.loadProgram()
                    }
                }
            } label: {
                ApexButton(title: "Try Again", icon: "arrow.clockwise")
            }
            .padding(.horizontal, 48)
            .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, Apex.pad)
    }

    // MARK: - Loaded: 12-Week Grid

    private func loadedView(mesocycle: Mesocycle) -> some View {
        let currentWeekIndex = viewModel.currentWeekIndex(in: mesocycle)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // NEXT UP hero — the calendar's primary action. Renders only when
                    // there is a next incomplete day; an in-progress session turns it
                    // into a Resume card (#507).
                    nextUpHero(mesocycle: mesocycle)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    // Phase progress bar header
                    phaseProgressBar(mesocycle: mesocycle, currentWeekIndex: currentWeekIndex)
                        .padding(.horizontal, 16)
                        .padding(.top, hasNextUp(in: mesocycle) ? 0 : 16)
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
                            liveTrainingDayId: deps.activeSessionCoordinator.liveTrainingDayId,
                            liveSetSummary: deps.activeSessionCoordinator.liveSetSummary
                        )
                        .padding(.horizontal, 16)
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

    // MARK: - NEXT UP hero (#507)

    /// True when there is a next incomplete day to surface a hero for. Drives the
    /// phase-bar top padding so the bar sits flush when the program is complete and
    /// no hero renders.
    private func hasNextUp(in mesocycle: Mesocycle) -> Bool {
        let coord = deps.activeSessionCoordinator
        // A live/paused session always surfaces a hero, even if every remaining
        // day is otherwise terminal.
        if coord.isLive || coord.pausedSessionExists { return true }
        return viewModel.nextIncompleteDay(in: mesocycle) != nil
    }

    /// What the hero is currently showing — drives label, accent and action.
    private enum HeroState { case idle, live, paused }

    /// The calendar's primary action: a prominent card at the top reflecting the
    /// program's current state.
    ///
    /// • A session is LIVE → a "LIVE NOW" card (volt-lime) showing set progress,
    ///   whose action jumps to the Workout tab (the single live WorkoutView host).
    /// • A session is PAUSED → a "PAUSED" card (amber) whose action jumps to the
    ///   Workout tab to resume. (This is the state that previously, incorrectly,
    ///   showed "Start workout".)
    /// • Otherwise, if a next incomplete day exists → a "NEXT UP" card that
    ///   navigates to that day's detail using the SAME NavigationLink →
    ///   ProgramDayDetailView the week rows use, so the Start/Generate gate logic
    ///   stays in one place (not re-implemented here).
    /// • Program complete and no session → renders nothing.
    @ViewBuilder
    private func nextUpHero(mesocycle: Mesocycle) -> some View {
        let coord = deps.activeSessionCoordinator
        if let liveId = coord.liveTrainingDayId,
           let found = viewModel.findTrainingDay(byId: liveId, in: mesocycle) {
            // Live: jump to the live WorkoutView host on the Workout tab.
            Button { switchToTab(1) } label: {
                nextUpHeroCard(day: found.day, week: found.week, state: .live)
            }
            .buttonStyle(.plain)
        } else if let pausedId = coord.pausedTrainingDayId,
                  let found = viewModel.findTrainingDay(byId: pausedId, in: mesocycle) {
            // Paused: jump to the Workout tab to resume the paused session.
            Button { switchToTab(1) } label: {
                nextUpHeroCard(day: found.day, week: found.week, state: .paused)
            }
            .buttonStyle(.plain)
        } else if let next = viewModel.nextIncompleteDay(in: mesocycle) {
            // Idle: navigate to the day's detail; the Start/Generate gate lives there
            // (same construction as WeekRowView).
            NavigationLink {
                ProgramDayDetailView(
                    day: next.day,
                    week: next.week,
                    mesocycleCreatedAt: mesocycle.createdAt,
                    programId: mesocycle.id,
                    viewModel: viewModel,
                    gymProfile: gymProfile
                )
            } label: {
                nextUpHeroCard(day: next.day, week: next.week, state: .idle)
            }
            .buttonStyle(.plain)
        }
    }

    /// The hero card body, shared by the idle / live / paused variants. Paused uses
    /// the amber accent (matching the app's paused convention); idle/live use lime.
    private func nextUpHeroCard(day: TrainingDay, week: TrainingWeek, state: HeroState) -> some View {
        let muscles = uniqueHeroMuscles(from: day.exercises)
        let weekday = weekdayLabel(dayOfWeek: day.dayOfWeek)
        let accent: Color = (state == .paused) ? Apex.amber : Apex.accent
        let label: String = {
            switch state {
            case .idle:   return "Next up"
            case .live:   return "Live now"
            case .paused: return "Paused"
            }
        }()
        let action = (state == .idle) ? "Start workout" : "Resume workout"
        // Live set progress, when the live session is reporting it.
        let liveSummary = (state == .live) ? deps.activeSessionCoordinator.liveSetSummary : nil

        return VStack(alignment: .leading, spacing: 14) {
            // Label row: state + week·weekday locator.
            HStack {
                ApexSectionLabel(text: label, color: accent)
                Spacer()
                Text("W\(week.weekNumber) · \(weekday)")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
            }

            // Big day title.
            Text(day.dayLabel.replacingOccurrences(of: "_", with: " ").uppercased())
                .font(.system(size: 30, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .lineLimit(1)

            // Live set progress when available; otherwise muscle chips + exercise count.
            if let s = liveSummary, s.setsCompleted > 0 {
                HStack(spacing: 8) {
                    Text("\(s.setsCompleted) SET\(s.setsCompleted == 1 ? "" : "S") DONE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.4)
                        .fontWidth(.condensed)
                        .foregroundStyle(accent)
                    if let kg = s.lastWeightKg, let reps = s.lastRepsCompleted {
                        Text("· \(formatHeroWeight(kg))kg × \(reps)")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.4)
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.textFaint)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(muscles.prefix(2), id: \.self) { muscle in
                        ApexTagChip(text: muscle)
                    }
                    Text("· \(day.exercises.count) EX")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.4)
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                }
            }

            // Primary action — filled, accent-tinted (lime for start/resume-live,
            // amber for resume-paused).
            ApexButton(
                title: action,
                icon: "play.fill",
                tint: (state == .paused) ? Apex.amber : nil
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous).fill(Apex.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(accent.opacity(0.55), lineWidth: 1.5)
        }
    }

    private func formatHeroWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
    }

    /// Deduplicated top-muscle labels for the hero, reusing the same shortening
    /// the day cards use (`formattedShortMuscleName`).
    private func uniqueHeroMuscles(from exercises: [PlannedExercise]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for ex in exercises {
            let muscle = ex.primaryMuscle.formattedShortMuscleName
            if seen.insert(muscle).inserted {
                result.append(muscle)
            }
            if result.count >= 2 { break }
        }
        return result
    }

    /// Weekday abbreviation from the ISO day-of-week (1 = Monday).
    private func weekdayLabel(dayOfWeek: Int) -> String {
        let days = ["", "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
        guard dayOfWeek >= 1 && dayOfWeek <= 7 else { return "DAY" }
        return days[dayOfWeek]
    }

    // MARK: - Pattern Progress Section

    /// Collapsible section showing per-movement-pattern phase state. Sourced
    /// from TraineeModelDigest.perPatternSummary via viewModel.patternPhaseSummaries
    /// (B3 / #88). Renders only when the digest has hydrated.
    @ViewBuilder
    private var patternProgressSection: some View {
        let summaries = viewModel.patternPhaseSummaries
        if !summaries.isEmpty {
            VStack(spacing: 0) {
                // Collapse/expand header
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isPatternProgressExpanded.toggle()
                    }
                } label: {
                    HStack {
                        ApexSectionLabel(text: "Pattern progress", color: Apex.textDim)
                        Spacer()
                        Image(systemName: isPatternProgressExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Apex.textFaint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                if isPatternProgressExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(summaries.enumerated()), id: \.element.pattern) { index, summary in
                            patternPhaseRow(summary)
                            if index < summaries.count - 1 {
                                Rectangle()
                                    .fill(Apex.hairline.opacity(0.6))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .apexCard()
            .padding(.horizontal, 16)
        }
    }

    // Q6 / B3: pattern name + phase badge, enriched (#507) with the real
    // trend + transition state the digest already computes. The digest still
    // carries no session-counter fields, so the legacy N/M counter + progress
    // bar stay dropped.
    //   • transition: `summary.inTransitionMode` (Bool) → a lime "TRANSITIONING"
    //     hint. The model carries no next-phase target, so we do NOT name a
    //     destination phase (the prototype's "→ INTENS" was a mock string).
    //   • trend: `summary.trend` (ProgressionTrend) → a direction glyph; lime
    //     only when progressing (the one meaningful accent), monochrome else.
    private func patternPhaseRow(_ summary: PatternSummary) -> some View {
        HStack(spacing: 10) {
            // Human-readable pattern name (e.g. "Horizontal Push")
            Text(summary.pattern.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Apex.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Transition hint — only when the pattern is genuinely transitioning.
            if summary.inTransitionMode {
                Text("TRANSITIONING")
                    .font(.system(size: 9, weight: .black))
                    .fontWidth(.condensed)
                    .tracking(0.4)
                    .foregroundStyle(Apex.accent)
            }

            // Phase badge — monochrome, outlined.
            Text(shortPhaseName(summary.currentPhase))
                .font(.system(size: 9, weight: .bold))
                .fontWidth(.condensed)
                .tracking(0.4)
                .foregroundStyle(Apex.textDim)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().stroke(Apex.hairline, lineWidth: 1))

            // Trend glyph — the real ProgressionTrend direction.
            trendGlyph(summary.trend, transitioning: summary.inTransitionMode)
        }
        .padding(.vertical, 11)
    }

    /// Direction glyph for a pattern's real capability trend. Lime is reserved
    /// for the meaningful "progressing" signal (and the transition swap);
    /// plateaued/declining stay monochrome.
    @ViewBuilder
    private func trendGlyph(_ trend: ProgressionTrend, transitioning: Bool) -> some View {
        if transitioning {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Apex.accent)
                .accessibilityLabel("Transitioning")
        } else {
            switch trend {
            case .progressing:
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Apex.accent)
                    .accessibilityLabel("Progressing")
            case .plateaued:
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Apex.textFaint)
                    .accessibilityLabel("Plateaued")
            case .declining:
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Apex.textDim)
                    .accessibilityLabel("Declining")
            }
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

    // MARK: - Phase Progress Bar

    private func phaseProgressBar(mesocycle: Mesocycle, currentWeekIndex: Int) -> some View {
        let phases: [(phase: MesocyclePhase, label: String, weeks: ClosedRange<Int>)] = [
            (.accumulation, "ACCUM", 0...3),
            (.intensification, "INTENS", 4...7),
            (.peaking, "PEAK", 8...10),
            (.deload, "DL", 11...11)
        ]

        // Count completed+skipped sessions across all days for the progress label.
        // Skipped sessions advance the programme pointer, so they count toward progress (#445).
        let allDays = mesocycle.weeks.flatMap { $0.trainingDays }
        let completedCount = mesocycle.completedDayCount
        let totalDays = allDays.count
        // Session-based completion fraction — updates immediately when a day is marked done.
        let sessionProgress = totalDays > 0 ? Double(completedCount) / Double(totalDays) : 0.0

        return VStack(alignment: .leading, spacing: 14) {
            // Week count (hero) + sessions/percent
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("WEEK")
                        .font(.system(size: 12, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textDim)
                        .baselineOffset(2)
                    ApexNumeral(text: "\(currentWeekIndex + 1)", size: 34)
                    Text("/ \(mesocycle.weeks.count)")
                        .font(.system(size: 15, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        ApexNumeral(text: "\(completedCount)", size: 17, color: Apex.accent)
                        Text("/ \(totalDays) SESSIONS")
                            .font(.system(size: 11, weight: .bold))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.textDim)
                    }
                    Text("\(Int(sessionProgress * 100))% COMPLETE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                }
            }

            // Phase segments — active segment is the one lime accent.
            HStack(spacing: 4) {
                ForEach(phases, id: \.phase) { item in
                    let isActive = item.weeks.contains(currentWeekIndex)
                    Rectangle()
                        .fill(isActive ? Apex.accent : Color.white.opacity(0.16))
                        .frame(height: 5)
                        .frame(maxWidth: .infinity)
                }
            }

            // Phase labels
            HStack(spacing: 0) {
                phaseTick("ACCUM", active: phases[0].weeks.contains(currentWeekIndex))
                phaseTick("INTENS", active: phases[1].weeks.contains(currentWeekIndex))
                phaseTick("PEAK", active: phases[2].weeks.contains(currentWeekIndex))
                phaseTick("DL", active: phases[3].weeks.contains(currentWeekIndex), width: 26)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    private func phaseTick(_ t: String, active: Bool, width: CGFloat? = nil) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .fontWidth(.condensed)
            .foregroundStyle(active ? Apex.accent : Apex.textFaint)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: width == nil ? .leading : .trailing)
            .frame(width: width)
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
        VStack(alignment: .leading, spacing: 8) {
            // Week header
            HStack(spacing: 8) {
                ApexNumeral(
                    text: "W\(week.weekNumber)",
                    size: 16,
                    color: isCurrent ? Apex.accent : Apex.text
                )

                // FB-008: Show weekLabel if available, else fall back to phase title
                Text((week.isDeload ? "DELOAD" : (week.weekLabel ?? week.phase.displayTitle)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .fontWidth(.condensed)
                    .tracking(0.8)
                    .foregroundStyle(isCurrent ? Apex.text : Apex.textDim)
                    .lineLimit(1)

                if isCurrent {
                    Text("CURRENT")
                        .font(.system(size: 9, weight: .black))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.onAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Apex.accent, in: Capsule())
                }

                Spacer()

                // Phase-relative progress: "WK 2/4"
                Text("WK \(phaseWeekNumber)/\(phaseWeekTotal)")
                    .font(.system(size: 10, weight: .semibold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Deload rationale line (#507). The week model carries no per-week
            // fatigue data, so this is an HONEST generic planned-deload line
            // derived from `week.isDeload` — no fabricated RPE / volume numbers.
            if week.isDeload {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Apex.textDim)
                    Text("PLANNED DELOAD · REDUCED VOLUME, INTENSITY MAINTAINED")
                        .font(.system(size: 9, weight: .bold))
                        .fontWidth(.condensed)
                        .tracking(0.4)
                        .foregroundStyle(Apex.textDim)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
            }

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
                .padding(.horizontal, 14)
                .padding(.bottom, 13)
            }
        }
        .background(weekBackground)
        .overlay(currentWeekBorder)
    }

    @ViewBuilder
    private var weekBackground: some View {
        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .fill(week.isDeload ? Color.white.opacity(0.04) : Color.white.opacity(0.025))
    }

    @ViewBuilder
    private var currentWeekBorder: some View {
        // Readable deload: dashed silver stroke; current: lime; else hairline.
        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .strokeBorder(
                isCurrent ? Apex.accent.opacity(0.55)
                    : (week.isDeload ? Color(white: 0.62).opacity(0.5) : Apex.hairline),
                style: week.isDeload
                    ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                    : StrokeStyle(lineWidth: isCurrent ? 1.5 : 1)
            )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Weekday + day label row
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(weekdayLabel(dayOfWeek: day.dayOfWeek))
                        .font(.system(size: 10, weight: .bold))
                        .fontWidth(.condensed)
                        .tracking(0.5)
                        .foregroundStyle(isLive ? Apex.accent : Apex.textFaint)

                    Text(day.dayLabel.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 15, weight: .black))
                        .fontWidth(.condensed)
                        .foregroundStyle(dayTitleColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Status glyph — record for live, checkmark for completed, pause for paused, xmark for skipped
                statusGlyph
            }

            if isLive {
                // Live session — set progress (if any sets logged) then pulsing LIVE badge
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    if let s = liveSetSummary, s.setsCompleted > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.setsCompleted) SET\(s.setsCompleted == 1 ? "" : "S") DONE")
                                .font(.system(size: 9, weight: .bold))
                                .fontWidth(.condensed)
                                .tracking(0.4)
                                .foregroundStyle(Apex.text.opacity(0.75))
                            if let kg = s.lastWeightKg, let reps = s.lastRepsCompleted {
                                Text("\(formatWeight(kg))kg · \(reps) reps")
                                    .font(.system(size: 9, weight: .medium))
                                    .fontWidth(.condensed)
                                    .foregroundStyle(Apex.textDim)
                                    .lineLimit(1)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Apex.accent)
                            .frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.6 : (livePulse ? 1.0 : 0.2))
                        Text("LIVE")
                            .font(.system(size: 9, weight: .black))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.accent)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().stroke(Apex.accent.opacity(0.5), lineWidth: 1))
                }
            } else if isPending {
                // FB-008: Session pending indicator
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 14))
                        .foregroundStyle(Apex.textFaint)
                    Text("SESSION\nPENDING")
                        .font(.system(size: 9, weight: .bold))
                        .fontWidth(.condensed)
                        .tracking(0.3)
                        .foregroundStyle(Apex.textFaint)
                        .lineLimit(2)
                }
            } else if isCompleted {
                Spacer(minLength: 0)
                statusPill("DONE", color: Apex.textDim)
            } else if isPaused {
                Spacer(minLength: 0)
                statusPill("PAUSED", color: Apex.amber)
            } else if isSkipped {
                Spacer(minLength: 0)
                statusPill("SKIPPED", color: Apex.textFaint)
            } else {
                // Primary muscles chips (top 2) — monochrome ApexTagChip (lime dot baked in).
                let muscles = uniqueTopMuscles(from: day.exercises)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(muscles.prefix(2), id: \.self) { muscle in
                        ApexTagChip(text: muscle)
                    }
                }

                Spacer(minLength: 0)

                // Exercise count indicator
                HStack(spacing: 4) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Apex.textFaint)
                    Text("\(day.exercises.count) EX")
                        .font(.system(size: 10, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                }
            }
        }
        .padding(11)
        .frame(width: 118, height: 122, alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
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

    // MARK: Status glyph

    @ViewBuilder
    private var statusGlyph: some View {
        if isLive {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Apex.accent)
                .opacity(reduceMotion ? 0.6 : (livePulse ? 1.0 : 0.4))
                .accessibilityLabel("Session in progress")
        } else if isCompleted {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Apex.textDim)
                .accessibilityLabel("Session completed")
        } else if isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Apex.amber)
                .accessibilityLabel("Workout paused")
        } else if isSkipped {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Apex.textFaint)
                .accessibilityLabel("Session skipped")
        }
    }

    private func statusPill(_ t: String, color: Color) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .black))
            .fontWidth(.condensed)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }

    private var dayTitleColor: Color {
        if isSkipped { return Apex.textFaint }
        if isPaused { return Apex.amber }
        if isPending { return Apex.text.opacity(0.55) }
        return Apex.text
    }

    @ViewBuilder
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .fill(dayFill)
    }

    @ViewBuilder
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .stroke(dayStroke, lineWidth: isLive ? 1.5 : 1)
    }

    private var dayFill: Color {
        if isLive { return Apex.accent.opacity(0.12) }
        if isPaused { return Apex.amber.opacity(0.07) }
        return Color.white.opacity(0.05)
    }

    private var dayStroke: Color {
        if isLive { return Apex.accent.opacity(0.6) }
        if isPaused { return Apex.amber.opacity(0.30) }
        return Apex.hairline
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
                macroPlanService: MacroPlanService(provider: provider),
                sessionPlanService: SessionPlanService(
                    provider: provider,
                    memoryService: MemoryService(supabase: supabase, embeddingAPIKey: ""),
                    supabaseClient: supabase
                ),
                userId: AppDependencies.placeholderUserId,
                resolveOwner: { nil }
            ),
            gymProfile: nil
        )
    }
    .preferredColorScheme(.dark)
}
