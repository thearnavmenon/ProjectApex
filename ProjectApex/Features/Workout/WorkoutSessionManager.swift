// Features/Workout/WorkoutSessionManager.swift
// ProjectApex
//
// Central actor that owns all active session state and orchestrates
// the full set-by-set AI loop:
//   startSession → preflight → active → completeSet → resting → active → …
//   → endSession → sessionComplete
//
// REENTRANCY GUARD:
//   inflightRequestCount tracks in-progress inference calls. If completeSet()
//   is called again before a prior inference resolves, the stale result is
//   discarded — it cannot overwrite the state for a new exercise.
//   The `inferenceGeneration` counter is incremented on each completeSet() call;
//   a returning inference result is silently discarded if its generation doesn't match.
//
// ACTOR ISOLATION:
//   All mutable state is actor-isolated. WorkoutViewModel reads state by
//   awaiting actor-isolated properties across async boundaries.
//
// DEPENDS ON:
//   AIInferenceService, HealthKitService, MemoryService, SupabaseClient, GymFactStore
//   WorkoutProgram models (TrainingDay, PlannedExercise)
//   WorkoutSession models (SetLog, SessionNote, SessionSummary)

import Foundation

// MARK: - SessionState

/// Finite state machine for the active workout session.
nonisolated enum SessionState: Sendable, Equatable {
    /// No session is running.
    case idle
    /// HealthKit + memory preflight fetch is in progress.
    case preflight
    /// User is actively performing a set.
    case active(exercise: PlannedExercise, setNumber: Int)
    /// Rest period between sets or exercises.
    case resting(nextExercise: PlannedExercise, setNumber: Int)
    /// All sets for an exercise are done; about to move to next (or finish).
    case exerciseComplete(nextExercise: PlannedExercise?)
    /// All exercises done; session summary generated.
    case sessionComplete(summary: SessionSummary)
    /// Unrecoverable error.
    case error(String)

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):                                    return true
        case (.preflight, .preflight):                          return true
        case (.active(let a, let n), .active(let b, let m)):   return a.id == b.id && n == m
        case (.resting(let a, let n), .resting(let b, let m)): return a.id == b.id && n == m
        case (.exerciseComplete(let a), .exerciseComplete(let b)):
            return a?.id == b?.id
        case (.sessionComplete, .sessionComplete):              return true
        case (.error(let a), .error(let b)):                    return a == b
        default:                                                return false
        }
    }
}

// MARK: - WorkoutSessionManager

/// Actor-isolated orchestrator for the full workout session lifecycle.
///
/// Ownership model:
///   • `WorkoutViewModel` holds a reference to this actor.
///   • UI reads state by awaiting actor-isolated properties.
///   • State mutations only happen inside this actor — no concurrent mutation is possible.
actor WorkoutSessionManager {

    // MARK: - Public state (actor-isolated)

    private(set) var sessionState: SessionState = .idle
    private(set) var currentPrescription: SetPrescription?
    private(set) var currentFallbackReason: FallbackReason?
    private(set) var restSecondsRemaining: Int = 0
    private(set) var completedSets: [SetLog] = []

    // MARK: - Private session state

    private var session: WorkoutSession?
    private var trainingDay: TrainingDay?
    /// Index into trainingDay.exercises for the current exercise.
    private var exerciseIndex: Int = 0
    /// 1-based set counter within the current exercise.
    private var currentSetNumber: Int = 1
    private var sessionNotes: [SessionNote] = []
    /// When the current rest period started, for elapsed calculation.
    private var restStartTime: Date?
    /// Planned rest duration for the current rest period.
    private var targetRestSeconds: Int = 90
    /// Counts active AIInferenceService.prescribe() calls (reentrancy guard).
    private(set) var inflightRequestCount: Int = 0
    /// Monotonically increasing generation counter. Incremented each completeSet().
    /// Inference results whose captured generation < inferenceGeneration are discarded.
    private var inferenceGeneration: Int = 0
    /// Running rest-timer Task reference so we can cancel it on early exit.
    private var restTimerTask: Task<Void, Never>?
    /// HealthKit biometrics cached at session start.
    private var cachedBiometrics: Biometrics?
    /// Streak result fetched at session start, included in every WorkoutContext.
    private var cachedStreakResult: StreakResult?
    /// RAG memory items for the current/next exercise.
    private var cachedRAGMemory: [RAGMemoryItem] = []
    /// Accumulated qualitative notes fed into every subsequent WorkoutContext.
    private var qualitativeNotesToday: [QualitativeNote] = []
    /// Exercises completed so far today, for the sessionHistoryToday field.
    private var sessionHistoryToday: [ExerciseHistoryItem] = []
    /// User biometric profile read from UserDefaults at session start (FB-003).
    private var cachedUserProfile: UserProfileContext? = nil

    // MARK: - Dependencies

    private let aiInference: AIInferenceService
    private let healthKit: HealthKitService
    private let memoryService: MemoryService
    private let supabase: SupabaseClient
    private let gymFactStore: GymFactStore
    private let writeAheadQueue: WriteAheadQueue
    private let gymStreakService: GymStreakService

    // MARK: - Init

    init(
        aiInference: AIInferenceService,
        healthKit: HealthKitService,
        memoryService: MemoryService,
        supabase: SupabaseClient,
        gymFactStore: GymFactStore,
        writeAheadQueue: WriteAheadQueue? = nil,
        gymStreakService: GymStreakService? = nil
    ) {
        self.aiInference = aiInference
        self.healthKit = healthKit
        self.memoryService = memoryService
        self.supabase = supabase
        self.gymFactStore = gymFactStore
        let waq = writeAheadQueue ?? WriteAheadQueue(supabase: supabase)
        self.writeAheadQueue = waq
        self.gymStreakService = gymStreakService ?? GymStreakService(supabase: supabase)
    }

    // MARK: - Public API

    /// Starts a new workout session for the given training day.
    ///
    /// Sequence (TDD §7.2):
    ///   1. Transitions state to `.preflight`
    ///   2. Creates WorkoutSession record in Supabase (fire-and-forget)
    ///   3. Fetches HealthKit biometrics + RAG memory for the first exercise
    ///   4. Fires AI prescription for the first set
    ///   5. Transitions to `.active(exercise:setNumber:)` when prescription arrives
    func startSession(trainingDay: TrainingDay, programId: UUID) async {
        guard case .idle = sessionState else { return }

        // Reset all session state
        self.trainingDay = trainingDay
        self.exerciseIndex = 0
        self.currentSetNumber = 1
        self.completedSets = []
        self.sessionNotes = []
        self.sessionHistoryToday = []
        self.qualitativeNotesToday = []
        self.cachedBiometrics = nil
        self.cachedStreakResult = nil
        self.cachedRAGMemory = []
        self.inflightRequestCount = 0
        self.inferenceGeneration = 0

        // FB-003: Read user biometrics from UserDefaults for WorkoutContext assembly.
        self.cachedUserProfile = Self.loadUserProfileFromDefaults()

        sessionState = .preflight

        let newSession = WorkoutSession(
            id: UUID(),
            userId: UUID(),         // Auth user ID — placeholder for MVP
            programId: programId,
            sessionDate: Date(),
            weekNumber: 1,          // Resolved by caller from mesocycle week; stub = 1
            dayType: trainingDay.dayLabel,
            completed: false,
            setLogs: [],
            sessionNotes: [],
            summary: nil
        )
        self.session = newSession

        // Fire-and-forget: create session row in Supabase
        let sessionPayload = WorkoutSessionPayload(from: newSession)
        Task.detached { [supabase, sessionPayload] in
            try? await supabase.insert(sessionPayload, table: "workout_sessions")
        }

        guard let firstExercise = trainingDay.exercises.first else {
            sessionState = .error("Training day has no exercises.")
            return
        }

        // Fetch streak and RAG memory in parallel — both are non-blocking
        async let streakFetch = gymStreakService.computeStreak(userId: newSession.userId)
        async let ragFetch = fetchRAGMemory(for: firstExercise)
        cachedStreakResult = await streakFetch
        cachedRAGMemory = await ragFetch

        // Trigger first prescription; state → .active when result arrives
        await triggerInference(for: firstExercise, setNumber: 1)
    }

    /// Called when the user marks a set as complete.
    ///
    /// Sequence (TDD §7.2):
    ///   1. Write SetLog to Supabase (fire-and-forget)
    ///   2. Transition state → .resting (rest timer starts immediately with plan default)
    ///   3. Assemble WorkoutContext
    ///   4. Await AI prescription on a child Task
    ///   5. On result: update currentPrescription; when timer expires → .active
    func completeSet(actualReps: Int, rpeFelt: Int?) async {
        guard case .active(let exercise, let setNumber) = sessionState,
              let session = session else { return }

        // Advance generation counter before spawning inference task.
        // Any task using the previous generation will discard its result.
        inferenceGeneration += 1
        inflightRequestCount += 1
        let capturedGeneration = inferenceGeneration

        // Build and store set log
        let setLog = SetLog(
            id: UUID(),
            sessionId: session.id,
            exerciseId: exercise.exerciseId,
            setNumber: setNumber,
            weightKg: currentPrescription?.weightKg ?? 0,
            repsCompleted: actualReps,
            rpeFelt: rpeFelt,
            rirEstimated: rpeFelt.map { max(0, 10 - $0) },
            aiPrescribed: currentPrescription,
            loggedAt: Date()
        )
        completedSets.append(setLog)

        // P4-T07: Auto-generate memory events (non-blocking)
        emitPRMemoryEventIfNeeded(for: setLog, exercise: exercise)
        let targetReps = currentPrescription?.reps ?? exercise.repRange.max
        emitPerformanceDropEventIfNeeded(
            actualReps: actualReps,
            targetReps: targetReps,
            exercise: exercise
        )

        // 1. Write to local queue first, then async POST to Supabase (P3-T06)
        let setPayload = SetLogPayload(from: setLog)
        try? await writeAheadQueue.enqueue(setPayload, table: "set_logs")

        // Determine whether this was the last set for this exercise
        let setsForExercise = completedSets.filter { $0.exerciseId == exercise.exerciseId }.count
        let isLastSetForExercise = setsForExercise >= exercise.sets

        if isLastSetForExercise {
            // Archive this exercise's sets into session history
            sessionHistoryToday.append(buildExerciseHistoryItem(for: exercise))
            exerciseIndex += 1
            currentSetNumber = 1
        } else {
            currentSetNumber = setNumber + 1
        }

        // Determine next exercise and set number
        let exercises = trainingDay?.exercises ?? []
        let nextExercise: PlannedExercise?
        let nextSetNumber: Int

        if isLastSetForExercise {
            nextExercise = exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
            nextSetNumber = 1
        } else {
            nextExercise = exercise
            nextSetNumber = currentSetNumber
        }

        // 2. Transition to resting immediately
        let planRestSeconds = currentPrescription?.restSeconds ?? exercise.restSeconds
        targetRestSeconds = planRestSeconds
        restStartTime = Date()
        currentPrescription = nil   // Clear stale prescription before next set

        let restTarget = nextExercise ?? exercise
        let isSessionEnd = nextExercise == nil && isLastSetForExercise
        sessionState = .resting(nextExercise: restTarget, setNumber: nextSetNumber)

        // Start countdown timer
        startRestTimer(duration: planRestSeconds, isSessionEnd: isSessionEnd)

        // 3 & 4. Fire inference for the next set concurrently
        if let next = nextExercise {
            if isLastSetForExercise {
                // Moving to a new exercise — refresh RAG memory
                cachedRAGMemory = await fetchRAGMemory(for: next)
            }

            let context = assembleWorkoutContext(exercise: next, setNumber: nextSetNumber)

            Task { [weak self] in
                guard let self else { return }
                let result = await self.aiInference.prescribe(context: context)
                await self.handleInferenceResult(
                    result,
                    generation: capturedGeneration,
                    targetExercise: next,
                    targetSetNumber: nextSetNumber
                )
                await self.decrementInflight()
            }
        } else {
            // No more exercises — no inference needed
            inflightRequestCount -= 1
        }
    }

    /// Adds a voice/text note to the session and queues background memory embedding.
    func addVoiceNote(transcript: String, exerciseId: String) async {
        guard let session = session else { return }

        let tags = detectNoteTags(in: transcript)
        let note = SessionNote(
            id: UUID(),
            sessionId: session.id,
            exerciseId: exerciseId,
            rawTranscript: transcript,
            tags: tags,
            loggedAt: Date()
        )
        sessionNotes.append(note)

        // Add to qualitative context for future AI calls
        let category = tags.contains("injury_concern") ? "pain" : "general"
        qualitativeNotesToday.append(QualitativeNote(
            category: category,
            text: transcript,
            loggedAt: Date()
        ))

        // Queue write to session_notes (P3-T06)
        let notePayload = SessionNotePayload(from: note)
        try? await writeAheadQueue.enqueue(notePayload, table: "session_notes")

        // Non-blocking: embed for RAG memory (TDD §7.3 / P4-T04)
        // Capture the exercise's muscle groups so MemoryService can store them.
        let muscleGroups: [String]
        if let currentExercise = trainingDay?.exercises.first(where: { $0.exerciseId == exerciseId }) {
            muscleGroups = [currentExercise.primaryMuscle] + currentExercise.synergists
        } else {
            muscleGroups = []
        }
        Task.detached { [memoryService, note, sessionId = session.id, userId = session.userId] in
            await memoryService.embed(
                text: note.rawTranscript,
                sessionId: sessionId.uuidString,
                exerciseId: exerciseId,
                muscleGroups: muscleGroups,
                userId: userId.uuidString
            )
        }
    }

    /// Terminates the session early. Writes a partial summary.
    func endSessionEarly() async {
        await finishSession(earlyExitReason: "User ended session early")
    }

    /// Completes the session after all exercises are done. Writes a full summary.
    func endSession() async {
        await finishSession(earlyExitReason: nil)
    }

    /// Applies a user-confirmed weight correction to the current prescription.
    /// Records the fact in GymFactStore so the AI avoids prescribing this weight again.
    func applyWeightCorrection(
        confirmedWeight: Double,
        equipmentType: EquipmentType
    ) async {
        guard var prescription = currentPrescription else { return }
        let unavailableWeight = prescription.weightKg
        prescription.weightKg = confirmedWeight
        prescription.userCorrectedWeight = true
        currentPrescription = prescription

        await gymFactStore.recordCorrection(
            equipmentType: equipmentType,
            unavailableWeight: unavailableWeight,
            availableWeight: confirmedWeight
        )
    }

    /// Resets the session state to .idle. Called after the user dismisses PostWorkoutSummaryView.
    func resetToIdle() {
        restTimerTask?.cancel()
        restTimerTask = nil
        session = nil
        trainingDay = nil
        exerciseIndex = 0
        currentSetNumber = 1
        completedSets = []
        sessionNotes = []
        sessionHistoryToday = []
        qualitativeNotesToday = []
        cachedBiometrics = nil
        cachedStreakResult = nil
        cachedRAGMemory = []
        cachedUserProfile = nil
        inflightRequestCount = 0
        inferenceGeneration = 0
        currentPrescription = nil
        currentFallbackReason = nil
        restSecondsRemaining = 0
        sessionState = .idle
    }

    /// Skips the remaining rest time and immediately transitions to the next active set,
    /// provided a prescription is ready. If inference is still in-flight, the transition
    /// will complete when the prescription arrives (same logic as timer expiry at 0).
    func skipRest() {
        guard case .resting(let nextExercise, let nextSetNumber) = sessionState else { return }
        restTimerTask?.cancel()
        restTimerTask = nil
        restSecondsRemaining = 0
        // Only advance if prescription is ready; otherwise handleInferenceResult() will
        // complete the transition once the in-flight request finishes.
        if currentPrescription != nil || currentFallbackReason != nil {
            sessionState = .active(exercise: nextExercise, setNumber: nextSetNumber)
        }
    }

    // MARK: - Context Assembly

    /// Assembles the full `WorkoutContext` from current in-memory session state.
    /// Populates all 10 fields required by the AI inference pipeline.
    func assembleWorkoutContext(
        exercise: PlannedExercise,
        setNumber: Int
    ) -> WorkoutContext {
        let sess = session ?? WorkoutSession(
            id: UUID(), userId: UUID(), programId: UUID(),
            sessionDate: Date(), weekNumber: 1, dayType: "",
            completed: false, setLogs: [], sessionNotes: [], summary: nil
        )

        // Read persisted session count from UserDefaults (FB-005).
        // Written at session completion; 0 until the first session is fully completed.
        let totalSessionCount = UserDefaults.standard.integer(forKey: UserProfileConstants.sessionCountKey)
        let metadata = SessionMetadata(
            sessionId: sess.id.uuidString,
            startedAt: sess.sessionDate,
            programName: nil,                               // Populated by WorkoutViewModel in future
            dayLabel: sess.dayType.isEmpty ? nil : sess.dayType,
            weekNumber: sess.weekNumber > 0 ? sess.weekNumber : nil,
            totalSessionCount: totalSessionCount
        )

        let currentEx = CurrentExercise(
            name: exercise.name,
            equipmentTypeKey: exercise.equipmentRequired.typeKey,
            setNumber: setNumber,
            plannedSets: exercise.sets,
            planTarget: PlanTarget(
                minReps: exercise.repRange.min,
                maxReps: exercise.repRange.max,
                rirTarget: exercise.rirTarget,
                intensityPercent: nil
            ),
            primaryMuscles: [exercise.primaryMuscle],
            secondaryMuscles: exercise.synergists
        )

        let currentExSets = completedSets
            .filter { $0.exerciseId == exercise.exerciseId }
            .map { log in
                CompletedSet(
                    setNumber: log.setNumber,
                    weightKg: log.weightKg,
                    reps: log.repsCompleted,
                    rirActual: log.rirEstimated,
                    rpe: log.rpeFelt.map(Double.init),
                    tempo: log.aiPrescribed?.tempo,
                    restTakenSeconds: nil,
                    completedAt: log.loggedAt,
                    userCorrectedWeight: log.aiPrescribed?.userCorrectedWeight
                )
            }

        // within_session_performance: all prior sets for this exercise (FB-006)
        let withinSessionSets = completedSets
            .filter { $0.exerciseId == exercise.exerciseId }
            .map { log in
                CompletedSet(
                    setNumber: log.setNumber,
                    weightKg: log.weightKg,
                    reps: log.repsCompleted,
                    rirActual: log.rirEstimated,
                    rpe: log.rpeFelt.map(Double.init),
                    tempo: log.aiPrescribed?.tempo,
                    restTakenSeconds: nil,
                    completedAt: log.loggedAt,
                    userCorrectedWeight: log.aiPrescribed?.userCorrectedWeight
                )
            }

        return WorkoutContext(
            requestType: "set_prescription",
            sessionMetadata: metadata,
            biometrics: cachedBiometrics,
            streakResult: cachedStreakResult,
            userProfile: cachedUserProfile,
            isFirstSession: totalSessionCount == 0,
            currentExercise: currentEx,
            sessionHistoryToday: sessionHistoryToday,
            currentExerciseSetsToday: currentExSets,
            withinSessionPerformance: withinSessionSets,
            historicalPerformance: nil,     // Supabase query deferred to P4
            qualitativeNotesToday: qualitativeNotesToday,
            ragRetrievedMemory: cachedRAGMemory
        )
    }

    // MARK: - Private Helpers

    /// Fires the initial AI inference for a new exercise/set and transitions
    /// state to `.active` when the result arrives.
    private func triggerInference(for exercise: PlannedExercise, setNumber: Int) async {
        inflightRequestCount += 1
        let generation = inferenceGeneration
        let context = assembleWorkoutContext(exercise: exercise, setNumber: setNumber)

        Task { [weak self] in
            guard let self else { return }
            let result = await self.aiInference.prescribe(context: context)
            await self.handleInferenceResult(
                result,
                generation: generation,
                targetExercise: exercise,
                targetSetNumber: setNumber
            )
            await self.decrementInflight()
        }
    }

    /// Handles a returned PrescriptionResult, applying the safety gate and
    /// transitioning state when appropriate.
    ///
    /// REENTRANCY GUARD: if `generation` != `inferenceGeneration`, this result
    /// is stale (another completeSet() was called first) and is discarded.
    private func handleInferenceResult(
        _ result: PrescriptionResult,
        generation: Int,
        targetExercise: PlannedExercise,
        targetSetNumber: Int
    ) {
        guard generation == inferenceGeneration else {
            // Stale result — a newer completeSet() has already advanced the generation.
            return
        }

        switch result {
        case .success(var prescription):
            // Safety gate (TDD §7.2 acceptance criteria):
            // if safetyFlags contains .painReported → rest ≥ 180 s
            if prescription.safetyFlags.contains(.painReported) {
                prescription.restSeconds = max(prescription.restSeconds, 180)
                extendRestTimer(to: prescription.restSeconds)
            }
            currentPrescription = prescription
            currentFallbackReason = nil

        case .fallback(let reason):
            currentFallbackReason = reason
            currentPrescription = makeFallbackPrescription(for: targetExercise)
        }

        // Transition .preflight → .active (first set) or
        // .resting → .active (if rest already elapsed)
        switch sessionState {
        case .preflight:
            sessionState = .active(exercise: targetExercise, setNumber: targetSetNumber)
        case .resting:
            if restSecondsRemaining <= 0 {
                sessionState = .active(exercise: targetExercise, setNumber: targetSetNumber)
            }
            // If rest is still running, onRestTimerExpired() will complete the transition.
        default:
            break
        }
    }

    private func decrementInflight() {
        inflightRequestCount = max(0, inflightRequestCount - 1)
    }

    /// Starts the rest-period countdown timer. Fires on 1-second ticks.
    /// When it reaches zero, transitions state from `.resting` to `.active`
    /// (or triggers `endSession()` if this was the final exercise).
    private func startRestTimer(duration: Int, isSessionEnd: Bool) {
        restTimerTask?.cancel()
        restSecondsRemaining = duration

        restTimerTask = Task { [weak self] in
            guard let self else { return }
            var remaining = duration
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                await self.tickRestTimer(remaining)
            }
            await self.onRestTimerExpired(isSessionEnd: isSessionEnd)
        }
    }

    private func tickRestTimer(_ remaining: Int) {
        restSecondsRemaining = remaining
    }

    private func onRestTimerExpired(isSessionEnd: Bool) {
        restSecondsRemaining = 0

        if isSessionEnd {
            Task { [weak self] in await self?.endSession() }
            return
        }

        guard case .resting(let nextExercise, let nextSetNumber) = sessionState else { return }

        // Prescription must be ready (either AI or fallback). If inference is still
        // in-flight, handleInferenceResult() will see restSecondsRemaining == 0 and
        // complete the transition itself.
        if currentPrescription != nil || currentFallbackReason != nil {
            sessionState = .active(exercise: nextExercise, setNumber: nextSetNumber)
        }
    }

    /// Extends the rest timer duration. Per TDD §7.4, rest can only be extended, never shortened.
    private func extendRestTimer(to newDuration: Int) {
        guard newDuration > targetRestSeconds else { return }
        let elapsed = targetRestSeconds - restSecondsRemaining
        let newRemaining = max(newDuration - elapsed, 0)
        targetRestSeconds = newDuration
        restSecondsRemaining = newRemaining
    }

    /// Builds a deterministic, conservative fallback prescription from the plan template.
    private func makeFallbackPrescription(for exercise: PlannedExercise) -> SetPrescription {
        SetPrescription(
            weightKg: 20.0,
            reps: exercise.repRange.max,
            tempo: exercise.tempo,
            rirTarget: exercise.rirTarget,
            restSeconds: exercise.restSeconds,
            coachingCue: "AI unavailable — use last known weight",
            reasoning: "Fallback: inference timed out or failed. Use your best judgement.",
            safetyFlags: [],
            confidence: nil
        )
    }

    private func buildExerciseHistoryItem(for exercise: PlannedExercise) -> ExerciseHistoryItem {
        let sets = completedSets
            .filter { $0.exerciseId == exercise.exerciseId }
            .map { log in
                CompletedSet(
                    setNumber: log.setNumber,
                    weightKg: log.weightKg,
                    reps: log.repsCompleted,
                    rirActual: log.rirEstimated,
                    rpe: log.rpeFelt.map(Double.init),
                    tempo: log.aiPrescribed?.tempo,
                    restTakenSeconds: nil,
                    completedAt: log.loggedAt,
                    userCorrectedWeight: log.aiPrescribed?.userCorrectedWeight
                )
            }
        return ExerciseHistoryItem(exerciseName: exercise.name, sets: sets)
    }

    /// Fetches the top-K most relevant memory items for `exercise` via the
    /// MemoryService RAG read path (TDD §9.2).
    private func fetchRAGMemory(for exercise: PlannedExercise) async -> [RAGMemoryItem] {
        guard let sess = session else { return [] }
        let queryText = ([exercise.name, exercise.primaryMuscle] + exercise.synergists).joined(separator: " ")
        return await memoryService.retrieveMemory(
            queryText: queryText,
            userId: sess.userId.uuidString
        )
    }

    // MARK: - Session Termination

    private func finishSession(earlyExitReason: String?) async {
        restTimerTask?.cancel()
        restTimerTask = nil

        guard var finalSession = session else {
            sessionState = .error("No active session to end.")
            return
        }

        // Build session summary
        let totalVolume = completedSets.reduce(0.0) { $0 + $1.weightKg * Double($1.repsCompleted) }
        let totalPlanned = trainingDay?.exercises.reduce(0) { $0 + $1.sets } ?? 0
        let sessionDuration: Int
        if let startDate = session?.sessionDate {
            sessionDuration = Int(Date().timeIntervalSince(startDate))
        } else {
            sessionDuration = 0
        }
        let summary = SessionSummary(
            totalVolumeKg: totalVolume,
            setsCompleted: completedSets.count,
            setsPlanned: totalPlanned,
            personalRecords: [],    // PR detection is a P4 deliverable
            aiAdjustmentCount: completedSets.filter { $0.aiPrescribed != nil }.count,
            notableNotes: sessionNotes.map(\.rawTranscript),
            earlyExitReason: earlyExitReason,
            durationSeconds: sessionDuration
        )

        finalSession.completed = earlyExitReason == nil
        finalSession.summary = summary
        self.session = finalSession

        // Blocking write: patch workout_sessions with completed + summary (P3-T06 AC)
        // Must complete before PostWorkoutSummaryView is shown.
        let patch = WorkoutSessionSummaryPatch(completed: finalSession.completed, summary: summary)
        let sessionId = finalSession.id
        do {
            try await writeAheadQueue.updateBlocking(patch, table: "workout_sessions", id: sessionId)
        } catch {
            // If the blocking write fails, enqueue it for retry
            print("[WorkoutSessionManager] Session summary write failed: \(error.localizedDescription)")
            try? await writeAheadQueue.enqueue(patch, table: "workout_sessions")
        }

        // Queue early-exit memory event (TDD §9.3 / P4-T07)
        // Format: "Early exit: {partial_exercises_completed}" per ARCHITECTURE.md §9.3
        if earlyExitReason != nil {
            let completedExerciseNames = sessionHistoryToday.map(\.exerciseName).joined(separator: ", ")
            let partialDescription = completedExerciseNames.isEmpty ? "no exercises completed" : completedExerciseNames
            let text = "Early exit: \(partialDescription)"
            let metaSessionId = finalSession.id.uuidString
            let userId = finalSession.userId.uuidString
            Task.detached { [memoryService, text, metaSessionId, userId] in
                await memoryService.embed(
                    text: text,
                    sessionId: metaSessionId,
                    tags: ["session_incomplete"],
                    userId: userId
                )
            }
        }

        // Emit per-exercise outcome memory events (FB-006)
        emitExerciseOutcomeEvents(session: finalSession)

        sessionState = .sessionComplete(summary: summary)

        // Increment persistent session count (FB-005) so subsequent sessions are
        // not treated as calibration sessions. Must run on actor; UserDefaults is
        // thread-safe for reads/writes so this is safe to call here.
        if earlyExitReason == nil {
            let currentCount = UserDefaults.standard.integer(forKey: UserProfileConstants.sessionCountKey)
            UserDefaults.standard.set(currentCount + 1, forKey: UserProfileConstants.sessionCountKey)
        }

        // Invalidate streak cache so the next session start re-fetches fresh data
        let sessionUserId = finalSession.userId
        Task.detached(priority: .utility) { [gymStreakService, sessionUserId] in
            await gymStreakService.invalidate(userId: sessionUserId)
        }
    }

    // MARK: - Memory Event Taxonomy (P4-T07 / FB-006)

    /// Emits one structured outcome memory event per exercise completed in the session.
    ///
    /// Outcome classification:
    ///   • on_target  — avg reps ≥ 90% of target
    ///   • overloaded — avg reps < 70% of target (weight was too heavy)
    ///   • underloaded — avg reps ≥ 110% of target (weight was too light)
    ///
    /// These events are retrieved via RAG before the same exercise next session,
    /// enabling the AI to open above/below the previous weight as appropriate (FB-006).
    private func emitExerciseOutcomeEvents(session: WorkoutSession) {
        guard let day = trainingDay else { return }
        let userId = session.userId.uuidString
        let sessionId = session.id.uuidString

        for exercise in day.exercises {
            let sets = completedSets.filter { $0.exerciseId == exercise.exerciseId }
            guard !sets.isEmpty else { continue }

            let targetReps = Double(exercise.repRange.max)
            let avgRepsCompleted = Double(sets.map(\.repsCompleted).reduce(0, +)) / Double(sets.count)
            let avgRpe = sets.compactMap(\.rpeFelt).map(Double.init).reduce(0, +)
                / Double(max(1, sets.compactMap(\.rpeFelt).count))
            let avgWeight = sets.map(\.weightKg).reduce(0, +) / Double(sets.count)

            let repCompletionPct = targetReps > 0 ? (avgRepsCompleted / targetReps) * 100.0 : 100.0
            let outcome: String
            if repCompletionPct < 70 {
                outcome = "overloaded"
            } else if repCompletionPct >= 110 {
                outcome = "underloaded"
            } else {
                outcome = "on_target"
            }

            let rpeStr = sets.compactMap(\.rpeFelt).isEmpty ? "n/a" : String(format: "%.1f", avgRpe)
            let text = """
                Exercise outcome — \(exercise.name): \
                avg \(String(format: "%.0f", avgRepsCompleted))/\(exercise.repRange.max) reps \
                (\(String(format: "%.0f", repCompletionPct))%), \
                avg weight \(formatWeight(avgWeight))kg, \
                avg RPE \(rpeStr), \
                outcome: \(outcome)
                """
            let tags = ["exercise_outcome", outcome, exercise.primaryMuscle]
            let muscleGroups = [exercise.primaryMuscle] + exercise.synergists

            Task.detached { [memoryService, text, tags, sessionId, exerciseId = exercise.exerciseId, userId, muscleGroups] in
                await memoryService.embed(
                    text: text,
                    sessionId: sessionId,
                    exerciseId: exerciseId,
                    tags: tags,
                    muscleGroups: muscleGroups,
                    userId: userId
                )
            }
        }
    }

    /// Checks for a PR and emits a memory event if one is detected.
    ///
    /// A PR is detected when the set's estimated 1RM (`weight × (1 + reps/30)`) exceeds
    /// the best previous estimated 1RM for the same exercise in this session.
    /// (Cross-session PR detection is a P4 deliverable; this covers within-session PRs.)
    private func emitPRMemoryEventIfNeeded(for log: SetLog, exercise: PlannedExercise) {
        guard let sess = session else { return }
        let currentEstimated1RM = log.weightKg * (1.0 + Double(log.repsCompleted) / 30.0)
        let priorBest = completedSets
            .filter { $0.exerciseId == exercise.exerciseId && $0.id != log.id }
            .map { $0.weightKg * (1.0 + Double($0.repsCompleted) / 30.0) }
            .max() ?? 0

        guard currentEstimated1RM > priorBest else { return }

        let text = "PR on \(exercise.name): \(formatWeight(log.weightKg))kg x \(log.repsCompleted)"
        let tags = ["pr_achieved", exercise.primaryMuscle]
        let sessionId = sess.id.uuidString
        let userId = sess.userId.uuidString
        let muscleGroups = [exercise.primaryMuscle] + exercise.synergists

        Task.detached { [memoryService, text, tags, sessionId, userId, muscleGroups] in
            await memoryService.embed(
                text: text,
                sessionId: sessionId,
                exerciseId: exercise.exerciseId,
                tags: tags,
                muscleGroups: muscleGroups,
                userId: userId
            )
        }
    }

    /// Emits a performance-drop memory event when actual reps fall > 2 below target.
    private func emitPerformanceDropEventIfNeeded(
        actualReps: Int,
        targetReps: Int,
        exercise: PlannedExercise
    ) {
        guard actualReps <= targetReps - 2 else { return }
        guard let sess = session else { return }

        let text = "Performance drop on \(exercise.name): \(actualReps)/\(targetReps) reps"
        let tags = ["performance_drop", "fatigue"]
        let sessionId = sess.id.uuidString
        let userId = sess.userId.uuidString
        let muscleGroups = [exercise.primaryMuscle] + exercise.synergists

        Task.detached { [memoryService, text, tags, sessionId, userId, muscleGroups] in
            await memoryService.embed(
                text: text,
                sessionId: sessionId,
                exerciseId: exercise.exerciseId,
                tags: tags,
                muscleGroups: muscleGroups,
                userId: userId
            )
        }
    }

    // MARK: - Keyword Helpers

    private let painKeywords = ["pain", "hurt", "tweaky", "clicking", "popping",
                                "tight", "impinged", "pulling", "straining", "sore"]

    private func containsPainKeywords(_ text: String) -> Bool {
        let lower = text.lowercased()
        return painKeywords.contains { lower.contains($0) }
    }

    private func detectNoteTags(in transcript: String) -> [String] {
        var tags: [String] = []
        if containsPainKeywords(transcript) { tags.append("injury_concern") }
        let lower = transcript.lowercased()
        if lower.contains("fatigue") || lower.contains("tired") { tags.append("fatigue") }
        if lower.contains("strong") || lower.contains("energy") { tags.append("energy") }
        return tags
    }

    private func formatWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
    }

    // MARK: - UserProfile Helpers (FB-003)

    /// Reads the user's biometric profile from UserDefaults.
    /// Written during onboarding and editable from Settings.
    nonisolated private static func loadUserProfileFromDefaults() -> UserProfileContext? {
        let defaults = UserDefaults.standard
        let bodyweight = defaults.object(forKey: UserProfileConstants.bodyweightKgKey) as? Double
        let height     = defaults.object(forKey: UserProfileConstants.heightCmKey) as? Double
        let age        = defaults.object(forKey: UserProfileConstants.ageKey) as? Int
        let trainingAge = defaults.string(forKey: UserProfileConstants.trainingAgeKey)

        // Only return a profile if we have at least one meaningful field.
        guard bodyweight != nil || height != nil || age != nil || trainingAge != nil else {
            return nil
        }

        return UserProfileContext(
            bodyweightKg: bodyweight,
            heightCm: height,
            age: age,
            trainingAge: trainingAge
        )
    }
}

// MARK: - Supabase Payload DTOs
//
// Lightweight Encodable structs matching the Supabase table column names.
// These avoid exposing the full Codable implementation of WorkoutSession models.

nonisolated private struct WorkoutSessionPayload: Encodable {
    let id: String
    let userId: String
    let programId: String
    let sessionDate: String
    let weekNumber: Int
    let dayType: String
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId      = "user_id"
        case programId   = "program_id"
        case sessionDate = "session_date"
        case weekNumber  = "week_number"
        case dayType     = "day_type"
        case completed
    }

    init(from session: WorkoutSession) {
        let formatter = ISO8601DateFormatter()
        self.id = session.id.uuidString
        self.userId = session.userId.uuidString
        self.programId = session.programId.uuidString
        self.sessionDate = formatter.string(from: session.sessionDate)
        self.weekNumber = session.weekNumber
        self.dayType = session.dayType
        self.completed = session.completed
    }
}

nonisolated private struct SetLogPayload: Encodable {
    let id: String
    let sessionId: String
    let exerciseId: String
    let setNumber: Int
    let weightKg: Double
    let repsCompleted: Int
    let rpeFelt: Int?
    let rirEstimated: Int?
    let loggedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId     = "session_id"
        case exerciseId    = "exercise_id"
        case setNumber     = "set_number"
        case weightKg      = "weight_kg"
        case repsCompleted = "reps_completed"
        case rpeFelt       = "rpe_felt"
        case rirEstimated  = "rir_estimated"
        case loggedAt      = "logged_at"
    }

    init(from log: SetLog) {
        let formatter = ISO8601DateFormatter()
        self.id = log.id.uuidString
        self.sessionId = log.sessionId.uuidString
        self.exerciseId = log.exerciseId
        self.setNumber = log.setNumber
        self.weightKg = log.weightKg
        self.repsCompleted = log.repsCompleted
        self.rpeFelt = log.rpeFelt
        self.rirEstimated = log.rirEstimated
        self.loggedAt = formatter.string(from: log.loggedAt)
    }
}

nonisolated private struct SessionNotePayload: Encodable {
    let id: String
    let sessionId: String
    let exerciseId: String?
    let rawTranscript: String
    let tags: [String]
    let loggedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId     = "session_id"
        case exerciseId    = "exercise_id"
        case rawTranscript = "raw_transcript"
        case tags
        case loggedAt      = "logged_at"
    }

    init(from note: SessionNote) {
        let formatter = ISO8601DateFormatter()
        self.id = note.id.uuidString
        self.sessionId = note.sessionId.uuidString
        self.exerciseId = note.exerciseId
        self.rawTranscript = note.rawTranscript
        self.tags = note.tags
        self.loggedAt = formatter.string(from: note.loggedAt)
    }
}

nonisolated private struct WorkoutSessionSummaryPatch: Encodable {
    let completed: Bool
    let summary: SessionSummary
}

// MARK: - TrainingDay bridging helpers

extension TrainingDay {
    /// Convenience accessor that exposes `dayLabel` as an Optional for nil-coalescing
    /// in WorkoutSessionManager (TrainingDay.dayLabel is non-optional in the model,
    /// but downstream code treats it as optional for future extensibility).
    var label: String? { dayLabel }
}
