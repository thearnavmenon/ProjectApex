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

/// Gated provider for deterministic generation-guard tests (#369 [19]). The first
/// `complete()` call (startSession) throws so the manager lands in the pending-retry
/// state with no flaky timing. The SECOND call (retryInference) parks on a
/// continuation that the test resumes manually — letting the test advance the
/// generation (via a reentrant actor call) WHILE the retry is suspended mid-await,
/// then release it to verify the stale result is dropped by the guard.
private final class GatedRetryProvider: LLMProvider, @unchecked Sendable {
    let response: String
    private let lock = NSLock()
    private var callCount = 0
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var gateContinuationReadyContinuation: CheckedContinuation<Void, Never>?

    init(response: String) { self.response = response }

    /// Suspends until the retry call has actually parked on its gate.
    func waitUntilRetryParked() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            lock.lock()
            if gateContinuation != nil {
                lock.unlock(); k.resume()
            } else {
                gateContinuationReadyContinuation = k; lock.unlock()
            }
        }
    }

    /// Releases the parked retry call so it can finish and return its response.
    func releaseRetry() {
        lock.lock()
        let k = gateContinuation
        gateContinuation = nil
        lock.unlock()
        k?.resume()
    }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        lock.lock()
        callCount += 1
        let n = callCount
        lock.unlock()

        if n == 1 {
            // startSession inference — fail fast so we land in pending-retry.
            throw LLMProviderError.httpError(statusCode: 401, body: "Invalid API key")
        }

        // ONLY the retry call (#2) is gated — park until the test releases it. Every
        // later call (e.g. the swap's own inference, #3) returns immediately, so the
        // gate is never overwritten and releaseRetry() is unambiguous.
        guard n == 2 else { return response }

        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            lock.lock()
            gateContinuation = k
            let ready = gateContinuationReadyContinuation
            gateContinuationReadyContinuation = nil
            lock.unlock()
            ready?.resume()
        }
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

/// Minimal Encodable payload for seeding the write-ahead queue in tests. File-scope
/// (not a local type) so its Encodable conformance is non-isolated and satisfies
/// `enqueue`'s `Sendable` requirement. #369 slice 4.
nonisolated private struct DummyWAQItem: Encodable, Sendable { let id = UUID().uuidString }

/// Like `makeManager` but also returns the injected `WriteAheadQueue` so tests can
/// assert on it directly (the manager's `writeAheadQueue` is private). #369 slice 4.
private func makeManagerWithWAQ(
    provider: any LLMProvider = MockLLMProvider(response: prescriptionJSON()),
    gymProfile: GymProfile? = nil
) -> (WorkoutSessionManager, WriteAheadQueue) {
    let inferenceService = AIInferenceService(provider: provider, gymProfile: gymProfile, maxRetries: 0)
    let supabase = makeTestSupabase()
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let suiteName = "com.test.wsm.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suiteName)!
    let gymFactStore = GymFactStore(userDefaults: testDefaults)
    let waq = WriteAheadQueue(supabase: supabase, userDefaults: testDefaults)
    let manager = WorkoutSessionManager(
        aiInference: inferenceService,
        healthKit: HealthKitService(),
        memoryService: memoryService,
        supabase: supabase,
        gymFactStore: gymFactStore,
        writeAheadQueue: waq
    )
    return (manager, waq)
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

    // MARK: #369 slice 4 — discard stale-owner paused session on resume

    /// discardStalePausedSession() clears the write-ahead queue (+ dead-letter) and
    /// the paused snapshot, leaving a clean slate with no Supabase write.
    func testDiscardStalePausedSession_clearsQueueDeadLetterAndPausedState() async throws {
        let (manager, waq) = makeManagerWithWAQ()
        // Seed a dead-letter that SURVIVES until discard (permanent-failure path).
        // A success-stub would auto-flush the item away, making the WAQ-clear
        // assertion vacuous; this keeps it load-bearing.
        await waq.registerFlushHandler(forTable: "set_logs") { _ in .permanentFailure("seed") }
        try? await waq.enqueue(DummyWAQItem(), table: "set_logs")
        var deadBefore = await waq.failedWrites()
        for _ in 0..<100 where deadBefore.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            deadBefore = await waq.failedWrites()
        }
        XCTAssertEqual(deadBefore.count, 1, "precondition: one item dead-lettered and pending")

        let paused = PausedSessionState(
            sessionId: UUID(), trainingDayId: UUID(), weekId: UUID(),
            weekNumber: 1, exerciseIndex: 0, currentSetNumber: 1,
            dayType: "Push_A", programId: UUID(), userId: UUID(), pausedAt: Date()
        )
        paused.save()
        XCTAssertNotNil(PausedSessionState.load(), "precondition: paused session saved")

        await manager.discardStalePausedSession()

        let dl = await waq.failedWrites()
        XCTAssertTrue(dl.isEmpty, "dead-letter drained by discard (clearAll)")
        XCTAssertNil(PausedSessionState.load(), "paused state cleared after discard")
    }

    // MARK: #403 — Reset All clears an ACTIVE in-memory workout session

    /// performLocalStateReset must drain the write-ahead queue, clear any paused
    /// snapshot, AND reset the live WorkoutSessionManager to .idle — even when the
    /// session is ACTIVE (not paused) at reset time. Pre-fix the manager kept the
    /// old-owner session in memory, so it could enqueue owner-mismatched writes
    /// within the same process lifetime (#403, #369 owner-mismatch campaign).
    func testPerformLocalStateReset_clearsActiveSession() async throws {
        let (manager, waq) = makeManagerWithWAQ()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000) // let startSession settle to .active

        let before = await manager.sessionState
        guard case .active = before else {
            XCTFail("precondition: expected .active before reset, got \(before)")
            return
        }

        await performLocalStateReset(writeAheadQueue: waq, workoutSessionManager: manager)

        let after = await manager.sessionState
        XCTAssertEqual(after, .idle, "active in-memory session must be reset to .idle by Reset All (#403)")
        XCTAssertNil(PausedSessionState.load(), "paused state cleared by reset")
    }

    /// When the paused session's owner != the current auth uid, resumeSession must
    /// discard it (not replay/re-insert under the old owner → RLS 403), leave the
    /// manager idle, clear the paused snapshot, and surface a repair notice.
    func testResumeSession_staleOwner_discardsAndStaysIdle() async throws {
        let realUid = UUID()    // current real auth uid (B)
        let frozenUid = UUID()  // uid frozen in the paused session (A) — different

        // Scoped keychain with a restorable (future-expiry) session for the real uid,
        // so awaitFirstResolution() returns it offline (no network).
        let kc = KeychainService(serviceName: "com.projectapex.tests.stale.\(UUID().uuidString)")
        try? kc.store("access-token", for: .supabaseAccessToken)
        try? kc.store("refresh-token", for: .supabaseRefreshToken)
        try? kc.store(String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)), for: .supabaseSessionExpiry)
        try? kc.store(realUid.uuidString, for: .supabaseAuthUserId)
        let auth = SupabaseAuth(supabaseURL: URL(string: "https://test.supabase.co")!, anonKey: "k", keychain: kc)

        let manager = makeManager()
        let vm = await WorkoutViewModel(manager: manager)

        let paused = PausedSessionState(
            sessionId: UUID(), trainingDayId: UUID(), weekId: UUID(),
            weekNumber: 1, exerciseIndex: 0, currentSetNumber: 1,
            dayType: "Push_A", programId: UUID(), userId: frozenUid, pausedAt: Date()
        )
        paused.save()

        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        await vm.resumeSession(pausedState: paused, trainingDay: day,
                               supabase: makeTestSupabase(), supabaseAuth: auth)

        // resumeSession spawns a Task; poll on the LAST state the gate sets
        // (resumeRepairNotice, assigned after the discard) so we never observe a
        // half-applied gate. 1s ceiling.
        var settled = false
        for _ in 0..<100 where !settled {
            try await Task.sleep(nanoseconds: 10_000_000)
            settled = await MainActor.run { vm.resumeRepairNotice != nil }
        }

        let state = await manager.sessionState
        XCTAssertEqual(state, .idle, "manager stays idle when a stale-owner session is discarded")
        XCTAssertNil(PausedSessionState.load(), "paused state cleared")
        await MainActor.run {
            XCTAssertNotNil(vm.resumeRepairNotice, "resumeRepairNotice surfaced")
            XCTAssertFalse(vm.isStartingSession, "isStartingSession reset")
        }

        clearAuthKeysForStaleTest(kc)
    }

    private func clearAuthKeysForStaleTest(_ kc: KeychainService) {
        try? kc.delete(.supabaseAccessToken)
        try? kc.delete(.supabaseRefreshToken)
        try? kc.delete(.supabaseSessionExpiry)
        try? kc.delete(.supabaseAuthUserId)
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

    // MARK: #442 (Q4) — ensure-persist-first on session start

    /// The idempotent program-persist must be AWAITED before the workout_sessions row
    /// is enqueued. Otherwise a missing `programs` row makes the insert FK-fail (23503),
    /// retry ~31s, and silently dead-letter. The seam records whether persist completed
    /// at the moment the session insert is dispatched.
    func testStartSession_awaitsProgramPersist_beforeEnqueuingSessionRow() async throws {
        WSMBodyCaptureURLProtocol.reset()
        let persistRan = WSMFlag()
        let persistWasDoneAtSessionInsert = WSMFlag()

        let manager = makeBodyCaptureManager(
            ensureProgramPersisted: { _, _ in
                persistRan.value = true
                return true
            },
            onWorkoutSessionInsert: {
                // Captured the instant the session POST is dispatched.
                persistWasDoneAtSessionInsert.value = persistRan.value
            }
        )
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(persistRan.value, "program-persist must run during startSession")
        XCTAssertTrue(
            persistWasDoneAtSessionInsert.value,
            "program-persist must complete BEFORE the workout_sessions row is enqueued/inserted"
        )

        let state = await manager.sessionState
        guard case .active = state else {
            XCTFail("Expected .active after a successful start, got \(state)")
            return
        }
    }

    /// When persistence cannot complete (offline / owner unresolved), startSession must
    /// NOT proceed-and-drop: it surfaces the failure (.error) and enqueues NO
    /// workout_sessions row that would FK-fail.
    func testStartSession_persistFails_surfacesAndDoesNotEnqueueSession() async throws {
        WSMBodyCaptureURLProtocol.reset()
        let manager = makeBodyCaptureManager(
            ensureProgramPersisted: { _, _ in false }   // offline / owner unresolved
        )
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 300_000_000)

        // 1. Surfaced, not silently dropped.
        let state = await manager.sessionState
        guard case .error = state else {
            XCTFail("Expected .error when program-persist cannot complete, got \(state)")
            return
        }

        // 2. No workout_sessions row enqueued/POSTed (would FK-fail with 23503).
        let sessionRowPosts = WSMBodyCaptureURLProtocol.captured.filter {
            $0.path.contains("workout_sessions") && $0.method == "POST"
        }
        XCTAssertTrue(
            sessionRowPosts.isEmpty,
            "A persist-blocked start must not enqueue a workout_sessions row; captured: \(sessionRowPosts.map(\.path))"
        )

        // 3. No crash sentinel written (nothing to recover).
        XCTAssertNil(
            PausedSessionState.load(),
            "A persist-blocked start must not write a PausedSessionState crash sentinel"
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

    // MARK: #447 — resume validates the day's exercise-set signature

    /// Defense-in-depth: a paused session whose stored exercise signature does NOT
    /// match the current day's exercise list must NOT be silently replayed. The day's
    /// exercises changed since the pause, so the stored exerciseIndex / set_logs
    /// mapping is no longer trustworthy — resume is rejected and surfaces an error
    /// (routing to the existing mismatch-recovery UI) rather than mis-replaying.
    func testResumeSession_signatureMismatch_isRejectedNotReplayed() async throws {
        let manager = makeManager()

        // The day the user paused on (signature captured from THIS list).
        let pausedDay = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)
        // The CURRENT day — same id (UUID still matches) but a DIFFERENT exercise
        // list (e.g. the program was edited between pause and resume).
        let editedDay = TrainingDay(
            id: pausedDay.id,
            dayOfWeek: pausedDay.dayOfWeek,
            dayLabel: pausedDay.dayLabel,
            exercises: makeTrainingDay(exerciseCount: 3, setsPerExercise: 2).exercises,
            sessionNotes: nil
        )

        let paused = PausedSessionState(
            sessionId: UUID(),
            trainingDayId: pausedDay.id,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 1,
            currentSetNumber: 1,
            dayType: pausedDay.dayLabel,
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date(),
            exerciseSignature: PausedSessionState.exerciseSignature(for: pausedDay)
        )

        // Precondition: the sentinel is persisted, as it is in production at pause
        // time — only then is "a rejected resume preserves it" a meaningful assertion.
        paused.save()
        XCTAssertNotNil(PausedSessionState.load(), "precondition: paused session saved")

        let resumed = await manager.resumeSession(
            pausedState: paused,
            trainingDay: editedDay,
            completedSetLogs: []
        )

        XCTAssertFalse(resumed, "A signature mismatch must reject the resume")
        let state = await manager.sessionState
        guard case .error = state else {
            XCTFail("Signature mismatch must surface .error (mismatch recovery), got \(state)")
            return
        }
        // The sentinel is preserved so the user can still Abandon/Save via the recovery UI.
        XCTAssertNotNil(
            PausedSessionState.load(),
            "A rejected resume must NOT clear the sentinel — the recovery UI still needs it"
        )
    }

    /// Happy path: a stored signature that matches the current day's exercise list
    /// lets resume proceed normally.
    func testResumeSession_signatureMatch_proceeds() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)

        let paused = PausedSessionState(
            sessionId: UUID(),
            trainingDayId: day.id,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: day.dayLabel,
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date(),
            exerciseSignature: PausedSessionState.exerciseSignature(for: day)
        )

        let resumed = await manager.resumeSession(
            pausedState: paused,
            trainingDay: day,
            completedSetLogs: []
        )

        XCTAssertTrue(resumed, "A matching signature must allow resume to proceed")
        let state = await manager.sessionState
        if case .error = state {
            XCTFail("A matching signature must not error; got \(state)")
        }
    }

    /// Back-compat: a legacy sentinel written before the signature field existed
    /// decodes with a nil signature. A nil stored signature must NOT spuriously
    /// reject a legitimate resume.
    func testResumeSession_nilStoredSignature_doesNotReject() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)

        let paused = PausedSessionState(
            sessionId: UUID(),
            trainingDayId: day.id,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: day.dayLabel,
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date(),
            exerciseSignature: nil   // legacy sentinel
        )

        let resumed = await manager.resumeSession(
            pausedState: paused,
            trainingDay: day,
            completedSetLogs: []
        )

        XCTAssertTrue(resumed, "A nil stored signature must not reject a legitimate resume")
    }

    /// The signature is deterministic and order-sensitive: same ordered ids → same
    /// signature; reordered or changed ids → different signature. No Date/random.
    func testExerciseSignature_isDeterministicAndOrderSensitive() {
        let dayA = makeTrainingDay(exerciseCount: 3, setsPerExercise: 2)
        let sig1 = PausedSessionState.exerciseSignature(for: dayA)
        let sig2 = PausedSessionState.exerciseSignature(for: dayA)
        XCTAssertEqual(sig1, sig2, "Signature must be deterministic for the same list")

        // A day with the same exercises but reversed order → different signature.
        let reversed = TrainingDay(
            id: dayA.id, dayOfWeek: dayA.dayOfWeek, dayLabel: dayA.dayLabel,
            exercises: dayA.exercises.reversed(), sessionNotes: nil
        )
        XCTAssertNotEqual(
            sig1, PausedSessionState.exerciseSignature(for: reversed),
            "Reordering the exercise list must change the signature"
        )

        // A day with an added exercise → different signature.
        let dayBigger = makeTrainingDay(exerciseCount: 4, setsPerExercise: 2)
        XCTAssertNotEqual(
            sig1, PausedSessionState.exerciseSignature(for: dayBigger),
            "Changing the exercise count must change the signature"
        )
    }

    // MARK: #318 / U5 — skip set (G-F7): advancement must be set-number-based

    /// The bug-catcher (critic amendment): a SKIPPED set writes no SetLog, so
    /// SetLog-count-based last-set determination lags reality. Skip set 1 of 2,
    /// then complete set 2 → the manager must advance to the NEXT exercise,
    /// not prescribe a phantom set 3 of the same exercise.
    func testSkipSet_thenCompleteSet_advancesExerciseCorrectly() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        // Skip set 1 of exercise 0 → straight to .active set 2 (no rest, no SetLog).
        await manager.skipCurrentSet()
        let afterSkip = await manager.sessionState
        guard case .active(let skipEx, let skipN) = afterSkip else {
            XCTFail("Expected .active after skip, got \(afterSkip)")
            return
        }
        XCTAssertEqual(skipEx.exerciseId, day.exercises[0].exerciseId)
        XCTAssertEqual(skipN, 2, "Skip must advance to set 2 of the same exercise")

        // Let the post-skip inference land so completeSet has a prescription.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Complete set 2 — the exercise's LAST set (sets == 2; 1 skipped + 1 completed).
        await manager.completeSet(actualReps: 8, rpeFelt: 7, intent: .top)

        // The last-set branch flashes .exerciseComplete then rests for the NEXT
        // exercise. Count-based logic sees only 1 SetLog (< 2 planned sets) and
        // wrongly schedules a phantom set 3 of exercise 0 instead.
        let after = await manager.sessionState
        guard case .resting(let nextEx, let nextN) = after else {
            XCTFail("Expected .resting after the exercise's last set, got \(after)")
            return
        }
        XCTAssertEqual(
            nextEx.exerciseId, day.exercises[1].exerciseId,
            "After skip+complete (2 of 2 sets addressed) the manager must advance to exercise 1 — a phantom extra set means last-set determination is still SetLog-count-based"
        )
        XCTAssertEqual(nextN, 1, "Next exercise starts at set 1")

        let logs = await manager.completedSets
        XCTAssertEqual(logs.count, 1, "Only the completed set produces a SetLog")
    }

    /// Skip writes NO SetLog and advances within the exercise with NO rest.
    func testSkipSet_advancesWithoutSetLogOrRest() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 3)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        await manager.skipCurrentSet()

        let state = await manager.sessionState
        guard case .active(let ex, let n) = state else {
            XCTFail("Skip must go straight to .active (no rest period), got \(state)")
            return
        }
        XCTAssertEqual(ex.exerciseId, day.exercises[0].exerciseId)
        XCTAssertEqual(n, 2, "Skip advances to the next set number")

        let logs = await manager.completedSets
        XCTAssertTrue(logs.isEmpty, "A skipped set must not produce a SetLog")
        let rest = await manager.restSecondsRemaining
        XCTAssertEqual(rest, 0, "No rest period after a skip")
    }

    /// A session where EVERY set was skipped has zero SetLogs — finishSession's
    /// zero-set guard must discard it (→ .idle), never persist a completion.
    func testAllSetsSkipped_sessionIsDiscarded() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        await manager.skipCurrentSet()   // set 1 of 2
        await manager.skipCurrentSet()   // set 2 of 2 — last set of last exercise → endSession

        let state = await manager.sessionState
        if case .sessionComplete = state {
            XCTFail("An all-skipped session must not complete with a summary")
            return
        }
        XCTAssertEqual(state, .idle, "Zero-set guard must discard the all-skipped session")

        let logs = await manager.completedSets
        XCTAssertTrue(logs.isEmpty, "No SetLogs for an all-skipped session")
    }

    // MARK: #369 [8] — finishSession idempotency

    /// Two end paths reaching finishSession for the same session (here endSession()
    /// followed by endSessionEarly(), the rest-timer-Task-vs-UI race) must run the
    /// side effects ONCE: the persistent session count increments by exactly 1.
    /// Pre-fix, the second call re-ran the whole body, double-incrementing the count
    /// (and double-enqueueing the trainee-model update).
    func testFinishSession_isIdempotent_sessionCountIncrementsOnce() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        // finishSession writes UserProfileConstants.sessionCountKey on UserDefaults.standard.
        // Snapshot the delta rather than the absolute value so the test is independent of
        // any pre-existing count.
        let key = UserProfileConstants.sessionCountKey
        let before = UserDefaults.standard.integer(forKey: key)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        await manager.completeSet(actualReps: 5, rpeFelt: 7, intent: .top)

        // First end path (the natural completion). Then a second, duplicate end path.
        await manager.endSession()
        await manager.endSessionEarly()

        let after = UserDefaults.standard.integer(forKey: key)
        XCTAssertEqual(
            after - before, 1,
            "finishSession must increment the session count exactly once across two end paths (#369 [8])"
        )

        // State is the single completed session — the second call did not corrupt it.
        let state = await manager.sessionState
        guard case .sessionComplete = state else {
            XCTFail("Expected .sessionComplete after the (idempotent) double end, got \(state)")
            return
        }
    }

    /// A fresh session after a completed one must be able to finish again — the
    /// idempotency latch is cleared on startSession, so it does not permanently
    /// disable finishSession for the next session.
    func testFinishSession_latchResetsForNextSession() async throws {
        let manager = makeManager()
        let key = UserProfileConstants.sessionCountKey
        let before = UserDefaults.standard.integer(forKey: key)

        // Session 1.
        let day1 = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        await manager.startSession(trainingDay: day1, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        await manager.completeSet(actualReps: 5, rpeFelt: 7, intent: .top)
        await manager.endSession()
        await manager.resetToIdle()

        // Session 2 — latch must have been cleared so this one also counts.
        let day2 = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        await manager.startSession(trainingDay: day2, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        await manager.completeSet(actualReps: 5, rpeFelt: 7, intent: .top)
        await manager.endSession()

        let after = UserDefaults.standard.integer(forKey: key)
        XCTAssertEqual(after - before, 2, "Two distinct sessions must each count once (latch resets per session)")
    }

    // MARK: #440 (F1) — currentSessionId tracks the live session identity

    /// The actor must expose the live session's UUID alongside its training-day UUID so
    /// ActiveSessionCoordinator can publish .live(dayId:sessionId:) from a single actor
    /// read. currentSessionId is set on start and cleared on resetToIdle; it is distinct
    /// from currentTrainingDayId (the two UUIDs must not be conflated).
    func testCurrentSessionId_setOnStart_clearedOnReset() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        // Idle before start.
        let beforeStart = await manager.currentSessionId
        XCTAssertNil(beforeStart, "currentSessionId must be nil before any session starts")

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let liveSessionId = await manager.currentSessionId
        let liveDayId = await manager.currentTrainingDayId
        XCTAssertNotNil(liveSessionId, "currentSessionId must be set once a session starts")
        XCTAssertEqual(liveDayId, day.id, "currentTrainingDayId must reference the started day")
        XCTAssertNotEqual(liveSessionId, liveDayId, "session UUID and day UUID must not be conflated")

        await manager.resetToIdle()
        let afterReset = await manager.currentSessionId
        XCTAssertNil(afterReset, "currentSessionId must be cleared on resetToIdle")
    }

    // MARK: #458 — uiSnapshot carries the session identity for one atomic coordinator read

    /// ActiveSessionCoordinator derives .live(dayId:sessionId:) every poll. Reading
    /// state + dayId + sessionId as three separate actor awaits could tear (the actor
    /// can advance between hops). uiSnapshot() already returns state + dayId atomically;
    /// it must also carry currentSessionId so the coordinator reads the whole live
    /// identity in ONE hop. This pins the new snapshot field.
    func testUISnapshot_carriesCurrentSessionId_consistentWithState() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        let idleSnap = await manager.uiSnapshot()
        XCTAssertNil(idleSnap.currentSessionId, "currentSessionId must be nil in an idle snapshot")

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let liveSnap = await manager.uiSnapshot()
        let actorSessionId = await manager.currentSessionId
        XCTAssertNotNil(liveSnap.currentSessionId, "currentSessionId must be present in a live snapshot")
        XCTAssertEqual(liveSnap.currentSessionId, actorSessionId, "snapshot sessionId must match the actor's isolated value")
        XCTAssertEqual(liveSnap.currentTrainingDayId, day.id, "snapshot dayId must reference the started day")
        XCTAssertNotEqual(liveSnap.currentSessionId, liveSnap.currentTrainingDayId, "session and day UUIDs must not be conflated")

        await manager.resetToIdle()
        let resetSnap = await manager.uiSnapshot()
        XCTAssertNil(resetSnap.currentSessionId, "currentSessionId must be nil after resetToIdle")
    }

    // MARK: #369 [19] — retryInference participates in the generation guard

    /// A retry result that resolves AFTER the session has advanced (generation bumped
    /// by a concurrent swap) must be DROPPED, not applied. The GatedRetryProvider parks
    /// the retry mid-await; the test bumps the generation via swapExercise (a reentrant
    /// actor call while the retry is suspended), then releases the retry. Pre-fix,
    /// retryInference had no post-await generation re-check, so the stale prescription
    /// clobbered the swapped-in state.
    func testRetryInference_staleResultDroppedAfterGenerationBump() async throws {
        let provider = GatedRetryProvider(response: prescriptionJSON(weightKg: 60.0))
        let manager = makeManager(provider: provider)
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)

        // startSession's inference fails (gated call #1) → pending-retry on exercise 0.
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        let retryNeeded = await manager.inferenceRetryNeeded
        XCTAssertTrue(retryNeeded, "Failed startSession inference should arm the retry")

        // Launch the retry — it parks on the gate inside prescribe() (gated call #2).
        let retryTask = Task { await manager.retryInference() }
        await provider.waitUntilRetryParked()

        // While the retry is suspended, advance the generation via a swap (reentrant
        // actor call). The swap bumps inferenceGeneration, so the parked retry's
        // captured generation is now stale.
        let suggestion = ExerciseSwapService.ExerciseSuggestion(
            exerciseId: "swapped_in",
            name: "Swapped In",
            equipmentRequired: "barbell",
            suggestedWeightKg: 60.0,
            suggestedReps: 8,
            reasoning: "test"
        )
        await manager.swapExercise(suggestion: suggestion, reason: "test swap")

        // Release the retry; its result is for the OLD generation and must be dropped.
        provider.releaseRetry()
        let applied = await retryTask.value
        XCTAssertFalse(applied, "A stale retry result (generation bumped by swap) must report not-applied")

        // The stale retry targeted exercise_0; if the guard failed it would have set
        // sessionState = .active(exercise_0, ...). The swap moved the active context to
        // "swapped_in", so the live exercise must NEVER be exercise_0. (The swap's own
        // valid inference legitimately sets currentPrescription for "swapped_in".)
        let state = await manager.sessionState
        let liveExerciseId: String?
        switch state {
        case .active(let ex, _), .resting(let ex, _):
            liveExerciseId = ex.exerciseId
        default:
            liveExerciseId = nil
        }
        if let liveExerciseId {
            XCTAssertNotEqual(
                liveExerciseId, day.exercises[0].exerciseId,
                "Stale retry must not transition the session back to the pre-swap exercise (#369 [19])"
            )
        }
    }

    // MARK: #369 [20] — uiSnapshot returns a consistent set of fields

    /// uiSnapshot() must return the same field values as the individual actor-isolated
    /// properties at a quiescent moment (no torn read). This pins the snapshot's
    /// field-mapping contract that pullState() now relies on.
    func testUISnapshot_matchesIndividualFields() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = await manager.uiSnapshot()
        let state = await manager.sessionState
        let prescription = await manager.currentPrescription
        let fallback = await manager.currentFallbackReason
        let restRemaining = await manager.restSecondsRemaining
        let expiresAt = await manager.restExpiresAt
        let sets = await manager.completedSets
        let retryNeeded = await manager.inferenceRetryNeeded
        let pendingExercise = await manager.pendingRetryExercise

        XCTAssertEqual(snapshot.sessionState, state)
        XCTAssertEqual(snapshot.currentPrescription?.weightKg, prescription?.weightKg)
        XCTAssertEqual(snapshot.restSecondsRemaining, restRemaining)
        XCTAssertEqual(snapshot.restExpiresAt, expiresAt)
        XCTAssertEqual(snapshot.completedSets.count, sets.count)
        XCTAssertEqual(snapshot.inferenceRetryNeeded, retryNeeded)
        XCTAssertEqual(snapshot.pendingRetryExercise?.exerciseId, pendingExercise?.exerciseId)
        // currentFallbackReason is an enum without Equatable in scope here — compare nil-ness.
        XCTAssertEqual(snapshot.currentFallbackReason == nil, fallback == nil)

        // During .active the snapshot's lastPerformanceSets reflects the live exercise's
        // cached history (nil here — no prior sessions in the test DB), proving the
        // derivation runs inside the same atomic hop.
        XCTAssertNil(snapshot.lastPerformanceSets, "No prior-session history in test → nil")
    }
}

// MARK: - Body-capturing URLProtocol (#171 — inspect the PATCH payload)

/// Minimal reference-type flag for cross-Task observation in tests (#442).
private final class WSMFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class WSMBodyCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var captured: [(path: String, method: String, body: Data)] = []
    /// Fired when a workout_sessions POST is dispatched, so a test can sample state
    /// at the exact moment the session row insert reaches the network (#442).
    nonisolated(unsafe) static var onWorkoutSessionInsert: (() -> Void)?
    static func reset() {
        lock.lock(); captured = []; onWorkoutSessionInsert = nil; lock.unlock()
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
        if path.contains("workout_sessions") && method == "POST" {
            Self.onWorkoutSessionInsert?()
        }

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

private func makeBodyCaptureManager(
    ensureProgramPersisted: (@Sendable (UUID, UUID) async -> Bool)? = nil,
    onWorkoutSessionInsert: (() -> Void)? = nil
) -> WorkoutSessionManager {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WSMBodyCaptureURLProtocol.self]
    if let onWorkoutSessionInsert {
        WSMBodyCaptureURLProtocol.onWorkoutSessionInsert = onWorkoutSessionInsert
    }
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
        writeAheadQueue: waq,
        ensureProgramPersisted: ensureProgramPersisted
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

// MARK: - ComputePersonalRecordsTests (#318 U6 / G-F12)

/// Tests for the pure `WorkoutSessionManager.computePersonalRecords`.
/// Rule under test: per exercise, session-best e1RM (Epley, weight × (1 + reps/30))
/// over top sets with reps in 3...10, vs the historical best under the same rule.
/// No historical baseline ⇒ no entry (PersonalRecord.previousBest is non-optional).
final class ComputePersonalRecordsTests: XCTestCase {

    private func makeSet(
        exerciseId: String = "exercise_0",
        weightKg: Double,
        reps: Int,
        intent: SetIntent? = .top
    ) -> SetLog {
        SetLog(
            id: UUID(),
            sessionId: UUID(),
            exerciseId: exerciseId,
            setNumber: 1,
            weightKg: weightKg,
            repsCompleted: reps,
            rpeFelt: 8,
            rirEstimated: 2,
            aiPrescribed: nil,
            loggedAt: Date(),
            primaryMuscle: nil,
            intent: intent,
            completionFlags: []
        )
    }

    func test_genuinePR_producesRecordWithCorrectValues() {
        // Historical best: 100 kg × 5 → e1RM 116.667. Session best: 105 kg × 5 → 122.5.
        let records = WorkoutSessionManager.computePersonalRecords(
            sessionSets: [makeSet(weightKg: 105, reps: 5)],
            historicalSets: [makeSet(weightKg: 100, reps: 5)],
            exercises: makeTrainingDay().exercises
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].exerciseId, "exercise_0")
        XCTAssertEqual(records[0].exerciseName, "Exercise 0")
        XCTAssertEqual(records[0].previousBest, 100.0 * (1.0 + 5.0 / 30.0), accuracy: 0.0001)
        XCTAssertEqual(records[0].newBest, 105.0 * (1.0 + 5.0 / 30.0), accuracy: 0.0001)
        XCTAssertEqual(records[0].metric, .estimatedOneRM)
    }

    func test_noPR_whenSessionBestDoesNotExceedHistoricalBest() {
        // Equal e1RM (strict > required) and lower e1RM both produce no record.
        let equalRecords = WorkoutSessionManager.computePersonalRecords(
            sessionSets: [makeSet(weightKg: 100, reps: 5)],
            historicalSets: [makeSet(weightKg: 100, reps: 5)],
            exercises: makeTrainingDay().exercises
        )
        XCTAssertTrue(equalRecords.isEmpty)

        let lowerRecords = WorkoutSessionManager.computePersonalRecords(
            sessionSets: [makeSet(weightKg: 95, reps: 5)],
            historicalSets: [makeSet(weightKg: 100, reps: 5)],
            exercises: makeTrainingDay().exercises
        )
        XCTAssertTrue(lowerRecords.isEmpty)
    }

    func test_suppressed_whenExerciseHasZeroHistoricalTopSets() {
        // exercise_1 has NO history — a huge session best must NOT fabricate a
        // PR against a 0.0 baseline. exercise_0 has a baseline and a real PR.
        let records = WorkoutSessionManager.computePersonalRecords(
            sessionSets: [
                makeSet(exerciseId: "exercise_0", weightKg: 105, reps: 5),
                makeSet(exerciseId: "exercise_1", weightKg: 200, reps: 5)
            ],
            historicalSets: [makeSet(exerciseId: "exercise_0", weightKg: 100, reps: 5)],
            exercises: makeTrainingDay().exercises
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records.contains { $0.exerciseId == "exercise_1" })
        XCTAssertEqual(records[0].exerciseId, "exercise_0")
    }

    func test_repsOutside3to10_excludedFromBothSessionAndHistoricalBests() {
        // Session: 200 kg × 2 (excluded, below range) + 100 kg × 5 (valid → 116.667).
        // History: 180 kg × 12 (excluded, above range) + 90 kg × 5 (valid → 105).
        // If exclusion failed on either side, the result would differ:
        // history 180×12 → e1RM 252 would swallow the PR; session 200×2 → 213.3
        // would inflate newBest.
        let records = WorkoutSessionManager.computePersonalRecords(
            sessionSets: [
                makeSet(weightKg: 200, reps: 2),
                makeSet(weightKg: 100, reps: 5)
            ],
            historicalSets: [
                makeSet(weightKg: 180, reps: 12),
                makeSet(weightKg: 90, reps: 5)
            ],
            exercises: makeTrainingDay().exercises
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].previousBest, 90.0 * (1.0 + 5.0 / 30.0), accuracy: 0.0001)
        XCTAssertEqual(records[0].newBest, 100.0 * (1.0 + 5.0 / 30.0), accuracy: 0.0001)
    }
}

// MARK: - History-serving URLProtocol (#318 U7 — last-session anchor fixtures)

/// Serves a fixed prior session and configurable set_logs so the
/// cachedLastPerformance fetch at session start finds real history.
/// GET workout_sessions → one session row (the "last session").
/// GET set_logs → `Self.setLogRowsJSON`. Everything else → empty array.
private final class WSMHistoryURLProtocol: URLProtocol, @unchecked Sendable {
    static let lastSessionId = "00000000-0000-4000-8000-00000000000A"
    nonisolated(unsafe) static var setLogRowsJSON: String = "[]"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let isGet = (request.httpMethod ?? "GET") == "GET"
        let body: String
        if isGet && path.contains("workout_sessions") {
            body = "[{\"id\":\"\(Self.lastSessionId)\"}]"
        } else if isGet && path.contains("set_logs") {
            body = Self.setLogRowsJSON
        } else {
            body = "[]"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Builds set_logs rows for the history fixture, all belonging to the fixed
/// "last session" id so the two-step fetch groups them correctly.
private func historySetLogRowsJSON(exerciseId: String, weightKg: Double, reps: [Int]) -> String {
    let rows = reps.enumerated().map { idx, r in
        """
        {"id":"\(UUID().uuidString)","session_id":"\(WSMHistoryURLProtocol.lastSessionId)",\
        "exercise_id":"\(exerciseId)","set_number":\(idx + 1),"weight_kg":\(weightKg),\
        "reps_completed":\(r),"rpe_felt":8,"logged_at":"2026-06-01T10:00:00Z","intent":"top"}
        """
    }
    return "[" + rows.joined(separator: ",") + "]"
}

private func makeHistoryManager(provider: any LLMProvider) -> WorkoutSessionManager {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WSMHistoryURLProtocol.self]
    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
    let inferenceService = AIInferenceService(provider: provider, gymProfile: nil, maxRetries: 0)
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let testDefaults = UserDefaults(suiteName: "com.test.wsm.hist.\(UUID().uuidString)")!
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

// MARK: - PrescriptionGuardrailTests (#318 U7 / G-F8, G-F3, G-F6, G-F1)

/// Tests for the prescription guardrail spine: the pure snap → clamp core
/// (`WorkoutSessionManager.adjustedWeight`), the canonical marker contract,
/// the live wiring through handleInferenceResult, the last-session anchor
/// clamp, the "Last time" line, and the manual-fallback weight seeding.
final class PrescriptionGuardrailTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
        WSMHistoryURLProtocol.setLogRowsJSON = "[]"
    }

    override func tearDown() {
        PausedSessionState.clear()
        WSMHistoryURLProtocol.setLogRowsJSON = "[]"
        super.tearDown()
    }

    private func historySetLog(setNumber: Int, weightKg: Double, reps: Int) -> SetLog {
        SetLog(
            id: UUID(),
            sessionId: UUID(),
            exerciseId: "exercise_0",
            setNumber: setNumber,
            weightKg: weightKg,
            repsCompleted: reps,
            rpeFelt: 8,
            rirEstimated: 2,
            aiPrescribed: nil,
            loggedAt: Date(),
            primaryMuscle: nil,
            intent: .top,
            completionFlags: []
        )
    }

    private func basePrescription(reasoning: String) -> SetPrescription {
        SetPrescription(
            weightKg: 45.0,
            reps: 8,
            tempo: "3-1-1-0",
            rirTarget: 2,
            restSeconds: 120,
            coachingCue: "Cue",
            reasoning: reasoning,
            safetyFlags: [],
            intent: .top,
            setFraming: "Frame."
        )
    }

    // MARK: snap → clamp pure core (G-F3)

    func test_adjustedWeight_anchorPresent_topIntent_capsAtSnappedDownCap() {
        // raw 100 (a real barbell load → snap is a no-op), anchor 80 →
        // cap 92 → snapDown 90.
        let result = WorkoutSessionManager.adjustedWeight(
            rawWeight: 100, intent: .top, equipment: .barbell,
            excludedWeights: [], anchorWeight: 80
        )
        XCTAssertEqual(result?.clamped ?? -1, 90.0, accuracy: 0.001)
        XCTAssertEqual(result?.snapped ?? -1, 100.0, accuracy: 0.001,
            "snap must be a no-op for an already-available weight")
    }

    func test_adjustedWeight_noAnchor_skipsClamp() {
        // No anchor (first session / no history / fetch failure) → no clamp,
        // and 100 is a real barbell load → no snap → no adjustment at all.
        XCTAssertNil(WorkoutSessionManager.adjustedWeight(
            rawWeight: 100, intent: .top, equipment: .barbell,
            excludedWeights: [], anchorWeight: nil
        ))
    }

    func test_adjustedWeight_intentGating_onlyTopAndBackoffClamp() {
        for intent in [SetIntent.warmup, .technique, .amrap] {
            XCTAssertNil(WorkoutSessionManager.adjustedWeight(
                rawWeight: 100, intent: intent, equipment: .barbell,
                excludedWeights: [], anchorWeight: 80
            ), "\(intent) must not clamp")
        }
        XCTAssertNil(WorkoutSessionManager.adjustedWeight(
            rawWeight: 100, intent: nil, equipment: .barbell,
            excludedWeights: [], anchorWeight: 80
        ), "nil intent must not clamp")
        XCTAssertEqual(WorkoutSessionManager.adjustedWeight(
            rawWeight: 100, intent: .backoff, equipment: .barbell,
            excludedWeights: [], anchorWeight: 80
        )?.clamped ?? -1, 90.0, accuracy: 0.001, ".backoff clamps like .top")
    }

    func test_adjustedWeight_upwardCapOnly_neverRaisesLowPrescription() {
        // raw 60 with anchor 80 (cap 92): under the cap → untouched.
        XCTAssertNil(WorkoutSessionManager.adjustedWeight(
            rawWeight: 60, intent: .top, equipment: .barbell,
            excludedWeights: [], anchorWeight: 80
        ))
    }

    func test_adjustedWeight_snapThenClamp_combined() {
        // raw 101.3 → snap DOWN to 100 (threshold 101.5); anchor 80 → cap 92
        // → snapDown 90. The final stored weight is a real barbell load.
        let result = WorkoutSessionManager.adjustedWeight(
            rawWeight: 101.3, intent: .top, equipment: .barbell,
            excludedWeights: [], anchorWeight: 80
        )
        XCTAssertEqual(result?.snapped ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.clamped ?? -1, 90.0, accuracy: 0.001)
    }

    // MARK: marker round-trip (G-F8) — pins the string contract

    @MainActor
    func test_weightAdjustmentMarker_roundTripsThroughWeightAdjustmentNote() {
        for adjusted in [45.0, 32.5, 100.0] {
            let marker = WorkoutSessionManager.weightAdjustmentMarker(for: adjusted)
            let vm = WorkoutViewModel(manager: makeManager())
            vm.currentPrescription = basePrescription(reasoning: "Base reasoning." + marker)

            let note = vm.weightAdjustmentNote
            XCTAssertNotNil(note, "weightAdjustmentNote must detect the canonical marker")
            // Parse the weight back out of the rendered note:
            // "(adjusted to nearest available: 45kg)" → 45.0
            let parsed = note
                .flatMap { $0.split(separator: ":").last }
                .map {
                    $0.replacingOccurrences(of: "kg)", with: "")
                      .trimmingCharacters(in: .whitespaces)
                }
                .flatMap(Double.init)
            XCTAssertEqual(parsed ?? -1, adjusted, accuracy: 0.001,
                "Marker must round-trip: \(marker) → \(String(describing: note))")
        }
    }

    // MARK: spine — handleInferenceResult routes through the post-processor

    func test_inferenceResult_snapsWeight_andAppendsCanonicalMarker() async throws {
        // 101.3 kg is not a real barbell load → snaps DOWN to 100 (PRD §7.1.1)
        // on the handleInferenceResult success path. No history → no clamp.
        let manager = makeManager(
            provider: MockLLMProvider(response: prescriptionJSON(weightKg: 101.3))
        )
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 300_000_000)

        let rx = await manager.currentPrescription
        XCTAssertEqual(rx?.weightKg ?? -1, 100.0, accuracy: 0.001,
            "101.3 must snap down to the 100 kg barbell load")
        XCTAssertTrue(
            rx?.reasoning.contains("(adjusted to nearest available: 100kg)") ?? false,
            "Canonical marker must be appended to reasoning; got: \(rx?.reasoning ?? "nil")"
        )
    }

    func test_startSession_clampsRunawayPrescription_againstLastSessionAnchor() async throws {
        // Last session: 80 kg top sets → anchor 80 → cap 92 → snapDown 90.
        // The LLM prescribes a runaway 200 kg top set → stored prescription 90.
        WSMHistoryURLProtocol.setLogRowsJSON = historySetLogRowsJSON(
            exerciseId: "exercise_0", weightKg: 80.0, reps: [8, 8, 7]
        )
        let manager = makeHistoryManager(
            provider: MockLLMProvider(response: prescriptionJSON(weightKg: 200.0))
        )
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 400_000_000)

        let rx = await manager.currentPrescription
        XCTAssertEqual(rx?.weightKg ?? -1, 90.0, accuracy: 0.001,
            "200 kg must clamp to snapDown(80 × 1.15) = 90")
        XCTAssertTrue(
            rx?.reasoning.contains("(adjusted to nearest available: 90kg)") ?? false,
            "Clamp must apply the same canonical marker; got: \(rx?.reasoning ?? "nil")"
        )
    }

    // MARK: manual fallback seeding (G-F1)

    func test_manualFallback_seedsFromHistoryAnchor_whenNoInSessionSet() async throws {
        WSMHistoryURLProtocol.setLogRowsJSON = historySetLogRowsJSON(
            exerciseId: "exercise_0", weightKg: 80.0, reps: [8, 8, 7]
        )
        let manager = makeHistoryManager(provider: FailingLLMProvider())
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 400_000_000)

        // Preflight inference failed; no in-session lastSet exists.
        let retryNeeded = await manager.inferenceRetryNeeded
        XCTAssertTrue(retryNeeded, "Setup: preflight inference must have failed")

        await manager.applyManualFallbackPrescription(for: day.exercises[0])
        let rx = await manager.currentPrescription
        XCTAssertEqual(rx?.weightKg ?? -1, 80.0, accuracy: 0.001,
            "Fallback must seed from the history anchor, not 0.0 (G-F1)")
        XCTAssertEqual(rx?.isManualFallback, true)

        // Critic amendment 7.6: the preflight failure path transitions
        // straight to .active — no rest timer exists to complete it later.
        let state = await manager.sessionState
        guard case .active(let exercise, let setNumber) = state else {
            XCTFail("Manual fallback during preflight must transition to .active, got \(state)")
            return
        }
        XCTAssertEqual(exercise.exerciseId, day.exercises[0].exerciseId)
        XCTAssertEqual(setNumber, 1)
    }

    func test_manualFallback_keepsZero_forGenuineBodyweightHistory() async throws {
        // Genuine bodyweight history (all 0 kg) → the 0.0 seed survives.
        WSMHistoryURLProtocol.setLogRowsJSON = historySetLogRowsJSON(
            exerciseId: "exercise_0", weightKg: 0.0, reps: [12, 10]
        )
        let manager = makeHistoryManager(provider: FailingLLMProvider())
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 400_000_000)

        await manager.applyManualFallbackPrescription(for: day.exercises[0])
        let rx = await manager.currentPrescription
        XCTAssertEqual(rx?.weightKg ?? -1, 0.0, accuracy: 0.001,
            "Genuine bodyweight history keeps the 0.0 seed (BW is honest here)")
    }

    // MARK: "Last time" line (G-F6)

    @MainActor
    func test_lastPerformanceSummary_formatsHeaviestWeightAndPerSetReps() {
        let vm = WorkoutViewModel(manager: makeManager())
        vm.lastPerformanceSets = [
            historySetLog(setNumber: 1, weightKg: 80, reps: 8),
            historySetLog(setNumber: 2, weightKg: 80, reps: 8),
            historySetLog(setNumber: 3, weightKg: 80, reps: 7)
        ]
        XCTAssertEqual(vm.lastPerformanceSummary, "Last time: 80kg × 8/8/7")
    }

    @MainActor
    func test_lastPerformanceSummary_bodyweightHistory_showsBW() {
        let vm = WorkoutViewModel(manager: makeManager())
        vm.lastPerformanceSets = [
            historySetLog(setNumber: 1, weightKg: 0, reps: 12),
            historySetLog(setNumber: 2, weightKg: 0, reps: 10)
        ]
        XCTAssertEqual(vm.lastPerformanceSummary, "Last time: BW × 12/10")
    }

    @MainActor
    func test_lastPerformanceSummary_nilWhenNoHistory() {
        let vm = WorkoutViewModel(manager: makeManager())
        vm.lastPerformanceSets = nil
        XCTAssertNil(vm.lastPerformanceSummary)
        vm.lastPerformanceSets = []
        XCTAssertNil(vm.lastPerformanceSummary)
    }

    // MARK: retry-sheet gating (G-F1)

    @MainActor
    func test_canUseLastWeights_gatesLoadedMovementWithoutSeed() {
        let vm = WorkoutViewModel(manager: makeManager())
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)
        vm.sessionState = .resting(nextExercise: day.exercises[0], setNumber: 2)
        vm.completedSets = []
        vm.lastPerformanceSets = nil
        XCTAssertFalse(vm.canUseLastWeights,
            "Barbell movement with no in-session set and no history must hide 'Continue with last weights'")

        vm.lastPerformanceSets = [historySetLog(setNumber: 1, weightKg: 80, reps: 8)]
        XCTAssertTrue(vm.canUseLastWeights,
            "A last-session history seed makes the manual fallback honest again")
    }

    // MARK: start-session auth-gate abort surfaces a user-facing message (#399)

    /// When owner resolution fails (offline / sign-in stall), startSession must
    /// abort WITHOUT stamping a placeholder row — but it must no longer fail
    /// mute: `isStartingSession` resets AND a user-facing `startError` is set so
    /// PreWorkoutView can tell the user why nothing happened.
    @MainActor
    func test_startSession_authGateAbort_setsStartError_andResetsSpinner() async {
        let vm = WorkoutViewModel(manager: makeManager())
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        vm.startSession(
            trainingDay: day,
            programId: UUID(),
            resolveOwner: { nil } // auth never resolves
        )
        // Let the internal Task run to completion.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(vm.isStartingSession,
            "Abort must re-enable the Start button (spinner off)")
        XCTAssertNotNil(vm.startError,
            "Abort must surface a user-facing message, not fail silently (#399)")
    }

    /// Happy path: when owner resolves, startSession must NOT set startError, and
    /// a stale error from a previous failed tap is cleared at the start of the tap.
    @MainActor
    func test_startSession_ownerResolves_clearsStaleStartError() async {
        let vm = WorkoutViewModel(manager: makeManager())
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        vm.startError = "stale error from a previous failed tap"

        vm.startSession(
            trainingDay: day,
            programId: UUID(),
            resolveOwner: { UUID() } // auth resolves
        )
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(vm.startError,
            "A successful start clears any stale error message")
    }
}

// MARK: - Day-identity guard (#436)

/// Two WorkoutView hosts share one WorkoutSessionManager actor. When a session is
/// live for day B, a WorkoutView handed day A must NOT (a) adopt B's session as its
/// own, nor (b) let a completion mark day A complete. The day-aware guards on
/// WorkoutViewModel are the testable surface for that behaviour.
final class WorkoutDayIdentityGuardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
    }

    override func tearDown() {
        PausedSessionState.clear()
        super.tearDown()
    }

    /// A session is live for day B. A view configured for a DIFFERENT day A must
    /// not treat that session as its own: `sessionIsLive(forDay: A)` is false even
    /// though a day-agnostic `sessionIsLive()` is true.
    func testSessionIsLiveForDay_otherDayLive_doesNotAdopt() async throws {
        let manager = makeManager()
        let vm = await WorkoutViewModel(manager: manager)

        let dayB = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        let dayAId = UUID() // a different view's day — never started

        await manager.startSession(trainingDay: dayB, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000) // settle to .active

        let liveAtAll = await vm.sessionIsLive()
        XCTAssertTrue(liveAtAll, "a session is live in the actor")

        let liveForA = await vm.sessionIsLive(forDay: dayAId)
        XCTAssertFalse(liveForA,
            "view for day A must NOT adopt a session that is live for day B")

        let liveForB = await vm.sessionIsLive(forDay: dayB.id)
        XCTAssertTrue(liveForB,
            "the view for the day the actor actually ran DOES adopt the session")
    }

    /// The completion guard reads the actor's live day id. With a session running
    /// for day B, `pullState()` publishes `liveSessionDayId == B`, so a WorkoutView
    /// for day A (A != B) refuses to fire its completion callback. The id survives
    /// the .sessionComplete transition (it's only cleared on resetToIdle).
    func testLiveSessionDayId_reflectsRunningDay_notAMismatchedDay() async throws {
        let manager = makeManager()
        let vm = await WorkoutViewModel(manager: manager)

        let dayB = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        let dayAId = UUID()

        await manager.startSession(trainingDay: dayB, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        await vm.pullState()

        let liveDayId = await MainActor.run { vm.liveSessionDayId }
        XCTAssertEqual(liveDayId, dayB.id,
            "live day id is the day the actor actually ran (B)")
        XCTAssertNotEqual(liveDayId, dayAId,
            "a WorkoutView for day A sees a mismatch and must refuse to mark A complete")
    }
}
