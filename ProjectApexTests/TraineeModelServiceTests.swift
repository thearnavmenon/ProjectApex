// TraineeModelServiceTests.swift
// ProjectApexTests
//
// Unit tests for TraineeModelService actor (Phase 1 / Slice 10, issue #11).
//
// The actor is the read-side interface to the trainee model — wraps the
// SwiftData local cache (@MainActor TraineeModelLocalStore) and the
// WriteAheadQueue. Phase 1 ships read(), digest(), enqueueUpdate(forSession:);
// the WAQ flush handler that routes trainee_model_update items to the
// Edge Function lands in Slice 11 (#12). Update-rule logic is Phase 2.
//
// The class is @MainActor because TraineeModelLocalStore must be created
// and torn down inside an active Swift Concurrency Task — same constraint
// as TraineeModelLocalStoreTests.
//
// Behaviours covered:
//   • read() returns nil when the local cache is empty (cold-start path)
//   • read() returns the cached snapshot after the store is hydrated
//   • digest() returns nil when the local cache is empty (cold-start path)
//   • digest() returns a TraineeModelDigest assembled from the cached model
//   • enqueueUpdate(forSession:) appends one item to the WAQ
//   • enqueueUpdate(forSession:) targets the trainee_model_updates table
//   • enqueueUpdate(forSession:) emits a payload whose decoded JSON shape
//     matches the Edge Function contract { user_id, session_id, session_payload }

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol that fails every request
//
// Used so the WAQ's automatic flush attempt does not silently drop the
// enqueued item before the test inspects the queue. A 500 response keeps
// the item in queue (with retryCount incremented) — perfect for the
// shape-only assertions this file makes.

private final class TMSAlwaysFailURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeFailingSupabase() -> SupabaseClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TMSAlwaysFailURLProtocol.self]
    return SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
}

// MARK: - TraineeModelServiceTests

@MainActor
final class TraineeModelServiceTests: XCTestCase {

    // MARK: ─── Lifecycle ─────────────────────────────────────────────────────

    private var store: TraineeModelLocalStore!
    private var waq: WriteAheadQueue!
    private var service: TraineeModelService!

    private let userId    = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let programId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let ref = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
        store   = try TraineeModelLocalStore.makeInMemory()
        waq     = WriteAheadQueue(supabase: makeFailingSupabase())
        service = TraineeModelService(store: store, writeAheadQueue: waq, now: { [ref] in ref })
    }

    override func tearDown() async throws {
        // Do NOT call `await waq.clearAll()` here. WAQ.flush() retries failed
        // writes via `queue[0] = item` after each backoff; if clearAll() runs
        // during that suspension window, the index-set crashes with
        // "Index out of range". The fix is to leave any in-flight flush
        // tasks alone — they will exhaust retries against the failing mock
        // and exit on their own — and rely on setUp's UserDefaults clear
        // to ensure no persisted state leaks into the next test.
        service = nil
        waq = nil
        store = nil
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
    }

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

    private func makeRichModel() -> TraineeModel {
        TraineeModel(
            goal: GoalState(statement: "Strength + size",
                            focusAreas: [.legs, .back],
                            updatedAt: ref),
            patterns: [
                .squat: PatternProfile(
                    pattern: .squat,
                    currentPhase: .accumulation,
                    sessionsInPhase: 4,
                    rpeOffset: -0.5,
                    confidence: .calibrating,
                    recentSessionDates: [ref.addingTimeInterval(-14 * 86400),
                                         ref.addingTimeInterval(-7 * 86400)]
                ),
                .horizontalPush: PatternProfile(
                    pattern: .horizontalPush,
                    currentPhase: .intensification,
                    sessionsInPhase: 6,
                    rpeOffset: 0,
                    confidence: .established,
                    recentSessionDates: [ref.addingTimeInterval(-10 * 86400),
                                         ref.addingTimeInterval(-3 * 86400)]
                ),
            ],
            muscles: [
                .legs: MuscleProfile(muscleGroup: .legs,
                                     volumeTolerance: 14,
                                     volumeDeficit: 2,
                                     focusWeight: 0.6,
                                     confidence: .calibrating)
            ],
            totalSessionCount: 8
        )
    }

    private func makeSession() -> WorkoutSession {
        WorkoutSession(
            id: sessionId,
            userId: userId,
            programId: programId,
            sessionDate: ref,
            weekNumber: 2,
            dayType: "Push A",
            completed: true,
            status: "completed"
        )
    }

    // MARK: ─── read() — cold start vs hydrated ───────────────────────────────

    func test_read_returnsNil_whenStoreEmpty() async {
        let result = await service.read()
        XCTAssertNil(result)
    }

    func test_read_returnsCachedSnapshot_afterSave() async throws {
        let model = makeRichModel()
        try store.save(model)

        let result = await service.read()

        XCTAssertEqual(result, model)
    }

    // MARK: ─── digest() — cold start vs hydrated ─────────────────────────────

    func test_digest_returnsNil_whenStoreEmpty() async {
        let result = await service.digest()
        XCTAssertNil(result)
    }

    func test_digest_returnsAssembledProjection_afterSave() async throws {
        let model = makeRichModel()
        try store.save(model)

        let maybe = await service.digest()
        let digest = try XCTUnwrap(maybe)

        XCTAssertEqual(digest.goal, model.goal)
        XCTAssertEqual(digest.perPatternSummary.count, 2)
        XCTAssertEqual(digest.perMuscleSummary.count, 1)
        // Confidence states surface verbatim — covers the per-axis
        // assembly path the issue calls out specifically.
        let patternConfidences = Set(digest.perPatternSummary.map { $0.confidence })
        XCTAssertEqual(patternConfidences, [.calibrating, .established])
    }

    // MARK: ─── enqueueUpdate(forSession:) — WAQ shape ────────────────────────

    func test_enqueueUpdate_appendsOneItemToQueue() async throws {
        let session = makeSession()

        try await service.enqueueUpdate(forSession: session)

        let pending = await waq.queue
        XCTAssertEqual(pending.count, 1, "Expected exactly one queued write")
    }

    func test_enqueueUpdate_targetsTraineeModelUpdatesTable() async throws {
        let session = makeSession()

        try await service.enqueueUpdate(forSession: session)

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(item.table, "trainee_model_updates")
    }

    func test_enqueueUpdate_payloadShape_matchesEdgeFunctionContract() async throws {
        let session = makeSession()

        try await service.enqueueUpdate(forSession: session)

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)

        // Edge Function (supabase/functions/update-trainee-model/index.ts)
        // expects exactly { user_id, session_id, session_payload } with
        // user_id and session_id as UUID strings and session_payload as a
        // JSON object. Phase 1 sends an empty session_payload object;
        // Phase 2 fills in set_logs / notes when rule logic ships.
        let json = try JSONSerialization.jsonObject(with: item.payload) as? [String: Any]
        let body = try XCTUnwrap(json)

        XCTAssertEqual((body["user_id"]    as? String)?.lowercased(), userId.uuidString.lowercased())
        XCTAssertEqual((body["session_id"] as? String)?.lowercased(), sessionId.uuidString.lowercased())
        XCTAssertNotNil(body["session_payload"] as? [String: Any],
                        "session_payload must be a JSON object per Edge Function contract")
        XCTAssertEqual(Set(body.keys), ["user_id", "session_id", "session_payload"],
                       "Payload must carry exactly the Edge Function contract keys")
    }
}
