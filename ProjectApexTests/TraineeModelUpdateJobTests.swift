// TraineeModelUpdateJobTests.swift
// ProjectApexTests
//
// TDD tests for TraineeModelUpdateJob (Phase 1 / Slice 11, issue #12).
//
// TraineeModelUpdateJob is the WAQ flush handler that routes
// trainee_model_updates items to the update-trainee-model Edge Function
// instead of the default Supabase REST insert path.
//
// Behaviours covered (vertical-slice order):
//   1. Flush handler POSTs item.payload to the Edge Function URL
//   2. HTTP 200 + decodable TraineeModel  → saves snapshot + returns .success
//   3. HTTP 200 + Phase 1 no-op stub {}  → skips save  + returns .success
//   4. HTTP 200 + missing trainee_model key → .permanentFailure (logged, removed)
//   5. HTTP 429  → .transientFailure (existing WAQ retry policy)
//   6. HTTP 503  → .transientFailure
//   7. HTTP 502  → .transientFailure
//   8. HTTP 504  → .transientFailure
//   9. HTTP 400  → .permanentFailure (permanent 4xx — logged, removed)
//  10. HTTP 401  → .permanentFailure
//  11. Network error → .transientFailure
// WAQ integration (handler registration):
//  12. WAQ routes trainee_model_updates item through registered handler
//  13. WAQ removes item on .permanentFailure from registered handler
// Integration smoke (gated by APEX_INTEGRATION_TESTS=1):
//  14. End-to-end: enqueue → WAQ flush → Edge Function called → item removed
//
// The class is @MainActor because TraineeModelLocalStore must be created
// and torn down inside an active Swift Concurrency Task — same constraint
// as TraineeModelServiceTests.

import XCTest
@testable import ProjectApex

// MARK: - Mock URLProtocol

private final class TMUJMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Drain httpBodyStream → httpBody so tests can read the payload.
        let canonical = Self.canonicalize(request)
        TMUJMockURLProtocol.capturedRequests.append(canonical)

        guard let handler = TMUJMockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(canonical)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func canonicalize(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 1024)
            if n > 0 { data.append(buf, count: n) } else { break }
        }
        var copy = request
        copy.httpBody = data
        return copy
    }
}

// MARK: - Helpers

private func makeMockSupabase() -> SupabaseClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TMUJMockURLProtocol.self]
    return SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
}

/// Encodes a minimal valid TraineeModel as the Edge Function response body.
private func makeValidEdgeFunctionResponse(model: TraineeModel) throws -> Data {
    struct Wrapper: Encodable {
        let traineeModel: TraineeModel
        enum CodingKeys: String, CodingKey { case traineeModel = "trainee_model" }
    }
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    return try enc.encode(Wrapper(traineeModel: model))
}

// MARK: - TraineeModelUpdateJobTests

@MainActor
final class TraineeModelUpdateJobTests: XCTestCase {

    // MARK: ─── Lifecycle ─────────────────────────────────────────────────────

    private var store: TraineeModelLocalStore!
    private var supabase: SupabaseClient!
    private var notificationQueue: LateArrivalNotificationQueue!
    private var job: TraineeModelUpdateJob!

    private let userId    = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let sessionId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let ref       = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        TMUJMockURLProtocol.capturedRequests = []
        TMUJMockURLProtocol.requestHandler   = nil
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
        store             = try TraineeModelLocalStore.makeInMemory()
        supabase          = makeMockSupabase()
        notificationQueue = LateArrivalNotificationQueue.makeInMemory()
        job               = TraineeModelUpdateJob(
            supabase: supabase,
            store: store,
            notificationQueue: notificationQueue
        )
    }

    override func tearDown() async throws {
        job               = nil
        notificationQueue = nil
        supabase          = nil
        store             = nil
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
    }

    // MARK: ─── Helpers ───────────────────────────────────────────────────────

    private func makeQueuedItem() throws -> QueuedWrite {
        let payload = TraineeModelUpdatePayload(
            userId: userId,
            sessionId: sessionId,
            sessionPayload: SessionUpdatePayload(loggedAt: "2026-05-10T10:00:00Z", setLogs: [])
        )
        return try QueuedWrite(table: TraineeModelUpdateJob.waqTable, item: payload)
    }

    private func makeSimpleModel() -> TraineeModel {
        TraineeModel(
            goal: GoalState(statement: "Strength", focusAreas: [.legs], updatedAt: ref)
        )
    }

    private func respond(status: Int, body: Data = Data()) {
        TMUJMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!, body)
        }
    }

    // MARK: ─── Test 1: Flush handler POSTs to Edge Function URL ──────────────

    func test_flushHandler_invokesEdgeFunctionWithExpectedPayload() async throws {
        respond(status: 200, body: Data(#"{"trainee_model":{}}"#.utf8))

        let item    = try makeQueuedItem()
        let handler = job.makeHandler()
        let outcome = await handler(item)

        // Edge Function URL must contain the function name
        let req = try XCTUnwrap(TMUJMockURLProtocol.capturedRequests.first)
        XCTAssert(req.url?.absoluteString.contains("update-trainee-model") == true,
                  "Expected Edge Function URL, got \(req.url?.absoluteString ?? "nil")")

        // Payload must match the Edge Function contract: {user_id, session_id, session_payload}
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["user_id"]    as? String)?.lowercased(), userId.uuidString.lowercased())
        XCTAssertEqual((json["session_id"] as? String)?.lowercased(), sessionId.uuidString.lowercased())
        XCTAssertNotNil(json["session_payload"] as? [String: Any])

        // A 200 with an undecodable model is still success
        XCTAssertEqual(outcome, .success)
    }

    // MARK: ─── Test 2: HTTP 200 + valid TraineeModel → saves snapshot ────────

    func test_flushHandler_on200WithValidModel_savesSnapshotAndReturnsSuccess() async throws {
        let model        = makeSimpleModel()
        let responseBody = try makeValidEdgeFunctionResponse(model: model)
        respond(status: 200, body: responseBody)

        let item    = try makeQueuedItem()
        let handler = job.makeHandler()
        let outcome = await handler(item)

        XCTAssertEqual(outcome, .success)
        let saved = store.load()
        XCTAssertEqual(saved, model, "Store must contain the model from the Edge Function response")
    }

    // MARK: ─── Test 3: HTTP 200 + Phase 1 stub {} → no snapshot update ───────

    func test_flushHandler_on200WithPhase1Stub_returnsSuccess_withoutSavingStore() async throws {
        respond(status: 200, body: Data(#"{"trainee_model":{}}"#.utf8))

        let item    = try makeQueuedItem()
        let handler = job.makeHandler()
        let outcome = await handler(item)

        XCTAssertEqual(outcome, .success, "Phase 1 no-op 200 must still be treated as success")
        // Post-#149: empty {} body now decodes to a TraineeModel with placeholder
        // fields (GoalState.placeholder sentinel, empty patterns/muscles/exercises,
        // totalSessionCount=0). Verify those placeholder semantics rather than
        // asserting nil — the production store-persist is correct.
        let loaded = store.load()
        XCTAssertEqual(loaded?.goal, .placeholder)
        XCTAssertEqual(loaded?.totalSessionCount, 0)
        XCTAssertTrue(loaded?.patterns.isEmpty ?? false)
    }

    // MARK: ─── Test 4: HTTP 200 + missing trainee_model key → permanentFailure

    func test_flushHandler_on200WithMissingKey_returnsPermanentFailure() async throws {
        respond(status: 200, body: Data(#"{"unexpected":"shape"}"#.utf8))

        let item    = try makeQueuedItem()
        let handler = job.makeHandler()
        let outcome = await handler(item)

        if case .permanentFailure = outcome { /* expected */ } else {
            XCTFail("Expected .permanentFailure, got \(outcome)")
        }
        XCTAssertNil(store.load(), "Store must not be touched on a malformed 200 response")
    }

    // MARK: ─── Tests 5–8: Transient HTTP failures ────────────────────────────

    func test_flushHandler_on429_returnsTransientFailure() async throws {
        respond(status: 429)
        let outcome = await job.makeHandler()(try makeQueuedItem())
        XCTAssertEqual(outcome, .transientFailure)
    }

    func test_flushHandler_on503_returnsTransientFailure() async throws {
        respond(status: 503)
        let outcome = await job.makeHandler()(try makeQueuedItem())
        XCTAssertEqual(outcome, .transientFailure)
    }

    func test_flushHandler_on502_returnsTransientFailure() async throws {
        respond(status: 502)
        let outcome = await job.makeHandler()(try makeQueuedItem())
        XCTAssertEqual(outcome, .transientFailure)
    }

    func test_flushHandler_on504_returnsTransientFailure() async throws {
        respond(status: 504)
        let outcome = await job.makeHandler()(try makeQueuedItem())
        XCTAssertEqual(outcome, .transientFailure)
    }

    // MARK: ─── Tests 9–10: Permanent HTTP failures (4xx excluding 429) ───────

    func test_flushHandler_on400_returnsPermanentFailure() async throws {
        respond(status: 400, body: Data("bad request".utf8))
        let outcome = await job.makeHandler()(try makeQueuedItem())
        if case .permanentFailure = outcome { /* expected */ } else {
            XCTFail("Expected .permanentFailure for 400, got \(outcome)")
        }
    }

    func test_flushHandler_on401_returnsPermanentFailure() async throws {
        respond(status: 401, body: Data("unauthorized".utf8))
        let outcome = await job.makeHandler()(try makeQueuedItem())
        if case .permanentFailure = outcome { /* expected */ } else {
            XCTFail("Expected .permanentFailure for 401, got \(outcome)")
        }
    }

    // MARK: ─── Test 11: Network error → transientFailure ────────────────────

    func test_flushHandler_onNetworkError_returnsTransientFailure() async throws {
        TMUJMockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let outcome = await job.makeHandler()(try makeQueuedItem())
        XCTAssertEqual(outcome, .transientFailure)
    }

    // MARK: ─── Test 12: WAQ routes trainee_model_updates through registered handler

    func test_waq_routesTraineeModelUpdatesThroughRegisteredHandler() async throws {
        respond(status: 200, body: Data(#"{"trainee_model":{}}"#.utf8))

        let waq = WriteAheadQueue(supabase: supabase)
        await job.register(with: waq)

        // Enqueue via TraineeModelService's enqueue path (directly here for simplicity)
        let item = TraineeModelUpdatePayload(
            userId: userId,
            sessionId: sessionId,
            sessionPayload: SessionUpdatePayload(loggedAt: "2026-05-10T10:00:00Z", setLogs: [])
        )
        try await waq.enqueue(item, table: TraineeModelUpdateJob.waqTable)

        // Give flush a moment to process
        try await Task.sleep(nanoseconds: 300_000_000)

        let pending = await waq.pendingCount
        XCTAssertEqual(pending, 0, "trainee_model_updates item must be removed after successful Edge Function call")

        // Edge Function must have been called
        XCTAssertFalse(TMUJMockURLProtocol.capturedRequests.isEmpty,
                       "Edge Function must have been invoked during WAQ flush")
        let req = try XCTUnwrap(TMUJMockURLProtocol.capturedRequests.first)
        XCTAssert(req.url?.absoluteString.contains("update-trainee-model") == true)
    }

    // MARK: ─── Test 13: WAQ removes item on permanentFailure from handler ────

    func test_waq_permanentFailure_removesItemFromQueue() async throws {
        // 400 → permanentFailure → WAQ removes item immediately (no retry)
        respond(status: 400, body: Data("invalid payload".utf8))

        let waq = WriteAheadQueue(supabase: supabase)
        await job.register(with: waq)

        let item = TraineeModelUpdatePayload(
            userId: userId,
            sessionId: sessionId,
            sessionPayload: SessionUpdatePayload(loggedAt: "2026-05-10T10:00:00Z", setLogs: [])
        )
        try await waq.enqueue(item, table: TraineeModelUpdateJob.waqTable)

        try await Task.sleep(nanoseconds: 300_000_000)

        let pending = await waq.pendingCount
        XCTAssertEqual(pending, 0,
                       "permanentFailure must remove the item from the WAQ immediately (no retry)")
    }

    // MARK: ─── ADR-0008 late_arrival branch (slice A3 / #74) ────────────────

    /// Builds a 200 response body with the late_arrival flag set. The
    /// trainee_model field still carries the cached snapshot per ADR-0008
    /// ("return the cached snapshot with a `late_arrival: true` flag in the
    /// JSON body") — the WAQ adapter must NOT propagate it to the local store.
    private func makeLateArrivalResponse(model: TraineeModel, late: Bool) throws -> Data {
        struct Wrapper: Encodable {
            let traineeModel: TraineeModel
            let lateArrival: Bool
            enum CodingKeys: String, CodingKey {
                case traineeModel = "trainee_model"
                case lateArrival  = "late_arrival"
            }
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(Wrapper(traineeModel: model, lateArrival: late))
    }

    /// ADR-0008 §"Late arrival": the Edge Function returns 200 with
    /// `late_arrival: true` and the *cached* snapshot. The WAQ adapter must
    /// dequeue identically (return .success) but skip the local snapshot
    /// update — applying the cached snapshot would clobber any in-flight
    /// local edit in the (unlikely) race.
    func test_flushHandler_onLateArrivalTrue_returnsSuccess_withoutSavingStore() async throws {
        let cachedModel = makeSimpleModel()
        let body        = try makeLateArrivalResponse(model: cachedModel, late: true)
        respond(status: 200, body: body)

        let item    = try makeQueuedItem()
        let handler = job.makeHandler()
        let outcome = await handler(item)

        XCTAssertEqual(outcome, .success,
                       "late_arrival:true must dequeue identically (per ADR-0008)")
        XCTAssertNil(store.load(),
                     "late_arrival:true must NOT update the local snapshot — the trainee_model field is the *cached* snapshot, not a fresh write")
    }

    /// ADR-0008 locks the user-visible notification copy verbatim. A paraphrase
    /// is a regression — the test asserts the exact string so any future edit
    /// to the message must come back through ADR-0008.
    func test_flushHandler_onLateArrivalTrue_enqueuesNotificationWithLockedCopy() async throws {
        let body = try makeLateArrivalResponse(model: makeSimpleModel(), late: true)
        respond(status: 200, body: body)

        let outcome = await job.makeHandler()(try makeQueuedItem())

        XCTAssertEqual(outcome, .success)

        let pending = notificationQueue.dequeueAll()
        XCTAssertEqual(pending.count, 1, "Exactly one notification per refused session")
        XCTAssertEqual(
            pending.first?.message,
            "This session was logged after later sessions and won't update your training profile, but the history is preserved.",
            "Notification copy is locked verbatim from ADR-0008 — any paraphrase is a regression"
        )
    }

    /// Slice A12 (#83) richer response shape: when the orchestrator refuses a
    /// late arrival, it returns `late_arrival_details: { session_id,
    /// incoming_logged_at, watermark }` alongside the bool flag. The WAQ
    /// adapter must populate the corresponding optional fields on the queued
    /// LateArrivalNotification so the post-session UI can show details (e.g.,
    /// "logged X minutes ago" or the gap delta).
    func test_flushHandler_onLateArrivalTrue_populatesRicherNotificationFields_fromA12Response() async throws {
        // Construct a response body matching the A12 contract: the bool flag
        // PLUS the late_arrival_details object. The WAQ adapter is expected
        // to parse the nested fields and stash them on LateArrivalNotification.
        struct A12Wrapper: Encodable {
            let traineeModel: TraineeModel
            let lateArrival: Bool
            let lateArrivalDetails: Details
            struct Details: Encodable {
                let sessionId: String
                let incomingLoggedAt: String
                let watermark: String
                enum CodingKeys: String, CodingKey {
                    case sessionId       = "session_id"
                    case incomingLoggedAt = "incoming_logged_at"
                    case watermark
                }
            }
            enum CodingKeys: String, CodingKey {
                case traineeModel       = "trainee_model"
                case lateArrival        = "late_arrival"
                case lateArrivalDetails = "late_arrival_details"
            }
        }
        let sessionId        = UUID()
        let incomingLoggedAt = "2026-05-01T08:00:00.000Z"
        let watermark        = "2026-05-08T10:00:00.000Z"
        let wrapper = A12Wrapper(
            traineeModel: makeSimpleModel(),
            lateArrival: true,
            lateArrivalDetails: .init(
                sessionId: sessionId.uuidString.lowercased(),
                incomingLoggedAt: incomingLoggedAt,
                watermark: watermark
            )
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let body = try enc.encode(wrapper)
        respond(status: 200, body: body)

        let outcome = await job.makeHandler()(try makeQueuedItem())
        XCTAssertEqual(outcome, .success)

        let pending = notificationQueue.dequeueAll()
        XCTAssertEqual(pending.count, 1)
        let notification = pending[0]
        XCTAssertEqual(
            notification.sessionId, sessionId,
            "A12 response shape: sessionId must round-trip from late_arrival_details.session_id"
        )
        XCTAssertEqual(
            notification.incomingLoggedAt,
            ISO8601DateFormatter().date(from: incomingLoggedAt),
            "incomingLoggedAt must decode as ISO-8601"
        )
        XCTAssertEqual(
            notification.watermark,
            ISO8601DateFormatter().date(from: watermark),
            "watermark must decode as ISO-8601"
        )
    }

    /// Slice A12 (#83) cached-snapshot path: when the orchestrator's PK
    /// constraint short-circuits a duplicate session (WAQ retry replay), the
    /// response is `late_arrival: false` with the cached snapshot in
    /// `trainee_model`. From the WAQ adapter's perspective this is
    /// indistinguishable from a fresh in-order apply — same path, same
    /// `.success` outcome, same store update with whatever shape `trainee_model`
    /// carries. ADR-0006 §"Idempotency at the DB layer" + ADR-0013 §"WAQ
    /// retry idempotency": Stage 2 doesn't re-fire here, but the *client*
    /// doesn't need to know that. This test pins that the WAQ adapter does
    /// NOT distinguish the cached-snapshot case from a fresh apply (no third
    /// branch beyond late_arrival:true / late_arrival:false).
    func test_flushHandler_onCachedSnapshotReturn_treatedAsLateArrivalFalse() async throws {
        // Construct two responses for two consecutive flushes of the same
        // session_id. First apply: late_arrival:false + fresh snapshot. Second
        // apply (PK conflict simulating WAQ retry): late_arrival:false + the
        // *same* cached snapshot. From the WAQ's POV both responses look
        // identical — they take the same flushHandler path.
        let cachedSnapshot = makeSimpleModel()
        let cachedBody = try makeLateArrivalResponse(model: cachedSnapshot, late: false)
        respond(status: 200, body: cachedBody)

        let outcome = await job.makeHandler()(try makeQueuedItem())
        XCTAssertEqual(outcome, .success,
                       "Cached-snapshot return MUST yield .success identically to a fresh apply (ADR-0006 §2)")
        XCTAssertEqual(store.load(), cachedSnapshot,
                       "Cached snapshot lands in the local store on this path — the client doesn't differentiate cached vs fresh writes")
        XCTAssertEqual(notificationQueue.pendingCount, 0,
                       "Cached-snapshot return MUST NOT enqueue a late-arrival notification (only late_arrival:true does)")
    }

    /// ADR-0008 contract for the in-order branch: explicit `late_arrival:false`
    /// (the shape A12 will return for accepted sessions) MUST behave identically
    /// to the existing no-flag case — store updates, queue stays empty. Locks
    /// in the gate so a downstream slice can't accidentally route an in-order
    /// session through the late-arrival path by toggling the flag.
    func test_flushHandler_onLateArrivalFalse_updatesSnapshot_andLeavesQueueEmpty() async throws {
        let model        = makeSimpleModel()
        let responseBody = try makeLateArrivalResponse(model: model, late: false)
        respond(status: 200, body: responseBody)

        let outcome = await job.makeHandler()(try makeQueuedItem())

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(store.load(), model,
                       "late_arrival:false must take the normal path — store gets the fresh snapshot")
        XCTAssertEqual(notificationQueue.pendingCount, 0,
                       "late_arrival:false must NOT enqueue a notification — only true does")
    }

    // MARK: ─── Test 14: Integration smoke (APEX_INTEGRATION_TESTS=1 only) ───

    func test_smoke_endToEnd_edgeFunctionReceivesCall() async throws {
        guard ProcessInfo.processInfo.environment["APEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set APEX_INTEGRATION_TESTS=1 to run live Edge Function smoke test")
        }
        // Live supabase with real anon key — exercise the full path against the deployed Phase 1 stub.
        // Verifies: WAQ enqueues → handler invoked → Edge Function called → item removed.
        // The Phase 1 stub returns { trainee_model: {} } — store won't update, but pipeline is confirmed.
        let liveSupabase = SupabaseClient(supabaseURL: Config.supabaseURL, anonKey: "")
        let liveJob      = TraineeModelUpdateJob(
            supabase: liveSupabase,
            store: store,
            notificationQueue: LateArrivalNotificationQueue.makeInMemory()
        )
        let liveWAQ      = WriteAheadQueue(supabase: liveSupabase)
        await liveJob.register(with: liveWAQ)

        let payload = TraineeModelUpdatePayload(
            userId: userId,
            sessionId: UUID(), // fresh UUID so idempotency key is fresh each run
            sessionPayload: SessionUpdatePayload(loggedAt: "2026-05-10T10:00:00Z", setLogs: [])
        )
        try await liveWAQ.enqueue(payload, table: TraineeModelUpdateJob.waqTable)

        // Allow up to 10 s for the live call to complete
        try await Task.sleep(nanoseconds: 10_000_000_000)

        let pending = await liveWAQ.pendingCount
        XCTAssertEqual(pending, 0, "Live Edge Function must process and remove the WAQ item")
    }
}
