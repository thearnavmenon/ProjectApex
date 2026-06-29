// RunDayRoutingTests.swift
// ProjectApexTests
//
// #441 — retire the sticky `crashResumeDay` / `crashResumeToPass` overrides in
// ContentView. Completion routing and the hosted day are now sourced from the
// RUN day (the actor's live/paused day via the coordinator + liveSessionDayId),
// never from sticky view state. These tests pin the run-day invariants:
//
//   • liveSessionDayId always names the day the actor actually ran (start OR resume),
//   • it survives .sessionComplete and is cleared on resetToIdle,
//   • markDay* routes purely by (dayId, weekId),
//   • the STATE-4 regression: resume B → leave without Done → start A routes to A,
//   • the pure `ContentView.hostDay(...)` render-target helper,
//   • resume is idempotent under a second call.
//
// Mirrors the file-private helpers in ActiveSessionCoordinatorTests (real
// WorkoutSessionManager actor, ephemeral UserDefaults suite, sentinel clearing
// in setUp/tearDown).

import XCTest
import Foundation
@testable import ProjectApex

// MARK: - Local test helpers (file-private, mirroring ActiveSessionCoordinatorTests)

private struct RDRMockLLMProvider: LLMProvider {
    let response: String
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        response
    }
}

/// Always returns HTTP 201 — prevents real network calls and WAQ retry loops.
private final class RDRAlwaysSucceedURLProtocol: URLProtocol, @unchecked Sendable {
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
    config.protocolClasses = [RDRAlwaysSucceedURLProtocol.self]
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
        provider: RDRMockLLMProvider(response: prescriptionJSON()),
        gymProfile: nil,
        maxRetries: 0
    )
    let supabase = makeTestSupabase()
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let suiteName = "com.test.rdr.\(UUID().uuidString)"
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

private func makeTrainingDay(
    label: String = "Push_A",
    exerciseCount: Int = 2,
    setsPerExercise: Int = 2
) -> TrainingDay {
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
        dayLabel: label,
        exercises: exercises,
        sessionNotes: nil
    )
}

/// Creates a ProgramViewModel backed by no-op services (mirrors SkipFeatureTests'
/// factory). Only the pure mark/route methods are exercised — no network calls.
@MainActor
private func makeProgramViewModel() -> ProgramViewModel {
    let supabase = makeTestSupabase()
    let provider: any LLMProvider = RDRMockLLMProvider(response: "{}")
    let memory = MemoryService(supabase: supabase, embeddingAPIKey: "test")
    return ProgramViewModel(
        supabaseClient: supabase,
        macroPlanService: MacroPlanService(provider: provider),
        sessionPlanService: SessionPlanService(
            provider: provider,
            memoryService: memory,
            supabaseClient: supabase
        ),
        userId: UUID(),
        resolveOwner: { UUID() }
    )
}

/// Builds a single-week mesocycle from the supplied days so the pure `hostDay`
/// helper has a real lookup surface.
private func makeMesocycle(days: [TrainingDay]) -> Mesocycle {
    let week = TrainingWeek(
        id: UUID(),
        weekNumber: 1,
        phase: .accumulation,
        trainingDays: days
    )
    return Mesocycle(
        id: UUID(),
        userId: UUID(),
        createdAt: Date(),
        isActive: true,
        weeks: [week],
        totalWeeks: 12,
        periodizationModel: "linear_periodization"
    )
}

// MARK: - RunDayRoutingTests

@MainActor
final class RunDayRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
    }

    override func tearDown() {
        PausedSessionState.clear()
        super.tearDown()
    }

    // 1. After a fresh start, liveSessionDayId equals the started day.
    func testLiveSessionDayId_afterStartSession_equalsStartedDay() async throws {
        let manager = makeManager()
        let vm = WorkoutViewModel(manager: manager)
        let dayA = makeTrainingDay(exerciseCount: 1, setsPerExercise: 1)

        await manager.startSession(trainingDay: dayA, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        await vm.pullState()

        XCTAssertEqual(vm.liveSessionDayId, dayA.id,
            "liveSessionDayId must name the day the actor actually started")
    }

    // 2. After a resume, liveSessionDayId equals the RESUMED day — not nextIncompleteDay.
    func testLiveSessionDayId_afterResume_equalsResumedDay_notNextIncompleteDay() async throws {
        let manager = makeManager()
        let vm = WorkoutViewModel(manager: manager)
        // dayA would be nextIncompleteDay; dayB is the paused day we resume.
        let dayA = makeTrainingDay(label: "Push_A", exerciseCount: 1, setsPerExercise: 1)
        let dayB = makeTrainingDay(label: "Pull_B", exerciseCount: 2, setsPerExercise: 2)
        XCTAssertNotEqual(dayA.id, dayB.id)

        let paused = PausedSessionState(
            sessionId: UUID(),
            trainingDayId: dayB.id,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: dayB.dayLabel,
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date(),
            exerciseSignature: PausedSessionState.exerciseSignature(for: dayB)
        )

        let resumed = await manager.resumeSession(
            pausedState: paused, trainingDay: dayB, completedSetLogs: []
        )
        XCTAssertTrue(resumed, "precondition: resume must succeed for a matching signature")
        try await Task.sleep(nanoseconds: 200_000_000)
        await vm.pullState()

        XCTAssertEqual(vm.liveSessionDayId, dayB.id,
            "after resume the live day is the resumed day B")
        XCTAssertNotEqual(vm.liveSessionDayId, dayA.id,
            "the resumed day must NOT be confused with nextIncompleteDay (A)")
    }

    // 3. liveSessionDayId survives the .sessionComplete transition.
    func testLiveSessionDayId_survivesSessionComplete() async throws {
        let manager = makeManager()
        let vm = WorkoutViewModel(manager: manager)
        let dayA = makeTrainingDay(exerciseCount: 1, setsPerExercise: 2)

        await manager.startSession(trainingDay: dayA, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        // Log one set so endSessionEarly produces a real summary (not the zero-set → idle guard).
        await manager.completeSet(actualReps: 8, rpeFelt: 7, intent: .top)
        await manager.endSessionEarly()
        await vm.pullState()

        if case .sessionComplete = vm.sessionState {} else {
            XCTFail("Expected .sessionComplete after endSessionEarly, got \(vm.sessionState)")
        }
        XCTAssertEqual(vm.liveSessionDayId, dayA.id,
            "liveSessionDayId must survive .sessionComplete (cleared only on resetToIdle)")
    }

    // 4. markDay* routes purely by (dayId, weekId) — marking B leaves A untouched.
    func testMarkDayCompleted_routesByDayId_notProgrammePointer() async {
        let dayA = makeTrainingDay(label: "Push_A")
        let dayB = makeTrainingDay(label: "Pull_B")
        let meso = makeMesocycle(days: [dayA, dayB])
        let week = meso.weeks[0]

        let vm = makeProgramViewModel()
        vm.currentMesocycle = meso   // markDay* reads currentMesocycle, not viewState
        vm.viewState = .loaded(meso)

        // Mark B complete by id; nextIncompleteDay (A) must stay non-terminal.
        vm.markDayCompleted(dayId: dayB.id, weekId: week.id)

        guard case .loaded(let updated) = vm.viewState else {
            XCTFail("viewState should remain .loaded"); return
        }
        let updatedA = updated.weeks[0].trainingDays.first { $0.id == dayA.id }
        let updatedB = updated.weeks[0].trainingDays.first { $0.id == dayB.id }
        XCTAssertEqual(updatedB?.status, .completed, "B was marked complete by its id")
        XCTAssertFalse(updatedA?.isTerminal ?? true,
            "A (nextIncompleteDay) must be untouched — routing is by id, not programme pointer")
    }

    // 5. THE STATE-4 regression: resume B (live=B) → leave without Done (resetToIdle)
    //    → start fresh A → liveSessionDayId == A, never the stale B.
    func testResumeThenAbandonWithoutDone_nextSessionRoutesToOwnDay() async throws {
        let manager = makeManager()
        let vm = WorkoutViewModel(manager: manager)
        let dayA = makeTrainingDay(label: "Push_A", exerciseCount: 1, setsPerExercise: 1)
        let dayB = makeTrainingDay(label: "Pull_B", exerciseCount: 2, setsPerExercise: 2)

        // Resume B.
        let paused = PausedSessionState(
            sessionId: UUID(),
            trainingDayId: dayB.id,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: dayB.dayLabel,
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date(),
            exerciseSignature: PausedSessionState.exerciseSignature(for: dayB)
        )
        let resumed = await manager.resumeSession(
            pausedState: paused, trainingDay: dayB, completedSetLogs: []
        )
        XCTAssertTrue(resumed)
        try await Task.sleep(nanoseconds: 200_000_000)
        await vm.pullState()
        XCTAssertEqual(vm.liveSessionDayId, dayB.id, "precondition: live day is the resumed B")

        // Leave WITHOUT reaching Done — the actor goes back to idle.
        await manager.resetToIdle()
        await vm.pullState()
        XCTAssertNil(vm.liveSessionDayId, "after leaving without Done the actor is idle")

        // Start a fresh session for A.
        await manager.startSession(trainingDay: dayA, programId: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        await vm.pullState()

        XCTAssertEqual(vm.liveSessionDayId, dayA.id,
            "STATE-4: the next session must route to its OWN day A, never the stale resumed B")
        XCTAssertNotEqual(vm.liveSessionDayId, dayB.id)
    }

    // 6a. Pure helper: nil coordinator active id → falls back to nextIncompleteDay.
    func testHostDay_fallsBackToNextIncomplete_whenCoordinatorActiveDayIdNil() {
        let dayA = makeTrainingDay(label: "Push_A")
        let dayB = makeTrainingDay(label: "Pull_B")
        let meso = makeMesocycle(days: [dayA, dayB])

        let host = ContentView.hostDay(
            nextIncomplete: dayA,
            coordinatorActiveDayId: nil,
            mesocycle: meso
        )
        XCTAssertEqual(host.id, dayA.id,
            "a nil coordinator active id hosts nextIncompleteDay")
    }

    // 6b. Pure helper: a coordinator active id that differs and resolves → hosts that day.
    func testHostDay_returnsCoordinatorDay_whenDiffersAndResolvable() {
        let dayA = makeTrainingDay(label: "Push_A")
        let dayB = makeTrainingDay(label: "Pull_B")
        let meso = makeMesocycle(days: [dayA, dayB])

        // Coordinator is live/paused for B while nextIncompleteDay is A.
        let host = ContentView.hostDay(
            nextIncomplete: dayA,
            coordinatorActiveDayId: dayB.id,
            mesocycle: meso
        )
        XCTAssertEqual(host.id, dayB.id,
            "when the coordinator's day differs from nextIncomplete AND resolves, host it")

        // An unresolvable id falls back to nextIncompleteDay.
        let hostUnresolvable = ContentView.hostDay(
            nextIncomplete: dayA,
            coordinatorActiveDayId: UUID(),
            mesocycle: meso
        )
        XCTAssertEqual(hostUnresolvable.id, dayA.id,
            "an unresolvable coordinator id falls back to nextIncompleteDay")
    }

    // 7. Resume is idempotent under a second call — the second resume returns false.
    func testResume_isIdempotentUnderSecondCall_doesNotDoubleResume() async throws {
        let manager = makeManager()
        let dayB = makeTrainingDay(label: "Pull_B", exerciseCount: 2, setsPerExercise: 2)

        let paused = PausedSessionState(
            sessionId: UUID(),
            trainingDayId: dayB.id,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: dayB.dayLabel,
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date(),
            exerciseSignature: PausedSessionState.exerciseSignature(for: dayB)
        )

        let first = await manager.resumeSession(
            pausedState: paused, trainingDay: dayB, completedSetLogs: []
        )
        XCTAssertTrue(first, "first resume succeeds")
        try await Task.sleep(nanoseconds: 200_000_000)

        let second = await manager.resumeSession(
            pausedState: paused, trainingDay: dayB, completedSetLogs: []
        )
        XCTAssertFalse(second, "a second resume against an already-live actor must be a no-op")

        let liveDay = await manager.currentTrainingDayId
        XCTAssertEqual(liveDay, dayB.id, "the single live session is still for the resumed day B")
    }
}
