// DurableTrainingDayIdTests.swift
// ProjectApexTests — #443 (Q2)
//
// Durable, server-visible day identity for workout_sessions.
//
//   1. WorkoutSession (the workout_sessions row) round-trips training_day_id,
//      including a legacy row that omits the column (decodes to nil).
//   2. startSession stamps trainingDay.id into the enqueued session payload.
//   3. attemptSupabaseRepair uses the recovered row's persisted training_day_id
//      (not a fabricated random UUID); falls back to a fresh id only when the
//      column is null (legacy rows).

import XCTest
import Foundation
@testable import ProjectApex

// MARK: - Stub URLProtocol returning a single workout_sessions row

/// Returns a fixed JSON body for the next GET, so attemptSupabaseRepair's
/// fetch resolves deterministically with no network.
private final class RepairRowURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody: String = "[]"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeStubSupabase() -> SupabaseClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RepairRowURLProtocol.self]
    return SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
}

final class DurableTrainingDayIdTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
    }

    override func tearDown() {
        PausedSessionState.clear()
        RepairRowURLProtocol.responseBody = "[]"
        super.tearDown()
    }

    // MARK: 1. Model round-trip (incl. legacy null row)

    func testWorkoutSessionRow_roundTripsTrainingDayId() throws {
        let dayId = UUID()
        let session = WorkoutSession(
            id: UUID(),
            userId: UUID(),
            programId: UUID(),
            sessionDate: Date(timeIntervalSince1970: 1_700_000_000),
            weekNumber: 2,
            dayType: "Push_A",
            completed: false,
            status: "active",
            trainingDayId: dayId
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        // The on-the-wire key is snake_case `training_day_id`.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedDayId = try XCTUnwrap(json["training_day_id"] as? String)
        XCTAssertEqual(UUID(uuidString: encodedDayId), dayId)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkoutSession.self, from: data)
        XCTAssertEqual(decoded.trainingDayId, dayId)
    }

    func testWorkoutSessionRow_legacyRowWithoutColumn_decodesToNil() throws {
        // A pre-#443 row has no training_day_id key at all.
        let legacy = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "user_id": "22222222-2222-4222-8222-222222222222",
          "program_id": "33333333-3333-4333-8333-333333333333",
          "session_date": "2026-06-17T00:00:00Z",
          "week_number": 1,
          "day_type": "Pull_B",
          "completed": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkoutSession.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.trainingDayId, "legacy row without the column decodes to nil")
    }

    // MARK: 2. startSession stamps training_day_id into the enqueued payload

    func testStartSession_stampsTrainingDayIdIntoEnqueuedPayload() async throws {
        let (manager, waq) = makeWSM443ManagerWithWAQ()

        // Capture the workout_sessions payload the manager enqueues. A
        // permanentFailure keeps the item out of the success auto-drain so the
        // handler is guaranteed to see it.
        let captured = PayloadBox()
        await waq.registerFlushHandler(forTable: "workout_sessions") { write in
            captured.store(write.payload)
            return .permanentFailure("captured-for-test")
        }

        let day = makeWSM443TrainingDay()
        await manager.startSession(
            trainingDay: day,
            programId: UUID(),
            userId: UUID(),
            weekNumber: 1
        )

        var payload: Data?
        for _ in 0..<100 where payload == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            payload = captured.value()
        }
        let data = try XCTUnwrap(payload, "session payload was enqueued")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stamped = try XCTUnwrap(json["training_day_id"] as? String)
        XCTAssertEqual(
            UUID(uuidString: stamped), day.id,
            "startSession stamps trainingDay.id into training_day_id"
        )
    }

    // MARK: 3. Repair uses the recovered row's persisted training_day_id

    func testAttemptSupabaseRepair_usesPersistedTrainingDayId() async {
        let serverDayId = UUID()
        let programId = UUID()
        RepairRowURLProtocol.responseBody = """
        [{
          "id": "44444444-4444-4444-8444-444444444444",
          "program_id": "\(programId.uuidString)",
          "week_number": 3,
          "day_type": "Legs",
          "training_day_id": "\(serverDayId.uuidString)"
        }]
        """
        PausedSessionState.clear()

        await PausedSessionState.attemptSupabaseRepair(userId: UUID(), supabase: makeStubSupabase())

        let restored = PausedSessionState.load()
        XCTAssertEqual(
            restored?.trainingDayId, serverDayId,
            "repair reuses the server row's training_day_id rather than a random UUID"
        )
    }

    func testAttemptSupabaseRepair_legacyNullColumn_doesNotUseAFixedId() async {
        // Legacy row: no training_day_id. Repair must still produce a paused
        // state (so the user gets the recovery path), but with a fresh id — the
        // ContentView mismatch path then offers Abandon for the unmatchable day.
        RepairRowURLProtocol.responseBody = """
        [{
          "id": "55555555-5555-4555-8555-555555555555",
          "program_id": "66666666-6666-4666-8666-666666666666",
          "week_number": 1,
          "day_type": "Push_A"
        }]
        """
        PausedSessionState.clear()

        await PausedSessionState.attemptSupabaseRepair(userId: UUID(), supabase: makeStubSupabase())

        let restored = PausedSessionState.load()
        XCTAssertNotNil(restored, "repair still reconstructs a paused state for a legacy row")
        // The id is not borrowed from any other column (it's a fresh fallback).
        XCTAssertNotEqual(restored?.trainingDayId, restored?.programId)
        XCTAssertNotEqual(
            restored?.trainingDayId,
            UUID(uuidString: "55555555-5555-4555-8555-555555555555"),
            "legacy fallback does not reuse the session id as the day id"
        )
    }
}

// MARK: - Local helpers (file-scoped to avoid colliding with WorkoutSessionManagerTests)

/// Thread-safe box for capturing a payload from the WAQ flush handler.
private final class PayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func store(_ d: Data) { lock.lock(); if data == nil { data = d }; lock.unlock() }
    func value() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}

private final class WSM443SucceedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeWSM443ManagerWithWAQ() -> (WorkoutSessionManager, WriteAheadQueue) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WSM443SucceedURLProtocol.self]
    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
    let inference = AIInferenceService(
        provider: WSM443StubProvider(),
        gymProfile: nil,
        maxRetries: 0
    )
    let memoryService = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let suiteName = "com.test.wsm443.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suiteName)!
    let gymFactStore = GymFactStore(userDefaults: testDefaults)
    let waq = WriteAheadQueue(supabase: supabase, userDefaults: testDefaults)
    let manager = WorkoutSessionManager(
        aiInference: inference,
        healthKit: HealthKitService(),
        memoryService: memoryService,
        supabase: supabase,
        gymFactStore: gymFactStore,
        writeAheadQueue: waq
    )
    return (manager, waq)
}

private struct WSM443StubProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        """
        {
          "set_prescription": {
            "weight_kg": 80.0, "reps": 8, "tempo": "3-1-1-0", "rir_target": 2,
            "rest_seconds": 120, "coaching_cue": "Drive", "reasoning": "trend",
            "safety_flags": [], "intent": "top", "set_framing": "Heaviest."
          }
        }
        """
    }
}

private func makeWSM443TrainingDay() -> TrainingDay {
    let ex = PlannedExercise(
        id: UUID(),
        exerciseId: "exercise_0",
        name: "Exercise 0",
        primaryMuscle: "pectoralis_major",
        synergists: ["triceps_brachii"],
        equipmentRequired: .barbell,
        sets: 2,
        repRange: RepRange(min: 6, max: 10),
        tempo: "3-1-1-0",
        restSeconds: 90,
        rirTarget: 2,
        coachingCues: ["Focus on form"]
    )
    return TrainingDay(id: UUID(), dayOfWeek: 1, dayLabel: "Push_A", exercises: [ex], sessionNotes: nil)
}
