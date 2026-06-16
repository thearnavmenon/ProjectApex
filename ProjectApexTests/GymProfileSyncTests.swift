// GymProfileSyncTests.swift
// ProjectApexTests — #409 PR-B (#369 owner-stamping workstream)
//
// Gates the `gym_profiles` deactivate+insert that fires from
// `ContentView.onEquipmentChanged` on the RESOLVED owner. Before this fix the
// site read the sync `deps.resolvedUserId`, which can be the pre-auth
// placeholder — so an equipment edit made before auth resolved would stamp a
// row the user could not own (the #369 owner-mismatch failure mode).
//
// These tests drive the smallest unit that owns the gate
// (`GymProfileSync.syncIfOwnerResolved`), since the SwiftUI ContentView itself
// is not directly drivable in a unit test.
//
//   1. Owner is nil (auth unresolved) → no server request (no placeholder write).
//   2. Owner is the placeholder uid    → no server request (resolve-before-stamp).
//   3. Owner resolves to a real uid     → deactivate fires (best-effort; a
//      zero-old-row patchNoMatch is NON-FATAL) and the insert STILL fires,
//      stamped with that exact resolved uid.

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol stub (reused pattern from OnboardingProgramPersistTests)

private final class GymProfileSyncStubURLProtocol: URLProtocol {
    /// Status code returned for the deactivate PATCH (first request).
    static var deactivateStatusCode: Int = 200
    /// Body returned for the deactivate PATCH. An empty JSON array makes
    /// `performExpectingRow` throw `patchNoMatch` (zero old active rows) — the
    /// realistic "first edit, nothing to deactivate" case.
    static var deactivateData: Data = "[]".data(using: .utf8)!
    /// Status code returned for the insert POST (second request).
    static var insertStatusCode: Int = 200
    /// Body returned for the insert POST.
    static var insertData: Data = "[]".data(using: .utf8)!

    static var requestCount: Int = 0
    static var lastRequest: URLRequest?
    static var requests: [URLRequest] = []
    static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isInsert = (request.httpMethod ?? "") == "POST"
        GymProfileSyncStubURLProtocol.requestCount += 1
        GymProfileSyncStubURLProtocol.lastRequest = request
        GymProfileSyncStubURLProtocol.requests.append(request)
        if let body = request.httpBody {
            GymProfileSyncStubURLProtocol.requestBodies.append(body)
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
            if !data.isEmpty { GymProfileSyncStubURLProtocol.requestBodies.append(data) }
        }

        let statusCode = isInsert
            ? GymProfileSyncStubURLProtocol.insertStatusCode
            : GymProfileSyncStubURLProtocol.deactivateStatusCode
        let payload = isInsert
            ? GymProfileSyncStubURLProtocol.insertData
            : GymProfileSyncStubURLProtocol.deactivateData

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

private func makeGymProfileSyncSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GymProfileSyncStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeGymProfileSyncClient() -> SupabaseClient {
    SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-anon-key",
        urlSession: makeGymProfileSyncSession()
    )
}

// MARK: - GymProfileSyncTests

final class GymProfileSyncTests: XCTestCase {

    private let realOwner = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000009")!

    override func setUp() {
        super.setUp()
        GymProfileSyncStubURLProtocol.deactivateStatusCode = 200
        GymProfileSyncStubURLProtocol.deactivateData = "[]".data(using: .utf8)!
        GymProfileSyncStubURLProtocol.insertStatusCode = 200
        GymProfileSyncStubURLProtocol.insertData = "[]".data(using: .utf8)!
        GymProfileSyncStubURLProtocol.requestCount = 0
        GymProfileSyncStubURLProtocol.lastRequest = nil
        GymProfileSyncStubURLProtocol.requests = []
        GymProfileSyncStubURLProtocol.requestBodies = []
    }

    /// Resolve-before-stamp guard: a nil owner (auth never resolved / offline)
    /// must NOT write anything server-side.
    func test_syncIfOwnerResolved_nilOwner_noRequests() async {
        let profile = GymProfile.mockProfile()
        let client = makeGymProfileSyncClient()

        let didSync = await GymProfileSync.syncIfOwnerResolved(profile, owner: nil, client: client)

        XCTAssertFalse(didSync, "A nil owner must skip the server sync.")
        XCTAssertEqual(
            GymProfileSyncStubURLProtocol.requestCount, 0,
            "No server request may be made when the owner is unresolved."
        )
    }

    /// Resolve-before-stamp guard: the placeholder uid must NEVER be persisted.
    func test_syncIfOwnerResolved_placeholderOwner_noRequests() async {
        let profile = GymProfile.mockProfile()
        let client = makeGymProfileSyncClient()

        let didSync = await GymProfileSync.syncIfOwnerResolved(
            profile,
            owner: AppDependencies.placeholderUserId,
            client: client
        )

        XCTAssertFalse(didSync, "The placeholder uid must never be persisted.")
        XCTAssertEqual(
            GymProfileSyncStubURLProtocol.requestCount, 0,
            "No server request may be made for the placeholder uid."
        )
    }

    /// Happy path with a non-fatal deactivate: the deactivate PATCH returns an
    /// empty array (zero old active rows → `patchNoMatch`), which is VALID, not an
    /// error. The insert must STILL fire and be stamped with the resolved owner.
    func test_syncIfOwnerResolved_realOwner_deactivatesThenInserts_nonFatalDeactivate() async throws {
        // Deactivate returns [] → SupabaseClient.deactivateGymProfiles throws
        // patchNoMatch; the helper swallows it (try?) and proceeds to the insert.
        GymProfileSyncStubURLProtocol.deactivateData = "[]".data(using: .utf8)!
        GymProfileSyncStubURLProtocol.insertStatusCode = 200
        GymProfileSyncStubURLProtocol.insertData = "[]".data(using: .utf8)!

        let profile = GymProfile.mockProfile()
        let client = makeGymProfileSyncClient()

        let didSync = await GymProfileSync.syncIfOwnerResolved(profile, owner: realOwner, client: client)

        XCTAssertTrue(didSync, "A non-fatal deactivate must not block the insert under a real owner.")

        // Both requests fire: the deactivate PATCH and the insert POST.
        XCTAssertEqual(
            GymProfileSyncStubURLProtocol.requestCount, 2,
            "Expected a deactivate PATCH then an insert POST."
        )

        // The insert is the POST request; assert its body stamps the resolved owner.
        let insertRequest = try XCTUnwrap(
            GymProfileSyncStubURLProtocol.requests.first(where: { $0.httpMethod == "POST" }),
            "The insert POST must fire even when the deactivate matched zero rows."
        )
        XCTAssertTrue(
            insertRequest.url?.absoluteString.contains("/gym_profiles") == true,
            "Insert must target gym_profiles, got \(insertRequest.url?.absoluteString ?? "nil")"
        )

        let insertBody = try XCTUnwrap(
            GymProfileSyncStubURLProtocol.requestBodies.last,
            "The insert must carry a body."
        )
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: insertBody) as? [String: Any])
        XCTAssertEqual(
            body["user_id"] as? String, realOwner.uuidString,
            "The inserted gym_profiles row must be stamped with the RESOLVED owner uid."
        )
    }
}
