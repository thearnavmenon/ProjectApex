// ProgramOwnerGateTests.swift
// ProjectApexTests — #409 PR-A (#369 owner-mismatch campaign, Slice 6 tail)
//
// ProgramViewModel was frozen to the `userId` captured at init — which on a fresh
// launch can be the pre-auth placeholder uid. The single owned write
// (`deactivateAndInsertProgram` inside `persistProgram`) therefore stamped the
// `programs` row under a uid the user could not own once anon-auth resolved.
//
// PR-A converts the owned write to ASYNC owner re-resolution at write time via an
// injected `resolveOwner: () async -> UUID?`. These tests drive `persistProgram`
// directly (it is `internal` for test access — same convention as
// `currentMesocycle`) because the public generate paths fire the persist on a
// detached Task that a unit test cannot deterministically await.
//
//   1. nilOwner        → no server request (auth unresolved → silent abort).
//   2. placeholderOwner→ no server request (resolve-before-stamp guard).
//   3. realOwner       → RPC body stamped with the resolved owner uid.
//   4. retry           → persistRetryAction re-resolves the owner (does not replay
//                        a captured uid): a network-failed real-owner persist arms
//                        the retry; re-invoking it re-resolves to a DIFFERENT owner
//                        and stamps that one.

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol stub (reused pattern from ProgramPersistenceTests / OnboardingProgramPersistTests)

private final class ProgramOwnerGateStubURLProtocol: URLProtocol {
    static var stubbedStatusCode: Int = 200
    static var stubbedData: Data = Data()
    static var lastRequest: URLRequest?
    static var requestBodies: [Data] = []
    static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ProgramOwnerGateStubURLProtocol.requestCount += 1
        ProgramOwnerGateStubURLProtocol.lastRequest = request
        if let body = request.httpBody {
            ProgramOwnerGateStubURLProtocol.requestBodies.append(body)
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
            if !data.isEmpty { ProgramOwnerGateStubURLProtocol.requestBodies.append(data) }
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: ProgramOwnerGateStubURLProtocol.stubbedStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ProgramOwnerGateStubURLProtocol.stubbedData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeOwnerGateSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProgramOwnerGateStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeOwnerGateClient() -> SupabaseClient {
    SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-anon-key",
        urlSession: makeOwnerGateSession()
    )
}

// MARK: - Minimal no-op LLM provider (mirrors SkipFeatureTests.makeViewModel)

private struct OwnerGateThrowingProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - ProgramOwnerGateTests

final class ProgramOwnerGateTests: XCTestCase {

    private let realOwner = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000009")!
    private let secondOwner = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000A")!

    override func setUp() {
        super.setUp()
        ProgramOwnerGateStubURLProtocol.stubbedStatusCode = 200
        // The RPC RETURNS TABLE(program_id uuid) → PostgREST replies with a JSON array.
        ProgramOwnerGateStubURLProtocol.stubbedData = "[]".data(using: .utf8)!
        ProgramOwnerGateStubURLProtocol.lastRequest = nil
        ProgramOwnerGateStubURLProtocol.requestBodies = []
        ProgramOwnerGateStubURLProtocol.requestCount = 0
    }

    /// Builds a ProgramViewModel backed by no-op services and a stubbed client,
    /// with an injected `resolveOwner`. Mirrors SkipFeatureTests.makeViewModel +
    /// the stubbed-client pattern from ProgramPersistenceTests.
    @MainActor
    private func makeViewModel(
        client: SupabaseClient,
        resolveOwner: @escaping () async -> UUID?
    ) -> ProgramViewModel {
        let provider: any LLMProvider = OwnerGateThrowingProvider()
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
            userId: AppDependencies.placeholderUserId,   // frozen id is the placeholder — the bug's setup
            resolveOwner: resolveOwner
        )
    }

    /// nil owner (auth never resolved / offline) → silent abort, NO server request.
    /// FAILS before the refactor: the frozen userId issues the RPC regardless.
    @MainActor
    func test_nilOwner_doesNotCallServer() async {
        let client = makeOwnerGateClient()
        let vm = makeViewModel(client: client, resolveOwner: { nil })

        await vm.persistProgram(Mesocycle.mockMesocycle(), context: "test_nilOwner")

        XCTAssertEqual(
            ProgramOwnerGateStubURLProtocol.requestCount, 0,
            "A nil owner must skip the server stamp (no deactivate_and_insert_program)."
        )
        XCTAssertNil(vm.persistError, "Owner-unresolved is a silent abort, not a sync failure.")
        XCTAssertNil(vm.persistRetryAction, "No retry is armed on an owner-unresolved abort.")
    }

    /// placeholder owner → resolve-before-stamp guard: NO server request.
    @MainActor
    func test_placeholderOwner_doesNotCallServer() async {
        let client = makeOwnerGateClient()
        let vm = makeViewModel(client: client, resolveOwner: { AppDependencies.placeholderUserId })

        await vm.persistProgram(Mesocycle.mockMesocycle(), context: "test_placeholder")

        XCTAssertEqual(
            ProgramOwnerGateStubURLProtocol.requestCount, 0,
            "The placeholder uid must never be stamped server-side."
        )
        XCTAssertNil(vm.persistError)
        XCTAssertNil(vm.persistRetryAction)
    }

    /// A resolved real owner → the RPC body is stamped with THAT uid (resolve-before-stamp).
    @MainActor
    func test_realOwner_stampsThatUid() async throws {
        let mesocycle = Mesocycle.mockMesocycle()
        ProgramOwnerGateStubURLProtocol.stubbedData =
            #"[{"program_id":"\#(mesocycle.id.uuidString)"}]"#.data(using: .utf8)!

        let client = makeOwnerGateClient()
        let vm = makeViewModel(client: client, resolveOwner: { self.realOwner })

        await vm.persistProgram(mesocycle, context: "test_realOwner")

        let req = try XCTUnwrap(
            ProgramOwnerGateStubURLProtocol.lastRequest,
            "A resolved owner must produce a server request."
        )
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(
            req.url?.absoluteString.contains("/rpc/deactivate_and_insert_program") == true,
            "Persist must go through the atomic RPC, got \(req.url?.absoluteString ?? "nil")"
        )

        let bodyData = try XCTUnwrap(ProgramOwnerGateStubURLProtocol.requestBodies.last)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(
            body["p_user_id"] as? String, realOwner.uuidString,
            "The program must be stamped with the RESOLVED owner uid, not the frozen placeholder."
        )
        XCTAssertEqual(body["p_program_id"] as? String, mesocycle.id.uuidString)
    }

    /// The retry must RE-RESOLVE the owner rather than replay a captured uid.
    ///
    /// Spec wrinkle: the prompt's "nil first → invoke persistRetryAction" can't be
    /// taken literally — an owner-unresolved abort is SILENT (it clears
    /// persistRetryAction to nil per the UX note), so a nil-first persist arms no
    /// retry to invoke. `persistRetryAction` is armed only by a NETWORK failure, so
    /// this drives the exact defect that fix targets: a real-owner persist whose RPC
    /// 500s arms the retry; the resolver then returns a DIFFERENT owner; invoking
    /// persistRetryAction must stamp the freshly-resolved owner — proving the retry
    /// re-resolves rather than replaying the captured uid.
    @MainActor
    func test_retry_reResolvesOwner() async throws {
        let mesocycle = Mesocycle.mockMesocycle()

        // Counter-backed resolver: realOwner on the first call, secondOwner after.
        let counter = OwnerResolveCounter(values: [realOwner, secondOwner])
        let client = makeOwnerGateClient()
        let vm = makeViewModel(client: client, resolveOwner: { await counter.next() })

        // First persist: real owner resolves, but the RPC fails → retry armed.
        ProgramOwnerGateStubURLProtocol.stubbedStatusCode = 500
        ProgramOwnerGateStubURLProtocol.stubbedData = "{}".data(using: .utf8)!
        await vm.persistProgram(mesocycle, context: "test_retry")

        XCTAssertEqual(
            ProgramOwnerGateStubURLProtocol.requestCount, 1,
            "The first persist resolves a real owner and issues exactly one (failing) request."
        )
        let firstBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(ProgramOwnerGateStubURLProtocol.requestBodies.last)) as? [String: Any]
        )
        XCTAssertEqual(firstBody["p_user_id"] as? String, realOwner.uuidString)
        let retry = try XCTUnwrap(vm.persistRetryAction, "A network-failed persist must arm a retry.")

        // Retry: the RPC now succeeds; the retry must RE-RESOLVE → secondOwner.
        ProgramOwnerGateStubURLProtocol.stubbedStatusCode = 200
        ProgramOwnerGateStubURLProtocol.stubbedData =
            #"[{"program_id":"\#(mesocycle.id.uuidString)"}]"#.data(using: .utf8)!
        await retry()

        XCTAssertEqual(
            ProgramOwnerGateStubURLProtocol.requestCount, 2,
            "Invoking the retry must issue a second request."
        )
        let retryBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(ProgramOwnerGateStubURLProtocol.requestBodies.last)) as? [String: Any]
        )
        XCTAssertEqual(
            retryBody["p_user_id"] as? String, secondOwner.uuidString,
            "The retry must stamp the freshly RE-RESOLVED owner, not replay the captured uid."
        )
    }
}

// MARK: - Counter-backed resolver

/// Returns successive values on each `next()` call (last value repeats once
/// exhausted). Actor so the `() async -> UUID?` closure can read it safely.
private actor OwnerResolveCounter {
    private let values: [UUID?]
    private var index = 0
    init(values: [UUID?]) { self.values = values }
    func next() -> UUID? {
        defer { if index < values.count - 1 { index += 1 } }
        return values.isEmpty ? nil : values[min(index, values.count - 1)]
    }
}
