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

    /// Starts a new session for the given day. Manages isStartingSession flag.
    func startSession(trainingDay: TrainingDay, programId: UUID, userId: UUID, weekNumber: Int = 1, startingExerciseIndex: Int = 0) {
        isStartingSession = true
        Task {
            await manager.startSession(trainingDay: trainingDay, programId: programId, userId: userId, weekNumber: weekNumber, startingExerciseIndex: startingExerciseIndex)
            await pullState()
            isStartingSession = false
            // Begin continuous state polling while session is live
            beginStatePolling()
        }
    }

    /// Called when the user taps "Set Complete".
    /// Disables the button during the async call to prevent double-taps.
    func onSetComplete(actualReps: Int, rpeFelt: Int?) {
        guard !isCompletingSet else { return }
        isCompletingSet = true
        Task {
            await manager.completeSet(actualReps: actualReps, rpeFelt: rpeFelt)
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
        let state = await manager.sessionState
        let prescription = await manager.currentPrescription
        let fallbackReason = await manager.currentFallbackReason
        let restRemaining = await manager.restSecondsRemaining
        let expiresAt = await manager.restExpiresAt
        let sets = await manager.completedSets
        let retryNeeded = await manager.inferenceRetryNeeded
        let retryReason = await manager.inferenceRetryReason

        sessionState = state
        currentPrescription = prescription
        restSecondsRemaining = restRemaining
        restExpiresAt = expiresAt
        completedSets = sets
        isAIOffline = fallbackReason != nil
        fallbackDescription = fallbackReason.map { Self.fallbackDescription(for: $0) }
        developerFallbackDescription = fallbackReason.map { Self.developerFallbackDescription(for: $0) }
        showInferenceRetrySheet = retryNeeded
        retryFailureDescription = retryReason.map { Self.retryDescription(for: $0) }
    }

    /// Starts a Task that polls actor state on every rest-timer tick and on
    /// state transitions. Stops automatically when the session completes or errors.
    func beginStatePolling() {
        Task { [weak self] in
            while let self, await self.sessionIsLive() {
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
    /// Only valid during .resting state where currentExercise is the pending next set's exercise.
    func onUseLastWeights() {
        guard let exercise = currentExercise else { return }
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
    func resumeSession(pausedState: PausedSessionState, trainingDay: TrainingDay, supabase: SupabaseClient) {
        isStartingSession = true
        Task {
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
        // The AIInferenceService appends a note in this exact format when it snaps weight
        let marker = "(adjusted to nearest available:"
        guard let range = reasoning.range(of: marker, options: .caseInsensitive) else { return nil }
        // Extract the parenthetical note to its closing ")"
        let suffix = String(reasoning[range.lowerBound...])
        if let endRange = suffix.firstIndex(of: ")") {
            return String(suffix[suffix.startIndex...endRange])
        }
        return nil
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
            intent: .top
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
            "intent": "top"
          }
        }
        """
    }
}
