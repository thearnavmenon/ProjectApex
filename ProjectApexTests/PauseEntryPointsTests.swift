// PauseEntryPointsTests.swift
// ProjectApexTests
//
// #466 — Pause flow: collapse to one pause function (kill the duplicate doorway).
//
// There used to be two byte-identical pause paths: the ••• menu's
// `onPauseSession()` and the AI-retry sheet's `onPauseFromRetrySheet()`. These
// tests pin that the retry-sheet entry point is now a THIN SHIM that delegates to
// `onPauseSession()` — one underlying pause path — while still dismissing the
// retry sheet first so it does not briefly overlay the paused screen.
//
//   • Delegation: `onPauseFromRetrySheet()` calls `onPauseSession()` exactly once
//     and clears `showInferenceRetrySheet`.
//   • Behaviour preserved: through a real WorkoutSessionManager, the retry-sheet
//     entry point still drives the actor through `pauseSession()` (a durable
//     PausedSessionState is written, the actor resets to .idle).
//
// Mirrors the file-private real-manager harness in RunDayRoutingTests
// (real WorkoutSessionManager actor, ephemeral UserDefaults suite, sentinel
// clearing in setUp/tearDown).

import XCTest
import Foundation
@testable import ProjectApex

// MARK: - Local test helpers (file-private, mirroring RunDayRoutingTests)

private struct PEPMockLLMProvider: LLMProvider {
    let response: String
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        response
    }
}

/// Always returns HTTP 201 — prevents real network calls and WAQ retry loops.
private final class PEPAlwaysSucceedURLProtocol: URLProtocol, @unchecked Sendable {
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
    config.protocolClasses = [PEPAlwaysSucceedURLProtocol.self]
    return SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
}

private func prescriptionJSON() -> String {
    """
    {
      "set_prescription": {
        "weight_kg": 80.0,
        "reps": 8,
        "tempo": "3-1-1-0",
        "rir_target": 2,
        "rest_seconds": 120,
        "coaching_cue": "Drive through the bar",
        "reasoning": "Based on recent performance trend.",
        "safety_flags": [],
        "intent": "top",
        "set_framing": "Heaviest work of the day. Brace and grind."
      }
    }
    """
}

private func makeManager() -> WorkoutSessionManager {
    let inferenceService = AIInferenceService(
        provider: PEPMockLLMProvider(response: prescriptionJSON()),
        gymProfile: nil,
        maxRetries: 0
    )
    let supabase = makeTestSupabase()
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let suiteName = "com.test.pep.\(UUID().uuidString)"
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

private func makeTrainingDay() -> TrainingDay {
    let exercise = PlannedExercise(
        id: UUID(),
        exerciseId: "exercise_0",
        name: "Exercise 0",
        primaryMuscle: "pectoralis_major",
        synergists: ["triceps_brachii"],
        equipmentRequired: .barbell,
        sets: 1,
        repRange: RepRange(min: 6, max: 10),
        tempo: "3-1-1-0",
        restSeconds: 90,
        rirTarget: 2,
        coachingCues: ["Focus on form"]
    )
    return TrainingDay(
        id: UUID(),
        dayOfWeek: 1,
        dayLabel: "Push_A",
        exercises: [exercise],
        sessionNotes: nil
    )
}

/// Spy subclass that records every call to `onPauseSession()` so the delegation
/// from the retry-sheet shim can be observed by call count (the issue's TDD ask).
@MainActor
private final class SpyWorkoutViewModel: WorkoutViewModel {
    private(set) var onPauseSessionCallCount = 0
    override func onPauseSession() {
        onPauseSessionCallCount += 1
        super.onPauseSession()
    }
}

// MARK: - PauseEntryPointsTests

@MainActor
final class PauseEntryPointsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
    }

    override func tearDown() {
        PausedSessionState.clear()
        super.tearDown()
    }

    // The retry-sheet entry point is a thin shim: it delegates to the single
    // `onPauseSession()` path and dismisses the retry sheet first.
    func testOnPauseFromRetrySheet_delegatesToOnPauseSession_andDismissesSheet() {
        let vm = SpyWorkoutViewModel(manager: makeManager())
        vm.showInferenceRetrySheet = true

        vm.onPauseFromRetrySheet()

        XCTAssertEqual(vm.onPauseSessionCallCount, 1,
            "onPauseFromRetrySheet must delegate to the single onPauseSession path")
        XCTAssertFalse(vm.showInferenceRetrySheet,
            "the retry sheet must dismiss before the actor goes idle")
    }

    // Behaviour preserved end-to-end: the shim still drives the real actor through
    // pauseSession() — a durable paused snapshot is written and the actor resets.
    func testOnPauseFromRetrySheet_stillPausesTheLiveSession() async throws {
        let manager = makeManager()
        let vm = WorkoutViewModel(manager: manager)
        let day = makeTrainingDay()

        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000) // settle to .active
        await vm.pullState()
        vm.showInferenceRetrySheet = true

        vm.onPauseFromRetrySheet()
        try await Task.sleep(nanoseconds: 200_000_000) // let the pause Task run
        await vm.pullState()

        XCTAssertFalse(vm.showInferenceRetrySheet, "retry sheet must dismiss")
        XCTAssertNotNil(PausedSessionState.load(),
            "the pause path must persist a durable PausedSessionState")
        XCTAssertEqual(vm.sessionState, .idle,
            "pauseSession resets the actor to idle after saving the snapshot")
    }
}
