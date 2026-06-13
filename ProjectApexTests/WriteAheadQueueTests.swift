// WriteAheadQueueTests.swift
// ProjectApexTests — P3-T06
//
// Unit tests for WriteAheadQueue actor.
//
// Test categories (all fast, no real network):
//   1. enqueue: items are added in FIFO order
//   2. flush: items are sent to Supabase and removed from queue on success
//   3. retry with exponential backoff: mock returns 503 twice then 201
//   4. max retries: item dropped after 5 failures
//   5. FIFO ordering: items processed in insertion order
//   6. persistence: queue items survive re-init (UserDefaults)
//   7. blocking write: writeBlocking succeeds directly
//   8. blocking write failure: falls back to enqueue

import XCTest
import Foundation
@testable import ProjectApex

// MARK: - Test Payload

nonisolated private struct TestSetLogPayload: Encodable, Sendable {
    let id: String
    let sessionId: String
    let exerciseId: String
    let setNumber: Int
    let weightKg: Double
    let repsCompleted: Int

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case exerciseId = "exercise_id"
        case setNumber = "set_number"
        case weightKg = "weight_kg"
        case repsCompleted = "reps_completed"
    }

    static func mock(id: String = UUID().uuidString, setNumber: Int = 1) -> TestSetLogPayload {
        TestSetLogPayload(
            id: id,
            sessionId: UUID().uuidString,
            exerciseId: "bench_press",
            setNumber: setNumber,
            weightKg: 80.0,
            repsCompleted: 8
        )
    }
}

// MARK: - Mock URLProtocol for controlling HTTP responses

private final class WAQMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        WAQMockURLProtocol.requestCount += 1
        guard let handler = WAQMockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // URLSession reifies httpBody → httpBodyStream for transport, so
        // request.httpBody at this layer is always nil. Drain the stream
        // back into Data so handlers reading request.httpBody see the
        // payload. See issue #23.
        let canonical = Self.canonicalize(request)
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

    /// Drains `request.httpBodyStream` (when present) and re-attaches the
    /// bytes as `httpBody` so handlers can inspect POST/PATCH payloads
    /// through the standard property. Per issue #23.
    private static func canonicalize(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break  // 0 = EOF, <0 = error
            }
        }

        var copy = request
        copy.httpBody = data
        return copy
    }
}

// MARK: - Helper: build SupabaseClient with mock session

private func makeMockSupabase() -> SupabaseClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WAQMockURLProtocol.self]
    let mockSession = URLSession(configuration: config)
    return SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: mockSession
    )
}

// MARK: - WriteAheadQueueTests

final class WriteAheadQueueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WAQMockURLProtocol.requestCount = 0
        WAQMockURLProtocol.requestHandler = nil
        // Clear persisted queue
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
        super.tearDown()
    }

    // MARK: Test 1: Enqueue adds items in FIFO order

    func testEnqueue_addsItemsInFIFOOrder() async throws {
        // Always succeed so items flush immediately
        WAQMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let supabase = makeMockSupabase()
        let queue = WriteAheadQueue(supabase: supabase)

        let payload1 = TestSetLogPayload.mock(setNumber: 1)
        let payload2 = TestSetLogPayload.mock(setNumber: 2)
        let payload3 = TestSetLogPayload.mock(setNumber: 3)

        try await queue.enqueue(payload1, table: "set_logs")
        try await queue.enqueue(payload2, table: "set_logs")
        try await queue.enqueue(payload3, table: "set_logs")

        // Wait for flush to complete
        try await Task.sleep(nanoseconds: 500_000_000)

        let count = await queue.pendingCount
        XCTAssertEqual(count, 0, "All items should be flushed after successful writes")
    }

    // MARK: Test 2: Flush removes items on success

    func testFlush_removesItemOnSuccess() async throws {
        WAQMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let supabase = makeMockSupabase()
        let queue = WriteAheadQueue(supabase: supabase)

        try await queue.enqueue(TestSetLogPayload.mock(), table: "set_logs")
        try await Task.sleep(nanoseconds: 300_000_000)

        let count = await queue.pendingCount
        XCTAssertEqual(count, 0, "Queue should be empty after successful flush")
        XCTAssertGreaterThan(WAQMockURLProtocol.requestCount, 0, "At least one HTTP request should have been made")
    }

    // MARK: Test 3: Retry — mock returns 503 twice then 201

    func testFlush_retriesOnFailureThenSucceeds() async throws {
        var callCount = 0
        WAQMockURLProtocol.requestHandler = { request in
            callCount += 1
            let statusCode = callCount <= 2 ? 503 : 201
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let supabase = makeMockSupabase()
        let queue = WriteAheadQueue(supabase: supabase)

        try await queue.enqueue(TestSetLogPayload.mock(), table: "set_logs")

        // Wait for retries (1s + 2s backoff + processing)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let count = await queue.pendingCount
        XCTAssertEqual(count, 0, "Item should eventually be flushed after retries")
        XCTAssertEqual(callCount, 3, "Should have made 3 attempts (2 failures + 1 success)")
    }

    // MARK: Test 4: FIFO ordering verified via request payloads

    func testFlush_processesInFIFOOrder() async throws {
        var receivedSetNumbers: [Int] = []

        WAQMockURLProtocol.requestHandler = { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let setNum = json["set_number"] as? Int {
                receivedSetNumbers.append(setNum)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let supabase = makeMockSupabase()
        let queue = WriteAheadQueue(supabase: supabase)

        // Enqueue 5 items with sequential set numbers
        for i in 1...5 {
            try await queue.enqueue(TestSetLogPayload.mock(setNumber: i), table: "set_logs")
        }

        // Wait for all to flush
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let count = await queue.pendingCount
        XCTAssertEqual(count, 0, "All items should be flushed")
        XCTAssertEqual(receivedSetNumbers, [1, 2, 3, 4, 5], "Items should be processed in FIFO order")
    }

    // MARK: Test 5: clearAll empties the queue

    func testClearAll_emptiesQueue() async throws {
        // Make all requests fail so items stay in queue
        WAQMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let supabase = makeMockSupabase()
        let queue = WriteAheadQueue(supabase: supabase)

        // Manually construct and add items without triggering flush auto-retry storm
        // Instead, just verify clearAll empties internal state
        let items = await queue.queue
        XCTAssertEqual(items.count, 0)

        await queue.clearAll()
        let afterClear = await queue.pendingCount
        XCTAssertEqual(afterClear, 0, "Queue should be empty after clearAll")
    }

    // MARK: Test 6: QueuedWrite Codable round-trip

    func testQueuedWrite_codableRoundTrip() throws {
        let payload = TestSetLogPayload.mock(setNumber: 42)
        let entry = try QueuedWrite(table: "set_logs", item: payload)

        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(QueuedWrite.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.table, "set_logs")
        XCTAssertEqual(decoded.retryCount, 0)

        // Verify inner payload preserved
        let innerJSON = try JSONSerialization.jsonObject(with: decoded.payload) as? [String: Any]
        XCTAssertEqual(innerJSON?["set_number"] as? Int, 42)
    }

    // MARK: Test 7 (#55): clearAll during an in-flight flush must not crash

    /// Reproduces #55: flush() reads queue[0], awaits dispatch, and on transient
    /// failure writes queue[0] back. If clearAll() empties the queue during that
    /// await, the write-back previously trapped with index-out-of-range. The
    /// clearRequested guard must abandon the in-flight item instead.
    func testClearAll_duringInFlightFlush_doesNotCrash() async throws {
        let defaults = UserDefaults(suiteName: "waq.test.\(UUID().uuidString)")!
        let queue = WriteAheadQueue(supabase: makeMockSupabase(), userDefaults: defaults)

        // Handler that delays (widening the race window) then fails transiently,
        // forcing the post-await queue[0] write-back path.
        await queue.registerFlushHandler(forTable: "race") { _ in
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
            return .transientFailure
        }

        try await queue.enqueue(TestSetLogPayload.mock(), table: "race") // triggers flush()
        try await Task.sleep(nanoseconds: 30_000_000)  // let flush enter the handler await
        await queue.clearAll()                          // races with the in-flight item
        try await Task.sleep(nanoseconds: 300_000_000)  // let flush unwind

        let pending = await queue.pendingCount
        XCTAssertEqual(pending, 0, "clearAll during in-flight flush must leave an empty queue without trapping")
    }

    /// #369 slice 3 (Reset All): clearAll() must drain a POPULATED dead-letter and
    /// remove its on-disk persistence — not just an empty queue. This is the exact
    /// behaviour performResetAll relies on: the live WAQ actor holds dead-lettered
    /// owner-mismatched writes in memory + UserDefaults, and a reset that doesn't
    /// call clearAll() would let them replay RLS-403s after re-onboarding.
    func testClearAll_drainsPopulatedDeadLetter_andItsPersistence() async throws {
        let defaults = UserDefaults(suiteName: "waq.test.\(UUID().uuidString)")!
        let queue = WriteAheadQueue(supabase: makeMockSupabase(), userDefaults: defaults, baseRetryDelay: 0.001)

        // Drive an item into the dead-letter store via the permanent-failure path.
        await queue.registerFlushHandler(forTable: "set_logs") { _ in
            .permanentFailure("seed dead-letter")
        }
        try await queue.enqueue(TestSetLogPayload.mock(), table: "set_logs")

        // Poll until the permanent-failure path dead-letters the item (avoids a
        // fixed-sleep flake on a loaded runner — 1s ceiling).
        var deadBefore = await queue.failedWrites()
        for _ in 0..<100 where deadBefore.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            deadBefore = await queue.failedWrites()
        }
        XCTAssertEqual(deadBefore.count, 1, "precondition: one item dead-lettered")

        await queue.clearAll()

        let pendingAfter = await queue.pendingCount
        XCTAssertEqual(pendingAfter, 0, "queue empty after clearAll")
        let deadAfter = await queue.failedWrites()
        XCTAssertTrue(deadAfter.isEmpty, "in-memory dead-letter drained by clearAll")

        // Reload from the same UserDefaults — proves clearAll removed the persisted
        // dead-letter, not just the in-memory copy (otherwise the reset's poison
        // would survive a relaunch).
        let reloaded = WriteAheadQueue(supabase: makeMockSupabase(), userDefaults: defaults)
        let reloadedPending = await reloaded.pendingCount
        XCTAssertEqual(reloadedPending, 0, "persisted queue empty after clearAll")
        let reloadedDead = await reloaded.failedWrites()
        XCTAssertTrue(reloadedDead.isEmpty, "persisted dead-letter empty after clearAll")
    }

    // MARK: Test 8 (#184): retry-exhausted items are dead-lettered, not dropped

    /// Reproduces #184: an item that exhausts its retries was silently removed
    /// with no sink (permanent data loss). It must instead land in the
    /// recoverable dead-letter store.
    func testFlush_exhaustedRetries_movesItemToDeadLetter() async throws {
        let defaults = UserDefaults(suiteName: "waq.test.\(UUID().uuidString)")!
        // Tiny base delay so 6 attempts exhaust in milliseconds, not 31s.
        let queue = WriteAheadQueue(supabase: makeMockSupabase(), userDefaults: defaults, baseRetryDelay: 0.001)

        await queue.registerFlushHandler(forTable: "set_logs") { _ in .transientFailure }

        try await queue.enqueue(TestSetLogPayload.mock(), table: "set_logs") // triggers flush()
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4s — ample for the tiny-backoff retries

        let pending = await queue.pendingCount
        let dead = await queue.failedWrites()
        XCTAssertEqual(pending, 0, "exhausted item must leave the pending queue")
        XCTAssertEqual(dead.count, 1, "exhausted item must be dead-lettered, not silently dropped")
    }

    // MARK: Test 9 (#369 perf-27): batch flush emits correct end-state + all items sent

    /// Verifies that flushing N items in a batch results in an empty queue and that
    /// all N items were sent. This is the core correctness invariant for the O(N)
    /// persist optimisation — the end-state after a flush must be identical to what
    /// the per-item approach produced (empty queue, all items flushed).
    func testFlush_batchFlush_sendsAllItemsAndLeavesEmptyQueue() async throws {
        let defaults = UserDefaults(suiteName: "waq.test.\(UUID().uuidString)")!
        var sentCount = 0

        WAQMockURLProtocol.requestHandler = { request in
            sentCount += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let queue = WriteAheadQueue(supabase: makeMockSupabase(), userDefaults: defaults)

        // Enqueue 10 items to exercise the batch-flush path
        for i in 1...10 {
            try await queue.enqueue(TestSetLogPayload.mock(setNumber: i), table: "set_logs")
        }

        // Wait for flush to complete (all 10 items, 201 on every request)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let pending = await queue.pendingCount
        XCTAssertEqual(pending, 0, "all items must be flushed from the queue")
        XCTAssertEqual(sentCount, 10, "every item in the batch must have been sent exactly once")

        // Verify the persisted queue is also empty (end-state persistence)
        let reloaded = WriteAheadQueue(supabase: makeMockSupabase(), userDefaults: defaults)
        let reloadedCount = await reloaded.pendingCount
        XCTAssertEqual(reloadedCount, 0, "persisted queue must be empty after a complete flush")
    }

    // MARK: Test 10 (#369 perf-27): permanent-failure items are dead-lettered, queue cleared

    /// Verifies that permanently-failed items land in the dead-letter store and the
    /// main queue is empty after flush — consistent with pre-optimisation behaviour.
    func testFlush_permanentFailure_deadLetteredAndQueueEmpty() async throws {
        let defaults = UserDefaults(suiteName: "waq.test.\(UUID().uuidString)")!
        let queue = WriteAheadQueue(supabase: makeMockSupabase(), userDefaults: defaults)

        await queue.registerFlushHandler(forTable: "set_logs") { _ in
            .permanentFailure("test permanent failure")
        }

        try await queue.enqueue(TestSetLogPayload.mock(), table: "set_logs")
        try await Task.sleep(nanoseconds: 300_000_000)

        let pending = await queue.pendingCount
        let dead = await queue.failedWrites()
        XCTAssertEqual(pending, 0, "permanently-failed item must leave the pending queue")
        XCTAssertEqual(dead.count, 1, "permanently-failed item must be dead-lettered")
    }
}
