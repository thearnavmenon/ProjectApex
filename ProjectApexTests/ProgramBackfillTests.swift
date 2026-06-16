// ProgramBackfillTests.swift
// ProjectApexTests — #425 (#369 owner-stamping workstream, safety-net B)
//
// Residual gap after #423/#424: when auth is UNRESOLVED at onboard time (offline,
// or a QUIC sign-in stall), onboarding persists the program ONLY locally — the
// server `programs` table stays empty — and nothing re-attempts the server write
// once a real session later resolves. The user is left with a local-only program
// and zero server programs, so every later workout FK-fails on
// `workout_sessions_program_id_fkey`.
//
// #425 adds a best-effort backfill to `ProgramViewModel.loadProgram`'s cache-hit
// fast path: keep showing the cached program immediately, then in the background
// resolve the owner and — only if the server fetch SUCCEEDS and finds NO active
// program — re-persist the cached mesocycle under the resolved owner. A fetch that
// THROWS (offline/transient) must NOT be mistaken for "server empty"; it just
// bails and a later load retries.
//
//   1. cacheHit_serverEmpty_realOwner_backfills — fetch succeeds + empty + real
//      owner → deactivate_and_insert_program fires with p_user_id == owner.
//   2. cacheHit_nilOwner_noServerWrite — resolveOwner = nil → no backfill RPC.
//   3. cacheHit_serverHasProgram_noBackfill — fetch returns an active program → no
//      redundant backfill RPC.
//   4. cacheHit_serverFetchFails_noBackfill — fetch THROWS (500) → no backfill RPC
//      (an error is not "empty").

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol stub
//
// Distinguishes the two endpoints the backfill touches:
//   • GET  /rest/v1/programs?...                       → fetchActiveProgram
//   • POST /rest/v1/rpc/deactivate_and_insert_program  → the backfill write
// so a test can stub the fetch result independently of counting the backfill RPC.

private final class ProgramBackfillStubURLProtocol: URLProtocol {
    /// Status + body returned for the GET fetchActiveProgram request.
    static var fetchStatusCode: Int = 200
    static var fetchData: Data = "[]".data(using: .utf8)!
    /// Status + body returned for the POST backfill RPC.
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
            ProgramBackfillStubURLProtocol.rpcRequestCount += 1
            if let body = request.httpBody {
                ProgramBackfillStubURLProtocol.rpcRequestBodies.append(body)
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
                if !data.isEmpty { ProgramBackfillStubURLProtocol.rpcRequestBodies.append(data) }
            }
        }

        let statusCode = isRPC
            ? ProgramBackfillStubURLProtocol.rpcStatusCode
            : ProgramBackfillStubURLProtocol.fetchStatusCode
        let payload = isRPC
            ? ProgramBackfillStubURLProtocol.rpcData
            : ProgramBackfillStubURLProtocol.fetchData

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

private func makeBackfillSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProgramBackfillStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeBackfillClient() -> SupabaseClient {
    SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-anon-key",
        urlSession: makeBackfillSession()
    )
}

// MARK: - Minimal no-op LLM provider (mirrors ProgramOwnerGateTests)

private struct BackfillThrowingProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - ProgramBackfillTests

final class ProgramBackfillTests: XCTestCase {

    private let realOwner = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000011")!

    override func setUp() {
        super.setUp()
        ProgramBackfillStubURLProtocol.fetchStatusCode = 200
        ProgramBackfillStubURLProtocol.fetchData = "[]".data(using: .utf8)!
        ProgramBackfillStubURLProtocol.rpcStatusCode = 200
        ProgramBackfillStubURLProtocol.rpcData = "[]".data(using: .utf8)!
        ProgramBackfillStubURLProtocol.rpcRequestCount = 0
        ProgramBackfillStubURLProtocol.rpcRequestBodies = []
        // Local cache is the fast-path seam under test — start clean.
        Task { @MainActor in Mesocycle.clearUserDefaults() }
    }

    override func tearDown() {
        Task { @MainActor in Mesocycle.clearUserDefaults() }
        super.tearDown()
    }

    /// Builds a ProgramViewModel backed by no-op services and the backfill-aware
    /// stub client, with an injected `resolveOwner`. Mirrors
    /// ProgramOwnerGateTests.makeViewModel.
    @MainActor
    private func makeViewModel(
        client: SupabaseClient,
        resolveOwner: @escaping () async -> UUID?
    ) -> ProgramViewModel {
        let provider: any LLMProvider = BackfillThrowingProvider()
        let memory = MemoryService(supabase: client, embeddingAPIKey: "test")
        return ProgramViewModel(
            supabaseClient: client,
            programGenerationService: ProgramGenerationService(provider: provider),
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

    /// Polls until the backfill RPC has fired (or the timeout elapses). The backfill
    /// runs on a detached Task off the fast path, so the count is not set
    /// synchronously when `loadProgram` returns.
    private func waitForRPC(count: Int, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ProgramBackfillStubURLProtocol.rpcRequestCount >= count { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }

    /// JSON body for a GET fetchActiveProgram response that contains one active program.
    private func activeProgramFetchBody(for mesocycle: Mesocycle) throws -> Data {
        let row = ProgramRow.forInsert(from: mesocycle, userId: realOwner)
        return try JSONEncoder.workoutProgram.encode([row])
    }

    // MARK: 1. cache hit + server empty + real owner → backfill fires with that owner

    @MainActor
    func test_cacheHit_serverEmpty_realOwner_backfills() async throws {
        let mesocycle = Mesocycle.mockMesocycle()
        mesocycle.saveToUserDefaults()

        // GET fetch SUCCEEDS and returns NO active program.
        ProgramBackfillStubURLProtocol.fetchStatusCode = 200
        ProgramBackfillStubURLProtocol.fetchData = "[]".data(using: .utf8)!
        // RPC returns the inserted program id.
        ProgramBackfillStubURLProtocol.rpcData =
            #"[{"program_id":"\#(mesocycle.id.uuidString)"}]"#.data(using: .utf8)!

        let client = makeBackfillClient()
        let vm = makeViewModel(client: client, resolveOwner: { self.realOwner })

        await vm.loadProgram()
        // Fast path still shows the cached program immediately.
        XCTAssertEqual(vm.viewState, .loaded(mesocycle), "Cache hit must display immediately.")

        await waitForRPC(count: 1)

        XCTAssertEqual(
            ProgramBackfillStubURLProtocol.rpcRequestCount, 1,
            "An empty server + real owner must backfill the cached program."
        )
        let bodyData = try XCTUnwrap(ProgramBackfillStubURLProtocol.rpcRequestBodies.last)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(
            body["p_user_id"] as? String, realOwner.uuidString,
            "The backfill must stamp the RESOLVED owner uid."
        )
        XCTAssertEqual(body["p_program_id"] as? String, mesocycle.id.uuidString)
    }

    // MARK: 2. cache hit + nil owner → no server write

    @MainActor
    func test_cacheHit_nilOwner_noServerWrite() async {
        let mesocycle = Mesocycle.mockMesocycle()
        mesocycle.saveToUserDefaults()

        let client = makeBackfillClient()
        let vm = makeViewModel(client: client, resolveOwner: { nil })

        await vm.loadProgram()
        XCTAssertEqual(vm.viewState, .loaded(mesocycle))

        // Give any (incorrect) background work a chance to fire before asserting zero.
        await waitForRPC(count: 1)

        XCTAssertEqual(
            ProgramBackfillStubURLProtocol.rpcRequestCount, 0,
            "An unresolved owner must not backfill — the next resolved load catches it."
        )
    }

    // MARK: 3. cache hit + server already has a program → no redundant backfill

    @MainActor
    func test_cacheHit_serverHasProgram_noBackfill() async throws {
        let mesocycle = Mesocycle.mockMesocycle()
        mesocycle.saveToUserDefaults()

        // GET fetch SUCCEEDS and returns an active program already.
        ProgramBackfillStubURLProtocol.fetchStatusCode = 200
        ProgramBackfillStubURLProtocol.fetchData = try activeProgramFetchBody(for: mesocycle)

        let client = makeBackfillClient()
        let vm = makeViewModel(client: client, resolveOwner: { self.realOwner })

        await vm.loadProgram()
        XCTAssertEqual(vm.viewState, .loaded(mesocycle))

        await waitForRPC(count: 1)

        XCTAssertEqual(
            ProgramBackfillStubURLProtocol.rpcRequestCount, 0,
            "When the server already has an active program, no backfill may fire."
        )
    }

    // MARK: 4. cache hit + server fetch THROWS → no backfill (error != empty)

    @MainActor
    func test_cacheHit_serverFetchFails_noBackfill() async {
        let mesocycle = Mesocycle.mockMesocycle()
        mesocycle.saveToUserDefaults()

        // GET fetch FAILS (transient/offline) — must NOT be read as "server empty".
        ProgramBackfillStubURLProtocol.fetchStatusCode = 500
        ProgramBackfillStubURLProtocol.fetchData = "{}".data(using: .utf8)!

        let client = makeBackfillClient()
        let vm = makeViewModel(client: client, resolveOwner: { self.realOwner })

        await vm.loadProgram()
        XCTAssertEqual(vm.viewState, .loaded(mesocycle))

        await waitForRPC(count: 1)

        XCTAssertEqual(
            ProgramBackfillStubURLProtocol.rpcRequestCount, 0,
            "A failed fetch must not be mistaken for an empty server — no backfill."
        )
    }
}
