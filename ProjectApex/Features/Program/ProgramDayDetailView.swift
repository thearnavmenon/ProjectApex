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

// MARK: - UserDefaults key for Start Any Day dev mode

private enum FreeDayKeys {
    /// DEBUG-only: when true, all generated days are always startable.
    static let startAnyDayMode = "dev_start_any_day_mode"
}

// MARK: - ProgramDayDetailView

struct ProgramDayDetailView: View {

    let day: TrainingDay
    let week: TrainingWeek
    /// Mesocycle creation date — used to derive session date for status.
    let mesocycleCreatedAt: Date
    /// Mesocycle programme ID — passed to WorkoutView and ManualSessionLogView.
    var programId: UUID = UUID()
    /// When true (dev override) the Start Workout button is always enabled.
    var devOverride: Bool = false
    /// FB-008: optional view model for on-demand session generation.
    var viewModel: ProgramViewModel? = nil
    /// FB-008: gym profile needed for SessionPlanService equipment constraints.
    var gymProfile: GymProfile? = nil

    @Environment(AppDependencies.self) private var deps

    /// FB-008: local state tracking whether session generation is in progress for this view.
    @State private var isGeneratingSession: Bool = false
    @State private var sessionGenerationError: String? = nil
    /// The current day — may be replaced in-place after session generation.
    @State private var currentDay: TrainingDay
    /// Controls the manual session logging sheet.
    @State private var showManualLogSheet: Bool = false
    /// Controls the set-log backfill sheet (completed days with no set logs).
    @State private var showBackfillSheet: Bool = false
    /// Drives the NavigationLink to WorkoutView (replaces the old fullScreenCover so the
    /// tab bar and back button remain visible during workouts).
    @State private var navigateToWorkout: Bool = false
    /// Controls the alert shown when the user tries to start a new session while another is paused.
    @State private var showExistingPausedSessionAlert: Bool = false
    /// Controls the confirmation alert for skipping a past unlogged session from the detail view.
    @State private var showSkipDayConfirmation: Bool = false
    /// Controls the confirmation alert for restarting an incomplete completed session.
    @State private var showRestartConfirmation: Bool = false
    /// 0-based exercise index passed to WorkoutView when starting/continuing a session.
    @State private var workoutStartingExerciseIndex: Int = 0

    // MARK: - Live session state (active session for this day)

    /// True when WorkoutSessionManager has an active session whose day matches this view's day.
    @State private var isSessionActiveForThisDay: Bool = false
    /// Completed set logs for the active session, grouped by exerciseId.
    /// Populated when isSessionActiveForThisDay == true so exercise cards can show real performance.
    @State private var liveSessionSets: [String: [SetLog]] = [:]

    // MARK: - Historical set log state (completed days only)

    /// Set logs loaded from Supabase for this completed day, grouped by exerciseId.
    @State private var historicalSetLogs: [String: [SetLog]] = [:]
    /// Session ID resolved for this completed day (used for Supabase queries).
    @State private var completedSessionId: UUID? = nil
    /// True while set logs are being fetched from Supabase.
    @State private var isLoadingSetLogs: Bool = false
    /// Computed total volume from the historical set logs (nil = not yet loaded).
    @State private var historicalVolume: Double? = nil
    /// Snapshot of set logs as originally loaded — used to construct "originally X" correction text.
    @State private var originalSetLogs: [UUID: SetLog] = [:]
    /// Set used to track which set log IDs have been manually edited.
    @State private var editedSetLogIds: Set<UUID> = []
    /// The set log currently being edited (drives the edit sheet).
    @State private var editingSetLog: SetLog? = nil

    // DEBUG-only: read the Start Any Day dev mode flag from UserDefaults.
    #if DEBUG
    private var startAnyDayModeActive: Bool {
        devOverride || UserDefaults.standard.bool(forKey: FreeDayKeys.startAnyDayMode)
    }
    #else
    private var startAnyDayModeActive: Bool { devOverride }
    #endif

    init(
        day: TrainingDay,
        week: TrainingWeek,
        mesocycleCreatedAt: Date,
        programId: UUID = UUID(),
        devOverride: Bool = false,
        viewModel: ProgramViewModel? = nil,
        gymProfile: GymProfile? = nil
    ) {
        self.day = day
        self.week = week
        self.mesocycleCreatedAt = mesocycleCreatedAt
        self.programId = programId
        self.devOverride = devOverride
        self.viewModel = viewModel
        self.gymProfile = gymProfile
        _currentDay = State(initialValue: day)
    }

    private var dayStatus: DayStatus {
        DayStatus.resolve(
            mesocycleCreatedAt: mesocycleCreatedAt,
            weekNumber: week.weekNumber,
            dayOfWeek: currentDay.dayOfWeek
        )
    }

    /// True when this completed session was exited early — at least one planned exercise
    /// has no set logs. Drives the continue/restart buttons in the bottom action area.
    private var isCompletedIncomplete: Bool {
        guard currentDay.status == .completed,
              !isLoadingSetLogs,
              completedSessionId != nil,
              !historicalSetLogs.isEmpty
        else { return false }
        return currentDay.exercises.contains { historicalSetLogs[$0.exerciseId]?.isEmpty ?? true }
    }

    /// 0-based index of the first exercise that has no set logs (the resume point).
    private var firstIncompleteExerciseIndex: Int {
        currentDay.exercises.firstIndex(where: { historicalSetLogs[$0.exerciseId]?.isEmpty ?? true }) ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

            if isGeneratingSession {
                // FB-008: "Preparing your session…" loading screen
                preparingSessionView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Phase + day header
                        dayHeaderSection

                        // Session pending banner (FB-008)
                        if currentDay.status == .pending {
                            sessionPendingBannerView
                        } else if currentDay.status == .completed {
                            // Completed days (including those preserved after regeneration)
                            // always show the completed banner regardless of calendar date.
                            completedBannerView
                        } else if currentDay.status == .paused {
                            // Paused session — amber info banner
                            statusBadge(
                                icon: "pause.circle.fill",
                                label: "Session Paused — tap Resume to continue",
                                color: Color(red: 1.00, green: 0.70, blue: 0.10)
                            )
                        } else if currentDay.status == .skipped {
                            // Skipped session — grey info banner
                            skippedBannerView
                        } else if dayStatus != .today {
                            // Session status banner (not shown for today)
                            statusBannerView
                        }

                        // Volume summary for completed days
                        if currentDay.status == .completed, let volume = historicalVolume {
                            completedVolumeSummary(volume: volume)
                        }

                        // Backfill prompt — shown when the session is completed but has no set logs
                        if currentDay.status == .completed,
                           !isLoadingSetLogs,
                           historicalSetLogs.isEmpty,
                           completedSessionId != nil {
                            backfillSetLogsPrompt
                        }

                        // Exercise list (empty for pending days)
                        if currentDay.exercises.isEmpty && currentDay.status == .pending {
                            pendingExercisePlaceholder
                        } else if currentDay.status == .completed {
                            if isLoadingSetLogs {
                                ProgressView()
                                    .tint(.white.opacity(0.45))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            } else {
                                ForEach(Array(currentDay.exercises.enumerated()), id: \.element.id) { index, exercise in
                                    CompletedExerciseCard(
                                        exercise: exercise,
                                        index: index + 1,
                                        setLogs: historicalSetLogs[exercise.exerciseId] ?? [],
                                        editedIds: editedSetLogIds,
                                        onTapSet: { log in editingSetLog = log },
                                        onAddSet: { newLog in Task { await addNewSetLog(newLog) } }
                                    )
                                }
                            }
                        } else if isSessionActiveForThisDay {
                            // Active session — show planned prescription alongside logged sets
                            ForEach(Array(currentDay.exercises.enumerated()), id: \.element.id) { index, exercise in
                                ExerciseDetailCard(
                                    exercise: exercise,
                                    index: index + 1,
                                    liveSetLogs: liveSessionSets[exercise.exerciseId] ?? []
                                )
                            }
                        } else {
                            ForEach(Array(currentDay.exercises.enumerated()), id: \.element.id) { index, exercise in
                                ExerciseDetailCard(exercise: exercise, index: index + 1)
                            }
                        }

                        // Session notes (if any)
                        if let notes = currentDay.sessionNotes, !notes.isEmpty {
                            sessionNotesCard(notes: notes)
                        }

                        // Error from session generation
                        if let error = sessionGenerationError {
                            sessionErrorCard(error: error)
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
        }
        .navigationTitle(currentDay.dayLabel.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onChange(of: day.status) { _, newStatus in
            // Sync if parent mutates the day (e.g. viewModel generates it)
            if newStatus == .generated && currentDay.status == .pending {
                currentDay = day
            }
        }
        .onAppear {
            if currentDay.status == .completed {
                Task { await loadHistoricalSetLogs() }
            }
            // Refresh live session state each time the view appears — this fires when the
            // user navigates back from WorkoutView so the exercise cards update immediately.
            Task { await refreshLiveSessionState() }
        }
        .sheet(item: $editingSetLog) { log in
            SetLogEditSheet(
                log: log,
                isEdited: editedSetLogIds.contains(log.id),
                onConfirm: { updatedLog in
                    Task { await applySetLogEdit(updatedLog) }
                }
            )
            .presentationDetents([.medium])
        }
        // NavigationLink destination for the workout — replaces the old fullScreenCover so
        // the tab bar and standard back button remain visible throughout the session.
        .navigationDestination(isPresented: $navigateToWorkout) {
            let resumeState = (currentDay.status == .paused) ? PausedSessionState.load() : nil
            let allDays = viewModel?.currentMesocycle?.weeks.flatMap(\.trainingDays) ?? []
            WorkoutView(
                trainingDay: currentDay,
                programId: programId,
                weekNumber: week.weekNumber,
                completedDayCount: allDays.filter { $0.status == .completed || $0.status == .skipped }.count,
                totalDayCount: allDays.count,
                onSessionCompleted: {
                    currentDay.status = .completed
                    viewModel?.markDayCompleted(dayId: currentDay.id, weekId: week.id)
                },
                onSessionPaused: {
                    currentDay.status = .paused
                    viewModel?.markDayPaused(dayId: currentDay.id, weekId: week.id)
                },
                onSessionDismissed: {
                    navigateToWorkout = false
                    viewModel?.scrollToCurrentWeekTrigger += 1
                    if currentDay.status == .completed {
                        Task { await loadHistoricalSetLogs() }
                    }
                },
                resumeState: resumeState,
                startingExerciseIndex: workoutStartingExerciseIndex,
                onSkipSession: {
                    currentDay.status = .skipped
                    viewModel?.markDaySkipped(dayId: currentDay.id, weekId: week.id)
                },
                onBack: {
                    navigateToWorkout = false
                }
            )
            .environment(deps)
        }
    }

    // MARK: - FB-008: Preparing Session Loading View

    private var preparingSessionView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
                .symbolEffect(.pulse)

            VStack(spacing: 10) {
                Text("Preparing Your Session")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Analysing your lift history and fatigue signals to build the optimal session for today.")
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

    // MARK: - FB-008: Session Pending Banner

    private var sessionPendingBannerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.caption.bold())
                .foregroundStyle(Color(red: 0.78, green: 0.82, blue: 0.88))
            VStack(alignment: .leading, spacing: 2) {
                Text("SESSION WILL BE GENERATED BEFORE YOU TRAIN")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.82, blue: 0.88))
                    .kerning(0.5)
                Text("Tap \"Start Workout\" to generate this session using your full lift history.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - FB-008: Pending exercises placeholder

    private var pendingExercisePlaceholder: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - FB-008: Session generation error card

    private func sessionErrorCard(error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 0.91, green: 0.63, blue: 0.19))
            Text(error)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.70))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.91, green: 0.63, blue: 0.19).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(red: 0.91, green: 0.63, blue: 0.19).opacity(0.25), lineWidth: 1)
        )
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
                label: "Scheduled — tap Start Workout to train this day early",
                color: Color(red: 0.54, green: 0.60, blue: 0.69)
            )
        case .past:
            statusBadge(
                icon: "calendar.badge.checkmark",
                label: "Past session — tap Start Workout to re-run or Log Past Session to backdate",
                color: Color(red: 0.78, green: 0.82, blue: 0.88)
            )
        case .today:
            EmptyView()
        }
    }

    /// Green "Session Completed" banner shown at the top of completed days.
    /// These days are read-only — no workout or log actions available.
    private var completedBannerView: some View {
        let green = Color(red: 0.24, green: 0.82, blue: 0.46)
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption.bold())
            Text("SESSION COMPLETED — THIS IS A HISTORICAL RECORD")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
        }
        .foregroundStyle(green)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(green.opacity(0.25), lineWidth: 1)
        )
    }

    /// Grey "Session Skipped" banner shown at the top of skipped days.
    /// Skipped days can be re-run — the start button remains available.
    private var skippedBannerView: some View {
        let grey = Color(red: 0.55, green: 0.58, blue: 0.63)
        return HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption.bold())
            Text("SESSION SKIPPED — TAP START WORKOUT TO RE-RUN")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
        }
        .foregroundStyle(grey)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(grey.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(grey.opacity(0.25), lineWidth: 1)
        )
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
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.06))

            VStack(spacing: 8) {
                bottomActionContent
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
        }
        .sheet(isPresented: $showManualLogSheet) {
            ManualSessionLogView(
                day: currentDay,
                week: week,
                mesocycleCreatedAt: mesocycleCreatedAt,
                programId: programId,
                onSessionLogged: {
                    // Mark the day as completed in the local calendar cache
                    currentDay.status = .completed
                    viewModel?.markDayCompleted(dayId: currentDay.id, weekId: week.id)
                }
            )
        }
        .alert("Existing Paused Session", isPresented: $showExistingPausedSessionAlert) {
            Button("Discard Paused Session", role: .destructive) {
                PausedSessionState.clear()
                navigateToWorkout = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have a paused session in progress. Discard it and start a new workout?")
        }
        .alert("Restart Session?", isPresented: $showRestartConfirmation) {
            Button("Restart", role: .destructive) {
                Task {
                    workoutStartingExerciseIndex = 0
                    await deps.workoutSessionManager.resetToIdle()
                    navigateToWorkout = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will start a new session from the first exercise. Your previous session data is preserved in history.")
        }
    }

    /// Bottom action content — read-only badge for completed days, action buttons otherwise.
    @ViewBuilder
    private var bottomActionContent: some View {
        let isCompleted = currentDay.status == .completed
        let isPaused    = currentDay.status == .paused
        let isPending   = currentDay.status == .pending
        let isSkipped   = currentDay.status == .skipped
        let hasExercises = !currentDay.exercises.isEmpty
        let accentColor = Color(red: 0.23, green: 0.56, blue: 1.00)
        let greenColor  = Color(red: 0.24, green: 0.82, blue: 0.46)
        let amberColor  = Color(red: 1.00, green: 0.70, blue: 0.10)
        // Skipped days fall through to the normal start/log buttons so the user can re-run them.
        let _ = isSkipped

        if isSessionActiveForThisDay && !isCompleted {
            // Active session for this day — show Continue Workout button
            Button(action: { navigateToWorkout = true }) {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Continue Workout")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            }

        } else if isCompleted {
            VStack(spacing: 10) {
                // Read-only badge — always shown for completed days.
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Session Completed")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(greenColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(greenColor.opacity(0.35), lineWidth: 1)
                )
                .foregroundStyle(greenColor)

                // Continue + Restart — only when session was exited early (some exercises have no logs).
                if isCompletedIncomplete {
                    // Primary: continue from the first incomplete exercise
                    Button(action: {
                        workoutStartingExerciseIndex = firstIncompleteExerciseIndex
                        Task {
                            await deps.workoutSessionManager.resetToIdle()
                            navigateToWorkout = true
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Continue Session")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                    }

                    // Secondary: restart from exercise 1
                    Button(action: { showRestartConfirmation = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Restart Session")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .foregroundStyle(.white.opacity(0.70))
                    }
                }
            }

        } else if isPaused {
            // Paused session — amber banner + resume button
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("SESSION PAUSED")
                        .font(.system(size: 13, weight: .bold))
                        .kerning(0.5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(amberColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(amberColor.opacity(0.30), lineWidth: 1)
                )
                .foregroundStyle(amberColor)

                Button(action: { navigateToWorkout = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Resume Session")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(amberColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.black)
                }
            }

        } else {
            let isEnabled = isPending || hasExercises
            let buttonLabel = isPending ? "Generate Session" : "Start Workout"

            // Primary: Start Workout / Generate Session
            Button(action: {
                if isPending {
                    // FB-008: trigger on-demand session generation
                    Task { await generateSessionOnDemand() }
                } else {
                    // Phase 4E: Guard against starting while another session is paused
                    if let paused = PausedSessionState.load(),
                       paused.trainingDayId != currentDay.id {
                        showExistingPausedSessionAlert = true
                    } else {
                        navigateToWorkout = true
                    }
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: isPending ? "wand.and.stars" : "figure.strengthtraining.traditional")
                        .font(.system(size: 17, weight: .semibold))
                    Text(buttonLabel)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    isEnabled ? accentColor : Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.30))
            }
            .disabled(!isEnabled)

            // Secondary: Log Past Session — only for generated days with exercises
            if !isPending && hasExercises {
                Button(action: { showManualLogSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.and.list.clipboard")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Log Past Session")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .foregroundStyle(.white.opacity(0.70))
                }
            }

            // Tertiary: Skip Session — for past unlogged days (not already skipped)
            if !isPending && hasExercises && dayStatus == .past && currentDay.status != .skipped {
                Button(action: { showSkipDayConfirmation = true }) {
                    Text("Skip this session")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .alert("Skip this session?", isPresented: $showSkipDayConfirmation) {
                    Button("Skip Session", role: .destructive) {
                        viewModel?.markDaySkipped(dayId: currentDay.id, weekId: week.id)
                        currentDay.status = .skipped
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This session won't be logged and the programme will advance to the next session.")
                }
            }
        }
    }

    // MARK: - Historical Set Log Views and Helpers (completed days)

    private func completedVolumeSummary(volume: Double) -> some View {
        let formatted = volume >= 1000
            ? String(format: "%.1f t", volume / 1000)
            : String(format: "%.0f kg", volume)
        return HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.caption.bold())
            Text("Total Volume: \(formatted)")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Color(red: 0.24, green: 0.82, blue: 0.46))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.24, green: 0.82, blue: 0.46).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(red: 0.24, green: 0.82, blue: 0.46).opacity(0.22), lineWidth: 1)
        )
    }

    /// Shown when a completed day has no set logs — lets the user backfill them.
    private var backfillSetLogsPrompt: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.40))
                Text("NO SET LOGS FOR THIS SESSION")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
                    .kerning(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showBackfillSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.and.list.clipboard")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Add Set Logs")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .foregroundStyle(.white.opacity(0.70))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .sheet(isPresented: $showBackfillSheet) {
            if let sessionId = completedSessionId {
                ManualSessionLogView(
                    day: currentDay,
                    week: week,
                    mesocycleCreatedAt: mesocycleCreatedAt,
                    programId: programId,
                    existingSessionId: sessionId,
                    onSessionLogged: {
                        // Reload set logs after backfill
                        Task { await loadHistoricalSetLogs() }
                    }
                )
                .environment(deps)
            }
        }
    }

    /// Fetches set logs for this completed day by finding the matching workout_session
    /// then querying set_logs where session_id matches.
    @MainActor
    private func loadHistoricalSetLogs() async {
        guard currentDay.status == .completed else { return }
        isLoadingSetLogs = true
        defer { isLoadingSetLogs = false }

        let supabase = deps.supabaseClient
        let userId = deps.resolvedUserId

        // Find the workout session for this day (match on day_type + user_id + completed)
        print("[ProgramDayDetailView] Querying sessions — userId: \(userId), dayLabel: '\(currentDay.dayLabel)', status: \(currentDay.status)")
        let sessions: [WorkoutSessionRow]
        do {
            sessions = try await supabase.fetch(
                WorkoutSessionRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",  op: .eq, value: userId.uuidString),
                    Filter(column: "day_type", op: .eq, value: currentDay.dayLabel),
                    Filter(column: "completed", op: .eq, value: "true")
                ]
            )
        } catch {
            print("[ProgramDayDetailView] Failed to fetch sessions: \(error.localizedDescription)")
            return
        }

        print("[ProgramDayDetailView] Found \(sessions.count) session(s) for day '\(currentDay.dayLabel)'")
        guard let sessionRow = sessions.last else {
            print("[ProgramDayDetailView] No matching session — completedSessionId stays nil, prompt will not show")
            return
        }
        completedSessionId = sessionRow.id

        // Fetch set logs for this session
        let setLogs: [SetLog]
        do {
            setLogs = try await supabase.fetch(
                SetLog.self,
                table: "set_logs",
                filters: [
                    Filter(column: "session_id", op: .eq, value: sessionRow.id.uuidString)
                ]
            )
        } catch {
            print("[ProgramDayDetailView] Failed to fetch set_logs: \(error.localizedDescription)")
            return
        }

        // Group by exerciseId, sorted by setNumber
        var grouped: [String: [SetLog]] = [:]
        for log in setLogs {
            grouped[log.exerciseId, default: []].append(log)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.setNumber < $1.setNumber }
        }
        historicalSetLogs = grouped
        historicalVolume = setLogs.reduce(0.0) { $0 + $1.weightKg * Double($1.repsCompleted) }
        // Snapshot originals so applySetLogEdit can construct "originally X" correction text.
        // Use merge with keep-existing semantics: if a key is already present (e.g. the view
        // reloaded after a first edit) the original pre-edit value is preserved, not overwritten.
        let freshSnapshot = Dictionary(uniqueKeysWithValues: setLogs.map { ($0.id, $0) })
        originalSetLogs.merge(freshSnapshot) { existing, _ in existing }
    }

    /// Patches the edited set log row in Supabase, deletes any stale embedding for that
    /// session+exercise, then writes a corrected embedding that explicitly describes what
    /// changed — so the AI's next RAG retrieval sees only accurate data.
    @MainActor
    private func applySetLogEdit(_ updated: SetLog) async {
        let supabase = deps.supabaseClient

        // 1. PATCH the set_logs row
        let patch = SetLogEditPatch(
            weightKg: updated.weightKg,
            repsCompleted: updated.repsCompleted,
            rpeFelt: updated.rpeFelt,
            rirEstimated: updated.rpeFelt.map { max(0, 10 - $0) }
        )
        do {
            try await supabase.update(patch, table: "set_logs", id: updated.id)
        } catch {
            print("[ProgramDayDetailView] set_logs patch failed: \(error.localizedDescription)")
        }

        // 2. Update local state immediately so UI reflects the edit
        editedSetLogIds.insert(updated.id)
        var newGroups = historicalSetLogs
        if var logs = newGroups[updated.exerciseId] {
            if let idx = logs.firstIndex(where: { $0.id == updated.id }) {
                logs[idx] = updated
            }
            newGroups[updated.exerciseId] = logs
        }
        historicalSetLogs = newGroups
        historicalVolume = newGroups.values.flatMap { $0 }
            .reduce(0.0) { $0 + $1.weightKg * Double($1.repsCompleted) }

        // 3. Build correction memory text.
        // Include "originally logged as X" so the AI understands this is a correction,
        // not a separate performance event.
        let memoryService = deps.memoryService
        let userId = deps.resolvedUserId.uuidString
        let sessionIdStr = completedSessionId?.uuidString ?? ""
        let exerciseName = currentDay.exercises
            .first(where: { $0.exerciseId == updated.exerciseId })?.name ?? updated.exerciseId
        let original = originalSetLogs[updated.id]

        // Determine outcome label relative to the planned rep range
        let plannedMax = currentDay.exercises
            .first(where: { $0.exerciseId == updated.exerciseId })?.repRange.max ?? updated.repsCompleted
        let repPct = Double(updated.repsCompleted) / Double(max(1, plannedMax))
        let outcome: String
        if repPct < 0.70 { outcome = "overloaded" }
        else if repPct >= 1.10 { outcome = "underloaded" }
        else { outcome = "on_target" }

        let weightStr: (Double) -> String = { kg in
            kg.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", kg) : String(format: "%.1f", kg)
        }
        var correctionText = "\(exerciseName) set \(updated.setNumber) corrected: "
            + "\(weightStr(updated.weightKg))kg × \(updated.repsCompleted) reps"
        if let rpe = updated.rpeFelt { correctionText += ", RPE \(rpe)" }
        if let orig = original {
            correctionText += " (originally logged as \(weightStr(orig.weightKg))kg × \(orig.repsCompleted) reps"
            if let origRpe = orig.rpeFelt { correctionText += ", RPE \(origRpe)" }
            correctionText += ")"
        }
        correctionText += ". Outcome: \(outcome)."

        let exerciseIdCopy = updated.exerciseId
        let muscleGroups = currentDay.exercises
            .first(where: { $0.exerciseId == exerciseIdCopy })
            .map { [$0.primaryMuscle] + $0.synergists } ?? []

        // 4. Delete stale correction embeddings for this session+exercise BEFORE writing the new one.
        // This prevents the AI from retrieving both the old and new correction at the same time.
        Task.detached {
            await memoryService.deleteSetCorrectionEmbeddings(
                sessionId: sessionIdStr,
                exerciseId: exerciseIdCopy,
                userId: userId
            )
            await memoryService.embed(
                text: correctionText,
                sessionId: sessionIdStr,
                exerciseId: exerciseIdCopy,
                tags: ["set_log_correction", outcome],
                muscleGroups: muscleGroups,
                userId: userId
            )
        }
    }

    /// Inserts a new set_log row for an exercise on this completed session,
    /// then refreshes local state so the new row appears immediately.
    @MainActor
    private func addNewSetLog(_ newLog: SetLog) async {
        guard let sessionId = completedSessionId else { return }
        let supabase = deps.supabaseClient

        // Determine set number = existing count + 1
        let existing = historicalSetLogs[newLog.exerciseId] ?? []
        let setNumber = existing.count + 1

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone.current

        struct NewSetLogPayload: Encodable {
            let id, sessionId, exerciseId, loggedAt: String
            let setNumber, repsCompleted: Int
            let weightKg: Double
            let rpeFelt, rirEstimated: Int?
            let primaryMuscle: String?
            enum CodingKeys: String, CodingKey {
                case id; case sessionId = "session_id"; case exerciseId = "exercise_id"
                case setNumber = "set_number"; case weightKg = "weight_kg"
                case repsCompleted = "reps_completed"; case rpeFelt = "rpe_felt"
                case rirEstimated = "rir_estimated"; case loggedAt = "logged_at"
                case primaryMuscle = "primary_muscle"
            }
        }
        let exerciseForLog = currentDay.exercises.first(where: { $0.exerciseId == newLog.exerciseId })
        let payload = NewSetLogPayload(
            id: newLog.id.uuidString,
            sessionId: sessionId.uuidString,
            exerciseId: newLog.exerciseId,
            loggedAt: isoFormatter.string(from: newLog.loggedAt),
            setNumber: setNumber,
            repsCompleted: newLog.repsCompleted,
            weightKg: newLog.weightKg,
            rpeFelt: newLog.rpeFelt,
            rirEstimated: newLog.rpeFelt.map { max(0, 10 - $0) },
            primaryMuscle: ExerciseLibrary.primaryMuscle(for: newLog.exerciseId)?.rawValue ?? exerciseForLog?.primaryMuscle
        )

        do {
            try await supabase.insert(payload, table: "set_logs")
        } catch {
            print("[ProgramDayDetailView] addNewSetLog insert failed: \(error.localizedDescription)")
            return
        }

        // Update local state immediately
        let inserted = SetLog(
            id: newLog.id,
            sessionId: sessionId,
            exerciseId: newLog.exerciseId,
            setNumber: setNumber,
            weightKg: newLog.weightKg,
            repsCompleted: newLog.repsCompleted,
            rpeFelt: newLog.rpeFelt,
            rirEstimated: newLog.rpeFelt.map { max(0, 10 - $0) },
            aiPrescribed: nil,
            loggedAt: newLog.loggedAt,
            primaryMuscle: ExerciseLibrary.primaryMuscle(for: newLog.exerciseId)?.rawValue ?? exerciseForLog?.primaryMuscle
        )
        var newGroups = historicalSetLogs
        newGroups[newLog.exerciseId, default: []].append(inserted)
        historicalSetLogs = newGroups
        historicalVolume = newGroups.values.flatMap { $0 }
            .reduce(0.0) { $0 + $1.weightKg * Double($1.repsCompleted) }

        // Embed into RAG memory
        let memoryService = deps.memoryService
        let userId = deps.resolvedUserId.uuidString
        let sessionIdStr = sessionId.uuidString
        let exerciseName = currentDay.exercises
            .first(where: { $0.exerciseId == newLog.exerciseId })?.name ?? newLog.exerciseId
        let muscleGroups = currentDay.exercises
            .first(where: { $0.exerciseId == newLog.exerciseId })
            .map { [$0.primaryMuscle] + $0.synergists } ?? []

        let weightStr = newLog.weightKg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", newLog.weightKg)
            : String(format: "%.1f", newLog.weightKg)
        var text = "Manual log — \(exerciseName) set \(setNumber): \(weightStr)kg × \(newLog.repsCompleted) reps"
        if let rpe = newLog.rpeFelt { text += ", RPE \(rpe)" }

        Task.detached {
            await memoryService.embed(
                text: text,
                sessionId: sessionIdStr,
                exerciseId: newLog.exerciseId,
                tags: ["manual_log", "exercise_outcome"],
                muscleGroups: muscleGroups,
                userId: userId
            )
        }
    }

    // MARK: - Live session state refresh

    /// Reads current session state from the actor and updates local state for rendering.
    /// Called on every view appear so returning from WorkoutView reflects the latest sets.
    @MainActor
    private func refreshLiveSessionState() async {
        let activeId = await deps.workoutSessionManager.currentTrainingDayId
        let state = await deps.workoutSessionManager.sessionState
        let isLive: Bool
        switch state {
        case .idle, .sessionComplete, .error: isLive = false
        default: isLive = true
        }
        isSessionActiveForThisDay = (activeId == currentDay.id) && isLive

        if isSessionActiveForThisDay {
            // Read completed sets from the actor, grouped by exerciseId
            let sets = await deps.workoutSessionManager.completedSets
            var grouped: [String: [SetLog]] = [:]
            for log in sets {
                grouped[log.exerciseId, default: []].append(log)
            }
            for key in grouped.keys {
                grouped[key]?.sort { $0.setNumber < $1.setNumber }
            }
            liveSessionSets = grouped
        } else {
            liveSessionSets = [:]
        }
    }

    // MARK: - FB-008: On-demand session generation

    @MainActor
    private func generateSessionOnDemand() async {
        guard let vm = viewModel, let profile = gymProfile else {
            sessionGenerationError = "Session generation requires a gym profile. Please scan your gym first."
            return
        }
        sessionGenerationError = nil
        isGeneratingSession = true
        defer { isGeneratingSession = false }

        if let generated = await vm.generateDaySession(
            day: currentDay,
            week: week,
            gymProfile: profile
        ) {
            currentDay = generated
        } else {
            sessionGenerationError = "Could not generate session. Check your API key and try again."
        }
    }
}

// MARK: - ExerciseDetailCard

private struct ExerciseDetailCard: View {

    let exercise: PlannedExercise
    let index: Int
    /// Completed set logs for an in-progress session. Non-empty only when
    /// ProgramDayDetailView.isSessionActiveForThisDay == true.
    var liveSetLogs: [SetLog] = []

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

            // Live set logs — shown when a session is in progress for this day
            if !liveSetLogs.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.08))
                liveSetLogsSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

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

    // MARK: Live Set Logs (active session)

    private var liveSetLogsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOGGED")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(0.6)

            ForEach(liveSetLogs, id: \.id) { log in
                HStack(spacing: 6) {
                    Text("Set \(log.setNumber)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                        .frame(width: 42, alignment: .leading)

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
                        Spacer()
                        Text("RPE \(rpe)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                }
            }
        }
    }

    private func formatWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fkg", kg)
            : String(format: "%.1fkg", kg)
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
        // Typed-first dispatch (Slice 1) with substring-match fallback for
        // non-canonical strings. Core branch removed — core is excluded from
        // the locked-six taxonomy per ADR-0005.
        if let primary = PrimaryMuscle(rawValue: muscle.lowercased()) {
            switch primary {
            case .chest:                            return Color(red: 0.96, green: 0.42, blue: 0.30)
            case .back:                             return Color(red: 0.30, green: 0.70, blue: 0.96)
            case .shoulders:                        return Color(red: 0.70, green: 0.50, blue: 0.96)
            case .quads, .hamstrings, .glutes,
                 .calves:                           return Color(red: 0.30, green: 0.96, blue: 0.60)
            case .biceps, .triceps:                 return Color(red: 0.96, green: 0.80, blue: 0.30)
            }
        }
        let lower = muscle.lowercased()
        if lower.contains("pector") || lower.contains("chest") { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if lower.contains("lat") || lower.contains("back") || lower.contains("rhom") { return Color(red: 0.30, green: 0.70, blue: 0.96) }
        if lower.contains("delt") || lower.contains("shoulder") { return Color(red: 0.70, green: 0.50, blue: 0.96) }
        if lower.contains("quad") || lower.contains("hamstr") || lower.contains("glut") || lower.contains("calf") { return Color(red: 0.30, green: 0.96, blue: 0.60) }
        if lower.contains("bicep") || lower.contains("tricep") { return Color(red: 0.96, green: 0.80, blue: 0.30) }
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

// MARK: - WorkoutSessionRow (lightweight Decodable for session query)

/// Lightweight read-only row decoded from `workout_sessions` for historical set log lookup.
private struct WorkoutSessionRow: Decodable, Identifiable {
    let id: UUID
    let dayType: String
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case dayType  = "day_type"
        case completed
    }
}

// MARK: - SetLogEditPatch (Encodable PATCH payload)

private struct SetLogEditPatch: Encodable {
    let weightKg: Double
    let repsCompleted: Int
    let rpeFelt: Int?
    let rirEstimated: Int?

    enum CodingKeys: String, CodingKey {
        case weightKg       = "weight_kg"
        case repsCompleted  = "reps_completed"
        case rpeFelt        = "rpe_felt"
        case rirEstimated   = "rir_estimated"
    }
}

// MARK: - CompletedExerciseCard

/// Exercise card variant shown on completed days — expands to show set log rows.
private struct CompletedExerciseCard: View {

    let exercise: PlannedExercise
    let index: Int
    let setLogs: [SetLog]
    let editedIds: Set<UUID>
    let onTapSet: (SetLog) -> Void
    let onAddSet: (SetLog) -> Void

    @State private var cuesExpanded = false
    @State private var showAddSetSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .top, spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(exercise.primaryMuscle.formattedMuscleName)
                        .font(.caption2.bold())
                        .foregroundStyle(muscleColor(for: exercise.primaryMuscle))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(muscleColor(for: exercise.primaryMuscle).opacity(0.15), in: Capsule())
                }

                Spacer()

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

            Divider().background(Color.white.opacity(0.08))

            // Set log rows
            if setLogs.isEmpty {
                Text("No sets logged")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(setLogs.enumerated()), id: \.element.id) { i, log in
                        SetLogRow(
                            log: log,
                            isEdited: editedIds.contains(log.id),
                            onTap: { onTapSet(log) }
                        )
                        if i < setLogs.count - 1 {
                            Divider()
                                .background(Color.white.opacity(0.06))
                                .padding(.leading, 16)
                        }
                    }
                }
            }

            // Add Set button
            Divider().background(Color.white.opacity(0.06))
            Button(action: { showAddSetSheet = true }) {
                Label("Add Set", systemImage: "plus.circle")
                    .font(.caption.bold())
                    .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .sheet(isPresented: $showAddSetSheet) {
                SetLogAddSheet(exerciseId: exercise.exerciseId, setNumber: setLogs.count + 1) { newLog in
                    onAddSet(newLog)
                }
                .presentationDetents([.medium])
            }

            // Coaching cues — expandable
            if !exercise.coachingCues.isEmpty {
                Divider().background(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 0) {
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
                    .padding(.vertical, 12)

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
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: cuesExpanded)
            }
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func muscleColor(for muscle: String) -> Color {
        // Typed-first dispatch (Slice 1) with substring-match fallback for
        // non-canonical strings. Core branch removed — core is excluded from
        // the locked-six taxonomy per ADR-0005.
        if let primary = PrimaryMuscle(rawValue: muscle.lowercased()) {
            switch primary {
            case .chest:                            return Color(red: 0.96, green: 0.42, blue: 0.30)
            case .back:                             return Color(red: 0.30, green: 0.70, blue: 0.96)
            case .shoulders:                        return Color(red: 0.70, green: 0.50, blue: 0.96)
            case .quads, .hamstrings, .glutes,
                 .calves:                           return Color(red: 0.30, green: 0.96, blue: 0.60)
            case .biceps, .triceps:                 return Color(red: 0.96, green: 0.80, blue: 0.30)
            }
        }
        let lower = muscle.lowercased()
        if lower.contains("pector") || lower.contains("chest") { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if lower.contains("lat") || lower.contains("back") || lower.contains("rhom") { return Color(red: 0.30, green: 0.70, blue: 0.96) }
        if lower.contains("delt") || lower.contains("shoulder") { return Color(red: 0.70, green: 0.50, blue: 0.96) }
        if lower.contains("quad") || lower.contains("hamstr") || lower.contains("glut") || lower.contains("calf") { return Color(red: 0.30, green: 0.96, blue: 0.60) }
        if lower.contains("bicep") || lower.contains("tricep") { return Color(red: 0.96, green: 0.80, blue: 0.30) }
        return Color(red: 0.78, green: 0.82, blue: 0.88)
    }
}

// MARK: - SetLogRow

private struct SetLogRow: View {

    let log: SetLog
    let isEdited: Bool
    let onTap: () -> Void

    private func weightString(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Set number badge
                Text("S\(log.setNumber)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.40))
                    .frame(width: 30, height: 24)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Weight
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(weightString(log.weightKg))
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("kg")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Text("×")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))

                // Reps
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(log.repsCompleted)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("reps")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }

                // RPE
                if let rpe = log.rpeFelt {
                    Text("RPE \(rpe)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }

                Spacer()

                // Edited badge
                if isEdited {
                    Text("Edited")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.91, green: 0.63, blue: 0.19))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.91, green: 0.63, blue: 0.19).opacity(0.15), in: Capsule())
                }

                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SetLogAddSheet

private struct SetLogAddSheet: View {

    let exerciseId: String
    let setNumber: Int
    let onConfirm: (SetLog) -> Void

    @State private var weightText: String = ""
    @State private var repsText: String = ""
    @State private var rpeValue: Int? = nil

    @Environment(\.dismiss) private var dismiss

    private var confirmedWeight: Double? { Double(weightText.replacingOccurrences(of: ",", with: ".")) }
    private var confirmedReps: Int? { Int(repsText) }
    private var canConfirm: Bool { confirmedWeight != nil && confirmedReps != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add Set \(setNumber)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    // Weight field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WEIGHT")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .kerning(0.8)
                        HStack(spacing: 8) {
                            TextField("e.g. 80", text: $weightText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text("kg")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.50))
                        }
                    }

                    // Reps field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REPS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .kerning(0.8)
                        TextField("e.g. 8", text: $repsText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // RPE stepper
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RPE (OPTIONAL)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .kerning(0.8)
                        HStack(spacing: 12) {
                            ForEach([6, 7, 8, 9, 10], id: \.self) { value in
                                Button {
                                    rpeValue = rpeValue == value ? nil : value
                                } label: {
                                    Text("\(value)")
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(
                                            rpeValue == value
                                                ? Color(red: 0.23, green: 0.56, blue: 1.00)
                                                : Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                        .foregroundStyle(rpeValue == value ? .white : .white.opacity(0.55))
                                }
                            }
                        }
                    }

                    Spacer()

                    Button {
                        guard let weight = confirmedWeight, let reps = confirmedReps else { return }
                        let newLog = SetLog(
                            id: UUID(),
                            sessionId: UUID(), // placeholder — addNewSetLog uses completedSessionId
                            exerciseId: exerciseId,
                            setNumber: setNumber,
                            weightKg: weight,
                            repsCompleted: reps,
                            rpeFelt: rpeValue,
                            rirEstimated: rpeValue.map { max(0, 10 - $0) },
                            aiPrescribed: nil,
                            loggedAt: Date()
                        )
                        onConfirm(newLog)
                        dismiss()
                    } label: {
                        Text("Add Set")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                canConfirm
                                    ? Color(red: 0.23, green: 0.56, blue: 1.00)
                                    : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .foregroundStyle(canConfirm ? .white : .white.opacity(0.30))
                    }
                    .disabled(!canConfirm)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }
}

// MARK: - SetLogEditSheet

struct SetLogEditSheet: View {

    let log: SetLog
    let isEdited: Bool
    let onConfirm: (SetLog) -> Void

    @State private var weightText: String
    @State private var repsText: String
    @State private var rpeValue: Int?

    @Environment(\.dismiss) private var dismiss

    init(log: SetLog, isEdited: Bool, onConfirm: @escaping (SetLog) -> Void) {
        self.log = log
        self.isEdited = isEdited
        self.onConfirm = onConfirm
        _weightText = State(initialValue: {
            let kg = log.weightKg
            return kg.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", kg)
                : String(format: "%.1f", kg)
        }())
        _repsText = State(initialValue: "\(log.repsCompleted)")
        _rpeValue = State(initialValue: log.rpeFelt)
    }

    private var confirmedWeight: Double? { Double(weightText) }
    private var confirmedReps: Int? { Int(repsText) }
    private var canConfirm: Bool { confirmedWeight != nil && confirmedReps != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 28) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edit Set \(log.setNumber)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        if isEdited {
                            Label("Previously edited", systemImage: "pencil.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.91, green: 0.63, blue: 0.19))
                        }
                    }

                    // Weight field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WEIGHT")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .kerning(0.8)
                        HStack(spacing: 8) {
                            TextField("e.g. 80", text: $weightText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text("kg")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.50))
                        }
                    }

                    // Reps field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REPS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .kerning(0.8)
                        TextField("e.g. 8", text: $repsText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // RPE stepper
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RPE (OPTIONAL)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .kerning(0.8)
                        HStack(spacing: 12) {
                            ForEach([6, 7, 8, 9, 10], id: \.self) { value in
                                Button {
                                    rpeValue = rpeValue == value ? nil : value
                                } label: {
                                    Text("\(value)")
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(
                                            rpeValue == value
                                                ? Color(red: 0.23, green: 0.56, blue: 1.00)
                                                : Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                        .foregroundStyle(rpeValue == value ? .white : .white.opacity(0.55))
                                }
                            }
                        }
                    }

                    Spacer()

                    // Confirm button
                    Button {
                        guard let weight = confirmedWeight, let reps = confirmedReps else { return }
                        let updated = SetLog(
                            id: log.id,
                            sessionId: log.sessionId,
                            exerciseId: log.exerciseId,
                            setNumber: log.setNumber,
                            weightKg: weight,
                            repsCompleted: reps,
                            rpeFelt: rpeValue,
                            rirEstimated: rpeValue.map { max(0, 10 - $0) },
                            aiPrescribed: log.aiPrescribed,
                            loggedAt: log.loggedAt
                        )
                        onConfirm(updated)
                        dismiss()
                    } label: {
                        Text("Confirm Edit")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                canConfirm
                                    ? Color(red: 0.23, green: 0.56, blue: 1.00)
                                    : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .foregroundStyle(canConfirm ? .white : .white.opacity(0.30))
                    }
                    .disabled(!canConfirm)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProgramDayDetailView(
            day: Mesocycle.mockMesocycle().weeks[0].trainingDays[0],
            week: Mesocycle.mockMesocycle().weeks[0],
            mesocycleCreatedAt: Date(),
            viewModel: nil,
            gymProfile: nil
        )
    }
}
