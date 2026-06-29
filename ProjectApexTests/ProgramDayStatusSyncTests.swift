// ProgramDayStatusSyncTests.swift
// ProjectApexTests — #444 (Programme↔Workout cure, Q5 = Option A)
//
// Today `markDay*` wrote per-day `TrainingDayStatus` ONLY to UserDefaults. The
// server `programs` blob froze statuses at generation time, so a reinstall /
// cache-clear reverted completed days to pending and fed wrong-day routing.
//
// #444 (Q5 = persist-to-server + reconcile-on-load):
//   PERSIST  — every markDayCompleted/Paused/Skipped re-persists the updated
//              mesocycle to the server (the durable record), OWNER-GATED
//              (resolve-before-stamp; never under the placeholder/unresolved
//              owner) and best-effort (UserDefaults stays the local source).
//   RECONCILE — loadProgram, when both a cached mesocycle and a server program
//              exist, prefers the MORE-ADVANCED status per day so neither a
//              stale server nor a stale cache regresses real progress. A day
//              completed on the server shows completed after a fresh load even
//              if the cache says pending.
//
//   1. markDayCompleted_realOwner_persistsToServer — RPC fires, stamped owner,
//      body carries the day's .completed status.
//   2. markDayCompleted_nilOwner_noServerWrite — unresolved owner → no RPC.
//   3. loadProgram_serverCompletedDay_reconcilesOntoCachedPending — cache says
//      pending, server says completed → loaded mesocycle shows completed.
//   4. loadProgram_serverStale_doesNotRegressLocalProgress — cache says
//      completed, server says pending → loaded mesocycle stays completed.

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol stub (mirrors ProgramBackfillTests: split fetch vs RPC)

private final class DayStatusSyncStubURLProtocol: URLProtocol {
    static var fetchStatusCode: Int = 200
    static var fetchData: Data = "[]".data(using: .utf8)!
    static var rpcStatusCode: Int = 200
    static var rpcData: Data = "[]".data(using: .utf8)!

    static var rpcRequestCount: Int = 0
    static var rpcRequestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var isRPC: Bool {
        request.url?.absoluteString.contains("/rpc/deactivate_and_insert_program") == true
    }

    override func startLoading() {
        if isRPC {
            DayStatusSyncStubURLProtocol.rpcRequestCount += 1
            if let body = request.httpBody {
                DayStatusSyncStubURLProtocol.rpcRequestBodies.append(body)
            } else if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) }
                }
                buffer.deallocate()
                stream.close()
                if !data.isEmpty { DayStatusSyncStubURLProtocol.rpcRequestBodies.append(data) }
            }
        }

        let statusCode = isRPC
            ? DayStatusSyncStubURLProtocol.rpcStatusCode
            : DayStatusSyncStubURLProtocol.fetchStatusCode
        let payload = isRPC
            ? DayStatusSyncStubURLProtocol.rpcData
            : DayStatusSyncStubURLProtocol.fetchData

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeDayStatusSyncSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DayStatusSyncStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeDayStatusSyncClient() -> SupabaseClient {
    SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-anon-key",
        urlSession: makeDayStatusSyncSession()
    )
}

private struct DayStatusSyncThrowingProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - ProgramDayStatusSyncTests

final class ProgramDayStatusSyncTests: XCTestCase {

    private let realOwner = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000044")!

    override func setUp() {
        super.setUp()
        DayStatusSyncStubURLProtocol.fetchStatusCode = 200
        DayStatusSyncStubURLProtocol.fetchData = "[]".data(using: .utf8)!
        DayStatusSyncStubURLProtocol.rpcStatusCode = 200
        DayStatusSyncStubURLProtocol.rpcData = "[]".data(using: .utf8)!
        DayStatusSyncStubURLProtocol.rpcRequestCount = 0
        DayStatusSyncStubURLProtocol.rpcRequestBodies = []
        Task { @MainActor in Mesocycle.clearUserDefaults() }
    }

    override func tearDown() {
        Task { @MainActor in Mesocycle.clearUserDefaults() }
        super.tearDown()
    }

    @MainActor
    private func makeViewModel(
        client: SupabaseClient,
        resolveOwner: @escaping () async -> UUID?
    ) -> ProgramViewModel {
        let provider: any LLMProvider = DayStatusSyncThrowingProvider()
        let memory = MemoryService(supabase: client, embeddingAPIKey: "test")
        return ProgramViewModel(
            supabaseClient: client,
            macroPlanService: MacroPlanService(provider: provider),
            sessionPlanService: SessionPlanService(
                provider: provider,
                memoryService: memory,
                supabaseClient: client
            ),
            userId: AppDependencies.placeholderUserId,
            resolveOwner: resolveOwner
        )
    }

    /// Polls until the persist RPC has fired (or the timeout elapses). The
    /// status persist runs on a detached Task off the in-memory update.
    private func waitForRPC(count: Int, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if DayStatusSyncStubURLProtocol.rpcRequestCount >= count { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }

    /// JSON body for a GET fetchActiveProgram response carrying one active program.
    private func activeProgramFetchBody(for mesocycle: Mesocycle) throws -> Data {
        let row = ProgramRow.forInsert(from: mesocycle, userId: realOwner)
        return try JSONEncoder.workoutProgram.encode([row])
    }

    // MARK: 1. markDayCompleted under a real owner re-persists to the server

    @MainActor
    func test_markDayCompleted_realOwner_persistsToServer() async throws {
        let mesocycle = Mesocycle.mockMesocycle()
        let week = mesocycle.weeks[0]
        let day = week.trainingDays[0]

        DayStatusSyncStubURLProtocol.rpcData =
            #"[{"program_id":"\#(mesocycle.id.uuidString)"}]"#.data(using: .utf8)!

        let client = makeDayStatusSyncClient()
        let vm = makeViewModel(client: client, resolveOwner: { self.realOwner })
        vm.currentMesocycle = mesocycle

        vm.markDayCompleted(dayId: day.id, weekId: week.id)

        await waitForRPC(count: 1)

        XCTAssertEqual(
            DayStatusSyncStubURLProtocol.rpcRequestCount, 1,
            "markDayCompleted under a real owner must re-persist the program to the server."
        )
        let bodyData = try XCTUnwrap(DayStatusSyncStubURLProtocol.rpcRequestBodies.last)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(
            body["p_user_id"] as? String, realOwner.uuidString,
            "The status persist must stamp the RESOLVED owner uid."
        )
        // The re-persisted blob must carry the day's NEW .completed status.
        let json = try XCTUnwrap(body["p_mesocycle_json"] as? [String: Any])
        let weeks = try XCTUnwrap(json["weeks"] as? [[String: Any]])
        let days = try XCTUnwrap(weeks.first?["training_days"] as? [[String: Any]])
        let firstDay = try XCTUnwrap(days.first)
        XCTAssertEqual(
            firstDay["status"] as? String, "completed",
            "The persisted blob must carry the updated per-day status."
        )
    }

    // MARK: 2. markDayCompleted under an unresolved owner writes nothing

    @MainActor
    func test_markDayCompleted_nilOwner_noServerWrite() async {
        let mesocycle = Mesocycle.mockMesocycle()
        let week = mesocycle.weeks[0]
        let day = week.trainingDays[0]

        let client = makeDayStatusSyncClient()
        let vm = makeViewModel(client: client, resolveOwner: { nil })
        vm.currentMesocycle = mesocycle

        vm.markDayCompleted(dayId: day.id, weekId: week.id)

        await waitForRPC(count: 1)

        XCTAssertEqual(
            DayStatusSyncStubURLProtocol.rpcRequestCount, 0,
            "An unresolved owner must not persist day status — resolve-before-stamp."
        )
    }

    // MARK: 3. loadProgram reconciles a server-completed day onto a cached pending day

    @MainActor
    func test_loadProgram_serverCompletedDay_reconcilesOntoCachedPending() async throws {
        // Cache: day 0 is still .pending (stale).
        let cached = Mesocycle.mockMesocycle()
        let targetDayId = cached.weeks[0].trainingDays[0].id
        cached.saveToUserDefaults()

        // Server: SAME mesocycle (same ids) but day 0 is .completed (durable record).
        var server = Mesocycle.mockMesocycle()
        server.weeks[0].trainingDays[0].status = .completed
        DayStatusSyncStubURLProtocol.fetchStatusCode = 200
        DayStatusSyncStubURLProtocol.fetchData = try activeProgramFetchBody(for: server)

        let client = makeDayStatusSyncClient()
        let vm = makeViewModel(client: client, resolveOwner: { self.realOwner })

        await vm.loadProgram()

        // Reconcile runs off the fast path; poll until the cached day flips.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if vm.currentMesocycle?.weeks[0].trainingDays.first(where: { $0.id == targetDayId })?.status == .completed {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let day = try XCTUnwrap(
            vm.currentMesocycle?.weeks[0].trainingDays.first(where: { $0.id == targetDayId })
        )
        XCTAssertEqual(
            day.status, .completed,
            "A day completed on the server must show completed after a fresh load, even if the cache said pending."
        )
    }

    // MARK: 4. loadProgram must NOT regress real local progress to a stale server

    @MainActor
    func test_loadProgram_serverStale_doesNotRegressLocalProgress() async throws {
        // Cache: day 0 is .completed (real local progress).
        var cached = Mesocycle.mockMesocycle()
        let targetDayId = cached.weeks[0].trainingDays[0].id
        cached.weeks[0].trainingDays[0].status = .completed
        cached.saveToUserDefaults()

        // Server: SAME mesocycle but day 0 is still .pending (stale).
        let server = Mesocycle.mockMesocycle()
        DayStatusSyncStubURLProtocol.fetchStatusCode = 200
        DayStatusSyncStubURLProtocol.fetchData = try activeProgramFetchBody(for: server)

        let client = makeDayStatusSyncClient()
        let vm = makeViewModel(client: client, resolveOwner: { self.realOwner })

        await vm.loadProgram()

        // Give reconcile a chance to (incorrectly) regress before asserting.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let day = try XCTUnwrap(
            vm.currentMesocycle?.weeks[0].trainingDays.first(where: { $0.id == targetDayId })
        )
        XCTAssertEqual(
            day.status, .completed,
            "A stale server must not regress a locally-completed day back to pending."
        )
    }
}
