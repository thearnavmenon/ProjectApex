// OnboardingProgramPersistTests.swift
// ProjectApexTests — #423 (#369 owner-stamping workstream)
//
// Captures the onboarding-program-persist bug: a fresh onboard generated the
// program, cached it in UserDefaults, but NEVER wrote it to the server `programs`
// table — so every later workout FK-failed on `workout_sessions_program_id_fkey`.
//
// The fix adds a resolve-before-stamp persist step. These tests drive the smallest
// unit that owns that step (`OnboardingProgramPersist.persistIfOwnerResolved`),
// since the onboarding SwiftUI view itself is not directly drivable in a unit test.
//
//   1. Owner resolves to a real uid  → server persist IS called with that uid.
//   2. Owner is nil (auth unresolved) → server persist is NOT called (no placeholder).
//   3. Owner is the placeholder uid   → server persist is NOT called (resolve-before-stamp).

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol stub (reused pattern from ProgramPersistenceTests)

private final class OnboardingPersistStubURLProtocol: URLProtocol {
    static var stubbedStatusCode: Int = 200
    static var stubbedData: Data = Data()
    static var lastRequest: URLRequest?
    static var requestBodies: [Data] = []
    static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        OnboardingPersistStubURLProtocol.requestCount += 1
        OnboardingPersistStubURLProtocol.lastRequest = request
        if let body = request.httpBody {
            OnboardingPersistStubURLProtocol.requestBodies.append(body)
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
            if !data.isEmpty { OnboardingPersistStubURLProtocol.requestBodies.append(data) }
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: OnboardingPersistStubURLProtocol.stubbedStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: OnboardingPersistStubURLProtocol.stubbedData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeOnboardingPersistSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OnboardingPersistStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeOnboardingPersistClient() -> SupabaseClient {
    SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-anon-key",
        urlSession: makeOnboardingPersistSession()
    )
}

// MARK: - OnboardingProgramPersistTests

final class OnboardingProgramPersistTests: XCTestCase {

    private let realOwner = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000007")!

    override func setUp() {
        super.setUp()
        OnboardingPersistStubURLProtocol.stubbedStatusCode = 200
        OnboardingPersistStubURLProtocol.stubbedData = Data()
        OnboardingPersistStubURLProtocol.lastRequest = nil
        OnboardingPersistStubURLProtocol.requestBodies = []
        OnboardingPersistStubURLProtocol.requestCount = 0
    }

    /// Reproduces the bug → fix: when the owner resolves to a real uid, the
    /// onboarding-generated program MUST be persisted to the server via the atomic
    /// `deactivate_and_insert_program` RPC, stamped with that exact resolved uid.
    /// Before the fix this helper did not exist / never ran, so the row never reached
    /// `public.programs` and workouts FK-failed.
    func test_persistIfOwnerResolved_realOwner_callsServerPersistWithThatOwner() async throws {
        let mesocycle = Mesocycle.mockMesocycle()
        OnboardingPersistStubURLProtocol.stubbedData =
            #"[{"program_id":"\#(mesocycle.id.uuidString)"}]"#.data(using: .utf8)!

        let client = makeOnboardingPersistClient()

        let didPersist = await OnboardingProgramPersist.persistIfOwnerResolved(
            mesocycle,
            owner: realOwner,
            client: client
        )

        XCTAssertTrue(didPersist, "A resolved real owner must trigger the server persist.")

        let req = try XCTUnwrap(
            OnboardingPersistStubURLProtocol.lastRequest,
            "A resolved owner must produce a server request."
        )
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(
            req.url?.absoluteString.contains("/rpc/deactivate_and_insert_program") == true,
            "Persist must go through the atomic RPC, got \(req.url?.absoluteString ?? "nil")"
        )

        let bodyData = try XCTUnwrap(OnboardingPersistStubURLProtocol.requestBodies.last)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(
            body["p_user_id"] as? String, realOwner.uuidString,
            "The program must be stamped with the RESOLVED owner uid (resolve-before-stamp)."
        )
        XCTAssertEqual(body["p_program_id"] as? String, mesocycle.id.uuidString)
    }

    /// Resolve-before-stamp guard: a nil owner (auth never resolved / offline)
    /// must NOT write anything server-side — the local cache is the fallback, and
    /// we never stamp a row we can't own.
    func test_persistIfOwnerResolved_nilOwner_doesNotCallServer() async {
        let mesocycle = Mesocycle.mockMesocycle()
        let client = makeOnboardingPersistClient()

        let didPersist = await OnboardingProgramPersist.persistIfOwnerResolved(
            mesocycle,
            owner: nil,
            client: client
        )

        XCTAssertFalse(didPersist, "A nil owner must skip the server persist.")
        XCTAssertEqual(
            OnboardingPersistStubURLProtocol.requestCount, 0,
            "No server request may be made when the owner is unresolved."
        )
    }

    /// Resolve-before-stamp guard: the placeholder uid must NEVER be persisted.
    /// (`resolvedOwnerUserId()` already returns nil for the placeholder, but the
    /// helper defends against it directly so a future caller can't regress it.)
    func test_persistIfOwnerResolved_placeholderOwner_doesNotCallServer() async {
        let mesocycle = Mesocycle.mockMesocycle()
        let client = makeOnboardingPersistClient()

        let didPersist = await OnboardingProgramPersist.persistIfOwnerResolved(
            mesocycle,
            owner: AppDependencies.placeholderUserId,
            client: client
        )

        XCTAssertFalse(didPersist, "The placeholder uid must never be persisted.")
        XCTAssertEqual(
            OnboardingPersistStubURLProtocol.requestCount, 0,
            "No server request may be made for the placeholder uid."
        )
    }
}
