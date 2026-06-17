// ActiveSessionCoordinatorTests.swift
// ProjectApexTests
//
// #440 — the coordinator is the single @Observable owner of live/paused day
// identity. These tests drive a real WorkoutSessionManager actor and call the
// coordinator's deterministic refresh() (rather than waiting on its 500ms timer),
// asserting that one refresh produces ONE ActiveSession value off which every
// derived accessor (badge / banner / day-detail) agrees — no poll-lag disagreement.

import XCTest
import Foundation
@testable import ProjectApex

// MARK: - Local test helpers (file-private, mirroring WorkoutSessionManagerTests)

private struct ASCMockLLMProvider: LLMProvider {
    let response: String
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        response
    }
}

/// Always returns HTTP 201 — prevents real network calls and WAQ retry loops.
private final class ASCAlwaysSucceedURLProtocol: URLProtocol, @unchecked Sendable {
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
    config.protocolClasses = [ASCAlwaysSucceedURLProtocol.self]
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
        provider: ASCMockLLMProvider(response: prescriptionJSON()),
        gymProfile: nil,
        maxRetries: 0
    )
    let supabase = makeTestSupabase()
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let suiteName = "com.test.asc.\(UUID().uuidString)"
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

/// Saves a paused sentinel for `day` directly (as pauseSession does in production),
/// returning its sessionId so a test can assert the coordinator surfaces it.
@discardableResult
private func savePausedSentinel(for day: TrainingDay) -> UUID {
    let sessionId = UUID()
    PausedSessionState(
        sessionId: sessionId,
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
    ).save()
    return sessionId
}

// MARK: - ActiveSessionCoordinatorTests

@MainActor
final class ActiveSessionCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
    }

    override func tearDown() {
        PausedSessionState.clear()
        super.tearDown()
    }

    // 1. Idle when nothing is running and no sentinel exists.
    func testIdle_whenNoSessionAndNoSentinel_publishesIdle() async {
        let manager = makeManager()
        let coordinator = ActiveSessionCoordinator(manager: manager)

        await coordinator.refresh()

        XCTAssertEqual(coordinator.session, .idle)
        XCTAssertFalse(coordinator.isLive)
        XCTAssertFalse(coordinator.pausedSessionExists)
        XCTAssertNil(coordinator.liveTrainingDayId)
    }

    // 2. Live after start — dayId AND sessionId are the actor's.
    func testLive_afterStartSession_publishesLiveWithDayAndSessionId() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let coordinator = ActiveSessionCoordinator(manager: manager)
        await coordinator.refresh()

        let actorSessionId = await manager.currentSessionId
        XCTAssertEqual(coordinator.session, .live(dayId: day.id, sessionId: actorSessionId!))
        XCTAssertTrue(coordinator.isLive)
        XCTAssertEqual(coordinator.liveTrainingDayId, day.id)
    }

    // 3. Paused after a sentinel is written and the actor is idle.
    func testPaused_afterPauseSession_publishesPausedWithSentinelIdentity() async {
        let manager = makeManager()
        let day = makeTrainingDay()
        let sessionId = savePausedSentinel(for: day)

        let coordinator = ActiveSessionCoordinator(manager: manager)
        await coordinator.refresh()

        XCTAssertEqual(coordinator.session, .paused(dayId: day.id, sessionId: sessionId))
        XCTAssertTrue(coordinator.pausedSessionExists)
        XCTAssertFalse(coordinator.isLive)
    }

    // 4. Precedence — a live actor wins over a stale paused sentinel.
    func testLiveWinsOverStalePausedSentinel() async throws {
        let manager = makeManager()
        let liveDay = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        // A stale sentinel for a DIFFERENT day is lying around.
        savePausedSentinel(for: makeTrainingDay())
        await manager.startSession(trainingDay: liveDay, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let coordinator = ActiveSessionCoordinator(manager: manager)
        await coordinator.refresh()

        XCTAssertTrue(coordinator.isLive, "A live actor must win over a stale paused sentinel")
        XCTAssertEqual(coordinator.liveTrainingDayId, liveDay.id)
        XCTAssertFalse(coordinator.pausedSessionExists)
    }

    // 5. THE keystone — one refresh, every derived accessor agrees off ONE enum.
    func testSingleValueDrivesBadgeBannerDayDetail_noDisagreement() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let coordinator = ActiveSessionCoordinator(manager: manager)
        await coordinator.refresh()

        // Badge (isLive), banner (pausedSessionExists), day-detail (isLive(forDay:)),
        // calendar (liveTrainingDayId) — all derived from the single .live enum, so
        // there is no poll-lag window in which they could disagree.
        XCTAssertTrue(coordinator.isLive)
        XCTAssertFalse(coordinator.pausedSessionExists)
        XCTAssertTrue(coordinator.isLive(forDay: day.id))
        XCTAssertFalse(coordinator.isPaused(forDay: day.id))
        XCTAssertEqual(coordinator.liveTrainingDayId, day.id)
    }

    // 6. Day-scoped accessors return false for a different day.
    func testDayScopedAccessors_returnFalseForOtherDay() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        let otherDayId = UUID()
        await manager.startSession(trainingDay: day, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let coordinator = ActiveSessionCoordinator(manager: manager)
        await coordinator.refresh()

        XCTAssertTrue(coordinator.isLive(forDay: day.id))
        XCTAssertFalse(coordinator.isLive(forDay: otherDayId))
        XCTAssertFalse(coordinator.isPaused(forDay: otherDayId))
    }

    // 7. Single resume path — .paused → .live, sentinel cleared.
    func testResume_clearsPausedSentinel_coordinatorReturnsToLive() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)
        let coordinator = ActiveSessionCoordinator(manager: manager)

        // Persist a sentinel matching the day → coordinator is paused.
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
        paused.save()

        await coordinator.refresh()
        XCTAssertTrue(coordinator.pausedSessionExists, "precondition: coordinator is paused")

        // Resume through the actor — this is the single resume path; it clears the sentinel.
        let resumed = await manager.resumeSession(
            pausedState: paused, trainingDay: day, completedSetLogs: []
        )
        XCTAssertTrue(resumed, "precondition: resume must succeed for a matching signature")
        try await Task.sleep(nanoseconds: 200_000_000)

        await coordinator.refresh()
        XCTAssertTrue(coordinator.isLive, "After resume the coordinator must reflect .live")
        XCTAssertFalse(coordinator.pausedSessionExists, "Resume clears the sentinel")
        XCTAssertEqual(coordinator.liveTrainingDayId, day.id)
    }

    // 8. #447 interplay — a signature mismatch rejects resume; coordinator stays not-live,
    //    sentinel preserved.
    func testResumeRejectedOnSignatureMismatch_doesNotGoLive() async throws {
        let manager = makeManager()
        let pausedDay = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)
        // The CURRENT day has a different exercise list (program edited since pause).
        let editedDay = TrainingDay(
            id: pausedDay.id,
            dayOfWeek: pausedDay.dayOfWeek,
            dayLabel: pausedDay.dayLabel,
            exercises: makeTrainingDay(exerciseCount: 3, setsPerExercise: 2).exercises,
            sessionNotes: nil
        )
        let coordinator = ActiveSessionCoordinator(manager: manager)

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
        paused.save()

        await coordinator.refresh()
        XCTAssertTrue(coordinator.pausedSessionExists, "precondition: coordinator is paused")

        let resumed = await manager.resumeSession(
            pausedState: paused, trainingDay: editedDay, completedSetLogs: []
        )
        XCTAssertFalse(resumed, "A signature mismatch must reject the resume (#447)")

        await coordinator.refresh()
        XCTAssertFalse(coordinator.isLive, "A rejected resume must not make the coordinator go live")
        XCTAssertNotNil(PausedSessionState.load(), "A rejected resume must preserve the sentinel")
    }

    // 9. #461 — polling/refresh (a tab open or the 500ms tick) must NEVER auto-revive a
    //    paused session. The actor stays .idle across repeated refreshes; only an explicit
    //    resumeSession transitions to live. Locks the invariant behind the on-appear fix
    //    that moved resume from view-appearance to a deliberate tap.
    func testRefresh_neverAutoResumesPausedSession_onlyExplicitResumeGoesLive() async throws {
        let manager = makeManager()
        let day = makeTrainingDay(exerciseCount: 2, setsPerExercise: 2)
        let coordinator = ActiveSessionCoordinator(manager: manager)

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
        paused.save()

        // Repeated refreshes simulate tab opens / the 500ms poll. None may revive the actor.
        for _ in 0..<3 {
            await coordinator.refresh()
            let state = await manager.sessionState
            XCTAssertEqual(state, .idle, "refresh()/poll must not auto-resume — the actor stays idle")
            XCTAssertTrue(coordinator.pausedSessionExists, "the sentinel remains until a deliberate resume")
            XCTAssertFalse(coordinator.isLive)
        }

        // Only an explicit resume — the deliberate tap path — transitions to live.
        let resumed = await manager.resumeSession(pausedState: paused, trainingDay: day, completedSetLogs: [])
        XCTAssertTrue(resumed)
        try await Task.sleep(nanoseconds: 200_000_000)
        await coordinator.refresh()
        XCTAssertTrue(coordinator.isLive, "the session goes live only after the explicit resume")
        XCTAssertFalse(coordinator.pausedSessionExists)
    }

    // 10. #462 — the NowTrainingBar state is a pure function of the coordinator flags.
    //     Live wins over a (stale) paused sentinel, mirroring coordinator precedence.
    func testNowTrainingBarState_pureResolve_allPermutations() {
        XCTAssertEqual(NowTrainingBar.BarState.resolve(isLive: true,  pausedExists: false), .live)
        XCTAssertEqual(NowTrainingBar.BarState.resolve(isLive: false, pausedExists: true),  .paused)
        XCTAssertEqual(NowTrainingBar.BarState.resolve(isLive: false, pausedExists: false), .idle)
        // Defined-but-impossible: a live actor must win over a stale paused sentinel.
        XCTAssertEqual(NowTrainingBar.BarState.resolve(isLive: true,  pausedExists: true),  .live)
    }

    // 11. #462 — driven off the real coordinator: the bar state agrees with the
    //     single ActiveSession enum at idle / paused / live, with no disagreement.
    func testNowTrainingBarState_matchesCoordinator_idlePausedLive() async throws {
        // Idle.
        let idleManager = makeManager()
        let idleCoordinator = ActiveSessionCoordinator(manager: idleManager)
        await idleCoordinator.refresh()
        XCTAssertEqual(
            NowTrainingBar.BarState.resolve(isLive: idleCoordinator.isLive, pausedExists: idleCoordinator.pausedSessionExists),
            .idle
        )

        // Paused (sentinel + idle actor).
        let pausedManager = makeManager()
        let pausedDay = makeTrainingDay()
        savePausedSentinel(for: pausedDay)
        let pausedCoordinator = ActiveSessionCoordinator(manager: pausedManager)
        await pausedCoordinator.refresh()
        XCTAssertEqual(
            NowTrainingBar.BarState.resolve(isLive: pausedCoordinator.isLive, pausedExists: pausedCoordinator.pausedSessionExists),
            .paused
        )
        PausedSessionState.clear()

        // Live.
        let liveManager = makeManager()
        let liveDay = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)
        await liveManager.startSession(trainingDay: liveDay, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        let liveCoordinator = ActiveSessionCoordinator(manager: liveManager)
        await liveCoordinator.refresh()
        XCTAssertEqual(
            NowTrainingBar.BarState.resolve(isLive: liveCoordinator.isLive, pausedExists: liveCoordinator.pausedSessionExists),
            .live
        )
    }
}
