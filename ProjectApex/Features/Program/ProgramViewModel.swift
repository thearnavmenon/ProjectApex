// ProgramViewModel.swift
// ProjectApex — Features/Program
//
// Observable view model bridging programme services to ProgramOverviewView.
// Manages loading, empty, generating, and loaded states.
//
// FB-008: Extended to support the two-service architecture:
//   • MacroPlanService — one-shot skeleton generation (phase structure, week intent)
//   • SessionPlanService — on-demand session generation before each workout
//
// The view model exposes:
//   • `viewState` for top-level program loading/generation state
//   • `generateDaySession(day:week:)` for on-demand session generation
//   • `currentMesocycle` so views can observe in-place day mutations

import SwiftUI

// MARK: - SessionMetaRow

/// Lightweight Decodable used to fetch workout_sessions metadata without the
/// broken nested set_logs join that the full WorkoutSession model requires.
private struct SessionMetaRow: Decodable {
    let id: UUID
    let dayType: String
    let sessionDate: String

    enum CodingKeys: String, CodingKey {
        case id
        case dayType     = "day_type"
        case sessionDate = "session_date"
    }
}

// MARK: - ProgramViewState

enum ProgramViewState: Equatable {
    case loading
    case empty
    case loaded(Mesocycle)
    case generating
    case generatingSession(dayId: UUID)   // FB-008: generating a single day's session
    case error(String)

    static func == (lhs: ProgramViewState, rhs: ProgramViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.empty, .empty), (.generating, .generating): return true
        case (.loaded(let a), .loaded(let b)):       return a.id == b.id
        case (.error(let a), .error(let b)):         return a == b
        case (.generatingSession(let a), .generatingSession(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - ProgramViewModel

@Observable
@MainActor
final class ProgramViewModel {

    // MARK: Published State

    var viewState: ProgramViewState = .loading
    var selectedDay: TrainingDay?
    var selectedWeek: TrainingWeek?
    /// Exposed so views can observe in-place mutations (e.g. day status changes).
    /// Internal (not private) so test targets can inject a mesocycle directly
    /// without going through the UserDefaults fast-path in loadProgram().
    var currentMesocycle: Mesocycle?
    /// Incremented by ContentView to tell ProgramOverviewView to scroll to the current week.
    var scrollToCurrentWeekTrigger: Int = 0

    // MARK: Private

    private let supabaseClient: SupabaseClient
    private let programGenerationService: ProgramGenerationService
    private let macroPlanService: MacroPlanService
    private let sessionPlanService: SessionPlanService

    /// User ID sourced from AppDependencies.resolvedUserId at construction time.
    private let userId: UUID

    // MARK: Init

    init(
        supabaseClient: SupabaseClient,
        programGenerationService: ProgramGenerationService,
        macroPlanService: MacroPlanService,
        sessionPlanService: SessionPlanService,
        userId: UUID
    ) {
        self.supabaseClient = supabaseClient
        self.programGenerationService = programGenerationService
        self.macroPlanService = macroPlanService
        self.sessionPlanService = sessionPlanService
        self.userId = userId
    }

    // MARK: - Load

    /// Loads the active program: tries UserDefaults cache first, then Supabase.
    func loadProgram() async {
        viewState = .loading

        // 1. Fast path: UserDefaults cache
        if let cached = Mesocycle.loadFromUserDefaults() {
            currentMesocycle = cached
            viewState = .loaded(cached)
            return
        }

        // 2. Network fetch
        do {
            if let row = try await supabaseClient.fetchActiveProgram(userId: userId) {
                let mesocycle = row.toMesocycle()
                mesocycle.saveToUserDefaults()
                currentMesocycle = mesocycle
                viewState = .loaded(mesocycle)
            } else {
                viewState = .empty
            }
        } catch {
            // If fetch fails but no cache → show empty so user can generate
            viewState = .empty
        }
    }

    // MARK: - Regenerate

    /// Replaces the existing program with a freshly generated one, preserving all
    /// completed days exactly as they are. The new skeleton takes over from the
    /// first incomplete day forward — nothing already done is touched.
    ///
    /// Algorithm:
    ///   1. Snapshot all completed days from the old mesocycle (ordered by week/day index).
    ///   2. Clear the local cache so the new program is not shadowed by the old one.
    ///   3. Generate a new program via the shared path.
    ///   4. Graft the completed days back into the new mesocycle at the same flat index
    ///      positions, overwriting whatever the new generation put there.
    ///   5. Mark grafted days as `.completed` so they are read-only in the new program.
    ///   6. Persist the merged mesocycle.
    ///
    /// Called from Settings → "Regenerate Program".
    func regenerateProgram(gymProfile: GymProfile) async {
        // 1. Snapshot completed days (flat ordered list) before clearing cache.
        let completedDaySnapshots = snapshotCompletedDays()

        // 2. Clear the local cache so generation is not shadowed by old data.
        Mesocycle.clearUserDefaults()

        // 3. Generate new program via the shared path (skip Supabase — we persist after grafting).
        await generateProgram(gymProfile: gymProfile, persistToSupabase: false)

        // 4. Graft completed days back if we have any and generation succeeded.
        guard !completedDaySnapshots.isEmpty,
              var mesocycle = currentMesocycle else { return }

        let graftCount = completedDaySnapshots.count
        var flatIndex = 0
        outer: for wIdx in mesocycle.weeks.indices {
            for dIdx in mesocycle.weeks[wIdx].trainingDays.indices {
                if flatIndex < graftCount {
                    // Overwrite with the completed snapshot; keep its .completed status.
                    mesocycle.weeks[wIdx].trainingDays[dIdx] = completedDaySnapshots[flatIndex]
                    flatIndex += 1
                } else {
                    break outer
                }
            }
        }

        // 5. Persist the merged result.
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)

        // Also update the Supabase row in the background.
        let capturedUserId = userId
        let capturedClient = supabaseClient
        let capturedMesocycle = mesocycle
        Task.detached {
            do {
                try await capturedClient.deactivatePrograms(userId: capturedUserId)
                let row = ProgramRow.forInsert(from: capturedMesocycle, userId: capturedUserId)
                try await capturedClient.insert(row, table: "programs")
            } catch {
                // Non-fatal
            }
        }
    }

    /// Returns a flat list of all terminal TrainingDays (`.completed` or `.skipped`) in the
    /// current mesocycle, ordered by week then day index.
    /// Used by `regenerateProgram` to graft resolved days into the new programme so training
    /// history is not lost across regenerations.
    private func snapshotCompletedDays() -> [TrainingDay] {
        guard let mesocycle = currentMesocycle else { return [] }
        return mesocycle.weeks.flatMap { week in
            week.trainingDays.filter { $0.status == .completed || $0.status == .skipped }
        }
    }

    // MARK: - Generate (legacy static path — ProgramGenerationService)

    /// Triggers full static program generation from a GymProfile and UserProfile.
    /// Called from the empty state CTA and from regenerateProgram().
    ///
    /// - Parameter persistToSupabase: When false, skips the Supabase write so the
    ///   caller (e.g. regenerateProgram) can write after applying its own post-processing.
    func generateProgram(gymProfile: GymProfile, persistToSupabase: Bool = true) async {
        guard await !programGenerationService.isGenerating else { return }
        viewState = .generating

        // Clear per-pattern phase state: this is a brand-new programme, not a regeneration.
        PatternPhaseService.clear()

        // Read user profile from UserDefaults for consistent generation across paths.
        let bwKg: Double? = UserDefaults.standard.double(forKey: UserProfileConstants.bodyweightKgKey) > 0
            ? UserDefaults.standard.double(forKey: UserProfileConstants.bodyweightKgKey) : nil
        let ageYears: Int? = UserDefaults.standard.integer(forKey: UserProfileConstants.ageKey) > 0
            ? UserDefaults.standard.integer(forKey: UserProfileConstants.ageKey) : nil
        let trainingAge: String? = UserDefaults.standard.string(forKey: UserProfileConstants.trainingAgeKey)
        let daysPerWeek: Int = {
            let v = UserDefaults.standard.integer(forKey: UserProfileConstants.daysPerWeekKey)
            return v > 0 ? v : 4
        }()

        print("[ProgramViewModel] generateProgram — training_days_per_week: \(daysPerWeek)")

        let userProfile = UserProfile(
            userId: userId.uuidString,
            experienceLevel: trainingAge ?? "intermediate",
            goals: ["hypertrophy"],
            bodyweightKg: bwKg,
            ageYears: ageYears
        )

        do {
            let mesocycle = try await programGenerationService.generate(
                userProfile: userProfile,
                gymProfile: gymProfile,
                trainingDaysPerWeek: daysPerWeek
            )
            if persistToSupabase {
                // Persist to Supabase (fire-and-forget for UX speed)
                let capturedUserId = userId
                let capturedClient = supabaseClient
                Task.detached {
                    do {
                        try await capturedClient.deactivatePrograms(userId: capturedUserId)
                        let row = ProgramRow.forInsert(from: mesocycle, userId: capturedUserId)
                        try await capturedClient.insert(row, table: "programs")
                    } catch {
                        // Non-fatal: program already in local cache
                    }
                }
            }
            mesocycle.saveToUserDefaults()
            currentMesocycle = mesocycle
            viewState = .loaded(mesocycle)
        } catch ProgramGenerationError.equipmentConstraintViolation(let violations) {
            viewState = .error("Could not satisfy equipment constraints for \(violations.count) exercise(s). Please re-scan your gym.")
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    // MARK: - FB-008: Generate Macro Skeleton

    /// Generates a 12-week skeleton (phase structure + week intents, no exercises).
    /// The resulting Mesocycle has all TrainingDays as `.pending` stubs.
    func generateMacroSkeleton(gymProfile: GymProfile) async {
        guard await !macroPlanService.isGenerating else { return }
        viewState = .generating

        // Clear per-pattern phase state: this is a brand-new programme, not a regeneration.
        PatternPhaseService.clear()

        // Read onboarding profile from UserDefaults if available.
        let bwKg: Double? = UserDefaults.standard.double(forKey: UserProfileConstants.bodyweightKgKey) > 0
            ? UserDefaults.standard.double(forKey: UserProfileConstants.bodyweightKgKey) : nil
        let ageYears: Int? = UserDefaults.standard.integer(forKey: UserProfileConstants.ageKey) > 0
            ? UserDefaults.standard.integer(forKey: UserProfileConstants.ageKey) : nil
        let trainingAge: String? = UserDefaults.standard.string(forKey: UserProfileConstants.trainingAgeKey)
        let daysPerWeek: Int = {
            let v = UserDefaults.standard.integer(forKey: UserProfileConstants.daysPerWeekKey)
            return v > 0 ? v : 4
        }()

        print("[ProgramViewModel] generateMacroSkeleton — training_days_per_week: \(daysPerWeek)")

        do {
            let skeleton = try await macroPlanService.generateSkeleton(
                userId: userId,
                gymProfile: gymProfile,
                experienceLevel: trainingAge ?? "intermediate",
                goals: ["hypertrophy"],
                bodyweightKg: bwKg,
                ageYears: ageYears,
                trainingAge: trainingAge,
                trainingDaysPerWeek: daysPerWeek
            )

            // Build pending mesocycle from skeleton
            let mesocycle = MacroPlanService.buildPendingMesocycle(from: skeleton, userId: userId)

            // Persist to Supabase (fire-and-forget)
            let capturedUserId = userId
            let capturedClient = supabaseClient
            Task.detached {
                do {
                    try await capturedClient.deactivatePrograms(userId: capturedUserId)
                    let row = ProgramRow.forInsert(from: mesocycle, userId: capturedUserId)
                    try await capturedClient.insert(row, table: "programs")
                } catch {
                    // Non-fatal
                }
            }
            mesocycle.saveToUserDefaults()
            currentMesocycle = mesocycle
            viewState = .loaded(mesocycle)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    // MARK: - FB-008: Generate Day Session

    /// Called when the user taps "Start Workout" on a `.pending` day.
    /// Shows a loading state, calls SessionPlanService, and mutates the day in-place.
    ///
    /// - Parameters:
    ///   - day: The pending TrainingDay stub.
    ///   - week: The containing TrainingWeek.
    ///   - gymProfile: User's gym equipment profile.
    /// - Returns: The generated (populated) TrainingDay, or nil on failure.
    @discardableResult
    func generateDaySession(
        day: TrainingDay,
        week: TrainingWeek,
        gymProfile: GymProfile
    ) async -> TrainingDay? {
        guard day.status == .pending else { return day }

        viewState = .generatingSession(dayId: day.id)

        // Read user profile
        let bwKg: Double? = UserDefaults.standard.double(forKey: "bodyweight_kg") > 0
            ? UserDefaults.standard.double(forKey: "bodyweight_kg") : nil
        let ageYears: Int? = UserDefaults.standard.integer(forKey: "user_age") > 0
            ? UserDefaults.standard.integer(forKey: "user_age") : nil
        let trainingAge: String? = UserDefaults.standard.string(forKey: "training_age")

        let userProfile = MacroPlanUserProfile(
            userId: userId.uuidString,
            experienceLevel: "intermediate",
            goals: ["hypertrophy"],
            bodyweightKg: bwKg,
            ageYears: ageYears,
            trainingAge: trainingAge
        )

        // ── Step 1: Fetch recent session metadata (last 7 days) for fatigue signals ──
        // Uses a lightweight SessionMetaRow instead of the full WorkoutSession, avoiding
        // the broken nested set_logs join that was causing recentSetLogs to always be [].
        var recentSetLogs: [SetLog] = []
        var weekSessionCount: Int = 0
        // recentSessions hoisted to outer scope so TemporalContext assembly can read it.
        var recentSessions: [SessionMetaRow] = []
        do {
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            recentSessions = try await supabaseClient.fetch(
                SessionMetaRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",      op: .eq,  value: userId.uuidString),
                    Filter(column: "session_date", op: .gte, value: ISO8601DateFormatter().string(from: sevenDaysAgo)),
                    Filter(column: "completed",    op: .is,  value: "true")
                ],
                order: "session_date.desc"
            )
            weekSessionCount = recentSessions.count
            if recentSessions.isEmpty {
                recentSetLogs = []
            } else {
                let ids = recentSessions.map(\.id.uuidString)
                let inValue = "(\(ids.joined(separator: ",")))"
                recentSetLogs = try await supabaseClient.fetch(
                    SetLog.self,
                    table: "set_logs",
                    filters: [Filter(column: "session_id", op: .in, value: inValue)]
                )
            }
        } catch {
            recentSetLogs = []
            weekSessionCount = 0
        }

        // ── Step 2: Per-exercise deep history (no date cap) ──
        // Fetch the last 10 sessions of this day type across all time and pull their set_logs.
        // No completed/status filter — sessions where the WAQ completion PATCH didn't arrive
        // (app killed post-last-set, network failure) are stored with completed=false but still
        // contain valid training data. Excluding them caused older sessions to be invisible,
        // making the AI treat exercises with weeks of history as first-time lifts.
        //
        // The previousExerciseIds block is used only to decide whether Supabase has any data
        // at all for this day type. We check EITHER the in-memory mesocycle (has completed days
        // with exercises) OR fall through to Supabase regardless when in doubt.
        var deepLiftHistory: [SetLog] = []
        do {
            // Consider a previous instance to exist if the mesocycle has ANY generated/completed
            // day with this label, even if exercises weren't persisted locally — Supabase is the
            // source of truth for lift history.
            let hasLocalHistory: Bool = {
                guard let mesocycle = currentMesocycle else { return false }
                return mesocycle.weeks
                    .flatMap(\.trainingDays)
                    .contains { $0.dayLabel == day.dayLabel && ($0.status == .completed || $0.status == .generated) }
            }()

            if !hasLocalHistory {
                // Genuinely first time this day label has been seen — use 7-day window
                deepLiftHistory = recentSetLogs
            } else {
                // Fetch the last 10 sessions of this day type (no date constraint, no status filter)
                let deepSessions = try await supabaseClient.fetch(
                    SessionMetaRow.self,
                    table: "workout_sessions",
                    filters: [
                        Filter(column: "user_id",  op: .eq,  value: userId.uuidString),
                        Filter(column: "day_type", op: .eq,  value: day.dayLabel),
                        Filter(column: "status",   op: .neq, value: "abandoned")
                    ],
                    order: "session_date.desc",
                    limit: 10
                )
                if deepSessions.isEmpty {
                    deepLiftHistory = recentSetLogs
                } else {
                    let deepIds = deepSessions.map(\.id.uuidString)
                    let deepInValue = "(\(deepIds.joined(separator: ",")))"
                    deepLiftHistory = try await supabaseClient.fetch(
                        SetLog.self,
                        table: "set_logs",
                        filters: [Filter(column: "session_id", op: .in, value: deepInValue)]
                    )
                }
            }
        } catch {
            deepLiftHistory = recentSetLogs
        }

        // Per-exercise session count — visible in console to verify lookback depth
        let exerciseSessionCounts = Dictionary(grouping: deepLiftHistory) { $0.exerciseId }
            .mapValues { logs in Set(logs.map { $0.sessionId }).count }
        print("[ProgramViewModel] deepLiftHistory: \(deepLiftHistory.count) set_log(s) across \(exerciseSessionCounts.count) exercise(s):")
        for (exerciseId, count) in exerciseSessionCounts.sorted(by: { $0.key < $1.key }) {
            print("[ProgramViewModel]   • \(exerciseId): \(count) session(s)")
        }

        // ── Step 3: Assemble TemporalContext — gap-awareness + per-pattern phase for the LLM ──
        // daysSinceLastSession: from the most recent session in the 7-day window (any type),
        // or fall back to the most recent date in deepLiftHistory.
        let temporalContext: TemporalContext = {
            let calendar = Calendar.current
            let now = Date()

            // daysSinceLastSession — prefer 7-day window first (ordered desc)
            var daysSinceLastSession: Int? = nil
            if let mostRecentSession = recentSessions.first {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                if let sessionDate = dateFormatter.date(from: mostRecentSession.sessionDate) {
                    daysSinceLastSession = calendar.dateComponents([.day], from: sessionDate, to: now).day
                }
            } else if let mostRecentLog = deepLiftHistory.max(by: { $0.loggedAt < $1.loggedAt }) {
                daysSinceLastSession = calendar.dateComponents([.day], from: mostRecentLog.loggedAt, to: now).day
            }

            // daysSinceLastTrainedByPattern — aggregate deepLiftHistory by movement pattern
            var patternMostRecent: [String: Date] = [:]
            for log in deepLiftHistory {
                guard let pattern = ExerciseLibrary.lookup(log.exerciseId)?.movementPattern.rawValue
                else { continue }
                if let existing = patternMostRecent[pattern] {
                    if log.loggedAt > existing { patternMostRecent[pattern] = log.loggedAt }
                } else {
                    patternMostRecent[pattern] = log.loggedAt
                }
            }
            var daysSinceByPattern: [String: Int] = [:]
            for (pattern, date) in patternMostRecent {
                if let days = calendar.dateComponents([.day], from: date, to: now).day {
                    daysSinceByPattern[pattern] = days
                }
            }

            // skippedSessionCountLast30Days — from local mesocycle cache
            let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            let skippedCount = currentMesocycle?.weeks
                .flatMap(\.trainingDays)
                .filter { $0.status == .skipped && ($0.skippedAt ?? .distantPast) >= thirtyDaysAgo }
                .count ?? 0

            // ── Phase 2: Per-pattern phase state ──
            // Load persisted states; if empty and history exists, run one-time migration.
            let daysPerWeek: Int = {
                let v = UserDefaults.standard.integer(forKey: UserProfileConstants.daysPerWeekKey)
                return v > 0 ? v : 4
            }()

            var persistedPhaseStates = PatternPhaseService.load()
            if persistedPhaseStates.isEmpty && !deepLiftHistory.isEmpty {
                persistedPhaseStates = PatternPhaseService.computeInitialPhases(
                    from: deepLiftHistory,
                    daysPerWeek: daysPerWeek
                )
                PatternPhaseService.persist(persistedPhaseStates)
                print("[ProgramViewModel] Pattern phase migration: initialised \(persistedPhaseStates.count) patterns from history.")
            }

            let patternPhases: [String: PatternPhaseInfo]? = persistedPhaseStates.isEmpty ? nil :
                Dictionary(uniqueKeysWithValues: persistedPhaseStates.map { state in
                    (state.pattern.rawValue, PatternPhaseInfo(
                        currentPhase: state.phase.rawValue,
                        sessionsCompleted: state.sessionsCompletedInPhase,
                        sessionsRequired: state.sessionsRequiredForPhase
                    ))
                })

            return TemporalContext(
                daysSinceLastSession: daysSinceLastSession,
                daysSinceLastTrainedByPattern: daysSinceByPattern,
                skippedSessionCountLast30Days: skippedCount,
                globalProgrammePhase: week.phase.rawValue,
                globalProgrammeWeek: week.weekNumber,
                patternPhases: patternPhases,
                requiresReturnPhaseOverride: (daysSinceLastSession ?? 0) >= 28
            )
        }()

        do {
            let generatedDay = try await sessionPlanService.generateSession(
                for: day,
                week: week,
                userId: userId,
                gymProfile: gymProfile,
                userProfile: userProfile,
                recentSetLogs: recentSetLogs,
                deepLiftHistory: deepLiftHistory,
                weekSessionCount: weekSessionCount,
                temporalContext: temporalContext
            )

            // Mutate mesocycle in-place
            if var mesocycle = currentMesocycle {
                if let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == week.id }),
                   let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == day.id }) {
                    mesocycle.weeks[wIdx].trainingDays[dIdx] = generatedDay
                    mesocycle.saveToUserDefaults()
                    currentMesocycle = mesocycle
                    viewState = .loaded(mesocycle)
                }
            }
            return generatedDay
        } catch {
            // Restore to loaded state; caller shows error
            if let m = currentMesocycle {
                viewState = .loaded(m)
            } else {
                viewState = .empty
            }
            return nil
        }
    }

    // MARK: - FB-010: Mark Day Completed (manual log & live session)

    /// Marks a training day as `.completed` in the local mesocycle cache.
    /// Triggers an immediate view state update so the calendar and progress bar re-render.
    func markDayCompleted(dayId: UUID, weekId: UUID) {
        guard var mesocycle = currentMesocycle else {
            print("[ProgramViewModel] markDayCompleted — no currentMesocycle, ignoring dayId: \(dayId)")
            return
        }
        guard let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == weekId }),
              let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == dayId })
        else {
            print("[ProgramViewModel] markDayCompleted — day not found: dayId=\(dayId) weekId=\(weekId)")
            return
        }
        mesocycle.weeks[wIdx].trainingDays[dIdx].status = .completed
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)
        print("[ProgramViewModel] markDayCompleted ✓ — dayId: \(dayId), week \(mesocycle.weeks[wIdx].weekNumber)")
    }

    // MARK: - Pause support

    /// Marks a training day as `.paused` in the local mesocycle cache.
    /// Called by ProgramDayDetailView when WorkoutView fires `onSessionPaused`.
    func markDayPaused(dayId: UUID, weekId: UUID) {
        guard var mesocycle = currentMesocycle else { return }
        guard let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == weekId }),
              let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == dayId })
        else { return }
        mesocycle.weeks[wIdx].trainingDays[dIdx].status = .paused
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)
        print("[ProgramViewModel] markDayPaused ✓ — dayId: \(dayId), week \(mesocycle.weeks[wIdx].weekNumber)")
    }

    // MARK: - Mark Day Skipped (Phase-1-Skip)

    /// Marks a training day as `.skipped` in the local mesocycle cache.
    ///
    /// This is the persistent skip — it advances programme position (Day X of Y) and
    /// permanently records the skip. The day's exercises are preserved so the user can
    /// view what was planned. Called from PreWorkoutView and ProgramDayDetailView.
    ///
    /// Programme progression rule: `programme_day_index` advances by +1 on every
    /// transition to `.completed` OR `.skipped`. Calendar logic never advances it.
    func markDaySkipped(dayId: UUID, weekId: UUID) {
        guard var mesocycle = currentMesocycle else {
            print("[ProgramViewModel] markDaySkipped — no currentMesocycle, ignoring dayId: \(dayId)")
            return
        }
        guard let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == weekId }),
              let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == dayId })
        else {
            print("[ProgramViewModel] markDaySkipped — day not found: dayId=\(dayId) weekId=\(weekId)")
            return
        }
        mesocycle.weeks[wIdx].trainingDays[dIdx].status = .skipped
        mesocycle.weeks[wIdx].trainingDays[dIdx].skippedAt = Date()
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)
        print("[ProgramViewModel] markDaySkipped ✓ — dayId: \(dayId), week \(mesocycle.weeks[wIdx].weekNumber)")
    }

    // MARK: - Computed helpers

    /// Current week index (0-based) based on training-time progression.
    ///
    /// Returns the index of the week that contains the next incomplete (non-completed,
    /// non-skipped) training day. This decouples programme position from calendar dates:
    /// the "current week" advances when the user completes or skips sessions, not when
    /// the calendar ticks over.
    ///
    /// If all days are done, returns the last week index.
    func currentWeekIndex(in mesocycle: Mesocycle) -> Int {
        for (wIdx, week) in mesocycle.weeks.enumerated() {
            for day in week.trainingDays {
                if day.status != .completed && day.status != .skipped {
                    return wIdx
                }
            }
        }
        // All days completed or skipped — return last week
        return max(0, mesocycle.weeks.count - 1)
    }

    /// Day IDs skipped this session (in-memory only; resets on app relaunch).
    /// When the user taps "Skip session" on the pre-workout screen, the day is added here
    /// so nextIncompleteDay() moves past it to the next pending day.
    private(set) var skippedDayIds: Set<UUID> = []

    /// Defers a training day for the current session by adding its ID to the skip set.
    /// Does not affect programme progress or session records — the day remains pending
    /// and will surface again on next launch (or after all other pending days complete).
    func skipDay(_ dayId: UUID) {
        skippedDayIds.insert(dayId)
    }

    /// Returns the first TrainingDay across all weeks where status is neither `.completed`
    /// nor `.skipped` (persistent), and the day has not been deferred this session (soft skip).
    /// Returns nil when every day is completed or skipped. Searches weeks in order, days within each week in order.
    /// If all remaining days have been soft-skipped this session, clears the defer set and starts over.
    func nextIncompleteDay(in mesocycle: Mesocycle) -> (day: TrainingDay, week: TrainingWeek)? {
        for week in mesocycle.weeks {
            for day in week.trainingDays {
                // Skip permanently-skipped and completed days; also skip soft-deferred days.
                if day.status != .completed && day.status != .skipped && !skippedDayIds.contains(day.id) {
                    return (day, week)
                }
            }
        }
        // All non-terminal days were soft-deferred — reset so the user isn't blocked indefinitely
        if !skippedDayIds.isEmpty {
            skippedDayIds = []
            return nextIncompleteDay(in: mesocycle)
        }
        return nil
    }

    /// Searches every week in `mesocycle` for a `TrainingDay` whose `id` matches `id`.
    ///
    /// Used by crash-recovery routing to locate a paused session's training day when
    /// its `trainingDayId` does not match `nextIncompleteDay` (e.g. after programme
    /// regeneration that changed day UUIDs).
    func findTrainingDay(byId id: UUID, in mesocycle: Mesocycle) -> (day: TrainingDay, week: TrainingWeek)? {
        for week in mesocycle.weeks {
            if let day = week.trainingDays.first(where: { $0.id == id }) {
                return (day: day, week: week)
            }
        }
        return nil
    }
}
