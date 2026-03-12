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

    /// All sets logged so far in this session.
    var completedSets: [SetLog] = []

    // MARK: - UI state (view-local, not from actor)

    /// True while `completeSet()` is in progress — disables the Set Complete button.
    var isCompletingSet: Bool = false

    /// True while `startSession()` preflight is running (HealthKit + RAG fetch).
    var isStartingSession: Bool = false

    /// Controls the end-session-early confirmation dialog.
    var showEndSessionEarlyConfirmation: Bool = false

    // MARK: - Dependencies

    private let manager: WorkoutSessionManager

    // MARK: - Init

    init(manager: WorkoutSessionManager) {
        self.manager = manager
    }

    // MARK: - Public Actions

    /// Starts a new session for the given day. Manages isStartingSession flag.
    func startSession(trainingDay: TrainingDay, programId: UUID) {
        isStartingSession = true
        Task {
            await manager.startSession(trainingDay: trainingDay, programId: programId)
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

    /// Called when the user confirms a weight correction from WeightCorrectionView.
    /// Updates the current prescription weight and records the correction in GymFactStore.
    func onWeightCorrection(confirmedWeight: Double, equipmentType: EquipmentType) {
        Task {
            await manager.applyWeightCorrection(
                confirmedWeight: confirmedWeight,
                equipmentType: equipmentType
            )
            await pullState()
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
        let sets = await manager.completedSets

        sessionState = state
        currentPrescription = prescription
        restSecondsRemaining = restRemaining
        completedSets = sets
        isAIOffline = fallbackReason != nil
        fallbackDescription = fallbackReason.map { Self.fallbackDescription(for: $0) }
        developerFallbackDescription = fallbackReason.map { Self.developerFallbackDescription(for: $0) }
    }

    /// Starts a Task that polls actor state on every rest-timer tick and on
    /// state transitions. Stops automatically when the session completes or errors.
    private func beginStatePolling() {
        Task { [weak self] in
            while let self, await self.sessionIsLive() {
                await self.pullState()
                try? await Task.sleep(nanoseconds: 500_000_000) // poll every 0.5 s
            }
            // Pull one final time to capture .sessionComplete
            await self?.pullState()
        }
    }

    private func sessionIsLive() async -> Bool {
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
            confidence: 0.87
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
            "safety_flags": []
          }
        }
        """
    }
}
