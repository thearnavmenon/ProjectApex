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
    /// Closure injected by the root TabView. Used by the "Continue Workout" CTA on
    /// a live day so it reuses Tab 1's WorkoutView instead of pushing a second one
    /// under Tab 0's nav stack. Defaults to a no-op outside the TabView (previews).
    @Environment(\.switchToTab) private var switchToTab

    /// FB-008: local state tracking whether session generation is in progress for this view.
    @State private var isGeneratingSession: Bool = false
    @State private var sessionGenerationError: String? = nil
    /// Controls the manual session logging sheet.
    @State private var showManualLogSheet: Bool = false
    /// Controls the set-log backfill sheet (completed days with no set logs).
    @State private var showBackfillSheet: Bool = false
    /// Controls the alert shown when the user tries to start a new session while another is paused.
    @State private var showExistingPausedSessionAlert: Bool = false
    /// Controls the confirmation alert for skipping a past unlogged session from the detail view.
    @State private var showSkipDayConfirmation: Bool = false
    /// Controls the confirmation alert for regenerating a generated-but-unlogged session (#318 U4).
    @State private var showRegenerateConfirmation: Bool = false

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

    // MARK: - Last-time + targets state (#507 — not-yet-started days)

    /// Most-recent prior result per exercise, derived from a targeted read of this
    /// day type's previous sessions. Keyed by exerciseId. Empty for exercises with
    /// no prior history (graceful omission — never fabricated).
    @State private var lastTimeByExercise: [String: LastTimeInfo] = [:]
    /// Coach floor/stretch targets per movement pattern, read from the digest
    /// projections. Empty when no projections exist (graceful omission).
    @State private var projectionByPattern: [MovementPattern: PatternProjection] = [:]

    // DEBUG-only: read the Start Any Day dev mode flag from UserDefaults.
    #if DEBUG
    private var startAnyDayModeActive: Bool {
        devOverride || UserDefaults.standard.bool(forKey: FreeDayKeys.startAnyDayMode)
    }
    #else
    private var startAnyDayModeActive: Bool { devOverride }
    #endif

    /// #437 (Q1 = CUT non-next starts): the id of the current programme pointer day —
    /// the only day a fresh session may be started from. nil when the programme is
    /// complete (no incomplete day remains).
    private var nextIncompleteDayId: UUID? {
        guard let meso = viewModel?.currentMesocycle else { return nil }
        return viewModel?.nextIncompleteDay(in: meso)?.day.id
    }

    /// #437 (Q1): pure start-gate predicate. A fresh session may only be started from
    /// the current pointer day (`dayId == nextIncompleteDayId`); the DEBUG-only
    /// startAnyDayMode override re-enables any day for developer testing. The paused /
    /// live-resume branches are this-day-scoped and handled separately, so they are
    /// unaffected by this gate. Static + parameterised so it is unit-testable.
    static func isStartableDay(
        dayId: UUID,
        nextIncompleteDayId: UUID?,
        startAnyDayModeActive: Bool
    ) -> Bool {
        startAnyDayModeActive || dayId == nextIncompleteDayId
    }

    /// #446 (Q6 = calendar-time DayStatus is informational only): the Skip-Session
    /// affordance keys off the day's training-time status — NOT the wall-clock
    /// `DayStatus`. A day with a real, unlogged session (`.generated`, has exercises)
    /// is skippable regardless of where it falls on the calendar. Completed / paused /
    /// pending / already-skipped days have nothing to skip. Pure + parameterised so it
    /// is unit-testable and provably free of any calendar-time dependency.
    static func isSkippableDay(
        status: TrainingDayStatus,
        hasExercises: Bool
    ) -> Bool {
        status == .generated && hasExercises
    }

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
    }

    /// #438: the day read live from `viewModel.currentMesocycle` by id on every render.
    /// The @Observable view model invalidates this reader on every status mutation
    /// (markDayCompleted / markDayPaused / markDaySkipped / generateDaySession), so the
    /// detail view never holds a stale snapshot. Falls back to the injected `day` when no
    /// matching mesocycle is loaded (e.g. SwiftUI previews with viewModel == nil).
    private var currentDay: TrainingDay {
        if let meso = viewModel?.currentMesocycle,
           let found = viewModel?.findTrainingDay(byId: day.id, in: meso) {
            return found.day
        }
        return day
    }

    private var dayStatus: DayStatus {
        DayStatus.resolve(
            mesocycleCreatedAt: mesocycleCreatedAt,
            weekNumber: week.weekNumber,
            dayOfWeek: currentDay.dayOfWeek
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background — pure-black Brutalist surface.
            Apex.bg.ignoresSafeArea()

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
                                label: "Workout paused",
                                color: Apex.amber
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
                                    .tint(Apex.textDim)
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
                                        // #65: intent is chosen by the user in the AddSet sheet.
                                        onAddSet: { newLog, intent in Task { await addNewSetLog(newLog, intent: intent) } }
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
                                ExerciseDetailCard(
                                    exercise: exercise,
                                    index: index + 1,
                                    lastTime: lastTimeByExercise[exercise.exerciseId],
                                    projection: projectionForExercise(exercise)
                                )
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
        .toolbarBackground(Apex.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if currentDay.status == .completed {
                Task { await loadHistoricalSetLogs() }
            } else if !currentDay.exercises.isEmpty {
                // #507: a not-yet-started day with planned exercises — load last-time
                // results + coach targets in the background (non-blocking, real data only).
                Task { await loadLastTimeAndTargets() }
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
        // #437: this view no longer hosts its own WorkoutView. Start/Resume routes to the
        // single Workout-tab host via switchToTab(1); there is exactly one live WorkoutView.
    }

    // MARK: - FB-008: Preparing Session Loading View

    private var preparingSessionView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(Apex.accent)
                .symbolEffect(.pulse)

            VStack(spacing: 10) {
                Text("Preparing Your Session")
                    .font(.system(size: 24, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)

                Text("Analysing your lift history and fatigue signals to build the optimal session for today.")
                    .font(.subheadline)
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
    }

    // MARK: - FB-008: Session Pending Banner

    private var sessionPendingBannerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Apex.textDim)
            VStack(alignment: .leading, spacing: 4) {
                ApexSectionLabel(text: "Session will be generated before you train")
                Text("Tap \"Generate Session\" to build this session using your full lift history.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Apex.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - FB-008: Pending exercises placeholder

    private var pendingExercisePlaceholder: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .fill(Apex.surface)
                    .frame(height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                            .stroke(Apex.hairline, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - FB-008: Session generation error card

    private func sessionErrorCard(error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Apex.amber)
            Text(error)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Apex.text.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Apex.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(Apex.amber.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Day Header

    private var dayHeaderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ApexSectionLabel(
                    text: "Week \(week.weekNumber) · \(week.phase.displayTitle)",
                    color: Apex.textDim
                )
                Spacer()
                // Phase chip — monochrome Brutalist tag.
                Text(week.phase.displayTitle)
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().stroke(Apex.hairline, lineWidth: 1))
            }

            // Real muscle-focus line — derived from this day's exercise primary muscles
            // (presentation of existing data; no fabricated duration). The day name
            // itself remains the large navigation title (preserved), so it is not
            // duplicated here.
            if let focus = muscleFocusLine {
                Text(focus)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    /// "N EXERCISES · CHEST · TRICEPS" — derived from the day's existing exercise
    /// primaryMuscle data (deduplicated, in first-appearance order). Returns nil when
    /// the day has no exercises (e.g. a pending day) so no empty line renders.
    private var muscleFocusLine: String? {
        let count = currentDay.exercises.count
        guard count > 0 else { return nil }
        var seen = Set<String>()
        var muscles: [String] = []
        for ex in currentDay.exercises {
            // Short form (e.g. "CHEST" not "PECTORALIS MAJOR") to match the calendar.
            let name = ex.primaryMuscle.formattedShortMuscleName.uppercased()
            if seen.insert(name).inserted {
                muscles.append(name)
            }
        }
        let head = "\(count) EXERCISE\(count == 1 ? "" : "S")"
        return ([head] + muscles).joined(separator: " · ")
    }

    // MARK: - Status Banner

    @ViewBuilder
    private var statusBannerView: some View {
        switch dayStatus {
        case .future:
            statusBadge(
                icon: "calendar.badge.clock",
                // #437 (Q1): non-next days are not startable — drop the "train this day early" Start promise.
                label: "Scheduled — unlocks when it becomes your next workout",
                color: Apex.textDim
            )
        case .past:
            statusBadge(
                icon: "calendar.badge.checkmark",
                // #437 (Q1): no re-run Start for past days; backdating via Log Past Session is kept.
                label: "Past session — Log Past Session to backdate",
                color: Apex.textDim
            )
        case .today:
            EmptyView()
        }
    }

    /// "Session Completed" banner shown at the top of completed days.
    /// These days are read-only — no workout or log actions available. Monochrome
    /// (the volt-lime accent is reserved for the live/primary action, never the
    /// completed/done state).
    private var completedBannerView: some View {
        statusBadge(
            icon: "checkmark.seal.fill",
            label: "Session completed — this is a historical record",
            color: Apex.textDim
        )
    }

    /// "Session Skipped" banner shown at the top of skipped days.
    /// #437 (Q1): a skipped day is never the programme pointer, so it is read-only here.
    private var skippedBannerView: some View {
        statusBadge(
            icon: "xmark.circle.fill",
            label: "Session skipped",
            color: Apex.textFaint
        )
    }

    private func statusBadge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .fontWidth(.condensed)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(color.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - Session Notes

    private func sessionNotesCard(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ApexSectionLabel(text: "Session notes", color: Apex.textFaint)
            Text(notes)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Apex.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - Start Workout Button

    private var startWorkoutButton: some View {
        VStack(spacing: 12) {
            bottomActionContent
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .background(
            LinearGradient(
                colors: [Apex.bg.opacity(0), Apex.bg],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .sheet(isPresented: $showManualLogSheet) {
            ManualSessionLogView(
                day: currentDay,
                week: week,
                mesocycleCreatedAt: mesocycleCreatedAt,
                programId: programId,
                onSessionLogged: {
                    // #438: markDay* is the single status writer — no local dual-write.
                    viewModel?.markDayCompleted(dayId: currentDay.id, weekId: week.id)
                }
            )
        }
        .alert("Workout paused", isPresented: $showExistingPausedSessionAlert) {
            Button("Discard workout", role: .destructive) {
                PausedSessionState.clear()
                switchToTab(1)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have a paused session in progress. Discard it and start a new workout?")
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
        // Skipped days fall through to the non-pointer branch (read-only note + Log Past Session).
        let _ = isSkipped

        if isSessionActiveForThisDay && !isCompleted {
            // Active session for this day — route to Tab 1's WorkoutView rather than
            // pushing a second one under this stack. switchToTab defaults to a no-op
            // outside the root TabView (previews), so this is safe to call unguarded.
            Button(action: { switchToTab(1) }) {
                ApexButton(title: "Continue Workout", icon: "play.fill")
            }

        } else if isCompleted {
            // Read-only badge — always shown for completed days. Monochrome (the
            // volt-lime accent is reserved for the live/primary action, never done).
            // #437 (Q1 = CUT non-next starts): a completed day is never the programme
            // pointer, so the Continue/Restart re-run affordances are removed — a
            // completed day is a read-only historical record here.
            HStack(spacing: 9) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("Session Completed")
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .fontWidth(.condensed)
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Apex.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(Apex.hairline, lineWidth: 1)
            )

        } else if isPaused {
            // Paused session — amber banner + resume button
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Workout Paused")
                        .font(.system(size: 13, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .fontWidth(.condensed)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Apex.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                        .stroke(Apex.amber.opacity(0.30), lineWidth: 1)
                )
                .foregroundStyle(Apex.amber)

                // #437: resume routes to the single Workout-tab host. A paused day is the
                // programme pointer (status .paused ≠ completed/skipped), so Tab 1 renders
                // it and its PausedSessionState sentinel drives the resume.
                Button(action: { switchToTab(1) }) {
                    ApexButton(title: "Resume workout", icon: "play.fill", tint: Apex.amber)
                }
            }

        } else {
            // #437 (Q1 = CUT non-next starts): a fresh session may only be started/generated
            // from the current programme pointer day. The DEBUG-only startAnyDayMode override
            // keeps any day startable for developer testing.
            let isStartable = Self.isStartableDay(
                dayId: currentDay.id,
                nextIncompleteDayId: nextIncompleteDayId,
                startAnyDayModeActive: startAnyDayModeActive
            )
            let isEnabled = isStartable && (isPending || hasExercises)
            let buttonLabel = isPending ? "Generate Session" : "Start Workout"

            // Primary: Start Workout / Generate Session — only shown for the pointer day.
            if isStartable {
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
                            // #437: route to the single Workout-tab host (no second WorkoutView).
                            switchToTab(1)
                        }
                    }
                }) {
                    ApexButton(
                        title: buttonLabel,
                        icon: isPending ? "wand.and.stars" : "figure.strengthtraining.traditional"
                    )
                    .opacity(isEnabled ? 1.0 : 0.35)
                }
                .disabled(!isEnabled)
            } else {
                // Non-pointer day — not startable (Q1). Informational note only.
                Text("This session unlocks when it becomes your next workout.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            // Secondary: Log Past Session — only for generated days with exercises
            if !isPending && hasExercises {
                Button(action: { showManualLogSheet = true }) {
                    ApexButton(title: "Log Past Session", kind: .ghost, icon: "pencil.and.list.clipboard")
                }
            }

            // Tertiary: Skip Session — for a generated, unlogged session. #446 (Q6): the
            // gate is the day's training-time status, NOT wall-clock DayStatus, so the
            // current pointer day is skippable regardless of its calendar position.
            if Self.isSkippableDay(status: currentDay.status, hasExercises: hasExercises) {
                Button(action: { showSkipDayConfirmation = true }) {
                    Text("Skip this session")
                        .font(.system(size: 13, weight: .semibold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                }
                .alert("Skip this session?", isPresented: $showSkipDayConfirmation) {
                    Button("Skip Session", role: .destructive) {
                        // #438: markDay* is the single status writer — no local dual-write.
                        viewModel?.markDaySkipped(dayId: currentDay.id, weekId: week.id)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This session won't be logged and the programme will advance to the next session.")
                }
            }

            // Tertiary: Regenerate — only for a .generated, unlogged day with no
            // live/paused session sentinel (#318 U4 / J-F10). The sentinel is
            // written at session start and updated every set, so a match means
            // logged work exists for this day.
            if currentDay.status == .generated,
               PausedSessionState.load()?.trainingDayId != currentDay.id {
                Button(action: { showRegenerateConfirmation = true }) {
                    Text("Regenerate this session")
                        .font(.system(size: 13, weight: .semibold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                }
                .alert("Regenerate this session?", isPresented: $showRegenerateConfirmation) {
                    Button("Regenerate", role: .destructive) {
                        guard let vm = viewModel else { return }
                        vm.resetDayToPending(dayId: currentDay.id, weekId: week.id)
                        // Only proceed when the reset actually took — the view
                        // model refuses ineligible days (completed/paused/sentinel).
                        // #438: the live currentDay read picks up the reset-to-pending status
                        // from currentMesocycle — no local snapshot to assign.
                        if let meso = vm.currentMesocycle,
                           let found = vm.findTrainingDay(byId: currentDay.id, in: meso),
                           found.day.status == .pending {
                            Task { await generateSessionOnDemand() }
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This discards the planned exercises for this day and generates a fresh session from your latest training data.")
                }
            }
        }
    }

    // MARK: - Historical Set Log Views and Helpers (completed days)

    private func completedVolumeSummary(volume: Double) -> some View {
        // Volume hero — monochrome Brutalist (done state is never lime). Big tabular
        // numeral over a tracked unit label.
        let value = volume >= 1000
            ? String(format: "%.1f", volume / 1000)
            : String(format: "%.0f", volume)
        let unit = volume >= 1000 ? "Tonnes Volume" : "KG Volume"
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            ApexNumeral(text: value, size: 44, color: Apex.text)
            ApexSectionLabel(text: unit, color: Apex.textDim)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    /// Shown when a completed day has no set logs — lets the user backfill them.
    private var backfillSetLogsPrompt: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Apex.textFaint)
                ApexSectionLabel(text: "No set logs for this session", color: Apex.textFaint)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showBackfillSheet = true }) {
                ApexButton(title: "Add Set Logs", kind: .ghost, icon: "pencil.and.list.clipboard")
            }
        }
        .padding(16)
        .apexCard()
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
    ///
    /// Slice 11 / #62 fix: query is keyed on (user_id, day_type, **week_number**) — the
    /// missing week_number filter caused every "Pull A" / "Push A" / etc. detail page
    /// across every week to render the same session's data, since the prior query
    /// matched all sessions of a given day_type and `sessions.last` returned a
    /// non-deterministic single row. Also drops the `completed = true` filter so a
    /// session that was started and ended early (e.g. one logged set) still renders
    /// its own real data on its own week's detail page rather than falling through
    /// to a different week's session. Order by session_date desc + limit 1 picks
    /// the most recent attempt deterministically when the user has re-run a
    /// (week, day) pair.
    @MainActor
    private func loadHistoricalSetLogs() async {
        guard currentDay.status == .completed else { return }
        isLoadingSetLogs = true
        defer { isLoadingSetLogs = false }

        let supabase = deps.supabaseClient
        let userId = deps.resolvedUserId

        // Find the workout session for this day. Filters: user + day_type + week_number.
        // No `completed` filter — incomplete sessions still render their real logged
        // sets on their own week's page (rather than mismatching to a different week).
        print("[ProgramDayDetailView] Querying sessions — userId: \(userId), dayLabel: '\(currentDay.dayLabel)', weekNumber: \(week.weekNumber), status: \(currentDay.status)")
        let sessions: [WorkoutSessionRow]
        do {
            sessions = try await supabase.fetch(
                WorkoutSessionRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",     op: .eq, value: userId.uuidString),
                    Filter(column: "day_type",    op: .eq, value: currentDay.dayLabel),
                    Filter(column: "week_number", op: .eq, value: "\(week.weekNumber)")
                ],
                order: "session_date.desc",
                limit: 1
            )
        } catch {
            print("[ProgramDayDetailView] Failed to fetch sessions: \(error.localizedDescription)")
            return
        }

        print("[ProgramDayDetailView] Found \(sessions.count) session(s) for day '\(currentDay.dayLabel)' week \(week.weekNumber)")
        guard let sessionRow = sessions.first else {
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

    // MARK: - #507: Last-time results + coach targets (not-yet-started days)

    /// Resolves the coach floor/stretch projection for a planned exercise by mapping
    /// exercise → movement pattern → matching `PatternProjection`. Returns nil when the
    /// exercise has no library entry or no projection exists for its pattern (omission).
    private func projectionForExercise(_ exercise: PlannedExercise) -> PatternProjection? {
        guard let pattern = ExerciseLibrary.lookup(exercise.exerciseId)?.movementPattern else { return nil }
        return projectionByPattern[pattern]
    }

    /// Targeted, non-blocking read for a not-yet-started day:
    ///   • Last-time result per planned exercise — the heaviest working set of that
    ///     exercise's most-recent prior session of this day type, plus an up/flat trend
    ///     vs. the session before it (by top-set e1RM). Real data only; exercises with
    ///     no prior history are simply omitted from `lastTimeByExercise`.
    ///   • Coach floor/stretch — read from the cached digest projections, keyed by pattern.
    ///
    /// Modelled on `ProgramViewModel.deepLiftHistory`: pull the recent prior sessions of
    /// this `day_type` (excluding the current week, which has no session yet) and their
    /// set logs in one `in (...)` query. Failures degrade to "no last-time element" rather
    /// than fabricating a number.
    @MainActor
    private func loadLastTimeAndTargets() async {
        // ── Coach targets — read projections from the cached digest (no network when warm) ──
        let digest = await deps.traineeModelService.digest()
        let projections = digest?.projections?.patternProjections ?? []
        projectionByPattern = Dictionary(projections.map { ($0.pattern, $0) }, uniquingKeysWith: { first, _ in first })

        // ── Last-time results — targeted read of this day type's prior sessions ──
        let supabase = deps.supabaseClient
        let userId = deps.resolvedUserId

        // Most recent prior sessions of this day type, excluding the current week (no
        // session exists for it yet, and we never want the in-progress session as "last").
        let priorSessions: [LastTimeSessionRow]
        do {
            priorSessions = try await supabase.fetch(
                LastTimeSessionRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",     op: .eq,  value: userId.uuidString),
                    Filter(column: "day_type",    op: .eq,  value: currentDay.dayLabel),
                    Filter(column: "week_number", op: .neq, value: "\(week.weekNumber)"),
                    Filter(column: "status",      op: .neq, value: "abandoned")
                ],
                order: "session_date.desc",
                limit: 8
            )
        } catch {
            print("[ProgramDayDetailView] last-time: session fetch failed: \(error.localizedDescription)")
            return
        }
        guard !priorSessions.isEmpty else { return }

        // Set logs for those sessions in one query.
        let sessionIds = priorSessions.map(\.id.uuidString)
        let inValue = "(\(sessionIds.joined(separator: ",")))"
        let setLogs: [SetLog]
        do {
            setLogs = try await supabase.fetch(
                SetLog.self,
                table: "set_logs",
                filters: [Filter(column: "session_id", op: .in, value: inValue)]
            )
        } catch {
            print("[ProgramDayDetailView] last-time: set_logs fetch failed: \(error.localizedDescription)")
            return
        }

        lastTimeByExercise = Self.lastTimeMap(
            forExerciseIds: currentDay.exercises.map(\.exerciseId),
            setLogs: setLogs
        )
    }

    /// Pure derivation of the per-exercise last-time result from a flat list of prior set
    /// logs. For each requested exercise: group its logs by session, order sessions by the
    /// latest log timestamp, take the most-recent session's heaviest working set as the
    /// headline, and set the trend up only when that session's top-set e1RM strictly beat
    /// the session before it (flat otherwise — never an invented "up"). Static + pure so
    /// the selection rule is unit-testable.
    static func lastTimeMap(forExerciseIds exerciseIds: [String], setLogs: [SetLog]) -> [String: LastTimeInfo] {
        let wanted = Set(exerciseIds)
        let byExercise = Dictionary(grouping: setLogs.filter { wanted.contains($0.exerciseId) }, by: \.exerciseId)

        var result: [String: LastTimeInfo] = [:]
        for (exerciseId, logs) in byExercise {
            // Group this exercise's logs into sessions, newest session first.
            let sessions = Dictionary(grouping: logs, by: \.sessionId)
                .map { (id: $0.key, logs: $0.value, latest: $0.value.map(\.loggedAt).max() ?? .distantPast) }
                .sorted { $0.latest > $1.latest }
            guard let mostRecent = sessions.first else { continue }

            // Headline = heaviest working set (drop warmups when intent is known).
            let working = mostRecent.logs.filter { $0.intent != .warmup }
            let pool = working.isEmpty ? mostRecent.logs : working
            guard let headline = pool.max(by: { $0.weightKg < $1.weightKg }) else { continue }

            // Trend: top-set e1RM of most-recent session vs. the one before it.
            let e1rm: ([SetLog]) -> Double = { setList in
                setList.map { $0.weightKg * (1.0 + Double($0.repsCompleted) / 30.0) }.max() ?? 0
            }
            let trendUp: Bool
            if sessions.count >= 2 {
                trendUp = e1rm(mostRecent.logs) > e1rm(sessions[1].logs)
            } else {
                trendUp = false
            }

            result[exerciseId] = LastTimeInfo(
                weightKg: headline.weightKg,
                reps: headline.repsCompleted,
                trendUp: trendUp
            )
        }
        return result
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
        // #409 PR-B: best-effort RAG embed; skip under an unresolved/placeholder owner
        // so a pre-auth placeholder uid never stamps correction embeddings.
        guard let owner = await deps.resolvedOwnerUserId() else { return }
        let userId = owner.uuidString
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
    /// Slice 6 / #60 fix: intent is required by the schema; passed explicitly
    /// by the caller (no silent defaults at the encoder layer per ADR-0005).
    @MainActor
    private func addNewSetLog(_ newLog: SetLog, intent: SetIntent) async {
        guard let sessionId = completedSessionId else { return }
        let supabase = deps.supabaseClient

        // Determine set number = existing count + 1
        let existing = historicalSetLogs[newLog.exerciseId] ?? []
        let setNumber = existing.count + 1

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone.current

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
            primaryMuscle: ExerciseLibrary.primaryMuscle(for: newLog.exerciseId)?.rawValue ?? exerciseForLog?.primaryMuscle,
            localDate: SetLog.formatLocalDate(newLog.loggedAt),
            intent: intent.rawValue
        )

        do {
            try await supabase.insert(payload, table: "set_logs")
        } catch {
            print("[ProgramDayDetailView] addNewSetLog insert failed: \(error.localizedDescription)")
            return
        }

        // Update local state immediately. intent mirrors the value just persisted
        // to set_logs so the in-memory model is consistent with the row on the server.
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
            primaryMuscle: ExerciseLibrary.primaryMuscle(for: newLog.exerciseId)?.rawValue ?? exerciseForLog?.primaryMuscle,
            intent: intent
        )
        var newGroups = historicalSetLogs
        newGroups[newLog.exerciseId, default: []].append(inserted)
        historicalSetLogs = newGroups
        historicalVolume = newGroups.values.flatMap { $0 }
            .reduce(0.0) { $0 + $1.weightKg * Double($1.repsCompleted) }

        // Embed into RAG memory
        let memoryService = deps.memoryService
        // #409 PR-B: best-effort RAG embed; skip under an unresolved/placeholder owner
        // so a pre-auth placeholder uid never stamps the manual-log embedding.
        guard let owner = await deps.resolvedOwnerUserId() else { return }
        let userId = owner.uuidString
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
        // #440: live/paused day identity comes from the single coordinator value, so
        // this view cannot disagree with the badge/banner from poll lag. The completed
        // set logs are genuinely not in the coordinator, so we still read them from the
        // actor when this day is the live one.
        isSessionActiveForThisDay = deps.activeSessionCoordinator.isLive(forDay: currentDay.id)

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

        // #438: generateDaySession writes the generated day back into currentMesocycle
        // (same id), so the live currentDay read reflects it — no local snapshot assignment.
        if await vm.generateDaySession(
            day: currentDay,
            week: week,
            gymProfile: profile
        ) == nil {
            sessionGenerationError = "Couldn't generate the session. Check your connection and try again."
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
    /// #507: most-recent prior result for this exercise (nil = no history → omit row).
    var lastTime: LastTimeInfo? = nil
    /// #507: coach floor/stretch targets for this exercise's pattern (nil = none → omit).
    var projection: PatternProjection? = nil

    @State private var cuesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .top, spacing: 12) {
                // Exercise number — condensed tabular numeral.
                ApexNumeral(text: String(format: "%02d", index), size: 15, color: Apex.textFaint)
                    .frame(width: 28, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(exercise.name)
                        .font(.system(size: 17, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)

                    // Muscle chip — monochrome Brutalist tag.
                    ApexTagChip(text: exercise.primaryMuscle.formattedMuscleName)
                }

                Spacer()

                // Equipment label
                Text(exercise.equipmentRequired.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            cardDivider

            // Prescription grid
            prescriptionGrid
                .padding(.horizontal, 14)
                .padding(.vertical, 16)

            // #507: Last-time result + coach floor/stretch — only when real data exists.
            if lastTime != nil || projection != nil {
                cardDivider
                lastTimeAndTargetsRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
            }

            // Live set logs — shown when a session is in progress for this day
            if !liveSetLogs.isEmpty {
                cardDivider
                liveSetLogsSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            // Coaching cues — expandable
            if !exercise.coachingCues.isEmpty {
                cardDivider
                coachingCueSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
            }
        }
        .apexCard()
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: cuesExpanded)
    }

    private var cardDivider: some View {
        Rectangle().fill(Apex.hairline).frame(height: 1)
    }

    // MARK: Last-Time + Targets (#507 — not-yet-started days)

    /// "LAST TIME 92.5kg × 8 ↗" on the left; "FLOOR / STRETCH" coach targets on the
    /// right. Each half renders only when its real data exists.
    @ViewBuilder
    private var lastTimeAndTargetsRow: some View {
        HStack(spacing: 0) {
            if let last = lastTime {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LAST TIME")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                    HStack(spacing: 6) {
                        ApexNumeral(text: last.label, size: 14, color: Apex.text)
                        Image(systemName: last.trendUp ? "arrow.up.right" : "arrow.right")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(last.trendUp ? Apex.accent : Apex.textFaint)
                    }
                }
            }

            Spacer(minLength: 12)

            if let proj = projection {
                HStack(spacing: 14) {
                    targetCol(label: "FLOOR", value: formatTarget(proj.floor), color: Apex.text)
                    targetCol(label: "STRETCH", value: formatTarget(proj.stretch), color: Apex.accent)
                }
            }
        }
    }

    private func targetCol(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textFaint)
            ApexNumeral(text: value, size: 15, color: color)
        }
    }

    /// Whole-number kg for clean target tiles (floor/stretch are kg projections).
    private func formatTarget(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
    }

    // MARK: Live Set Logs (active session)

    private var liveSetLogsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ApexSectionLabel(text: "Logged", color: Apex.textFaint)

            ForEach(liveSetLogs, id: \.id) { log in
                HStack(spacing: 8) {
                    Text("SET \(log.setNumber)")
                        .font(.system(size: 11, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                        .frame(width: 44, alignment: .leading)

                    ApexNumeral(text: formatWeight(log.weightKg), size: 15, color: Apex.text)

                    Text("×")
                        .font(.system(size: 12))
                        .foregroundStyle(Apex.textFaint)

                    ApexNumeral(text: "\(log.repsCompleted)", size: 15, color: Apex.text)
                    Text("REPS")
                        .font(.system(size: 10, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)

                    if let rpe = log.rpeFelt {
                        Spacer()
                        Text("RPE \(rpe)")
                            .font(.system(size: 12, weight: .bold))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.textDim)
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
        VStack(spacing: 5) {
            ApexNumeral(text: value, size: 17, color: Apex.text)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private var prescriptionDivider: some View {
        Rectangle()
            .fill(Apex.hairline)
            .frame(width: 1, height: 34)
    }

    // MARK: Coaching Cues (Expandable)

    private var coachingCueSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Expand/collapse toggle
            Button(action: { cuesExpanded.toggle() }) {
                HStack {
                    ApexSectionLabel(text: "Coaching cues", color: Apex.textDim)
                    Spacer()
                    Image(systemName: cuesExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Apex.textFaint)
                }
            }
            .buttonStyle(.plain)

            if cuesExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(exercise.coachingCues, id: \.self) { cue in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle()
                                .fill(Apex.accent)
                                .frame(width: 3, height: 3)
                                .padding(.top, 7)
                            Text(cue)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Apex.textDim)
                        }
                    }
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Helpers

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

    /// Short, display-friendly muscle name from snake_case (e.g. "pectoralis_major"
    /// → "Chest"). Mirrors the calendar's shortening so the day-header focus line
    /// reads "CHEST" rather than "PECTORALIS MAJOR".
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
        // Fallback: Title Case the raw string.
        return formattedMuscleName
    }
}

// MARK: - WorkoutSessionRow (lightweight Decodable for session query)

/// Lightweight read-only row decoded from `workout_sessions` for historical set log lookup.
/// Hotfix: `session_date` (Postgres `date` type, format "yyyy-MM-dd") is intentionally NOT
/// decoded — the row was breaking the entire fetch when the field was typed `Date?` because
/// the default decoder couldn't parse the bare-date format. Ordering / limit happens
/// server-side via the `order: "session_date.desc"` query parameter, so the column never
/// has to round-trip through Swift's decoder for this read path.
private struct WorkoutSessionRow: Decodable, Identifiable {
    let id: UUID
    let dayType: String
    let weekNumber: Int
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case dayType     = "day_type"
        case weekNumber  = "week_number"
        case completed
    }
}

// MARK: - LastTimeSessionRow (#507 — session id only)

/// Lightweight `workout_sessions` row for the last-time lookup. Only `id` is decoded —
/// ordering / limit happen server-side via the query parameters, so `session_date`
/// (a bare-date Postgres `date`) never has to round-trip through the decoder. Same
/// rationale as `WorkoutSessionRow`.
private struct LastTimeSessionRow: Decodable, Identifiable {
    let id: UUID
}

// MARK: - LastTimeInfo (#507 — most-recent prior result for an exercise)

/// One exercise's most-recent prior result, rendered on a not-yet-started card.
/// Derived only from real set logs — there is no "empty/placeholder" value: an
/// exercise with no prior history is simply absent from the map.
struct LastTimeInfo: Equatable {
    let weightKg: Double
    let reps: Int
    /// True only when the most-recent session's top-set e1RM beat the session before it.
    let trendUp: Bool

    /// "92.5kg × 8" — drops the trailing ".0" for whole numbers.
    var label: String {
        let w = weightKg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", weightKg)
            : String(format: "%.1f", weightKg)
        return "\(w)kg × \(reps)"
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

/// set_logs row for a set added to an already-completed session (no ai_prescribed column).
// internal (not private) and hoisted to file scope (was nested in `addNewSetLog`):
// exposed for encoder regression tests (#66).
struct NewSetLogPayload: Encodable {
    let id, sessionId, exerciseId, loggedAt: String
    let setNumber, repsCompleted: Int
    let weightKg: Double
    let rpeFelt, rirEstimated: Int?
    let primaryMuscle: String?
    let localDate: String
    let intent: String
    enum CodingKeys: String, CodingKey {
        case id; case sessionId = "session_id"; case exerciseId = "exercise_id"
        case setNumber = "set_number"; case weightKg = "weight_kg"
        case repsCompleted = "reps_completed"; case rpeFelt = "rpe_felt"
        case rirEstimated = "rir_estimated"; case loggedAt = "logged_at"
        case primaryMuscle = "primary_muscle"
        case localDate = "local_date"; case intent
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
    let onAddSet: (SetLog, SetIntent) -> Void

    @State private var cuesExpanded = false
    @State private var showAddSetSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .top, spacing: 12) {
                ApexNumeral(text: String(format: "%02d", index), size: 15, color: Apex.textFaint)
                    .frame(width: 28, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(exercise.name)
                        .font(.system(size: 17, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)

                    ApexTagChip(text: exercise.primaryMuscle.formattedMuscleName)
                }

                Spacer()

                Text(exercise.equipmentRequired.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            cardDivider

            // Set log rows
            if setLogs.isEmpty {
                Text("No sets logged")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textFaint)
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
                            Rectangle()
                                .fill(Apex.hairline.opacity(0.6))
                                .frame(height: 1)
                                .padding(.leading, 16)
                        }
                    }
                }
            }

            // #507: coach reasoning — re-surface the AI's "why this weight/reps" the app
            // already wrote + already fetched into `SetLog.aiPrescribed.reasoning`. One
            // block per exercise, sourced from the most relevant logged set's reasoning
            // (see `coachReasoning`). Omitted entirely when no logged set carries a
            // non-empty reasoning (graceful omission — never fabricated). The "COACH"
            // label + sparkles use the lime accent to mark the coach's voice (an allowed
            // accent use, consistent with the prototype); the body stays monochrome.
            if let reasoning = coachReasoning {
                cardDivider
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Apex.accent)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("COACH")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.accent)
                        Text(reasoning)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Apex.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            // Add Set button — monochrome (secondary editing action, not the live action).
            cardDivider
            Button(action: { showAddSetSheet = true }) {
                Label("Add Set", systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .bold))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Apex.textDim)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .sheet(isPresented: $showAddSetSheet) {
                SetLogAddSheet(exerciseId: exercise.exerciseId, setNumber: setLogs.count + 1) { newLog, intent in
                    onAddSet(newLog, intent)
                }
                .presentationDetents([.medium, .large])
            }

            // Coaching cues — expandable
            if !exercise.coachingCues.isEmpty {
                cardDivider
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: { cuesExpanded.toggle() }) {
                        HStack {
                            ApexSectionLabel(text: "Coaching cues", color: Apex.textDim)
                            Spacer()
                            Image(systemName: cuesExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Apex.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 13)

                    if cuesExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(exercise.coachingCues, id: \.self) { cue in
                                HStack(alignment: .top, spacing: 8) {
                                    Rectangle()
                                        .fill(Apex.accent)
                                        .frame(width: 3, height: 3)
                                        .padding(.top, 7)
                                    Text(cue)
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundStyle(Apex.textDim)
                                }
                            }
                        }
                        .padding(.bottom, 13)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: cuesExpanded)
            }
        }
        .apexCard()
    }

    private var cardDivider: some View {
        Rectangle().fill(Apex.hairline).frame(height: 1)
    }

    /// #507: the single coach-reasoning string shown for this exercise's completed card.
    /// Sourced from the heaviest working set's `aiPrescribed.reasoning` — the working set
    /// is the one the prescription most centres on (warmups carry boilerplate), and this
    /// mirrors the heaviest-working-set rule already used for the "last time" headline.
    /// Falls back to the first logged set that carries any non-empty reasoning. Returns
    /// nil — so the block is omitted — when no logged set has reasoning. Real text only.
    private var coachReasoning: String? {
        let working = setLogs.filter { $0.intent != .warmup }
        let pool = working.isEmpty ? setLogs : working
        let heaviestReasoning = pool
            .max(by: { $0.weightKg < $1.weightKg })?
            .aiPrescribed?.reasoning
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = heaviestReasoning, !r.isEmpty { return r }
        // Fall back to the first logged set carrying any non-empty reasoning.
        return setLogs.lazy
            .compactMap { $0.aiPrescribed?.reasoning.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
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
                // Set number
                Text("SET \(log.setNumber)")
                    .font(.system(size: 11, weight: .bold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
                    .frame(width: 44, alignment: .leading)

                // Weight
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    ApexNumeral(text: weightString(log.weightKg), size: 16, color: Apex.text)
                    Text("kg")
                        .font(.system(size: 10, weight: .semibold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                }

                Text("×")
                    .font(.system(size: 12))
                    .foregroundStyle(Apex.textFaint)

                // Reps
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    ApexNumeral(text: "\(log.repsCompleted)", size: 16, color: Apex.text)
                    Text("reps")
                        .font(.system(size: 10, weight: .semibold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                }

                // RPE
                if let rpe = log.rpeFelt {
                    Text("RPE \(rpe)")
                        .font(.system(size: 11, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textDim)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().stroke(Apex.hairline, lineWidth: 1))
                }

                Spacer()

                // Edited badge
                if isEdited {
                    Text("Edited")
                        .font(.system(size: 10, weight: .bold))
                        .fontWidth(.condensed)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(Apex.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Apex.amber.opacity(0.15), in: Capsule())
                }

                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Apex.textFaint.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SetLogAddSheet

private struct SetLogAddSheet: View {

    let exerciseId: String
    let setNumber: Int
    let onConfirm: (SetLog, SetIntent) -> Void

    @State private var weightText: String = ""
    @State private var repsText: String = ""
    @State private var rpeValue: Int? = nil
    // #65: intent is now user-selectable. Pre-selects .backoff — the prior
    // hardcoded default, and the typical set added after the fact — but the
    // user can change it before logging.
    @State private var intent: SetIntent = .backoff

    @Environment(\.dismiss) private var dismiss

    private var confirmedWeight: Double? { Double(weightText.replacingOccurrences(of: ",", with: ".")) }
    private var confirmedReps: Int? { Int(repsText) }
    private var canConfirm: Bool { confirmedWeight != nil && confirmedReps != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Apex.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("Add Set \(setNumber)")
                            .font(.system(size: 24, weight: .black))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.text)

                        // Weight field
                        VStack(alignment: .leading, spacing: 10) {
                            ApexSectionLabel(text: "Weight", color: Apex.textDim)
                            HStack(spacing: 8) {
                                setLogTextField("e.g. 80", text: $weightText, keyboard: .decimalPad)
                                Text("kg")
                                    .font(.system(size: 18, weight: .semibold))
                                    .fontWidth(.condensed)
                                    .foregroundStyle(Apex.textDim)
                            }
                        }

                        // Reps field
                        VStack(alignment: .leading, spacing: 10) {
                            ApexSectionLabel(text: "Reps", color: Apex.textDim)
                            setLogTextField("e.g. 8", text: $repsText, keyboard: .numberPad)
                        }

                        // Intent picker (#65) — mirrors the live-workout chip affordance.
                        VStack(alignment: .leading, spacing: 10) {
                            ApexSectionLabel(text: "Intent", color: Apex.textDim)
                            intentChipRow
                        }

                        // RPE stepper
                        VStack(alignment: .leading, spacing: 10) {
                            ApexSectionLabel(text: "RPE (optional)", color: Apex.textDim)
                            SetLogRPEPicker(rpeValue: $rpeValue)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom) {
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
                        onConfirm(newLog, intent)
                        dismiss()
                    } label: {
                        ApexButton(title: "Add Set")
                            .opacity(canConfirm ? 1.0 : 0.35)
                    }
                    .disabled(!canConfirm)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .background(Apex.bg)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Apex.textDim)
                }
            }
        }
    }

    /// Intent chips — mirror the live-workout `intentChipRow`: ordering
    /// (warmup → top → backoff, then technique → amrap) and selected/unselected
    /// styling, for cross-screen consistency. Pre-selected to `.backoff`.
    @ViewBuilder
    private var intentChipRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach([SetIntent.warmup, .top, .backoff], id: \.self) { intentChip($0) }
            }
            HStack(spacing: 8) {
                ForEach([SetIntent.technique, .amrap], id: \.self) { intentChip($0) }
            }
        }
    }

    @ViewBuilder
    private func intentChip(_ value: SetIntent) -> some View {
        let isSelected = intent == value
        Button {
            intent = value
        } label: {
            Text(Self.intentLabel(value))
                .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(isSelected ? Apex.onAccent : Apex.text.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                            .fill(isSelected ? Apex.accent : Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                            .stroke(isSelected ? Color.clear : Apex.hairline, lineWidth: 1)
                    }
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.intentLabel(value))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: 0.18), value: intent)
    }

    private static func intentLabel(_ intent: SetIntent) -> String {
        switch intent {
        case .warmup:    return "Warmup"
        case .top:       return "Top"
        case .backoff:   return "Backoff"
        case .technique: return "Technique"
        case .amrap:     return "AMRAP"
        }
    }
}

// MARK: - Set-log sheet shared atoms

/// Brutalist numeric input field for the add/edit set sheets.
private func setLogTextField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
    TextField(placeholder, text: text)
        .keyboardType(keyboard)
        .font(.system(size: 28, weight: .black).monospacedDigit())
        .fontWidth(.condensed)
        .foregroundStyle(Apex.text)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Apex.surface, in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(Apex.hairline, lineWidth: 1)
        )
}

/// Brutalist RPE picker (6–10) shared by the add/edit set sheets. The selected
/// value fills volt-lime — this is the primary in-sheet choice.
private struct SetLogRPEPicker: View {
    @Binding var rpeValue: Int?

    var body: some View {
        HStack(spacing: 12) {
            ForEach([6, 7, 8, 9, 10], id: \.self) { value in
                Button {
                    rpeValue = rpeValue == value ? nil : value
                } label: {
                    Text("\(value)")
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .fontWidth(.condensed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            rpeValue == value ? Apex.accent : Apex.surface,
                            in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                                .stroke(rpeValue == value ? Color.clear : Apex.hairline, lineWidth: 1)
                        )
                        .foregroundStyle(rpeValue == value ? Apex.onAccent : Apex.textDim)
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
                Apex.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 28) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Edit Set \(log.setNumber)")
                            .font(.system(size: 24, weight: .black))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.text)
                        if isEdited {
                            Label("Previously edited", systemImage: "pencil.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .fontWidth(.condensed)
                                .foregroundStyle(Apex.amber)
                        }
                    }

                    // Weight field
                    VStack(alignment: .leading, spacing: 10) {
                        ApexSectionLabel(text: "Weight", color: Apex.textDim)
                        HStack(spacing: 8) {
                            setLogTextField("e.g. 80", text: $weightText, keyboard: .decimalPad)
                            Text("kg")
                                .font(.system(size: 18, weight: .semibold))
                                .fontWidth(.condensed)
                                .foregroundStyle(Apex.textDim)
                        }
                    }

                    // Reps field
                    VStack(alignment: .leading, spacing: 10) {
                        ApexSectionLabel(text: "Reps", color: Apex.textDim)
                        setLogTextField("e.g. 8", text: $repsText, keyboard: .numberPad)
                    }

                    // RPE stepper
                    VStack(alignment: .leading, spacing: 10) {
                        ApexSectionLabel(text: "RPE (optional)", color: Apex.textDim)
                        SetLogRPEPicker(rpeValue: $rpeValue)
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
                        ApexButton(title: "Confirm Edit")
                            .opacity(canConfirm ? 1.0 : 0.35)
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
                        .foregroundStyle(Apex.textDim)
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
