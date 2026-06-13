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
import OSLog

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
    case exerciseComplete(completedExercise: PlannedExercise, nextExercise: PlannedExercise?)
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
        case (.exerciseComplete(let ac, let an), .exerciseComplete(let bc, let bn)):
            return ac.id == bc.id && an?.id == bn?.id
        case (.sessionComplete, .sessionComplete):              return true
        case (.error(let a), .error(let b)):                    return a == b
        default:                                                return false
        }
    }
}

// MARK: - WorkoutUISnapshot

/// Atomic snapshot of every actor-isolated field `WorkoutViewModel.pullState()`
/// needs to render the live session UI (#369 [20]). Returning all of these in ONE
/// actor hop avoids the torn read that `pullState` previously produced by awaiting
/// ~9 separate isolated properties — between hops the actor could advance, so the
/// published `sessionState` and `currentPrescription` (etc.) could be from different
/// instants. `lastPerformance` is the cached last-session set logs for the *live*
/// exercise, resolved inside the actor so the liveExercise derivation is part of the
/// same consistent snapshot.
nonisolated struct WorkoutUISnapshot: Sendable {
    let sessionState: SessionState
    let currentPrescription: SetPrescription?
    let currentFallbackReason: FallbackReason?
    let restSecondsRemaining: Int
    let restExpiresAt: Date?
    let completedSets: [SetLog]
    let inferenceRetryNeeded: Bool
    let inferenceRetryReason: FallbackReason?
    let pendingRetryExercise: PlannedExercise?
    let lastPerformanceSets: [SetLog]?
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
    /// The training day ID for the currently active session (nil when idle/complete).
    /// Exposed so ProgramDayDetailView can detect and display live session state
    /// without having to cross actor boundaries repeatedly.
    private(set) var currentTrainingDayId: UUID? = nil
    private(set) var currentPrescription: SetPrescription?
    private(set) var currentFallbackReason: FallbackReason?
    private(set) var restSecondsRemaining: Int = 0
    private(set) var completedSets: [SetLog] = []

    /// True when inference failed and the user must choose Retry or Pause.
    /// The retry sheet is presented by WorkoutView as an overlay on .resting and .preflight states.
    private(set) var inferenceRetryNeeded: Bool = false
    /// The reason that triggered the retry sheet (for display in the UI subtitle).
    private(set) var inferenceRetryReason: FallbackReason?
    /// The exercise that needs a prescription retry — restored after sheet is shown.
    /// Readable (#318 U7 / 7.6) so WorkoutViewModel can gate and target the
    /// manual-fallback path during .preflight, where currentExercise is nil.
    private(set) var pendingRetryExercise: PlannedExercise?
    private var pendingRetrySetNumber: Int = 0

    // MARK: - Private session state

    private var session: WorkoutSession?
    private var trainingDay: TrainingDay?
    /// The mesocycle week ID stored at session start — used by pauseSession() to
    /// write PausedSessionState so the resume path can find the right week.
    private var weekId: UUID = UUID()
    /// Index into trainingDay.exercises for the current exercise.
    private var exerciseIndex: Int = 0
    /// 1-based set counter within the current exercise.
    private var currentSetNumber: Int = 1
    private var sessionNotes: [SessionNote] = []
    /// When the current rest period started, for elapsed calculation.
    private var restStartTime: Date?
    /// Planned rest duration for the current rest period.
    private var targetRestSeconds: Int = 90
    /// Absolute expiry time of the current rest period (nil when not resting).
    /// Used by RestTimerView to display the correct remaining time after foreground.
    private(set) var restExpiresAt: Date? = nil
    /// Counts active AIInferenceService.prescribe() calls (reentrancy guard).
    private(set) var inflightRequestCount: Int = 0
    /// Monotonically increasing generation counter. Incremented each completeSet().
    /// Inference results whose captured generation < inferenceGeneration are discarded.
    private var inferenceGeneration: Int = 0
    /// Idempotency latch for finishSession (#369 [8]). Set the instant finishSession
    /// begins so concurrent/duplicate end paths (endSession from the rest-timer Task
    /// racing endSessionEarly from the UI) run the side effects — session-count
    /// increment, trainee-model enqueue, completion PATCH — at most once.
    /// Reset wherever a fresh session lifecycle begins (startSession / resumeSession /
    /// resetToIdle).
    private var isFinishingSession: Bool = false
    /// Running rest-timer Task reference so we can cancel it on early exit.
    private var restTimerTask: Task<Void, Never>?

    // MARK: - Fix 4: RAG latency instrumentation
    // Signpost intervals are visible in Instruments → os_signpost track.
    // Wall-clock log lines are grep-able in Console with "RAG fetch latency".
    // Decision point: if p95 > 150 ms (from TestFlight data), promote this call
    // to an async prefetch that runs before the rest timer expires.
    private let ragSignposter = OSSignposter(subsystem: "com.projectapex", category: "RAGFetch")
    private let ragLogger     = Logger(subsystem: "com.projectapex",      category: "RAGFetch")
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
    /// Rolling 7-day fatigue projection (B4 / #89). Fetched at session start
    /// and forwarded into TraineeModelService.digest(weeklyFatigue:) on each
    /// per-set context build. Nil only on Supabase fetch error — the digest's
    /// non-optional weeklyFatigue field substitutes an empty struct in that
    /// case (γ2 lock).
    private var cachedWeeklyFatigue: WeekFatigueSignals? = nil
    /// GymProfile snapshot cached at session start — used by assembleWorkoutContext()
    /// to look up bodyweightOnly flags without crossing actor boundaries.
    private var cachedGymProfile: GymProfile? = nil
    /// Completed session count fetched from Supabase at session start (FB-005 fix).
    /// Replaces the local UserDefaults counter as the source of truth.
    private var cachedTotalSessionCount: Int = 0
    /// Last-session set logs per exerciseId (#318 U7). Populated at session
    /// start and at every exercise transition (next exercise, skip into a new
    /// exercise, swap, resume). Powers the runaway-clamp anchor (G-F3), the
    /// "Last time" line (G-F6), and the manual-fallback weight seed (G-F1).
    private var cachedLastPerformance: [String: [SetLog]] = [:]
    /// Records of any mid-session exercise swaps (P3-T10).
    private var swapRecords: [SwapRecord] = []

    // MARK: - Dependencies

    private let aiInference: AIInferenceService
    private let healthKit: HealthKitService
    private let memoryService: MemoryService
    private let supabase: SupabaseClient
    private let gymFactStore: GymFactStore
    private let writeAheadQueue: WriteAheadQueue
    private let gymStreakService: GymStreakService
    private let traineeModelService: TraineeModelService?

    // MARK: - Init

    init(
        aiInference: AIInferenceService,
        healthKit: HealthKitService,
        memoryService: MemoryService,
        supabase: SupabaseClient,
        gymFactStore: GymFactStore,
        writeAheadQueue: WriteAheadQueue? = nil,
        gymStreakService: GymStreakService? = nil,
        traineeModelService: TraineeModelService? = nil
    ) {
        self.aiInference = aiInference
        self.healthKit = healthKit
        self.memoryService = memoryService
        self.supabase = supabase
        self.gymFactStore = gymFactStore
        let waq = writeAheadQueue ?? WriteAheadQueue(supabase: supabase)
        self.writeAheadQueue = waq
        self.gymStreakService = gymStreakService ?? GymStreakService(supabase: supabase)
        self.traineeModelService = traineeModelService
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
    func startSession(trainingDay: TrainingDay, programId: UUID, userId: UUID = UUID(), weekId: UUID = UUID(), weekNumber: Int = 1, startingExerciseIndex: Int = 0) async {
        guard case .idle = sessionState else { return }

        // An errored start must mutate NOTHING — no state reset, no crash sentinel,
        // no enqueued session row. A day with no generated exercises can't be started;
        // this guard runs BEFORE any mutation so a failed start leaves zero durable traces.
        guard !trainingDay.exercises.isEmpty else {
            sessionState = .error("Training day has no exercises.")
            return
        }

        // Reset all session state
        self.trainingDay = trainingDay
        self.currentTrainingDayId = trainingDay.id
        self.weekId = weekId
        self.exerciseIndex = min(max(startingExerciseIndex, 0), max(trainingDay.exercises.count - 1, 0))
        self.currentSetNumber = 1
        self.completedSets = []
        self.sessionNotes = []
        self.sessionHistoryToday = []
        self.qualitativeNotesToday = []
        self.cachedBiometrics = nil
        self.cachedStreakResult = nil
        self.cachedRAGMemory = []
        self.cachedWeeklyFatigue = nil
        self.cachedGymProfile = nil
        self.cachedLastPerformance = [:]
        self.swapRecords = []
        self.inflightRequestCount = 0
        self.inferenceGeneration = 0
        self.isFinishingSession = false   // #369 [8] — fresh session, latch cleared

        // FB-003: Read user biometrics from UserDefaults for WorkoutContext assembly.
        self.cachedUserProfile = Self.loadUserProfileFromDefaults()
        // Cache GymProfile for bodyweightOnly lookups in assembleWorkoutContext().
        self.cachedGymProfile = await MainActor.run { GymProfile.loadFromUserDefaults() }

        sessionState = .preflight

        let newSession = WorkoutSession(
            id: UUID(),
            userId: userId,
            programId: programId,
            sessionDate: Date(),
            weekNumber: weekNumber,
            dayType: trainingDay.dayLabel,
            completed: false,
            status: "active",
            setLogs: [],
            sessionNotes: [],
            summary: nil
        )
        self.session = newSession

        // Write crash sentinel — if the app is killed mid-session, relaunch detects this
        // and offers a recovery prompt that reuses the existing resumeSession() flow.
        PausedSessionState(
            sessionId: newSession.id,
            trainingDayId: trainingDay.id,
            weekId: weekId,
            weekNumber: weekNumber,
            exerciseIndex: self.exerciseIndex,
            currentSetNumber: 1,
            dayType: trainingDay.dayLabel,
            programId: programId,
            userId: userId,
            pausedAt: Date()
        ).save()

        // Write session row via WAQ so it is recoverable if the app crashes mid-workout.
        // Status is completed=false (in_progress). Updated to completed=true at session end.
        let sessionPayload = WorkoutSessionPayload(from: newSession)
        print("[WorkoutSessionManager] Enqueuing session row — id: \(newSession.id), userId: \(newSession.userId), programId: \(programId), dayType: \(trainingDay.dayLabel)")
        try? await writeAheadQueue.enqueue(sessionPayload, table: "workout_sessions")

        let firstExercise = trainingDay.exercises[self.exerciseIndex]

        // Fetch streak, RAG memory, weekly fatigue, and session count in parallel
        async let streakFetch        = gymStreakService.computeStreak(userId: newSession.userId)
        async let ragFetch           = fetchRAGMemory(for: firstExercise)
        async let fatigueFetch       = fetchWeeklyFatigue(userId: newSession.userId)
        async let sessionCountFetch  = fetchCompletedSessionCount(userId: newSession.userId)
        async let lastPerfFetch      = fetchLastPerformance(
            for: firstExercise, userId: newSession.userId, excludingSessionId: newSession.id
        )
        cachedStreakResult           = await streakFetch
        cachedRAGMemory             = await ragFetch
        cachedWeeklyFatigue  = await fatigueFetch
        cachedTotalSessionCount      = await sessionCountFetch
        if let lastPerf = await lastPerfFetch {
            cachedLastPerformance[firstExercise.exerciseId] = lastPerf
        }

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
    func completeSet(
        actualReps: Int,
        rpeFelt: Int?,
        intent: SetIntent,
        completionFlags: [SetCompletionFlag] = []
    ) async {
        guard case .active(let exercise, let setNumber) = sessionState,
              let session = session else { return }

        // Advance generation counter before spawning inference task.
        // Any task using the previous generation will discard its result.
        inferenceGeneration += 1
        inflightRequestCount += 1
        let capturedGeneration = inferenceGeneration

        // Build and store set log.
        // Slice 6 (#10): intent is the RESOLVED value from the rep/RPE
        // sheet — defaults to the prescription's intent for AI-prescribed
        // sets, or the user's deviation pick if they tapped "Did
        // something different?". `is_deviation` is derivable from
        // `setLog.intent != setLog.aiPrescribed?.intent`, so we don't
        // store it as a separate field on SetLog — single source of
        // truth principle. CompletedSet (the WorkoutContext shape) DOES
        // materialize the boolean for AI prompt clarity.
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
            loggedAt: Date(),
            primaryMuscle: ExerciseLibrary.primaryMuscle(for: exercise.exerciseId)?.rawValue ?? exercise.primaryMuscle,
            intent: intent,
            completionFlags: completionFlags
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

        // 1. Write to local queue then immediately flush to Supabase (P3-T06).
        //    Immediate flush ensures each set_log lands in Supabase synchronously,
        //    so killing the app between sets never loses data.
        //    intent is the function's required parameter — threaded explicitly per
        //    Slice 6 / #60 fix so the encoder cannot silently fall back to nil.
        let setPayload = SetLogPayload(from: setLog, intent: intent)
        try? await writeAheadQueue.enqueue(setPayload, table: "set_logs")
        print("[WAQ] Enqueued set_log — session_id: \(session.id), set: \(setNumber), exercise: \(exercise.name), weight: \(currentPrescription?.weightKg ?? 0)kg, reps: \(actualReps)")

        // Determine whether this was the last set for this exercise and
        // advance position. SET-NUMBER-based, shared with skipCurrentSet()
        // (#318 / U5): counting SetLogs lags reality after a skip (a skipped
        // set writes no SetLog) and would prescribe a phantom extra set.
        let (isLastSetForExercise, nextExercise, nextSetNumber) =
            advancePosition(after: exercise, setNumber: setNumber)

        // 2. Transition to resting (or end session immediately if this was the last set)
        let planRestSeconds = currentPrescription?.restSeconds ?? exercise.restSeconds
        targetRestSeconds = planRestSeconds
        restStartTime = Date()
        currentPrescription = nil   // Clear stale prescription before next set

        let isSessionEnd = nextExercise == nil && isLastSetForExercise

        if isSessionEnd {
            // No next exercise — skip rest entirely and go straight to summary.
            await endSession()
            return
        }

        if isLastSetForExercise {
            // Flash .exerciseComplete for 1.2 s before entering rest.
            // Inference fires immediately on entry so it overlaps the celebration window.
            sessionState = .exerciseComplete(completedExercise: exercise, nextExercise: nextExercise)

            if let next = nextExercise {
                // Moving to a new exercise — refresh RAG memory.
                // MARK: Fix 4 — RAG latency measurement
                let signpostID = ragSignposter.makeSignpostID()
                let signpostState = ragSignposter.beginInterval("RAGFetch", id: signpostID,
                    "\(next.name, privacy: .public)")
                let ragStart = ContinuousClock.now
                cachedRAGMemory = await fetchRAGMemory(for: next)
                let ragElapsed = ragStart.duration(to: .now)
                ragSignposter.endInterval("RAGFetch", signpostState)
                ragLogger.info("RAG fetch latency: \(ragElapsed, privacy: .public) exercise=\(next.name, privacy: .public)")

                // #318 U7: refresh last-session history for the next exercise —
                // clamp anchor (G-F3), "Last time" line (G-F6), fallback seed (G-F1).
                await refreshLastPerformance(for: next)

                let context = await assembleWorkoutContext(exercise: next, setNumber: nextSetNumber)
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
                inflightRequestCount -= 1
            }

            // Wait 1.2 s, then enter rest. If pause fires during the window,
            // sessionState is reset to .idle by resetToIdle() — guard catches that.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard case .exerciseComplete = sessionState else { return }
            sessionState = .resting(nextExercise: nextExercise!, setNumber: nextSetNumber)
            startRestTimer(duration: planRestSeconds, isSessionEnd: false)
        } else {
            // Same exercise, next set — go directly to resting.
            sessionState = .resting(nextExercise: nextExercise!, setNumber: nextSetNumber)
            startRestTimer(duration: planRestSeconds, isSessionEnd: false)

            if let next = nextExercise {
                let context = await assembleWorkoutContext(exercise: next, setNumber: nextSetNumber)
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
                inflightRequestCount -= 1
            }
        }
    }

    /// Skips the current set without logging it (#318 / U5, G-F7).
    ///
    /// Advances exactly like completeSet() but writes NO SetLog, NO WAQ entry,
    /// NO memory event, and takes NO rest period: state moves straight to
    /// .active for the next set (ActiveSetView renders the thinking indicator
    /// while currentPrescription is nil) and inference fires immediately.
    /// Skipping the last set of the last exercise ends the session; a session
    /// where EVERY set was skipped is then discarded by finishSession's
    /// zero-set guard (completedSets.isEmpty → .idle, nothing persisted).
    func skipCurrentSet() async {
        guard case .active(let exercise, let setNumber) = sessionState,
              session != nil else { return }

        // Invalidate any in-flight inference aimed at the skipped set —
        // same reentrancy discipline as completeSet().
        inferenceGeneration += 1

        let (isLastSetForExercise, nextExercise, nextSetNumber) =
            advancePosition(after: exercise, setNumber: setNumber)

        currentPrescription = nil   // ActiveSetView shows the thinking indicator

        guard let next = nextExercise else {
            // Skipped the last set of the last exercise — end the session.
            await endSession()
            return
        }

        if isLastSetForExercise {
            // Moving to a new exercise — refresh RAG memory (mirrors
            // completeSet's last-set branch; the sessionHistoryToday archive
            // already happened inside advancePosition).
            cachedRAGMemory = await fetchRAGMemory(for: next)
            // #318 U7: same exercise-transition refresh as completeSet.
            await refreshLastPerformance(for: next)
        }

        // No rest after a skip — go straight to the next set and fire inference.
        sessionState = .active(exercise: next, setNumber: nextSetNumber)
        await triggerInference(for: next, setNumber: nextSetNumber)
    }

    /// Shared advancement tail for completeSet()/skipCurrentSet() (#318 / U5).
    ///
    /// Last-set determination is SET-NUMBER-based (`setNumber >= exercise.sets`),
    /// NOT SetLog-count-based: a skipped set writes no SetLog, so counting logs
    /// lags reality after a skip and would prescribe a phantom extra set.
    ///
    /// Advances exerciseIndex/currentSetNumber, archives the finished exercise
    /// into sessionHistoryToday on the last set, and refreshes the crash
    /// sentinel. Returns the position to move to next — a nil nextExercise
    /// (only possible when isLastSetForExercise) means the session is over.
    private func advancePosition(
        after exercise: PlannedExercise,
        setNumber: Int
    ) -> (isLastSetForExercise: Bool, nextExercise: PlannedExercise?, nextSetNumber: Int) {
        let isLastSetForExercise = setNumber >= exercise.sets

        if isLastSetForExercise {
            // Archive this exercise's sets into session history
            sessionHistoryToday.append(buildExerciseHistoryItem(for: exercise))
            exerciseIndex += 1
            currentSetNumber = 1
        } else {
            currentSetNumber = setNumber + 1
        }

        // Update crash sentinel so crash recovery reflects the latest set/exercise position.
        if let session, let day = trainingDay {
            PausedSessionState(
                sessionId: session.id,
                trainingDayId: day.id,
                weekId: weekId,
                weekNumber: session.weekNumber,
                exerciseIndex: exerciseIndex,
                currentSetNumber: currentSetNumber,
                dayType: session.dayType,
                programId: session.programId,
                userId: session.userId,
                pausedAt: Date()
            ).save()
        }

        // Determine next exercise and set number
        let exercises = trainingDay?.exercises ?? []
        if isLastSetForExercise {
            let next = exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
            return (true, next, 1)
        } else {
            return (false, exercise, currentSetNumber)
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
    ///
    /// - Parameters:
    ///   - unavailableWeight: The weight the AI prescribed that wasn't available.
    ///                        Passed explicitly by the caller so the GymFactStore write
    ///                        is never silently dropped if currentPrescription is nil.
    ///   - confirmedWeight: The actual weight the user selected as available.
    ///   - equipmentType: The equipment type for this exercise.
    func applyWeightCorrection(
        unavailableWeight: Double,
        confirmedWeight: Double,
        equipmentType: EquipmentType
    ) async {
        // Sanity check: warn loudly if this looks like an accidentally low weight block.
        // The user already chose "Missing permanently" in the two-step UI, so we save
        // regardless — this log is for debugging if the pattern recurs.
        let isSuspicious = await gymFactStore.isSuspiciouslyLowCorrection(
            equipmentType: equipmentType,
            unavailableWeight: unavailableWeight
        )
        if isSuspicious {
            print("[WorkoutSessionManager] ⚠️ GymFactStore sanity check: \(unavailableWeight)kg is suspiciously low for \(equipmentType.typeKey). If this was an accident, open Developer Settings → Gym Weight Corrections to remove it.")
        }

        // Always record the correction — the GymFactStore write must not depend on
        // currentPrescription being non-nil (it can be nil during state transitions).
        await gymFactStore.recordCorrection(
            equipmentType: equipmentType,
            unavailableWeight: unavailableWeight,
            availableWeight: confirmedWeight
        )
        print("[WorkoutSessionManager] GymFactStore correction recorded — \(equipmentType.typeKey): \(unavailableWeight)kg → \(confirmedWeight)kg")

        // Also update the live prescription if a session is active so the current
        // set reflects the corrected weight immediately.
        if var prescription = currentPrescription {
            prescription.weightKg = confirmedWeight
            prescription.userCorrectedWeight = true
            currentPrescription = prescription
        }
    }

    /// Retries inference for the exercise that last failed.
    /// Called when the user taps "Retry" on the InferenceRetrySheet.
    /// Returns true if a prescription was obtained, false if inference failed again.
    func retryInference() async -> Bool {
        guard let exercise = pendingRetryExercise else { return false }
        let setNumber = pendingRetrySetNumber

        // #369 [19] — capture the generation BEFORE the network/post-processing awaits.
        // retryInference previously applied its result with no generation re-check, so a
        // result that resolved AFTER a concurrent completeSet()/skip/swap advanced the
        // session could clobber the newer state. Participate in the same guard discipline
        // as handleInferenceResult: drop the result if the generation moved on.
        let generation = inferenceGeneration

        // Clear failed state before retrying so UI shows "thinking" state
        currentFallbackReason = nil
        inferenceRetryNeeded = false

        let context = await assembleWorkoutContext(exercise: exercise, setNumber: setNumber)
        let result = await aiInference.prescribe(context: context)

        switch result {
        case .success(var rx):
            // #318 U7: snap → clamp → marker — same shared post-processor as
            // handleInferenceResult (the only other live LLM path).
            rx = await postProcessPrescription(rx, for: exercise)
            // #369 [19] — re-check the generation after the awaits (assembleWorkoutContext,
            // prescribe, postProcessPrescription all suspend). If the session advanced in
            // the meantime, this prescription is stale: drop it without mutating state.
            guard generation == inferenceGeneration else { return false }
            if rx.safetyFlags.contains(.painReported) { rx.restSeconds = max(rx.restSeconds, 180) }
            currentPrescription = rx
            currentFallbackReason = nil
            inferenceRetryNeeded = false
            inferenceRetryReason = nil
            pendingRetryExercise = nil
            pendingRetrySetNumber = 0
            // Transition to active from whatever state we're in
            sessionState = .active(exercise: exercise, setNumber: setNumber)
            return true
        case .fallback(let reason):
            // #369 [19] — a stale fallback must not re-arm the retry sheet for a set the
            // session has already moved past.
            guard generation == inferenceGeneration else { return false }
            currentFallbackReason = reason
            inferenceRetryReason = reason
            inferenceRetryNeeded = true
            return false
        }
    }

    /// Pauses the current session. Flushes the write-ahead queue, PATCHes the session
    /// row to status="paused", saves PausedSessionState to UserDefaults, then resets to idle.
    func pauseSession() async {
        guard let sess = session, let day = trainingDay else { return }

        // 1. Cancel rest timer to stop any pending transitions.
        restTimerTask?.cancel()
        restTimerTask = nil

        // 2. Save PausedSessionState to UserDefaults FIRST — this is the durable
        //    record the resume path reads. Persisting before any network work
        //    means a freeze / background / kill during the (now non-blocking)
        //    sync can no longer lose the pause point (#190). Queued set_logs are
        //    already persisted in the WAQ (and dead-lettered if retries exhaust,
        //    #184), so they are safe regardless.
        PausedSessionState(
            sessionId: sess.id,
            trainingDayId: day.id,
            weekId: weekId,
            weekNumber: sess.weekNumber,
            exerciseIndex: exerciseIndex,
            currentSetNumber: currentSetNumber,
            dayType: sess.dayType,
            programId: sess.programId,
            userId: sess.userId,
            pausedAt: Date()
        ).save()

        // 3. Sync to the server WITHOUT blocking the UI (#190): pauseSession
        //    previously awaited writeAheadQueue.flush() (up to 1+2+4+8+16s of
        //    backoff on a bad network) and then a blocking PATCH, which froze the
        //    pause — and if the user backgrounded during that freeze, the pause
        //    point was lost. Both are best-effort and now fire-and-forget: the
        //    set_logs live in the WAQ, and the paused status is recovered from
        //    the UserDefaults snapshot saved above (not from the DB row).
        let patch = WorkoutSessionStatusPatch(status: "paused", completed: false)
        let sessionId = sess.id
        let waq = writeAheadQueue
        Task.detached {
            await waq.flush()
            try? await waq.updateBlocking(patch, table: "workout_sessions", id: sessionId)
        }

        print("[WorkoutSessionManager] pauseSession ✓ — sessionId: \(sess.id), exerciseIndex: \(exerciseIndex), setNumber: \(currentSetNumber)")

        // 4. Reset actor state to idle (does not affect the saved paused state).
        resetToIdle()
    }

    /// Marks an interrupted session as abandoned. Called when the user dismisses the
    /// crash-recovery prompt on relaunch without choosing to resume.
    ///
    /// Flushes the WAQ first to ensure the session row is in Supabase (the row may still be
    /// queued from the prior launch), then PATCHes `status = "abandoned"` so the session
    /// does not count toward streak or programme progress.
    func abandonSession(sessionId: UUID) async {
        // Flush pending writes — ensures the session row exists in Supabase before PATCH
        await writeAheadQueue.flush()
        // PATCH session to abandoned (best-effort; failure leaves an orphaned "active" row)
        let patch = WorkoutSessionStatusPatch(status: "abandoned", completed: false)
        try? await writeAheadQueue.updateBlocking(patch, table: "workout_sessions", id: sessionId)
        // Always clear the recovery state so the prompt does not reappear next launch
        PausedSessionState.clear()
        print("[WorkoutSessionManager] Session \(sessionId) marked abandoned via recovery dismiss")
    }

    /// Discards a stale paused session whose owner does not match the current
    /// authenticated uid. Clears the write-ahead queue (live + dead-letter) and the
    /// paused snapshot, but issues NO Supabase write — the frozen session_id and
    /// set_logs belong to a different owner, so every write against them is rejected
    /// by RLS (42501). (#369 owner-mismatch campaign, slice 4.)
    func discardStalePausedSession() async {
        await writeAheadQueue.clearAll()
        PausedSessionState.clear()
        print("[WorkoutSessionManager] stale-owner paused session discarded — WAQ cleared")
    }

    /// Returns a hint string showing the available weight options near `weight` for the given
    /// equipment type, based on confirmed GymFactStore corrections for this user's gym.
    ///
    /// Returns nil when no corrections have been recorded for this equipment type — meaning there
    /// are no known unavailable weights and no hint is needed.
    ///
    /// Example return value: "Available: 40kg · 42.5kg · 45kg · 47.5kg · 50kg"
    func availableWeightHint(for equipmentType: EquipmentType, near weight: Double) async -> String? {
        let nearby = await gymFactStore.nearbyAvailableWeights(near: weight, for: equipmentType)
        guard !nearby.isEmpty else { return nil }
        let strings = nearby.map { w in
            w.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fkg", w)
                : String(format: "%.1fkg", w)
        }
        return "Available: " + strings.joined(separator: " · ")
    }

    /// Flushes the write-ahead queue. Called before fetching set_logs on resume so
    /// all writes queued from the prior session are in Supabase before we read them back.
    func flushWriteAheadQueue() async {
        await writeAheadQueue.flush()
    }

    /// Returns pending `set_log` entries for `sessionId` that remain in the WAQ
    /// after a flush attempt (i.e., could not be sent due to network failure).
    /// Used by `WorkoutViewModel.resumeSession()` to cover the offline-resume case.
    func pendingSetLogs(forSession sessionId: UUID) async -> [SetLog] {
        await writeAheadQueue.pendingSetLogs(forSession: sessionId)
    }

    /// Applies a session-only weight override — updates the current prescription in-memory
    /// but does NOT write to GymFactStore. Use this for one-off adjustments where the weight
    /// is simply not right for this exercise today, not because it's absent from the gym.
    func applySessionOnlyWeightOverride(confirmedWeight: Double) {
        guard var prescription = currentPrescription else { return }
        prescription.weightKg = confirmedWeight
        prescription.userCorrectedWeight = true
        currentPrescription = prescription
        print("[WorkoutSessionManager] Session-only weight override — \(confirmedWeight)kg (GymFactStore NOT updated)")
    }

    /// Called when the user taps "Continue with last weights" on InferenceRetrySheet.
    /// Builds a prescription from the most recently logged set for this exercise in the
    /// current session, falling back to program defaults if no prior set exists.
    func applyManualFallbackPrescription(for exercise: PlannedExercise) {
        let lastSet = completedSets
            .filter { $0.exerciseId == exercise.exerciseId }
            .max(by: { $0.setNumber < $1.setNumber })

        // Intent carry-over: when the user opts into the manual fallback
        // ("Continue with last weights"), inherit the prior set's intent as a
        // *suggestion* for the picker to prefill. Stays `nil` when there's no
        // prior set in the session — the picker then has no prefill and the
        // user must pick explicitly per Slice 6's no-silent-default rule.

        // #318 U7 / G-F1: with no in-session set, seed the weight from the
        // last-session history (cachedLastPerformance top set) instead of
        // 0.0 — no more "BW" shown on a loaded movement. 0.0 survives ONLY
        // for genuine bodyweight history (all sets 0 kg) or no history at all.
        let seedWeight = lastSet?.weightKg
            ?? historySeedWeight(for: exercise.exerciseId)
            ?? 0.0

        let prescription = SetPrescription(
            weightKg:          seedWeight,
            reps:              lastSet?.repsCompleted ?? exercise.repRange.min,
            tempo:             exercise.tempo,
            rirTarget:         exercise.rirTarget,
            restSeconds:       exercise.restSeconds,
            coachingCue:       "Using last session weights",
            reasoning:         "Manual fallback — AI unavailable.",
            safetyFlags:       [],
            confidence:        nil,
            userCorrectedWeight: nil,
            isManualFallback:  true,
            intent:            lastSet?.intent,
            // Manual-fallback path uses a generic framing — there's no AI
            // call to produce one. Inherits intent from last set; framing
            // mirrors that. No silent default at the AI layer; this is
            // the explicit fallback shape.
            setFraming:        "Using last session weights. No AI guidance."
        )
        currentPrescription = prescription
        inferenceRetryNeeded = false
        inferenceRetryReason = nil

        // Critic amendment 7.6 (#318 U7): give the preflight failure path a
        // manual way forward too. When inference failed before any rest period
        // existed (first set of a session, post-swap set 1, resume), applying
        // the manual fallback transitions straight to .active — there is no
        // rest timer on this path to complete the transition later.
        if case .preflight = sessionState {
            sessionState = .active(exercise: exercise, setNumber: max(1, pendingRetrySetNumber))
        }

        pendingRetryExercise = nil
    }

    /// Resumes a previously paused session.
    /// Restores all relevant in-memory state, PATCHes the session back to "active",
    /// and fires inference for the exercise/set where the user left off.
    func resumeSession(
        pausedState: PausedSessionState,
        trainingDay: TrainingDay,
        completedSetLogs: [SetLog]
    ) async {
        guard case .idle = sessionState else { return }

        // Restore session state
        self.trainingDay = trainingDay
        self.currentTrainingDayId = trainingDay.id
        self.weekId = pausedState.weekId
        self.exerciseIndex = min(pausedState.exerciseIndex, max(0, trainingDay.exercises.count - 1))
        self.currentSetNumber = pausedState.currentSetNumber
        self.completedSets = completedSetLogs
        self.sessionNotes = []
        self.qualitativeNotesToday = []
        self.cachedBiometrics = nil
        self.cachedStreakResult = nil
        self.cachedRAGMemory = []
        self.cachedWeeklyFatigue = nil
        self.cachedLastPerformance = [:]
        self.inflightRequestCount = 0
        // #369 [21] — bump (not reset to 0) so any inference Task still in flight from
        // BEFORE the pause is rejected by the generation guard when it returns. The actor
        // is always idle here (resume guards on .idle, and the prior pause/end ran
        // resetToIdle which left the counter at 0), so this advances 0 → 1. A pre-pause
        // straggler that captured generation 0 (the common case: paused before/just as
        // the first prescription landed) therefore no longer matches the resumed
        // generation. NOTE: a straggler that captured a generation ≥ 1 deeper into the
        // pre-pause session could still coincide with the resumed counter once it climbs
        // there; fully closing that requires a lifetime-monotonic counter (never zeroed in
        // resetToIdle) — deferred as a wider change. Documented in PR / report.
        self.inferenceGeneration += 1
        self.isFinishingSession = false   // #369 [8] — resumed session can end again
        self.inferenceRetryNeeded = false
        self.inferenceRetryReason = nil
        self.pendingRetryExercise = nil
        self.pendingRetrySetNumber = 0
        self.restSecondsRemaining = 0
        self.restExpiresAt = nil
        self.currentPrescription = nil
        self.currentFallbackReason = nil
        self.cachedUserProfile = Self.loadUserProfileFromDefaults()
        self.cachedGymProfile = await MainActor.run { GymProfile.loadFromUserDefaults() }

        // Reconstruct the in-memory WorkoutSession (same id, no rest timer needed)
        self.session = WorkoutSession(
            id: pausedState.sessionId,
            userId: pausedState.userId,
            programId: pausedState.programId,
            sessionDate: Date(),
            weekNumber: pausedState.weekNumber,
            dayType: pausedState.dayType,
            completed: false,
            status: "active",
            setLogs: completedSetLogs,
            sessionNotes: [],
            summary: nil
        )

        // Rebuild sessionHistoryToday from the set logs for all exercises before the current index
        self.sessionHistoryToday = reconstructSessionHistory(
            from: completedSetLogs,
            exercises: trainingDay.exercises,
            upToExerciseIndex: self.exerciseIndex
        )

        sessionState = .preflight

        // PATCH the session status back to "active" now that we are resuming
        let patch = WorkoutSessionStatusPatch(status: "active", completed: false)
        do {
            try await writeAheadQueue.updateBlocking(patch, table: "workout_sessions", id: pausedState.sessionId)
        } catch {
            print("[WorkoutSessionManager] resumeSession — status PATCH failed: \(error)")
        }

        // Clear the persisted pause snapshot — we are now live again
        PausedSessionState.clear()

        // Fetch streak, RAG memory, weekly fatigue, and session count in parallel
        guard exerciseIndex < trainingDay.exercises.count else {
            // Edge case: all exercises were already completed before pause
            await finishSession(earlyExitReason: nil)
            return
        }
        let currentExercise = trainingDay.exercises[exerciseIndex]
        async let streakFetch       = gymStreakService.computeStreak(userId: pausedState.userId)
        async let ragFetch          = fetchRAGMemory(for: currentExercise)
        async let fatigueFetch      = fetchWeeklyFatigue(userId: pausedState.userId)
        async let sessionCountFetch = fetchCompletedSessionCount(userId: pausedState.userId)
        async let lastPerfFetch     = fetchLastPerformance(
            for: currentExercise, userId: pausedState.userId, excludingSessionId: pausedState.sessionId
        )
        cachedStreakResult          = await streakFetch
        cachedRAGMemory            = await ragFetch
        cachedWeeklyFatigue = await fatigueFetch
        cachedTotalSessionCount    = await sessionCountFetch
        if let lastPerf = await lastPerfFetch {
            cachedLastPerformance[currentExercise.exerciseId] = lastPerf
        }

        print("[WorkoutSessionManager] resumeSession ✓ — sessionId: \(pausedState.sessionId), exerciseIndex: \(exerciseIndex), setNumber: \(currentSetNumber)")

        // Fire inference for the current exercise/set
        await triggerInference(for: currentExercise, setNumber: currentSetNumber)
    }

    /// Rebuilds the sessionHistoryToday array from set logs for exercises before `upToExerciseIndex`.
    private func reconstructSessionHistory(
        from setLogs: [SetLog],
        exercises: [PlannedExercise],
        upToExerciseIndex: Int
    ) -> [ExerciseHistoryItem] {
        exercises.prefix(upToExerciseIndex).map { exercise in
            let sets = setLogs
                .filter { $0.exerciseId == exercise.exerciseId }
                .map { $0.toCompletedSet(daysAgo: 0) }
            return ExerciseHistoryItem(exerciseName: exercise.name, sets: sets)
        }
    }

    /// Resets the session state to .idle. Called after the user dismisses PostWorkoutSummaryView.
    func resetToIdle() {
        restTimerTask?.cancel()
        restTimerTask = nil
        session = nil
        trainingDay = nil
        currentTrainingDayId = nil
        weekId = UUID()
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
        cachedWeeklyFatigue = nil
        cachedGymProfile = nil
        cachedLastPerformance = [:]
        swapRecords = []
        inflightRequestCount = 0
        inferenceGeneration = 0
        isFinishingSession = false   // #369 [8] — clean slate for the next session
        currentPrescription = nil
        currentFallbackReason = nil
        inferenceRetryNeeded = false
        inferenceRetryReason = nil
        pendingRetryExercise = nil
        pendingRetrySetNumber = 0
        restSecondsRemaining = 0
        restExpiresAt = nil
        sessionState = .idle
    }

    // MARK: - Exercise Swap (P3-T10)

    /// Builds a SwapContext snapshot from the current actor state for ExerciseSwapService.
    func buildSwapContext() -> ExerciseSwapService.SwapContext? {
        guard let day = trainingDay,
              exerciseIndex < day.exercises.count else { return nil }

        let currentExercise = day.exercises[exerciseIndex]
        let completedExerciseIds = day.exercises
            .prefix(exerciseIndex)
            .map(\.exerciseId)

        let availableEquipment = cachedGymProfile?.equipment.map { $0.equipmentType.typeKey } ?? []

        let ragSnippets = cachedRAGMemory.prefix(3).map(\.summary)

        return ExerciseSwapService.SwapContext(
            exerciseName: currentExercise.name,
            equipmentTypeKey: currentExercise.equipmentRequired.typeKey,
            primaryMuscle: currentExercise.primaryMuscle,
            setsCompleted: currentSetNumber - 1,
            totalSets: currentExercise.sets,
            availableEquipment: availableEquipment,
            completedExerciseIds: completedExerciseIds,
            ragMemory: Array(ragSnippets)
        )
    }

    /// Replaces the current exercise with the AI-suggested one and fires inference for set 1.
    func swapExercise(
        suggestion: ExerciseSwapService.ExerciseSuggestion,
        reason: String
    ) async {
        guard var day = trainingDay,
              exerciseIndex < day.exercises.count,
              let sess = session else { return }

        let oldExercise = day.exercises[exerciseIndex]

        // Build a PlannedExercise from the suggestion, inheriting rep/set structure from the old one
        let newExercise = PlannedExercise(
            id: UUID(),
            exerciseId: suggestion.exerciseId,
            name: suggestion.name,
            primaryMuscle: oldExercise.primaryMuscle,
            synergists: oldExercise.synergists,
            equipmentRequired: EquipmentType(typeKey: suggestion.equipmentRequired),
            sets: oldExercise.sets,
            repRange: oldExercise.repRange,
            tempo: oldExercise.tempo,
            restSeconds: oldExercise.restSeconds,
            rirTarget: oldExercise.rirTarget,
            coachingCues: []
        )

        // Replace the exercise in the training day
        day.exercises[exerciseIndex] = newExercise
        trainingDay = day

        // Record the swap
        swapRecords.append(SwapRecord(
            originalExerciseId: oldExercise.exerciseId,
            originalExerciseName: oldExercise.name,
            newExerciseId: suggestion.exerciseId,
            newExerciseName: suggestion.name,
            reason: reason,
            setsCompletedBeforeSwap: currentSetNumber - 1,
            swappedAt: Date()
        ))

        // Reset set counter for the new exercise
        currentSetNumber = 1
        currentPrescription = nil
        inferenceRetryNeeded = false

        // #369 [21] — bump the generation BEFORE firing inference for the swapped-in
        // exercise. A swap changes "what we're inferring for" mid-session: an inference
        // Task for the OLD exercise may still be in flight, having captured the prior
        // generation. Bumping here means that stale result is rejected by the guard in
        // handleInferenceResult when it returns, instead of clobbering the new
        // exercise's prescription. Mirrors completeSet()/skipCurrentSet().
        inferenceGeneration += 1

        // Embed a memory event so the AI learns about the swap
        let userId = sess.userId.uuidString
        let sessionId = sess.id.uuidString
        let swapText = "\(oldExercise.name) swapped to \(suggestion.name) — reason: \(reason)"
        Task.detached { [memoryService, swapText, sessionId, userId] in
            await memoryService.embed(
                text: swapText,
                sessionId: sessionId,
                tags: ["exercise_swap"],
                userId: userId
            )
        }

        // Prefetch RAG memory for the new exercise and fire inference for set 1
        sessionState = .preflight
        cachedRAGMemory = await fetchRAGMemory(for: newExercise)
        // #318 U7: a swap is an exercise transition too — refresh last-session
        // history so the clamp anchor and "Last time" line cover the new exercise.
        await refreshLastPerformance(for: newExercise)
        await triggerInference(for: newExercise, setNumber: 1)
    }

    /// Skips the remaining rest time and immediately transitions to the next active set,
    /// provided a prescription is ready. If inference is still in-flight, the transition
    /// will complete when the prescription arrives (same logic as timer expiry at 0).
    func skipRest() {
        guard case .resting(let nextExercise, let nextSetNumber) = sessionState else { return }
        restTimerTask?.cancel()
        restTimerTask = nil
        restSecondsRemaining = 0
        if currentPrescription != nil {
            // Prescription is ready — advance immediately.
            sessionState = .active(exercise: nextExercise, setNumber: nextSetNumber)
        } else if currentFallbackReason != nil {
            // Inference failed — show retry sheet instead of advancing.
            inferenceRetryNeeded = true
        }
        // If inference still in-flight, handleInferenceResult() will complete the transition.
    }

    // MARK: - Context Assembly

    /// Assembles the full `WorkoutContext` from current in-memory session state.
    /// Populates all fields required by the AI inference pipeline, including
    /// GymFactStore weight constraints for the current exercise's equipment type.
    func assembleWorkoutContext(
        exercise: PlannedExercise,
        setNumber: Int
    ) async -> WorkoutContext {
        let sess = session ?? WorkoutSession(
            id: UUID(), userId: UUID(), programId: UUID(),
            sessionDate: Date(), weekNumber: 1, dayType: "",
            completed: false, status: nil, setLogs: [], sessionNotes: [], summary: nil
        )

        // Use the Supabase-derived session count fetched at session start (FB-005 fix).
        // cachedTotalSessionCount is populated by fetchCompletedSessionCount() during
        // the parallel preflight in startSession(). It reflects the real completed-session
        // count from the database and survives reinstalls — unlike the UserDefaults counter
        // which starts at 0 on every fresh install.
        let totalSessionCount = cachedTotalSessionCount
        let metadata = SessionMetadata(
            sessionId: sess.id.uuidString,
            startedAt: sess.sessionDate,
            programName: nil,                               // Populated by WorkoutViewModel in future
            dayLabel: sess.dayType.isEmpty ? nil : sess.dayType,
            weekNumber: sess.weekNumber > 0 ? sess.weekNumber : nil,
            totalSessionCount: totalSessionCount
        )

        // Look up the bodyweightOnly flag from the cached GymProfile snapshot.
        let isBodyweightOnly: Bool = {
            if let profile = cachedGymProfile,
               let item = profile.item(for: exercise.equipmentRequired) {
                return item.bodyweightOnly
            }
            // Fallback: use the type's natural default (covers resume path if profile not cached).
            return exercise.equipmentRequired.isNaturallyBodyweightOnly
        }()

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
            secondaryMuscles: exercise.synergists,
            bodyweightOnly: isBodyweightOnly ? true : nil
        )

        let currentExSets = completedSets
            .filter { $0.exerciseId == exercise.exerciseId }
            .map { $0.toCompletedSet(daysAgo: 0) }

        // within_session_performance: all prior sets for this exercise (FB-006)
        let withinSessionSets = completedSets
            .filter { $0.exerciseId == exercise.exerciseId }
            .map { $0.toCompletedSet(daysAgo: 0) }

        // Read confirmed unavailable weights for this equipment type from GymFactStore.
        // These are injected as hard constraints so the AI never prescribes unavailable loads.
        let gymFacts = await gymFactStore.contextStrings(for: exercise.equipmentRequired)

        // Trainee-model projection (B1 / #86, B4 / #89). Weekly fatigue is now
        // routed through the digest's weeklyFatigue field per (α)+(I); cache
        // can be nil on Supabase fetch error → digest substitutes empty struct.
        let traineeModelDigest = await traineeModelService?.digest(
            weeklyFatigue: cachedWeeklyFatigue
        )

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
            ragRetrievedMemory: cachedRAGMemory,
            sessionLog: buildSessionLog(),
            gymWeightFacts: gymFacts.isEmpty ? nil : gymFacts,
            traineeModelDigest: traineeModelDigest
        )
    }

    // MARK: - Private Helpers

    /// Fires the initial AI inference for a new exercise/set and transitions
    /// state to `.active` when the result arrives.
    private func triggerInference(for exercise: PlannedExercise, setNumber: Int) async {
        inflightRequestCount += 1
        let generation = inferenceGeneration
        let context = await assembleWorkoutContext(exercise: exercise, setNumber: setNumber)

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
    ) async {
        guard generation == inferenceGeneration else {
            // Stale result — a newer completeSet() has already advanced the generation.
            return
        }

        switch result {
        case .success(let rawPrescription):
            // #318 U7: snap → clamp → marker (G-F8 + G-F3) — the single shared
            // post-processor for LLM prescriptions (also used by retryInference).
            var prescription = await postProcessPrescription(rawPrescription, for: targetExercise)
            // Re-check the reentrancy guard after the await: postProcessPrescription
            // suspends on GymFactStore, and a newer completeSet() may have advanced
            // the generation during that hop.
            guard generation == inferenceGeneration else { return }
            // Safety gate (TDD §7.2 acceptance criteria):
            // if safetyFlags contains .painReported → rest ≥ 180 s
            if prescription.safetyFlags.contains(.painReported) {
                prescription.restSeconds = max(prescription.restSeconds, 180)
                extendRestTimer(to: prescription.restSeconds)
            }
            currentPrescription = prescription
            currentFallbackReason = nil
            // Clear any pending retry state — prescription arrived successfully
            inferenceRetryNeeded = false
            inferenceRetryReason = nil
            pendingRetryExercise = nil
            pendingRetrySetNumber = 0

        case .fallback(let reason):
            // No silent fallback — store failure state and let the user choose.
            currentFallbackReason = reason
            inferenceRetryReason = reason
            pendingRetryExercise = targetExercise
            pendingRetrySetNumber = targetSetNumber
            // currentPrescription stays nil — the retry sheet will be shown.
        }

        // Transition .preflight → .active (first set) or
        // .resting → .active (if rest already elapsed).
        // Only advance if we have a prescription; otherwise surface the retry sheet.
        switch sessionState {
        case .preflight:
            if currentPrescription != nil {
                sessionState = .active(exercise: targetExercise, setNumber: targetSetNumber)
            } else if currentFallbackReason != nil {
                // Inference failed before rest started — show retry sheet immediately.
                inferenceRetryNeeded = true
            }
        case .resting:
            if let prescription = currentPrescription {
                _ = prescription   // prescription is ready
                if restSecondsRemaining <= 0 {
                    sessionState = .active(exercise: targetExercise, setNumber: targetSetNumber)
                }
                // If rest still running, onRestTimerExpired() will complete the transition.
            } else if currentFallbackReason != nil {
                // Inference failed during rest period.
                if restSecondsRemaining <= 0 {
                    // Rest already expired — show retry sheet now.
                    inferenceRetryNeeded = true
                }
                // If rest still running, do nothing — onRestTimerExpired() handles it.
            }
        case .active:
            // Post-skip path (#318 / U5): skipCurrentSet() moves straight to
            // .active with a nil prescription. On success the prescription was
            // applied above and the card appears; on failure surface the retry
            // sheet now — there is no rest timer on this path to defer to.
            if currentPrescription == nil && currentFallbackReason != nil {
                inferenceRetryNeeded = true
            }
        default:
            break
        }
    }

    private func decrementInflight() {
        inflightRequestCount = max(0, inflightRequestCount - 1)
    }

    /// Starts the rest-period countdown timer using absolute time anchoring.
    ///
    /// The expiry time is stored so RestTimerView can snap to the correct
    /// remaining value after the app returns from background — the OS may
    /// suspend Task.sleep but the expiry date is always correct.
    ///
    /// When it reaches zero, transitions state from `.resting` to `.active`
    /// (or triggers `endSession()` if this was the final exercise).
    private func startRestTimer(duration: Int, isSessionEnd: Bool) {
        restTimerTask?.cancel()
        let expiresAt = Date().addingTimeInterval(TimeInterval(duration))
        restExpiresAt = expiresAt
        restSecondsRemaining = duration

        restTimerTask = Task { [weak self] in
            guard let self else { return }
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)  // tick every 0.5 s
                if Task.isCancelled { return }
                let remaining = max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
                await self.tickRestTimer(remaining)
                if remaining <= 0 { break }
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

        if let prescription = currentPrescription {
            _ = prescription
            // Prescription is ready — advance to active immediately.
            sessionState = .active(exercise: nextExercise, setNumber: nextSetNumber)
        } else if currentFallbackReason != nil {
            // Inference failed and rest has now expired — surface retry sheet.
            inferenceRetryNeeded = true
        }
        // If inference is still in-flight (no fallback reason), handleInferenceResult()
        // will see restSecondsRemaining == 0 and complete the transition itself.
    }

    /// Extends the rest timer duration. Per TDD §7.4, rest can only be extended, never shortened.
    private func extendRestTimer(to newDuration: Int) {
        guard newDuration > targetRestSeconds else { return }
        let elapsed = targetRestSeconds - restSecondsRemaining
        let newRemaining = max(newDuration - elapsed, 0)
        targetRestSeconds = newDuration
        restSecondsRemaining = newRemaining
        // Shift the absolute expiry forward to match the extended duration.
        restExpiresAt = Date().addingTimeInterval(TimeInterval(newRemaining))
    }

    private func buildExerciseHistoryItem(for exercise: PlannedExercise) -> ExerciseHistoryItem {
        let sets = completedSets
            .filter { $0.exerciseId == exercise.exerciseId }
            .map { $0.toCompletedSet(daysAgo: 0) }
        return ExerciseHistoryItem(exerciseName: exercise.name, sets: sets)
    }

    /// Builds the append-only session log from all sets completed so far this session.
    /// Each entry describes what was prescribed vs what the user actually did (FB-009).
    private func buildSessionLog() -> [SessionLogEntry] {
        completedSets.map { log in
            let prescribed = log.aiPrescribed
            let prescribedReps = prescribed?.reps ?? 0
            let actualReps = log.repsCompleted
            let targetReps = prescribedReps > 0 ? prescribedReps : 1
            let completionPct = Double(actualReps) / Double(targetReps)
            let outcomeNote: String
            if actualReps >= targetReps {
                let e1RMNow    = log.weightKg * (1.0 + Double(actualReps) / 30.0)
                let priorBest  = completedSets
                    .filter { $0.exerciseId == log.exerciseId && $0.id != log.id }
                    .map { $0.weightKg * (1.0 + Double($0.repsCompleted) / 30.0) }
                    .max() ?? 0
                outcomeNote = e1RMNow > priorBest ? "pr" : "completed"
            } else if completionPct >= 0.80 {
                outcomeNote = "near_miss"
            } else if completionPct >= 0.60 {
                outcomeNote = "moderate_miss"
            } else {
                outcomeNote = "significant_miss"
            }
            // Resolve exercise name from trainingDay; fall back to exerciseId
            let exerciseName = trainingDay?.exercises
                .first(where: { $0.exerciseId == log.exerciseId })?.name ?? log.exerciseId
            return SessionLogEntry(
                exercise: exerciseName,
                setNumber: log.setNumber,
                prescribedWeightKg: prescribed?.weightKg ?? log.weightKg,
                prescribedReps: prescribedReps,
                actualReps: actualReps,
                rpe: log.rpeFelt.map(Double.init),
                outcomeNote: outcomeNote
            )
        }
    }

    /// Fetches the number of completed sessions from Supabase for `userId`.
    ///
    /// This is the source-of-truth count used to determine `is_first_session` in the
    /// AI coaching context (FB-005). Unlike the UserDefaults counter, this survives
    /// reinstalls and manual log entries.
    ///
    /// Falls back to the UserDefaults counter if the network call fails so that
    /// offline-first sessions degrade gracefully.
    private func fetchCompletedSessionCount(userId: UUID) async -> Int {
        do {
            // Use select:"id" to fetch only the primary key — avoids pulling
            // ai_prescribed JSONB payloads for potentially many rows.
            struct SessionIdRow: Decodable { let id: UUID }
            let rows: [SessionIdRow] = try await supabase.fetch(
                SessionIdRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",   op: .eq,  value: userId.uuidString),
                    Filter(column: "completed", op: .is,  value: "true")
                ],
                select: "id"
            )
            return rows.count
        } catch {
            // Network or decode failure — fall back to local counter.
            let local = UserDefaults.standard.integer(forKey: UserProfileConstants.sessionCountKey)
            print("[WorkoutSessionManager] fetchCompletedSessionCount failed (\(error.localizedDescription)); falling back to UserDefaults count: \(local)")
            return local
        }
    }

    /// Fetches recent set logs from Supabase and computes the rolling 7-day
    /// fatigue projection using `WeekFatigueSignals.compute`. Called once at
    /// session start (and again on resume) and stored in `cachedWeeklyFatigue`.
    ///
    /// B4 (#89): rewritten under (α)+(I) to produce the canonical
    /// `WeekFatigueSignals` shape that the digest carries. Session count for
    /// the week is derived from distinct session_ids in the fetched logs.
    private func fetchWeeklyFatigue(userId: UUID) async -> WeekFatigueSignals? {
        let sevenDaysAgo = ISO8601DateFormatter().string(
            from: Date(timeIntervalSinceNow: -7 * 24 * 3600)
        )
        do {
            // set_logs has no user_id column — it is keyed by session_id
            // (FK → workout_sessions). The prior single-query filter on
            // set_logs.user_id returned HTTP 400 (#186), silently swallowed
            // here so weekly fatigue was never populated. Two-query pattern
            // (mirrors ProgressViewModel / ProgramViewModel): resolve the
            // user's recent sessions, then fetch their set_logs by session_id.
            // No `completed` filter — fatigue counts all recent logged work,
            // matching the original logged_at-window semantics (and avoiding
            // the #171 completion-drift undercount).
            struct SessionIdRow: Decodable { let id: UUID }
            let sessionRows: [SessionIdRow] = try await supabase.fetch(
                SessionIdRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",      op: .eq,  value: userId.uuidString),
                    Filter(column: "session_date", op: .gte, value: sevenDaysAgo)
                ],
                select: "id"
            )
            guard !sessionRows.isEmpty else {
                return WeekFatigueSignals.compute(from: [], sessionCount: 0)
            }
            let sessionIds = sessionRows.map { $0.id.uuidString }.joined(separator: ",")
            let recentLogs: [SetLog] = try await supabase.fetch(
                SetLog.self,
                table: "set_logs",
                filters: [
                    Filter(column: "session_id", op: .in,  value: "(\(sessionIds))"),
                    Filter(column: "logged_at",  op: .gte, value: sevenDaysAgo)
                ]
            )
            let sessionCount = Set(recentLogs.map(\.sessionId)).count
            return WeekFatigueSignals.compute(from: recentLogs, sessionCount: sessionCount)
        } catch {
            return nil
        }
    }

    /// Fetches the top-K most relevant memory items for `exercise` via the
    /// MemoryService RAG read path (TDD §9.2).
    private func fetchRAGMemory(for exercise: PlannedExercise) async -> [RAGMemoryItem] {
        guard let sess = session else { return [] }
        let queryText = ([exercise.name, exercise.primaryMuscle] + exercise.synergists).joined(separator: " ")
        return await memoryService.retrieveMemory(
            queryText: queryText,
            userId: sess.userId.uuidString,
            threshold: 0.60
        )
    }

    // MARK: - Prescription Guardrails (#318 U7 / G-F8, G-F3, G-F6, G-F1)

    /// Last-session set logs for `exerciseId`, if cached. Read by
    /// WorkoutViewModel to render the "Last time" line (G-F6) and to gate
    /// the manual-fallback affordance (G-F1).
    func lastPerformance(for exerciseId: String) -> [SetLog]? {
        cachedLastPerformance[exerciseId]
    }

    /// #369 [20] — returns every field `WorkoutViewModel.pullState()` needs in ONE
    /// actor hop, so the published UI state is internally consistent. The liveExercise
    /// derivation (and its `lastPerformance` lookup) mirror the prior pullState logic
    /// exactly — during .active/.resting the live exercise is the one in the state;
    /// otherwise it is the pending-retry exercise (relevant during .preflight, where
    /// the manual-fallback path targets pendingRetryExercise).
    func uiSnapshot() -> WorkoutUISnapshot {
        let liveExercise: PlannedExercise?
        switch sessionState {
        case .active(let exercise, _), .resting(let exercise, _):
            liveExercise = exercise
        default:
            liveExercise = pendingRetryExercise
        }
        let lastPerformanceSets: [SetLog]? = liveExercise.flatMap { cachedLastPerformance[$0.exerciseId] }

        return WorkoutUISnapshot(
            sessionState: sessionState,
            currentPrescription: currentPrescription,
            currentFallbackReason: currentFallbackReason,
            restSecondsRemaining: restSecondsRemaining,
            restExpiresAt: restExpiresAt,
            completedSets: completedSets,
            inferenceRetryNeeded: inferenceRetryNeeded,
            inferenceRetryReason: inferenceRetryReason,
            pendingRetryExercise: pendingRetryExercise,
            lastPerformanceSets: lastPerformanceSets
        )
    }

    /// Refreshes `cachedLastPerformance` for `exercise`. Called at session
    /// start and at EVERY exercise transition: next exercise in completeSet,
    /// skip into a new exercise, swapExercise, and resume.
    private func refreshLastPerformance(for exercise: PlannedExercise) async {
        guard let sess = session else { return }
        if let sets = await fetchLastPerformance(
            for: exercise, userId: sess.userId, excludingSessionId: sess.id
        ) {
            cachedLastPerformance[exercise.exerciseId] = sets
        }
    }

    /// Fetches the most recent prior session's set logs for `exercise`.
    /// Two-step query mirroring `fetchHistoricalTopSets` — set_logs has no
    /// user_id column: resolve the user's recent non-abandoned sessions
    /// (excluding the current one), then fetch set_logs for those ids
    /// filtered to this exercise, keeping only the newest session that has
    /// any. Best-effort: failure returns nil — no anchor, the clamp is
    /// skipped, the "Last time" line stays hidden; never blocks the session.
    private func fetchLastPerformance(
        for exercise: PlannedExercise,
        userId: UUID,
        excludingSessionId: UUID
    ) async -> [SetLog]? {
        do {
            struct SessionIdRow: Decodable { let id: UUID }
            let sessionRows: [SessionIdRow] = try await supabase.fetch(
                SessionIdRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id", op: .eq,  value: userId.uuidString),
                    Filter(column: "status",  op: .neq, value: "abandoned"),
                    Filter(column: "id",      op: .neq, value: excludingSessionId.uuidString)
                ],
                order: "session_date.desc",
                limit: 20,
                select: "id"
            )
            guard !sessionRows.isEmpty else { return nil }
            let orderedIds = sessionRows.map(\.id)
            let idList = orderedIds.map(\.uuidString).joined(separator: ",")
            let logs: [SetLog] = try await supabase.fetch(
                SetLog.self,
                table: "set_logs",
                filters: [
                    Filter(column: "session_id",  op: .in, value: "(\(idList))"),
                    Filter(column: "exercise_id", op: .eq, value: exercise.exerciseId)
                ]
            )
            let bySession = Dictionary(grouping: logs, by: \.sessionId)
            guard let lastSessionId = orderedIds.first(where: { bySession[$0] != nil }),
                  let lastSets = bySession[lastSessionId]
            else { return nil }
            return lastSets.sorted { $0.setNumber < $1.setNumber }
        } catch {
            print("[WorkoutSessionManager] fetchLastPerformance failed (\(error.localizedDescription)) — no last-session history for \(exercise.exerciseId)")
            return nil
        }
    }

    /// G-F3 clamp anchor: the last session's top-set weight — heaviest cached
    /// last-session set with reps in 3...10. Nil when there is no usable
    /// history (first session, fetch failure, bodyweight-only history) — the
    /// clamp is then skipped entirely so calibration stays free.
    private func clampAnchorWeight(for exerciseId: String) -> Double? {
        cachedLastPerformance[exerciseId]?
            .filter { (3...10).contains($0.repsCompleted) && $0.weightKg > 0 }
            .map(\.weightKg)
            .max()
    }

    /// G-F1 fallback seed: heaviest last-session set regardless of reps.
    /// Nil for genuine bodyweight history (all 0 kg) or no history — the
    /// manual fallback then keeps its 0.0 default.
    private func historySeedWeight(for exerciseId: String) -> Double? {
        cachedLastPerformance[exerciseId]?
            .map(\.weightKg)
            .filter { $0 > 0 }
            .max()
    }

    /// #318 U7 spine: the ONE snap → clamp → marker post-processor that every
    /// LLM-produced prescription routes through. handleInferenceResult success
    /// and retryInference success are the only two live paths that set
    /// currentPrescription from an LLM result — both call this. The marker is
    /// appended AFTER validate() ran inside AIInferenceService; nothing
    /// re-validates on decode, so the ≤200-char reasoning rule is unaffected.
    private func postProcessPrescription(
        _ rx: SetPrescription,
        for exercise: PlannedExercise
    ) async -> SetPrescription {
        let equipment = exercise.equipmentRequired
        let excluded = await gymFactStore.facts
            .filter { $0.equipmentType == equipment }
            .map(\.unavailableWeight)
        let anchor = clampAnchorWeight(for: exercise.exerciseId)
        guard let adjustment = Self.adjustedWeight(
            rawWeight: rx.weightKg,
            intent: rx.intent,
            equipment: equipment,
            excludedWeights: excluded,
            anchorWeight: anchor
        ) else { return rx }

        // Raw→adjusted telemetry (#318 U7) — print only, no new schema field.
        print("[WorkoutSessionManager] Prescription weight adjusted — raw: \(rx.weightKg)kg, snapped: \(adjustment.snapped)kg, clamped: \(adjustment.clamped)kg (\(exercise.name), anchor: \(anchor.map { "\($0)kg" } ?? "none"))")

        var adjusted = rx
        adjusted.weightKg = adjustment.clamped
        adjusted.reasoning += Self.weightAdjustmentMarker(for: adjustment.clamped)
        return adjusted
    }

    /// Pure snap → clamp core (#318 U7). Returns nil when the weight needs no
    /// adjustment; otherwise both intermediate values for telemetry.
    ///
    /// Snap (G-F8): PRD §7.1.1 via DefaultWeightIncrements.snap — applies only
    /// when the equipment has a weight table, weight > 0, and the weight is
    /// not already available (epsilon membership; GymFactStore exclusions
    /// honoured).
    /// Clamp (G-F3): upward cap ONLY, intents .top/.backoff ONLY —
    /// final ≤ snapDown(anchor × 1.15), re-snapped so the stored weight is a
    /// real available weight. No anchor (first session, no history) ⇒ no
    /// clamp. A low prescription is never raised.
    nonisolated static func adjustedWeight(
        rawWeight: Double,
        intent: SetIntent?,
        equipment: EquipmentType,
        excludedWeights: [Double],
        anchorWeight: Double?
    ) -> (snapped: Double, clamped: Double)? {
        let snapped = DefaultWeightIncrements.snap(
            rawWeight, for: equipment, excluding: excludedWeights
        ) ?? rawWeight

        var clamped = snapped
        if intent == .top || intent == .backoff,
           let anchor = anchorWeight, anchor > 0 {
            let cap = anchor * 1.15   // +15% per-session ceiling — accepted call
            if clamped > cap + 0.001 {
                // Re-snap the cap DOWN so the stored weight is still a real
                // available weight (raw cap only when the equipment has no
                // weight table at all).
                clamped = DefaultWeightIncrements.snapDown(
                    cap, for: equipment, excluding: excludedWeights
                ) ?? cap
            }
        }
        return abs(clamped - rawWeight) > 0.001 ? (snapped, clamped) : nil
    }

    /// Canonical adjusted-weight marker (#318 U7 / G-F8). Parsed verbatim by
    /// WorkoutViewModel.weightAdjustmentNote and rendered on ActiveSetView —
    /// the format must round-trip.
    nonisolated static func weightAdjustmentMarker(for kg: Double) -> String {
        let formatted = kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
        return " (adjusted to nearest available: \(formatted)kg)"
    }

    // MARK: - Personal Records (#318 U6 / G-F12)

    /// Fetches the user's historical top-intent set logs for PR comparison.
    /// Two-step query mirroring `fetchWeeklyFatigue` — set_logs has no
    /// user_id column, so resolve the user's recent non-abandoned sessions
    /// first, then fetch their set_logs filtered to `intent = top`. The
    /// current session is excluded so the baseline never includes the sets
    /// just logged (they may already be flushed via the WAQ).
    /// Best-effort: any failure returns empty history, which suppresses all
    /// PR claims (no baseline ⇒ no claim) — never blocks the summary.
    private func fetchHistoricalTopSets(userId: UUID?, excludingSessionId: UUID?) async -> [SetLog] {
        guard let userId else { return [] }
        do {
            struct SessionIdRow: Decodable { let id: UUID }
            var sessionFilters = [
                Filter(column: "user_id", op: .eq,  value: userId.uuidString),
                Filter(column: "status",  op: .neq, value: "abandoned")
            ]
            if let excludingSessionId {
                sessionFilters.append(Filter(column: "id", op: .neq, value: excludingSessionId.uuidString))
            }
            let sessionRows: [SessionIdRow] = try await supabase.fetch(
                SessionIdRow.self,
                table: "workout_sessions",
                filters: sessionFilters,
                order: "session_date.desc",
                limit: 50,
                select: "id"
            )
            guard !sessionRows.isEmpty else { return [] }
            let sessionIds = sessionRows.map { $0.id.uuidString }.joined(separator: ",")
            return try await supabase.fetch(
                SetLog.self,
                table: "set_logs",
                filters: [
                    Filter(column: "session_id", op: .in, value: "(\(sessionIds))"),
                    Filter(column: "intent",     op: .eq, value: SetIntent.top.rawValue)
                ]
            )
        } catch {
            print("[WorkoutSessionManager] fetchHistoricalTopSets failed (\(error.localizedDescription)) — treating as empty history")
            return []
        }
    }

    /// Pure PR computation. Per exercise: the session-best e1RM over the
    /// session's top sets with reps in 3...10, compared against the
    /// historical-best e1RM under the same rule. e1RM uses the existing
    /// Epley estimate (`weight × (1 + reps/30)`) shared with the in-session
    /// PR memory event and ProgressViewModel.
    ///
    /// Suppression rule: an exercise with ZERO historical top sets produces
    /// NO entry — `PersonalRecord.previousBest` is non-optional, and a
    /// first-ever session must not fabricate a "PR" against a 0.0 baseline.
    static func computePersonalRecords(
        sessionSets: [SetLog],
        historicalSets: [SetLog],
        exercises: [PlannedExercise]
    ) -> [PersonalRecord] {
        func e1RM(_ log: SetLog) -> Double {
            log.weightKg * (1.0 + Double(log.repsCompleted) / 30.0)
        }
        func isCandidate(_ log: SetLog) -> Bool {
            log.intent == .top && (3...10).contains(log.repsCompleted)
        }

        let namesById = Dictionary(
            exercises.map { ($0.exerciseId, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let historicalCandidates = historicalSets.filter(isCandidate)

        var records: [PersonalRecord] = []
        for (exerciseId, sets) in Dictionary(grouping: sessionSets.filter(isCandidate), by: \.exerciseId) {
            // No historical baseline ⇒ no claim ⇒ no entry (suppression rule).
            guard let previousBest = historicalCandidates
                .filter({ $0.exerciseId == exerciseId })
                .map(e1RM).max()
            else { continue }
            guard let sessionBest = sets.map(e1RM).max(), sessionBest > previousBest else { continue }
            records.append(PersonalRecord(
                exerciseId: exerciseId,
                exerciseName: namesById[exerciseId] ?? exerciseId,
                previousBest: previousBest,
                newBest: sessionBest,
                metric: .estimatedOneRM
            ))
        }
        return records.sorted { $0.exerciseName < $1.exerciseName }
    }

    // MARK: - Session Termination

    private func finishSession(earlyExitReason: String?) async {
        // #369 [8] — idempotency guard. endSession() (rest-timer Task, completeSet
        // last-set, skip last-set, resume edge case) and endSessionEarly() can both
        // reach here for the same session; the actor serialises them but each would
        // otherwise run the full body, double-incrementing the session count and
        // double-enqueueing the trainee-model update. Check-and-set on entry so the
        // side effects run exactly once. The latch is cleared when a fresh session
        // begins (startSession / resumeSession / resetToIdle).
        guard !isFinishingSession else {
            print("[WorkoutSessionManager] finishSession ignored — already finishing/finished")
            return
        }
        isFinishingSession = true

        // Clear crash sentinel — session ending normally or via early exit.
        // pauseSession() overwrites this instead of clearing it.
        PausedSessionState.clear()
        print("[WorkoutSessionManager] Session finished — crash sentinel cleared")

        restTimerTask?.cancel()
        restTimerTask = nil

        // PR history fetch (#318 U6 / G-F12) runs CONCURRENTLY with the WAQ
        // flush below so it adds no extra await to the summary gate. A failed
        // fetch resolves to empty history → personalRecords: [].
        async let historicalTopSets = fetchHistoricalTopSets(
            userId: session?.userId,
            excludingSessionId: session?.id
        )

        // Flush WAQ before PATCH so all set_logs are in Supabase before the session row
        // is marked completed. Mirrors pauseSession() and abandonSession() exactly.
        await writeAheadQueue.flush()

        guard var finalSession = session else {
            sessionState = .error("No active session to end.")
            return
        }

        // Guard: a session with no logged sets must not be saved as completed.
        // It advances the programme pointer and gives the AI nothing to learn from.
        // If this is an early-exit with zero sets, abort silently — the caller
        // (endSessionEarly) is responsible for showing the discard confirmation UI.
        if completedSets.isEmpty {
            print("[WorkoutSessionManager] finishSession aborted — no sets logged. Session will not be saved.")
            sessionState = .idle
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
        // Real PR detection (#318 U6 / G-F12): session-best e1RM vs the
        // historical best over top sets with 3–10 reps. The history fetch was
        // started concurrently with the WAQ flush above.
        let personalRecords = Self.computePersonalRecords(
            sessionSets: completedSets,
            historicalSets: await historicalTopSets,
            exercises: trainingDay?.exercises ?? []
        )
        let summary = SessionSummary(
            totalVolumeKg: totalVolume,
            setsCompleted: completedSets.count,
            setsPlanned: totalPlanned,
            personalRecords: personalRecords,
            aiAdjustmentCount: completedSets.filter { $0.aiPrescribed != nil }.count,
            notableNotes: sessionNotes.map(\.rawTranscript),
            earlyExitReason: earlyExitReason,
            durationSeconds: sessionDuration,
            swappedExercises: swapRecords.isEmpty ? nil : swapRecords
        )

        finalSession.completed = earlyExitReason == nil
        finalSession.summary = summary
        self.session = finalSession

        // Blocking write: patch workout_sessions with status + completed + summary (P3-T06 AC)
        // Must complete before PostWorkoutSummaryView is shown.
        // Keep (status, completed) internally consistent (#171): an early exit is
        // NOT a full completion, so don't hardcode status="completed" alongside
        // completed=false. Use "partial" — not "abandoned", since the deep
        // lift-history fetch excludes 'abandoned' but a partial session carries
        // real logged sets we want the model and history to see.
        let status = finalSession.completed ? "completed" : "partial"
        let patch = WorkoutSessionSummaryPatch(status: status, completed: finalSession.completed, summary: summary)
        let sessionId = finalSession.id
        print("[WorkoutSessionManager] Writing session completion — id: \(sessionId), completed: \(finalSession.completed), sets: \(completedSets.count)")
        do {
            try await writeAheadQueue.updateBlocking(patch, table: "workout_sessions", id: sessionId)
            print("[WorkoutSessionManager] Session completion write succeeded")
        } catch {
            // If the blocking write fails, enqueue it for retry
            print("[WorkoutSessionManager] Session completion write failed: \(error.localizedDescription) — enqueueing for retry")
            try? await writeAheadQueue.enqueue(patch, table: "workout_sessions")
        }

        // Producer side of the trainee-model update pipeline (#135). Fire for
        // ANY saved session, including early exits (#171). We only reach this
        // point when completedSets is non-empty (guard at the top of this
        // method), so the model always has real logged sets to learn from. The
        // Edge Function aggregates actual logged sets and never reads
        // workout_sessions.status/completed, so a partial session contributes
        // accurately instead of vanishing. Must run AFTER the PATCH so the
        // session row exists when the WAQ flush dispatches this item to the EF.
        if let traineeModelService {
            try? await traineeModelService.enqueueUpdate(forSession: finalSession, setLogs: completedSets)
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
        // Early-exit sessions count — the user trained and data was logged.
        let currentCount = UserDefaults.standard.integer(forKey: UserProfileConstants.sessionCountKey)
        UserDefaults.standard.set(currentCount + 1, forKey: UserProfileConstants.sessionCountKey)

        // Invalidate streak cache so the next session start re-fetches fresh data
        let sessionUserId = finalSession.userId
        Task.detached(priority: .utility) { [gymStreakService, sessionUserId] in
            await gymStreakService.invalidate(userId: sessionUserId)
        }

        // Stagnation signals + per-pattern phase advancement are now computed
        // server-side by the trainee-model pipeline (PatternProfile.trend per
        // ADR-0009 hybrid plateau verdict; PatternProfile.currentPhase per
        // ADR-0011 cyclic mesocycle) and surfaced via TraineeModelDigest.
        // The legacy client-side StagnationService + PatternPhaseService hooks
        // were removed in B1 (#86) and B3 (#88) respectively.
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
        // A 0-rep set (failed attempt) must never emit a PR event (#318 / U5):
        // weight × (1 + 0/30) still exceeds a 0.0 priorBest on the first set.
        guard log.repsCompleted > 0 else { return }
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
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId      = "user_id"
        case programId   = "program_id"
        case sessionDate = "session_date"
        case weekNumber  = "week_number"
        case dayType     = "day_type"
        case completed
        case status
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
        self.status = session.status
    }
}

/// PATCH payload used for pause/resume lifecycle transitions.
/// Only updates the status and completed flag — leaves all other columns untouched.
nonisolated struct WorkoutSessionStatusPatch: Encodable {
    let status: String
    let completed: Bool
}

// internal (not private): exposed for encoder regression tests (#66).
nonisolated struct SetLogPayload: Encodable {
    let id: String
    let sessionId: String
    let exerciseId: String
    let setNumber: Int
    let weightKg: Double
    let repsCompleted: Int
    let rpeFelt: Int?
    let rirEstimated: Int?
    let loggedAt: String
    let primaryMuscle: String?
    let localDate: String
    let intent: String

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
        case primaryMuscle = "primary_muscle"
        case localDate     = "local_date"
        case intent
    }

    /// Slice 6 / #60 fix: intent is required by the schema (NOT NULL, no
    /// default). local_date is required by the schema (NOT NULL with a
    /// backfill-only sentinel default that this writer must not rely on,
    /// per #63). Intent is a required parameter (compiler-enforced) rather
    /// than read off the SetLog optional, so callers cannot silently fall
    /// back to nil — ADR-0005 "no silent defaults at any layer."
    init(from log: SetLog, intent: SetIntent) {
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
        self.primaryMuscle = log.primaryMuscle
        self.localDate = SetLog.formatLocalDate(log.loggedAt)
        self.intent = intent.rawValue
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
    let status: String
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
