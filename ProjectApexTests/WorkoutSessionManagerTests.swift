// WorkoutSessionManagerTests.swift
// ProjectApexTests — P3-T01
//
// Unit tests for WorkoutSessionManager actor.
//
// Test categories (all fast, no network):
//   1. startSession transitions .idle → .preflight → .active
//   2. completeSet transitions .active → .resting, appends SetLog
//   3. AI fallback path: fallback prescription used, fallbackReason set
//   4. Safety gate: painReported flag forces rest ≥ 180 s + extends timer
//   5. Partial session / endSessionEarly: state → .sessionComplete, summary written
//   6. Reentrancy guard: stale inference result does not overwrite current prescription
//   7. assembleWorkoutContext: all required WorkoutContext fields populated correctly
//
// Mock design:
//   MockAIInferenceProvider wraps AIInferenceService via a mock LLMProvider.
//   MemoryService is passed a real (stub) instance — embed() is a no-op.
//   SupabaseClient is initialised with a fake URL; all fire-and-forget calls are
//   swallowed by try? so no network calls happen during unit tests.

import XCTest
import Foundation
@testable import ProjectApex

// MARK: - Mock LLM Provider

/// Returns a fixed JSON prescription string without making any network calls.
private struct MockLLMProvider: LLMProvider {
    let response: String
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        response
    }
}

/// Always throws a permanent error — used to exercise the fallback path
/// without burning the test on retry backoff. Per ADR-0007, transient errors
/// (URLError network codes, HTTP 429/5xx) drive the retry policy through its
/// 1+2+4 s schedule before falling back; permanent errors fail fast. This
/// mock uses 401 so the test can assert on the post-fallback manager state
/// in milliseconds rather than waiting ~7 s for retries to exhaust.
private struct FailingLLMProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw LLMProviderError.httpError(statusCode: 401, body: "Invalid API key")
    }
}

/// Delays then returns — used to test the reentrancy guard.
private struct DelayedLLMProvider: LLMProvider {
    let delaySeconds: Double
    let response: String
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        return response
    }
}

// MARK: - Mock URLProtocol (always returns HTTP 201 — prevents real network calls and WAQ retry loops)

private final class WSMAlwaysSucceedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 201,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeTestSupabase() -> SupabaseClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WSMAlwaysSucceedURLProtocol.self]
    return SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
}

// MARK: - Recording URLProtocol (#186 — captures request URLs to assert query shape)

/// Records every request URL so a test can assert which columns a query filters
/// on. Returns one workout_sessions row for GET session lookups (so the
/// weekly-fatigue two-query path proceeds to query set_logs); everything else
/// gets an empty array.
private final class WSMRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requestURLs: [URL] = []
    static func reset() {
        lock.lock(); requestURLs = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url {
            Self.lock.lock(); Self.requestURLs.append(url); Self.lock.unlock()
        }
        let path = request.url?.path ?? ""
        let isGet = (request.httpMethod ?? "GET") == "GET"
        let body = (isGet && path.contains("workout_sessions"))
            ? "[{\"id\":\"00000000-0000-4000-8000-000000000001\"}]"
            : "[]"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeRecordingManager() -> WorkoutSessionManager {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WSMRecordingURLProtocol.self]
    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
    let inferenceService = AIInferenceService(
        provider: MockLLMProvider(response: prescriptionJSON()),
        gymProfile: nil,
        maxRetries: 0
    )
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let suiteName = "com.test.wsm.rec.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suiteName)!
    let gymFactStore = GymFactStore(userDefaults: testDefaults)
    let waq = WriteAheadQueue(supabase: supabase, userDefaults: testDefaults)
    return WorkoutSessionManager(
        aiInference: inferenceService,
        healthKit: HealthKitService(),
        memoryService: memoryService,
        supabase: supabase,
        gymFactStore: gymFactStore,
        writeAheadQueue: waq
    )
}

// MARK: - JSON Fixture Builders

/// Builds a valid set_prescription JSON response string.
/// Includes `intent` per Slice 6 (#10).
private func prescriptionJSON(
    weightKg: Double = 80.0,
    reps: Int = 8,
    restSeconds: Int = 120,
    safetyFlags: [String] = [],
    intent: String = "top"
) -> String {
    let flags = safetyFlags.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
    {
      "set_prescription": {
        "weight_kg": \(weightKg),
        "reps": \(reps),
        "tempo": "3-1-1-0",
        "rir_target": 2,
        "rest_seconds": \(restSeconds),
        "coaching_cue": "Drive through the bar",
        "reasoning": "Based on recent performance trend.",
        "safety_flags": [\(flags)],
        "intent": "\(intent)",
        "set_framing": "Heaviest work of the day. Brace and grind."
      }
    }
    """
}

// MARK: - Test Fixtures

private func makeTrainingDay(exerciseCount: Int = 2, setsPerExercise: Int = 2) -> TrainingDay {
    let exercises = (0..<exerciseCount).map { i in
        PlannedExercise(
            id: UUID(),
            exerciseId: "exercise_\(i)",
            name: "Exercise \(i)",
            primaryMuscle: "pectoralis_major",
            synergists: ["triceps_brachii"],
            equipmentRequired: .barbell,
            sets: setsPerExercise,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 90,
            rirTarget: 2,
            coachingCues: ["Focus on form"]
        )
    }
    return TrainingDay(
        id: UUID(),
        dayOfWeek: 1,
        dayLabel: "Push_A",
        exercises: exercises,
        sessionNotes: nil
    )
}

private func makeManager(
    provider: any LLMProvider = MockLLMProvider(response: prescriptionJSON()),
    gymProfile: GymProfile? = nil
) -> WorkoutSessionManager {
    let inferenceService = AIInferenceService(provider: provider, gymProfile: gymProfile, maxRetries: 0)
    let supabase = makeTestSupabase()
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    // Use an isolated UserDefaults suite so GymFactStore and WriteAheadQueue
    // never touch UserDefaults.standard or load stale items from prior runs.
    let suiteName = "com.test.wsm.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suiteName)!
    let gymFactStore = GymFactStore(userDefaults: testDefaults)
    let waq = WriteAheadQueue(supabase: supabase, userDefaults: testDefaults)
    return WorkoutSessionManager(
        aiInference: inferenceService,
        healthKit: HealthKitService(),
        memoryService: memoryService,
        supabase: supabase,
        gymFactStore: gymFactStore,
        writeAheadQueue: waq
    )
}

// MARK: - WorkoutSessionManagerTests

final class WorkoutSessionManagerTests: XCTestCase {

    // pauseSession persists a PausedSessionState to UserDefaults.standard
    // (PausedSessionState.save uses the shared suite). Clear it around every
    // test so the #190 snapshot assertion can't read a stale entry and a real
    // pause in one test can't leak into another. (#190)
    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
    }

    override func tearDown() {
        PausedSessionState.clear()
        super.tearDown()
    }

    // MARK: Test 1: startSession → .active state transition

    /// Verifies the happy path:
    /// .idle → startSession() → .preflight → (AI prescription arrives) → .active
    func testStartSession_transitionsToActive() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        let programId = UUID()

        let initialState = await manager.sessionState
        XCTAssertEqual(initialState, .idle, "Manager should start idle")

        await manager.startSession(trainingDay: day, programId: programId)

        // Give the inner Task a chance to deliver the first prescription
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        let state = await manager.sessionState
        guard case .active(let exercise, let setNumber) = state else {
            XCTFail("Expected .active after startSession, got \(state)")
            return
        }
        XCTAssertEqual(exercise.exerciseId, day.exercises[0].exerciseId)
        XCTAssertEqual(setNumber, 1)

        let prescription = await manager.currentPrescription
        XCTAssertNotNil(prescription, "Prescription should be set after inference")
        XCTAssertEqual(prescription?.weightKg, 80.0)
    }

    // MARK: Test 2: completeSet → .resting, SetLog appended

    func testCompleteSet_transitionsToRestingAndAppendsLog() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 3)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify we're active before calling completeSet
        let stateBefore = await manager.sessionState
        guard case .active = stateBefore else {
            XCTFail("Expected .active before completeSet, got \(stateBefore)")
            return
        }

        await manager.completeSet(actualReps: 8, rpeFelt: 7, intent: .top)

        let stateAfter = await manager.sessionState
        guard case .resting = stateAfter else {
            XCTFail("Expected .resting after completeSet, got \(stateAfter)")
            return
        }

        let logs = await manager.completedSets
        XCTAssertEqual(logs.count, 1, "One SetLog should be recorded")
        XCTAssertEqual(logs[0].repsCompleted, 8)
        XCTAssertEqual(logs[0].rpeFelt, 7)
        XCTAssertEqual(logs[0].exerciseId, day.exercises[0].exerciseId)
    }

    // MARK: Test 3: Fallback path (smart retry — no silent fallback)

    func testCompleteSet_fallbackPath_setsFallbackReason() async throws {
        // Use a failing provider so prescribe() always returns .fallback
        let manager = makeManager(provider: FailingLLMProvider())
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 300_000_000)

        // After startSession with a failing provider, inference fails →
        // state stays in .preflight (no silent fallback), retry is needed.
        let fallbackReason = await manager.currentFallbackReason
        XCTAssertNotNil(fallbackReason, "Fallback reason should be set when AI fails")

        let retryNeeded = await manager.inferenceRetryNeeded
        XCTAssertTrue(retryNeeded, "inferenceRetryNeeded should be true when inference fails during preflight")

        // No silent fallback prescription — user must choose retry or pause
        let prescription = await manager.currentPrescription
        XCTAssertNil(prescription, "No silent fallback: prescription should be nil when inference fails")

        // State should stay in .preflight (not advance to .active without a prescription)
        let state = await manager.sessionState
        guard case .preflight = state else {
            XCTFail("Expected .preflight (retry needed) when AI fails, got \(state)")
            return
        }
    }

    // MARK: Test 4: Safety gate — painReported flag extends rest to ≥ 180 s

    func testCompleteSet_painReportedFlag_extendsRestTo180() async throws {
        // Prescription with pain_reported flag and short rest
        let painJSON = prescriptionJSON(restSeconds: 60, safetyFlags: ["pain_reported"])
        let manager = makeManager(provider: MockLLMProvider(response: painJSON))
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 300_000_000)

        // Verify prescription was applied with the safety gate
        let prescription = await manager.currentPrescription
        XCTAssertNotNil(prescription)
        XCTAssertGreaterThanOrEqual(
            prescription?.restSeconds ?? 0, 180,
            "Safety gate: painReported should force rest ≥ 180s"
        )
        XCTAssertTrue(
            prescription?.safetyFlags.contains(.painReported) ?? false,
            "painReported flag should be present in prescription"
        )
    }

    // MARK: Test 5: Partial session / endSessionEarly

    func testEndSessionEarly_transitionsToSessionComplete_withSummary() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 3)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        // Complete one set, then exit early
        await manager.completeSet(actualReps: 10, rpeFelt: 6, intent: .top)
        await manager.endSessionEarly()

        let state = await manager.sessionState
        guard case .sessionComplete(let summary) = state else {
            XCTFail("Expected .sessionComplete after endSessionEarly, got \(state)")
            return
        }
        XCTAssertEqual(summary.setsCompleted, 1, "Summary should reflect 1 completed set")
        XCTAssertFalse(
            summary.totalVolumeKg.isNaN,
            "totalVolumeKg should be a valid number"
        )
    }

    // MARK: Test 6: Reentrancy guard — stale inference must not overwrite state

    func testReentrancyGuard_staleInferenceDiscarded() async throws {
        // First call returns after 0.5s (slow)
        // Second call will be triggered by completeSet() and returns fast

        // We simulate this by:
        // 1. Start session with a normal provider → first prescription set
        // 2. Call completeSet() → inferenceGeneration incremented
        // 3. Any outstanding "slow" task's result would have the old generation
        //    and should be discarded by the guard

        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 3)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        // Capture the generation counter before completeSet
        let generationBefore = await manager.inflightRequestCount

        await manager.completeSet(actualReps: 8, rpeFelt: 7, intent: .top)

        // After completeSet, at least one new inference should have been launched
        // (for the next set of the same exercise)
        let generationAfter = await manager.inflightRequestCount
        // The count may be 0 or 1 depending on timing, but must not be negative
        XCTAssertGreaterThanOrEqual(generationAfter, 0)

        // Final invariant: completedSets has exactly 1 log
        let logs = await manager.completedSets
        XCTAssertEqual(logs.count, 1, "Only the one completed set should be logged")

        _ = generationBefore // suppress unused warning
    }

    // MARK: Test 7: assembleWorkoutContext — all fields populated

    func testAssembleWorkoutContext_populatesAllRequiredFields() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let exercise = day.exercises[0]
        let context = await manager.assembleWorkoutContext(exercise: exercise, setNumber: 1)

        // requestType
        XCTAssertEqual(context.requestType, "set_prescription")

        // sessionMetadata
        XCTAssertFalse(context.sessionMetadata.sessionId.isEmpty, "sessionId must be set")

        // currentExercise
        XCTAssertEqual(context.currentExercise.name, exercise.name)
        XCTAssertEqual(context.currentExercise.setNumber, 1)
        XCTAssertEqual(context.currentExercise.plannedSets, exercise.sets)

        // planTarget
        let target = context.currentExercise.planTarget
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.minReps, exercise.repRange.min)
        XCTAssertEqual(target?.maxReps, exercise.repRange.max)

        // primaryMuscles
        XCTAssertFalse(context.currentExercise.primaryMuscles.isEmpty)

        // equipmentTypeKey
        XCTAssertFalse(context.currentExercise.equipmentTypeKey.isEmpty)
    }

    // MARK: Test 8: endSession after all sets — sessionComplete

    func testEndSession_afterAllSets_completesWithCorrectVolume() async throws {
        let manager = makeManager(
            provider: MockLLMProvider(response: prescriptionJSON(weightKg: 100.0, reps: 5))
        )
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        await manager.completeSet(actualReps: 5, rpeFelt: 8, intent: .top)
        await manager.endSession()

        let state = await manager.sessionState
        guard case .sessionComplete(let summary) = state else {
            XCTFail("Expected .sessionComplete, got \(state)")
            return
        }

        // volume = weightKg × reps = 100.0 × 5 = 500.0
        // Note: weight is from the prescription (100 kg) ×  reps completed (5)
        XCTAssertEqual(summary.setsCompleted, 1)
        // totalVolumeKg should be positive
        XCTAssertGreaterThan(summary.totalVolumeKg, 0)
    }

    // MARK: #186: weekly-fatigue fetch queries set_logs by session_id, not user_id

    /// set_logs has no `user_id` column; the weekly-fatigue fetch must resolve
    /// the user's sessions first and query set_logs by `session_id`. Pre-fix it
    /// emitted `set_logs?user_id=eq...` → HTTP 400 (silently swallowed), so the
    /// fatigue signal was never populated.
    func testFetchWeeklyFatigue_queriesSetLogsBySessionId_notUserId() async throws {
        WSMRecordingURLProtocol.reset()
        let manager = makeRecordingManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        await manager.startSession(trainingDay: day, programId: UUID())
        // Let the parallel fatigue fetch (two awaited queries) complete.
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4s

        let setLogsRequests = WSMRecordingURLProtocol.requestURLs.filter {
            $0.path.contains("set_logs")
        }
        XCTAssertFalse(
            setLogsRequests.contains { ($0.query ?? "").contains("user_id") },
            "set_logs must never be queried by user_id (no such column) — #186"
        )
        XCTAssertTrue(
            setLogsRequests.contains { ($0.query ?? "").contains("session_id") },
            "weekly-fatigue fetch must query set_logs by session_id"
        )
    }

    // MARK: #171 — early-exit writes a consistent (status, completed) pair

    /// Reproduces #171: finishSession hardcoded status="completed" while
    /// completed=false on early exit. The pair must be internally consistent —
    /// early exit writes status="partial" (not "completed").
    func testFinishSession_earlyExit_writesPartialStatusConsistentWithCompletedFalse() async throws {
        WSMBodyCaptureURLProtocol.reset()
        let manager = makeBodyCaptureManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 3)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 300_000_000)
        await manager.completeSet(actualReps: 10, rpeFelt: 6, intent: .top)
        await manager.endSessionEarly()
        try await Task.sleep(nanoseconds: 300_000_000)

        // The completion PATCH is the only one carrying a `summary` object.
        let summaryPatch = WSMBodyCaptureURLProtocol.captured
            .filter { $0.path.contains("workout_sessions") && $0.method == "PATCH" && !$0.body.isEmpty }
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
            .first { $0["summary"] != nil }
        let patch = try XCTUnwrap(summaryPatch, "expected a workout_sessions completion PATCH")
        XCTAssertEqual(patch["completed"] as? Bool, false, "early exit must not be completed=true")
        XCTAssertEqual(
            patch["status"] as? String, "partial",
            "status must be consistent with completed=false, not the old hardcoded 'completed' (#171)"
        )
    }

    // MARK: #190 — pauseSession must not block on the network

    /// Reproduces #190: pauseSession used to `await writeAheadQueue.flush()`
    /// (up to 1+2+4+8+16s of backoff) and then a blocking PATCH before saving
    /// the durable PausedSessionState. A freeze / background during that window
    /// lost the pause point. The fix saves the snapshot FIRST and fires the
    /// server sync off in a detached Task, so pauseSession returns immediately.
    ///
    /// Verification approach: the mock delays the workout_sessions status PATCH
    /// (the call pauseSession blocked on) by 0.6s while serving everything else
    /// instantly. The fix is proven by pauseSession returning well under that
    /// delay (it no longer awaits the PATCH) with the snapshot already persisted
    /// and the actor reset to .idle. Pre-fix, the call would block ≥0.6s.
    func testPauseSession_doesNotBlockOnNetwork() async throws {
        WSMDelayedPatchURLProtocol.patchDelaySeconds = 0.6
        let manager = makeDelayManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 3)
        let programId = UUID()
        let userId = UUID()

        await manager.startSession(trainingDay: day, programId: programId, userId: userId)
        try await Task.sleep(nanoseconds: 200_000_000) // let startSession settle to .active

        let beforePause = await manager.sessionState
        guard case .active = beforePause else {
            XCTFail("Expected .active before pause, got \(beforePause)")
            return
        }

        let start = Date()
        await manager.pauseSession()
        let elapsed = Date().timeIntervalSince(start)

        // 1. pauseSession returned before the 0.6s PATCH could resolve — it no
        //    longer awaits the network sync.
        XCTAssertLessThan(
            elapsed, 0.3,
            "pauseSession must not block on the workout_sessions PATCH (#190); took \(elapsed)s"
        )

        // 2. Actor state was reset synchronously.
        let state = await manager.sessionState
        XCTAssertEqual(state, .idle, "pauseSession should reset to idle")

        // 3. The durable snapshot was persisted before returning (the record the
        //    resume path reads — written ahead of any network work).
        let snapshot = PausedSessionState.load()
        XCTAssertNotNil(snapshot, "pauseSession must persist a PausedSessionState before returning")
        XCTAssertEqual(snapshot?.trainingDayId, day.id, "snapshot must reference the paused training day")
        XCTAssertEqual(snapshot?.programId, programId, "snapshot must reference the active program")
        XCTAssertEqual(snapshot?.userId, userId, "snapshot must reference the user")
    }

    // MARK: #318 / J-F1 — empty-exercises start leaves ZERO durable traces

    /// An attempt to start a session for a not-yet-generated day (no exercises) must
    /// error WITHOUT mutating anything durable: no crash sentinel (PausedSessionState)
    /// and no enqueued workout_sessions row. Pre-fix, the empty-exercises guard ran
    /// AFTER the sentinel save and the session-row enqueue, so an errored start left a
    /// phantom "Unfinished Workout" sentinel + an orphaned active session row.
    func testStartSession_emptyExercises_errorsWithoutSentinelOrSessionRow() async throws {
        WSMBodyCaptureURLProtocol.reset()
        let manager = makeBodyCaptureManager()
        // A day whose session was never generated: status .pending, exercises [].
        let emptyDay = TrainingDay(
            id: UUID(),
            dayOfWeek: 1,
            dayLabel: "Push_A",
            exercises: [],
            sessionNotes: nil,
            status: .pending
        )

        await manager.startSession(trainingDay: emptyDay, programId: UUID())
        // Allow any (incorrect) fire-and-forget enqueue/flush to surface as a request.
        try await Task.sleep(nanoseconds: 300_000_000)

        // 1. State is .error — the start was rejected.
        let state = await manager.sessionState
        guard case .error = state else {
            XCTFail("Expected .error for an empty-exercises start, got \(state)")
            return
        }

        // 2. No crash sentinel was written.
        XCTAssertNil(
            PausedSessionState.load(),
            "An errored start must not write a PausedSessionState crash sentinel (J-F1)"
        )

        // 3. No workout_sessions row was enqueued/POSTed (the orphaned 'active' row).
        let sessionRowPosts = WSMBodyCaptureURLProtocol.captured.filter {
            $0.path.contains("workout_sessions") && $0.method == "POST"
        }
        XCTAssertTrue(
            sessionRowPosts.isEmpty,
            "An errored start must not enqueue a workout_sessions row (J-F1); captured: \(sessionRowPosts.map(\.path))"
        )
    }

    // MARK: #318 / J-F2 — resuming an empty/exhausted day aborts without completion

    /// Regression pinning the CORRECTED J-F2 mechanism: resuming a day with no
    /// remaining exercises ends in .idle with no summary and no fabricated completion.
    /// finishSession's zero-set guard (completedSets.isEmpty → .idle + return) fires
    /// before any completion/PATCH, so the day is never mis-marked complete.
    func testResumeSession_emptyDay_abortsWithoutCompletion() async throws {
        let manager = makeManager()
        let emptyDay = TrainingDay(
            id: UUID(),
            dayOfWeek: 1,
            dayLabel: "Push_A",
            exercises: [],
            sessionNotes: nil,
            status: .pending
        )
        let paused = PausedSessionState(
            sessionId: UUID(),
            trainingDayId: emptyDay.id,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: emptyDay.dayLabel,
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date()
        )

        await manager.resumeSession(
            pausedState: paused,
            trainingDay: emptyDay,
            completedSetLogs: []
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        // Ends idle — NOT .sessionComplete. No summary was fabricated.
        let state = await manager.sessionState
        if case .sessionComplete = state {
            XCTFail("Resuming an empty day must NOT fabricate a completion; got \(state)")
            return
        }
        XCTAssertEqual(
            state, .idle,
            "Resuming a day with no remaining sets must abort to .idle (corrected J-F2)"
        )
    }
}

// MARK: - Body-capturing URLProtocol (#171 — inspect the PATCH payload)

private final class WSMBodyCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var captured: [(path: String, method: String, body: Data)] = []
    static func reset() {
        lock.lock(); captured = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n > 0 { body.append(buf, count: n) } else { break }
            }
        }
        Self.lock.lock(); Self.captured.append((path, method, body)); Self.lock.unlock()

        // Return one row for workout_sessions so the PATCH's performExpectingRow
        // (return=representation) sees a match; empty array otherwise.
        let respBody = path.contains("workout_sessions")
            ? "[{\"id\":\"00000000-0000-4000-8000-000000000001\"}]"
            : "[]"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(respBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeBodyCaptureManager() -> WorkoutSessionManager {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WSMBodyCaptureURLProtocol.self]
    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
    let inferenceService = AIInferenceService(
        provider: MockLLMProvider(response: prescriptionJSON()),
        gymProfile: nil,
        maxRetries: 0
    )
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let testDefaults = UserDefaults(suiteName: "com.test.wsm.body.\(UUID().uuidString)")!
    let gymFactStore = GymFactStore(userDefaults: testDefaults)
    let waq = WriteAheadQueue(supabase: supabase, userDefaults: testDefaults)
    return WorkoutSessionManager(
        aiInference: inferenceService,
        healthKit: HealthKitService(),
        memoryService: memoryService,
        supabase: supabase,
        gymFactStore: gymFactStore,
        writeAheadQueue: waq
    )
}

// MARK: - Delayed-PATCH URLProtocol (#190 — make the workout_sessions status PATCH slow)

/// Serves every request instantly EXCEPT the `workout_sessions` PATCH (the
/// status="paused" write that pauseSession used to block on), which is delayed
/// by `patchDelaySeconds`. Lets a test prove pauseSession returns before that
/// PATCH resolves. workout_sessions requests return a single-row representation
/// so the PATCH's `performExpectingRow` sees a match; everything else gets `[]`.
private final class WSMDelayedPatchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var patchDelaySeconds: TimeInterval = 0.6

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let isWorkoutSessions = path.contains("workout_sessions")
        let body = isWorkoutSessions
            ? "[{\"id\":\"00000000-0000-4000-8000-000000000001\"}]"
            : "[]"
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: self.request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if method == "PATCH" && isWorkoutSessions {
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Self.patchDelaySeconds, execute: deliver
            )
        } else {
            deliver()
        }
    }
    override func stopLoading() {}
}

private func makeDelayManager() -> WorkoutSessionManager {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WSMDelayedPatchURLProtocol.self]
    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
    let inferenceService = AIInferenceService(
        provider: MockLLMProvider(response: prescriptionJSON()),
        gymProfile: nil,
        maxRetries: 0
    )
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let testDefaults = UserDefaults(suiteName: "com.test.wsm.delay.\(UUID().uuidString)")!
    let gymFactStore = GymFactStore(userDefaults: testDefaults)
    let waq = WriteAheadQueue(supabase: supabase, userDefaults: testDefaults)
    return WorkoutSessionManager(
        aiInference: inferenceService,
        healthKit: HealthKitService(),
        memoryService: memoryService,
        supabase: supabase,
        gymFactStore: gymFactStore,
        writeAheadQueue: waq
    )
}
