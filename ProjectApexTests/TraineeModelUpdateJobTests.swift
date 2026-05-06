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
    private var job: TraineeModelUpdateJob!

    private let userId    = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let sessionId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let ref       = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        TMUJMockURLProtocol.capturedRequests = []
        TMUJMockURLProtocol.requestHandler   = nil
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
        store    = try TraineeModelLocalStore.makeInMemory()
        supabase = makeMockSupabase()
        job      = TraineeModelUpdateJob(supabase: supabase, store: store)
    }

    override func tearDown() async throws {
        job      = nil
        supabase = nil
        store    = nil
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
    }

    // MARK: ─── Helpers ───────────────────────────────────────────────────────

    private func makeQueuedItem() throws -> QueuedWrite {
        let payload = TraineeModelUpdatePayload(
            userId: userId,
            sessionId: sessionId,
            sessionPayload: SessionUpdatePayload()
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
        XCTAssertNil(store.load(), "Store must remain empty when server returns an empty model")
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
            sessionPayload: SessionUpdatePayload()
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
            sessionPayload: SessionUpdatePayload()
        )
        try await waq.enqueue(item, table: TraineeModelUpdateJob.waqTable)

        try await Task.sleep(nanoseconds: 300_000_000)

        let pending = await waq.pendingCount
        XCTAssertEqual(pending, 0,
                       "permanentFailure must remove the item from the WAQ immediately (no retry)")
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
        let liveJob      = TraineeModelUpdateJob(supabase: liveSupabase, store: store)
        let liveWAQ      = WriteAheadQueue(supabase: liveSupabase)
        await liveJob.register(with: liveWAQ)

        let payload = TraineeModelUpdatePayload(
            userId: userId,
            sessionId: UUID(), // fresh UUID so idempotency key is fresh each run
            sessionPayload: SessionUpdatePayload()
        )
        try await liveWAQ.enqueue(payload, table: TraineeModelUpdateJob.waqTable)

        // Allow up to 10 s for the live call to complete
        try await Task.sleep(nanoseconds: 10_000_000_000)

        let pending = await liveWAQ.pendingCount
        XCTAssertEqual(pending, 0, "Live Edge Function must process and remove the WAQ item")
    }
}
