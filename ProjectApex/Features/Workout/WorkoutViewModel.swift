// Features/Workout/WorkoutViewModel.swift
// ProjectApex — P3-T02
//
// @Observable ViewModel that bridges WorkoutSessionManager actor state
// to the SwiftUI layer. All actor reads hop to @MainActor before updating
// published properties so views can bind without managing actor concurrency.
//
// Pattern used throughout:
//   Task { @MainActor in
//       self.someProp = await manager.someProp
//   }
//
// No direct Supabase or HealthKit calls live here — all go through the manager.

import SwiftUI

// MARK: - WorkoutViewModel

@Observable
@MainActor
final class WorkoutViewModel {

    // MARK: - Observed state (all updated via pullState())

    /// Current FSM state from WorkoutSessionManager.
    var sessionState: SessionState = .idle

    /// The AI-generated prescription for the upcoming set (nil during preflight).
    var currentPrescription: SetPrescription?

    /// Derived: true when AI inference failed and a fallback is in use.
    var isAIOffline: Bool = false

    /// Short human-readable description of why the AI is offline, if applicable.
    var fallbackDescription: String?

    /// Developer-facing fallback reason string (shown in Settings > Developer).
    var developerFallbackDescription: String?

    /// Remaining seconds in the current rest period (0 when not resting).
    var restSecondsRemaining: Int = 0

    /// Absolute expiry time of the current rest period.
    /// Used by RestTimerView to snap to correct remaining time after foregrounding.
    var restExpiresAt: Date? = nil

    /// All sets logged so far in this session.
    var completedSets: [SetLog] = []

    /// Last-session set logs for the live exercise (#318 U7 / G-F6). Pulled
    /// from the manager's cachedLastPerformance; nil when no history exists.
    var lastPerformanceSets: [SetLog]? = nil

    /// The exercise awaiting a prescription retry (#318 U7 / 7.6). Non-nil
    /// while the retry sheet is up; used to gate and target the manual
    /// fallback during .preflight, where currentExercise is nil.
    var retryExercise: PlannedExercise? = nil

    /// True when inference failed and the user must choose Retry or Pause.
    var showInferenceRetrySheet: Bool = false

    /// Non-nil when a resume detected a missing session row in Supabase and re-created
    /// it. Auto-dismisses after 5 seconds. Shown as a non-blocking banner in WorkoutView.
    var resumeRepairNotice: String? = nil

    /// Human-readable reason why the retry sheet is showing.
    var retryFailureDescription: String?

    /// True while a retry attempt is in progress (shows loading state in retry sheet).
    var isRetrying: Bool = false

    // MARK: - UI state (view-local, not from actor)

    /// True while `completeSet()` is in progress — disables the Set Complete button.
    var isCompletingSet: Bool = false

    /// True while `startSession()` preflight is running (HealthKit + RAG fetch).
    var isStartingSession: Bool = false

    /// Controls the end-session-early confirmation dialog.
    var showEndSessionEarlyConfirmation: Bool = false

    /// Controls the exercise swap chat sheet (P3-T10).
    var showExerciseSwapSheet: Bool = false

    /// Controls the session-plan sheet — shown when the user wants planned reps
    /// alongside what they've logged so far. Toggled from ActiveSetView and
    /// RestTimerView via the clipboard icon next to the ellipsis menu.
    var showSessionPlanSheet: Bool = false

    /// Available weight hint for the current exercise's equipment type.
    /// Non-nil only when GymFactStore has at least one confirmed correction for that equipment type.
    /// Format: "Available: 40kg · 42.5kg · 45kg · 47.5kg · 50kg"
    var gymWeightHintText: String? = nil

    // MARK: - Dependencies

    private let manager: WorkoutSessionManager

    // MARK: - Init

    init(manager: WorkoutSessionManager) {
        self.manager = manager
    }

    // MARK: - Public Actions

    /// Starts a new session for the given day. Awaits auth resolution so the
    /// session is stamped with the real `auth.uid()`; aborts silently (resetting
    /// `isStartingSession`) when auth has not resolved, so no placeholder-keyed
    /// row is ever written (the RLS-403 owner-mismatch root cause). The
    /// `isStartingSession` flag keeps the Start button disabled / spinner visible
    /// during the brief await.
    func startSession(trainingDay: TrainingDay, programId: UUID, deps: AppDependencies, weekNumber: Int = 1, startingExerciseIndex: Int = 0) {
        // Re-entrancy guard (mirrors onSetComplete/onSkipSet): the auth await below
        // widens the window between tap and session creation, so a second invocation
        // before SwiftUI re-renders the disabled state could start two sessions.
        guard !isStartingSession else { return }
        isStartingSession = true
        Task {
            guard let userId = await deps.resolvedOwnerUserId() else {
                // Auth did not resolve — do NOT stamp a placeholder-keyed row.
                isStartingSession = false
                return
            }
            await manager.startSession(trainingDay: trainingDay, programId: programId, userId: userId, weekNumber: weekNumber, startingExerciseIndex: startingExerciseIndex)
            await pullState()
            isStartingSession = false
            // Begin continuous state polling while session is live
            beginStatePolling()
        }
    }

    /// Called when the user taps "Log Set" on the rep/RPE confirmation
    /// sheet. Disables the button during the async call to prevent
    /// double-taps. Slice 6 / #10:
    ///   - `intent` is the resolved intent (deviated value if the user
    ///     used the deviation picker; prescribed value otherwise).
    ///   - `completionFlags` is the user-reported flag set raised on
    ///     this specific set (pain / form_breakdown). Empty by default.
    func onSetComplete(
        actualReps: Int,
        rpeFelt: Int?,
        intent: SetIntent,
        completionFlags: [SetCompletionFlag] = []
    ) {
        guard !isCompletingSet else { return }
        isCompletingSet = true
        Task {
            await manager.completeSet(
                actualReps: actualReps,
                rpeFelt: rpeFelt,
                intent: intent,
                completionFlags: completionFlags
            )
            await pullState()
            isCompletingSet = false
        }
    }

    /// Called when the user taps "Skip Set" in the overflow menu (#318 / U5,
    /// G-F7). Mirrors onSetComplete's task shape — reuses the isCompletingSet
    /// flag so a skip and a complete can't race each other.
    func onSkipSet() {
        guard !isCompletingSet else { return }
        isCompletingSet = true
        Task {
            await manager.skipCurrentSet()
            await pullState()
            isCompletingSet = false
        }
    }

    /// Submits a voice note transcript to the session.
    func onAddVoiceNote(transcript: String, exerciseId: String) {
        Task {
            await manager.addVoiceNote(transcript: transcript, exerciseId: exerciseId)
        }
    }

    /// Session-only weight override — updates the current prescription weight in-memory
    /// but does NOT write to GymFactStore. Use this when the user wants a different weight
    /// for this set/session without permanently flagging it as absent from the gym.
    func onWeightOverrideSessionOnly(confirmedWeight: Double, equipmentType: EquipmentType) {
        Task {
            await manager.applySessionOnlyWeightOverride(confirmedWeight: confirmedWeight)
            await pullState()
            let hint = await manager.availableWeightHint(for: equipmentType, near: confirmedWeight)
            gymWeightHintText = hint
        }
    }

    /// Called when the user confirms a PERMANENT weight correction from WeightCorrectionView.
    /// Updates the current prescription weight AND records the correction in GymFactStore so
    /// the AI never prescribes the unavailable weight again on this equipment type.
    ///
    /// - Parameters:
    ///   - unavailableWeight: The weight that was prescribed but isn't available.
    ///                        Must be passed by the caller — cannot be read from the actor
    ///                        reliably because currentPrescription may be nil by callback time.
    ///   - confirmedWeight: The weight the user selected as available.
    ///   - equipmentType: The equipment type for this exercise.
    func onWeightCorrection(unavailableWeight: Double, confirmedWeight: Double, equipmentType: EquipmentType) {
        Task {
            await manager.applyWeightCorrection(
                unavailableWeight: unavailableWeight,
                confirmedWeight: confirmedWeight,
                equipmentType: equipmentType
            )
            await pullState()
            // Refresh hint immediately after a new correction is saved
            let hint = await manager.availableWeightHint(for: equipmentType, near: confirmedWeight)
            gymWeightHintText = hint
        }
    }

    /// Refreshes the available-weight hint for the current exercise's equipment type.
    /// Called from ActiveSetView whenever the prescription or exercise changes.
    func refreshGymWeightHint(equipmentType: EquipmentType, near weight: Double) {
        Task {
            let hint = await manager.availableWeightHint(for: equipmentType, near: weight)
            gymWeightHintText = hint
        }
    }

    /// Triggers the end-session-early confirmation dialog.
    func requestEndSessionEarly() {
        showEndSessionEarlyConfirmation = true
    }

    /// Called when user confirms the end-early dialog.
    func onEndSessionEarly() {
        showEndSessionEarlyConfirmation = false
        Task {
            await manager.endSessionEarly()
            await pullState()
        }
    }

    /// Resets the session to idle state. Called from the Done button on PostWorkoutSummaryView.
    func resetSession() {
        Task {
            await manager.resetToIdle()
            await pullState()
        }
    }

    // MARK: - State Synchronisation

    /// Pulls the latest actor state onto @MainActor properties.
    /// Safe to call from any context — awaits on the actor then updates self.
    func pullState() async {
        // #369 [20] — single atomic actor hop. Previously this awaited ~9 separate
        // isolated properties, so the actor could advance between hops and publish a
        // torn snapshot (e.g. sessionState from one instant, currentPrescription from
        // another). uiSnapshot() returns all of them — including the live exercise's
        // last-session history — captured at one consistent instant. Behaviour is
        // identical; only the read is now atomic.
        let snapshot = await manager.uiSnapshot()

        let fallbackReason = snapshot.currentFallbackReason
        sessionState = snapshot.sessionState
        currentPrescription = snapshot.currentPrescription
        restSecondsRemaining = snapshot.restSecondsRemaining
        restExpiresAt = snapshot.restExpiresAt
        completedSets = snapshot.completedSets
        isAIOffline = fallbackReason != nil
        fallbackDescription = fallbackReason.map { Self.fallbackDescription(for: $0) }
        developerFallbackDescription = fallbackReason.map { Self.developerFallbackDescription(for: $0) }
        showInferenceRetrySheet = snapshot.inferenceRetryNeeded
        retryFailureDescription = snapshot.inferenceRetryReason.map { Self.retryDescription(for: $0) }
        retryExercise = snapshot.pendingRetryExercise
        lastPerformanceSets = snapshot.lastPerformanceSets
    }

    /// Token for the currently-running polling task, so a second caller (e.g.
    /// resumeSession firing while WorkoutView.task has already begun polling)
    /// cancels the previous loop instead of stacking a parallel one.
    private var pollingTask: Task<Void, Never>? = nil

    /// Starts a Task that polls actor state on every rest-timer tick and on
    /// state transitions. Stops automatically when the session completes or
    /// errors. Cancels any existing polling task first so callers never spawn
    /// two parallel loops against the same actor.
    func beginStatePolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while let self, !Task.isCancelled, await self.sessionIsLive() {
                await self.pullState()
                try? await Task.sleep(nanoseconds: 500_000_000) // poll every 0.5 s
            }
            // Pull one final time to capture .sessionComplete
            await self?.pullState()
        }
    }

    /// Syncs state from the actor and restarts polling if a session is live.
    /// Call this on WorkoutView appear to recover from navigation-away events
    /// where the viewModel was kept alive but polling had stopped.
    func syncFromLiveSession() {
        Task { [weak self] in
            guard let self else { return }
            await pullState()
            if await sessionIsLive() {
                beginStatePolling()
            }
        }
    }

    // MARK: - Retry actions

    /// Called when the user taps "Retry" on InferenceRetrySheet.
    func onRetryInference() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            let success = await manager.retryInference()
            await pullState()
            isRetrying = false
            if success { showInferenceRetrySheet = false }
        }
    }

    /// Called when the user taps "Continue with last weights" on InferenceRetrySheet.
    /// Valid during .resting (currentExercise is the pending next set's exercise)
    /// and during .preflight (#318 U7 / 7.6 — retryExercise carries the target,
    /// since currentExercise is nil before the first prescription lands).
    func onUseLastWeights() {
        guard let exercise = currentExercise ?? retryExercise else { return }
        Task {
            await manager.applyManualFallbackPrescription(for: exercise)
            await pullState()
            showInferenceRetrySheet = false
        }
    }

    /// Called when the user taps "Pause Session" on InferenceRetrySheet.
    func onPauseFromRetrySheet() {
        showInferenceRetrySheet = false
        Task { await manager.pauseSession(); await pullState() }
    }

    // MARK: - Pause action

    /// Called when user taps "Pause Session" from the ellipsis menu during active/resting state.
    func onPauseSession() {
        Task { await manager.pauseSession(); await pullState() }
    }

    // MARK: - Exercise swap (P3-T10)

    /// Opens the exercise swap chat sheet.
    func requestExerciseSwap() {
        showExerciseSwapSheet = true
    }

    /// Builds a SwapContext snapshot from the current session for ExerciseSwapService.
    func buildSwapContext() async -> ExerciseSwapService.SwapContext? {
        await manager.buildSwapContext()
    }

    /// Called when the user confirms a swap suggestion in ExerciseSwapView.
    func onExerciseSwapConfirmed(suggestion: ExerciseSwapService.ExerciseSuggestion, reason: String) {
        showExerciseSwapSheet = false
        Task {
            await manager.swapExercise(suggestion: suggestion, reason: reason)
            await pullState()
        }
    }

    // MARK: - Resume action

    /// Resumes a paused session. Flushes the write-ahead queue first so all
    /// set_log writes from the prior session are in Supabase before fetching.
    func resumeSession(pausedState: PausedSessionState, trainingDay: TrainingDay, supabase: SupabaseClient, supabaseAuth: SupabaseAuth) {
        isStartingSession = true
        Task {
            // 0. Ownership gate (#369 slice 4): the paused session carries the owner
            //    frozen at start time. If it doesn't match the current real auth uid
            //    (identity changed across launches, or it was the placeholder),
            //    replaying it — and re-inserting the workout_sessions row under the old
            //    owner at step 2 — is rejected by RLS (42501). Discard instead of
            //    replaying. awaitFirstResolution() is bounded; nil (sign-in unresolved)
            //    is treated as a mismatch — an unverifiable session can't be resumed safely.
            let resolvedUid = await supabaseAuth.awaitFirstResolution()?.userId
            if resolvedUid != pausedState.userId {
                await manager.discardStalePausedSession()
                resumeRepairNotice = "Couldn't confirm your previous workout for this account — it was cleared. Start a new one when you're ready."
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.resumeRepairNotice = nil
                }
                isStartingSession = false
                return
            }

            // 1. Attempt to flush WAQ so pending set_logs land in Supabase before the fetch.
            //    If offline, flush is best-effort — unflushed items stay in the WAQ.
            await manager.flushWriteAheadQueue()

            // 2. Verify the session row exists in Supabase. If it's missing (e.g. after an
            //    uninstall/reinstall or cross-device session start), re-create it so the
            //    set_logs fetch in step 3 has a valid foreign key parent row.
            struct SessionIdRow: Decodable { let id: UUID }
            let sessionExists = (try? await supabase.fetch(
                SessionIdRow.self,
                table: "workout_sessions",
                filters: [Filter(column: "id", op: .eq, value: pausedState.sessionId.uuidString)],
                limit: 1
            ).first) != nil

            if !sessionExists {
                struct SessionInsertRow: Encodable {
                    let id: UUID
                    let userId: UUID
                    let programId: UUID
                    let sessionDate: Date
                    let weekNumber: Int
                    let dayType: String
                    let completed: Bool
                    let status: String
                    enum CodingKeys: String, CodingKey {
                        case id
                        case userId      = "user_id"
                        case programId   = "program_id"
                        case sessionDate = "session_date"
                        case weekNumber  = "week_number"
                        case dayType     = "day_type"
                        case completed, status
                    }
                }
                let row = SessionInsertRow(
                    id: pausedState.sessionId,
                    userId: pausedState.userId,
                    programId: pausedState.programId,
                    sessionDate: pausedState.pausedAt,
                    weekNumber: pausedState.weekNumber,
                    dayType: pausedState.dayType,
                    completed: false,
                    status: "paused"
                )
                try? await supabase.insert(row, table: "workout_sessions")
                resumeRepairNotice = "Session data was restored from your device."
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.resumeRepairNotice = nil
                }
            }

            // 3. Fetch whatever Supabase has (successful flushes + previously persisted rows).
            let remoteLogs: [SetLog] = (try? await supabase.fetch(
                SetLog.self,
                table: "set_logs",
                filters: [Filter(column: "session_id", op: .eq, value: pausedState.sessionId.uuidString)],
                order: "set_number.asc"
            )) ?? []

            // 4. Read any set_logs still queued locally (flush may have failed for these).
            let waqLogs = await manager.pendingSetLogs(forSession: pausedState.sessionId)

            // 5. Merge: WAQ wins on conflict (same SetLog.id → WAQ version is authoritative
            //    because it is the most recently written copy and may not yet be in Supabase).
            var mergedById: [UUID: SetLog] = Dictionary(
                uniqueKeysWithValues: remoteLogs.map { ($0.id, $0) }
            )
            for waqLog in waqLogs {
                mergedById[waqLog.id] = waqLog  // WAQ overwrites remote on same id
            }
            let setLogs = mergedById.values.sorted {
                $0.setNumber < $1.setNumber
            }

            print("[WorkoutViewModel] resumeSession — remote:\(remoteLogs.count) waq:\(waqLogs.count) merged:\(setLogs.count) for session \(pausedState.sessionId)")

            await manager.resumeSession(
                pausedState: pausedState,
                trainingDay: trainingDay,
                completedSetLogs: setLogs
            )
            await pullState()
            isStartingSession = false
            beginStatePolling()
        }
    }

    func sessionIsLive() async -> Bool {
        let state = await manager.sessionState
        switch state {
        case .idle, .sessionComplete, .error: return false
        default: return true
        }
    }

    // MARK: - Derived Helpers

    /// Human-readable description of the fallback reason for the "Coach offline" banner.
    /// Per P3-T07 AC: "Coach offline — using program defaults"
    static func fallbackDescription(for reason: FallbackReason) -> String {
        switch reason {
        case .timeout:
            return "Coach offline — using program defaults"
        case .maxRetriesExceeded:
            return "Coach offline — using program defaults"
        case .llmProviderError:
            return "Coach offline — using program defaults"
        case .encodingFailed:
            return "Coach offline — using program defaults"
        case .malformedResponse:
            return "Coach offline — using program defaults"
        case .systemPromptUnavailable:
            return "Coach offline — using program defaults"
        }
    }

    /// Developer-facing description showing the specific FallbackReason variant.
    /// Displayed in Settings > Developer when in developer mode (P3-T07 AC).
    static func developerFallbackDescription(for reason: FallbackReason) -> String {
        switch reason {
        case .timeout:
            return ".apiTimeout"
        case .maxRetriesExceeded(let lastError):
            return ".maxRetriesExceeded(\(lastError.prefix(80)))"
        case .llmProviderError(let msg):
            return ".networkUnavailable(\(msg.prefix(80)))"
        case .encodingFailed(let detail):
            return ".encodingFailed(\(detail.prefix(80)))"
        case .malformedResponse(let detail):
            return ".malformedResponse(\(detail.prefix(80)))"
        case .systemPromptUnavailable(let detail):
            return ".systemPromptUnavailable(\(detail.prefix(80)))"
        }
    }

    /// Short subtitle shown on the InferenceRetrySheet explaining what went wrong.
    static func retryDescription(for reason: FallbackReason) -> String {
        switch reason {
        case .timeout:
            return "The AI coach took too long to respond."
        case .maxRetriesExceeded(let e):
            return "Invalid response: \(String(e.prefix(80)))"
        case .llmProviderError(let m):
            return "Network error: \(String(m.prefix(80)))"
        case .encodingFailed(let d):
            return "Internal error: \(String(d.prefix(80)))"
        case .malformedResponse(let d):
            return "Invalid response: \(String(d.prefix(80)))"
        case .systemPromptUnavailable:
            return "App misconfigured — contact support."
        }
    }

    // MARK: - Convenience Computed Properties

    /// The exercise currently being performed, if in .active state.
    var currentExercise: PlannedExercise? {
        if case .active(let exercise, _) = sessionState { return exercise }
        if case .resting(let exercise, _) = sessionState { return exercise }
        return nil
    }

    /// The current set number, if in .active or .resting state.
    var currentSetNumber: Int? {
        if case .active(_, let n) = sessionState { return n }
        if case .resting(_, let n) = sessionState { return n }
        return nil
    }

    /// The session summary, if the session has completed.
    var sessionSummary: SessionSummary? {
        if case .sessionComplete(let summary) = sessionState { return summary }
        return nil
    }

    /// True when at least one set has been logged in the current session.
    /// Used to gate session completion and show the correct end-early dialog.
    var hasLoggedAnySets: Bool { !completedSets.isEmpty }

    /// True while the preflight async fetch is in progress.
    var isPreflight: Bool {
        if case .preflight = sessionState { return true }
        return isStartingSession
    }

    /// True while in the rest period between sets.
    var isResting: Bool {
        if case .resting = sessionState { return true }
        return false
    }

    /// Formatted rest time string, e.g. "1:30".
    var formattedRestTime: String {
        let mins = restSecondsRemaining / 60
        let secs = restSecondsRemaining % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Annotation shown on the prescription card when weight was rounded to the
    /// nearest available increment. Derived from the prescription's reasoning field
    /// by looking for the canonical "(adjusted to nearest available:" prefix.
    var weightAdjustmentNote: String? {
        guard let reasoning = currentPrescription?.reasoning else { return nil }
        // WorkoutSessionManager's prescription post-processor appends a note in
        // this exact format when it snaps/clamps weight (#318 U7) — see
        // WorkoutSessionManager.weightAdjustmentMarker(for:).
        let marker = "(adjusted to nearest available:"
        guard let range = reasoning.range(of: marker, options: .caseInsensitive) else { return nil }
        // Extract the parenthetical note to its closing ")"
        let suffix = String(reasoning[range.lowerBound...])
        if let endRange = suffix.firstIndex(of: ")") {
            return String(suffix[suffix.startIndex...endRange])
        }
        return nil
    }

    /// Muted "Last time" one-liner under the hero numbers (#318 U7 / G-F6),
    /// e.g. "Last time: 80kg × 8/8/7". Weight shown is the heaviest set of the
    /// last session; reps are listed per set in set order. Nil when no
    /// last-session history is cached for this exercise.
    var lastPerformanceSummary: String? {
        guard let sets = lastPerformanceSets, !sets.isEmpty else { return nil }
        let topWeight = sets.map(\.weightKg).max() ?? 0
        let weightString: String
        if topWeight <= 0 {
            weightString = "BW"
        } else if topWeight.truncatingRemainder(dividingBy: 1) == 0 {
            weightString = String(format: "%.0fkg", topWeight)
        } else {
            weightString = String(format: "%.1fkg", topWeight)
        }
        let reps = sets.map { "\($0.repsCompleted)" }.joined(separator: "/")
        return "Last time: \(weightString) × \(reps)"
    }

    /// True when "Continue with last weights" can produce an honest
    /// prescription (#318 U7 / G-F1): an in-session set for the exercise, a
    /// last-session history seed, or a genuinely bodyweight movement. Gates
    /// the manual-fallback affordance so a 0 kg "BW" card can never appear
    /// for a loaded movement.
    var canUseLastWeights: Bool {
        guard let exercise = currentExercise ?? retryExercise else { return false }
        let hasInSessionSet = completedSets.contains { $0.exerciseId == exercise.exerciseId }
        let hasHistorySeed = !(lastPerformanceSets ?? []).isEmpty
        let isBodyweight = exercise.equipmentRequired.isNaturallyBodyweightOnly
        return hasInSessionSet || hasHistorySeed || isBodyweight
    }

    /// Skips the current rest period and advances immediately to the next active set.
    func skipRest() {
        Task {
            await manager.skipRest()
            await pullState()
        }
    }
}

// MARK: - Mock for Previews

extension WorkoutViewModel {

    /// Returns a WorkoutViewModel pre-loaded with mock active-set state.
    /// Uses a non-functional mock manager — safe for SwiftUI previews.
    @MainActor
    static func mockActive() -> WorkoutViewModel {
        let mock = WorkoutViewModel(manager: WorkoutSessionManager.mock())
        mock.sessionState = .active(
            exercise: PlannedExercise(
                id: UUID(),
                exerciseId: "barbell_bench_press",
                name: "Barbell Bench Press",
                primaryMuscle: "pectoralis_major",
                synergists: ["anterior_deltoid", "triceps_brachii"],
                equipmentRequired: .barbell,
                sets: 4,
                repRange: RepRange(min: 6, max: 10),
                tempo: "3-1-1-0",
                restSeconds: 150,
                rirTarget: 2,
                coachingCues: ["Retract scapula", "Drive through the bar"]
            ),
            setNumber: 2
        )
        mock.currentPrescription = SetPrescription(
            weightKg: 82.5,
            reps: 8,
            tempo: "3-1-1-0",
            rirTarget: 2,
            restSeconds: 150,
            coachingCue: "Control descent, pause at chest",
            reasoning: "Up 2.5 kg from last session — HRV trending positive.",
            safetyFlags: [],
            confidence: 0.87,
            intent: .top,
        setFraming: "Heaviest work of the day. Brace and grind."
        )
        mock.isAIOffline = false
        return mock
    }

    @MainActor
    static func mockResting() -> WorkoutViewModel {
        let mock = WorkoutViewModel(manager: WorkoutSessionManager.mock())
        let exercise = PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: ["anterior_deltoid"],
            equipmentRequired: .barbell,
            sets: 4,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 150,
            rirTarget: 2,
            coachingCues: []
        )
        mock.sessionState = .resting(nextExercise: exercise, setNumber: 3)
        mock.restSecondsRemaining = 87
        return mock
    }

    @MainActor
    static func mockPreflight() -> WorkoutViewModel {
        let mock = WorkoutViewModel(manager: WorkoutSessionManager.mock())
        mock.sessionState = .preflight
        mock.isStartingSession = true
        return mock
    }
}

// MARK: - WorkoutSessionManager mock factory

private extension WorkoutSessionManager {
    /// Returns a WorkoutSessionManager wired to no-op stubs.
    /// For use in SwiftUI previews only.
    @MainActor
    static func mock() -> WorkoutSessionManager {
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://preview.supabase.co")!,
            anonKey: "preview"
        )
        let memory = MemoryService(supabase: supabase, embeddingAPIKey: "")
        return WorkoutSessionManager(
            aiInference: AIInferenceService(
                provider: PreviewLLMProvider(),
                gymProfile: nil,
                maxRetries: 0
            ),
            healthKit: HealthKitService(),
            memoryService: memory,
            supabase: supabase,
            gymFactStore: GymFactStore()
        )
    }
}

/// No-op LLM provider for previews — never makes network calls.
private struct PreviewLLMProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        // Return a valid prescription so previews don't show fallback state
        return """
        {
          "set_prescription": {
            "weight_kg": 80.0,
            "reps": 8,
            "tempo": "3-1-1-0",
            "rir_target": 2,
            "rest_seconds": 120,
            "coaching_cue": "Preview prescription",
            "reasoning": "Preview mode — no real AI.",
            "safety_flags": [],
            "intent": "top",
            "set_framing": "Heaviest work of the day. Brace and grind."
          }
        }
        """
    }

}
