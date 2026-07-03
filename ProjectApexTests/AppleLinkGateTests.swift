// AppleLinkGateTests.swift
// ProjectApexTests — #598 (SiWA Slice C, umbrella #595)
//
// The backfill link gate: an install already PAST onboarding whose identity is
// not yet Apple-anchored gets prompted to link on launch (same Slice-A flow,
// preserving its current uid). This is what delivers the durability promise to
// current alpha users — without it their data stays bound to one install.
//
// Covered here:
//   1. `AppleLinkGate.shouldEvaluate` — the pure launch predicate (only
//      installs past onboarding, only while not locally marked linked).
//   2. `SupabaseAuth.fetchIdentityState()` — the truthful server-side check
//      (GET /auth/v1/user → identities[].provider + is_anonymous), fail-open:
//      nil on no-session / network failure / non-2xx, so the gate can never
//      block or brick a launch.

import XCTest
@testable import ProjectApex

// MARK: - Mock

/// Minimal handler-based URLProtocol for the GET /auth/v1/user stubs.
private final class UserInfoMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// (path, authorizationHeader) → (status, body). 404 default.
    nonisolated(unsafe) static var handler: ((String, String?) -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() { handler = nil; requestCount = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let (status, data) = Self.handler?(
            request.url?.path ?? "",
            request.value(forHTTPHeaderField: "Authorization")
        ) ?? (404, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private let testURL = URL(string: "https://test.supabase.co")!

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UserInfoMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeScopedKeychain() -> KeychainService {
    KeychainService(serviceName: "com.projectapex.tests.linkgate.\(UUID().uuidString)")
}

private func clearAuthKeys(_ keychain: KeychainService) {
    try? keychain.delete(.supabaseAccessToken)
    try? keychain.delete(.supabaseRefreshToken)
    try? keychain.delete(.supabaseSessionExpiry)
    try? keychain.delete(.supabaseAuthUserId)
}

private func seedAnonSession(_ keychain: KeychainService, uid: UUID) throws {
    try keychain.store("gate-access", for: .supabaseAccessToken)
    try keychain.store("gate-refresh", for: .supabaseRefreshToken)
    try keychain.store(String(Int(Date().timeIntervalSince1970) + 3600), for: .supabaseSessionExpiry)
    try keychain.store(uid.uuidString, for: .supabaseAuthUserId)
}

private func userInfoJSON(identityProviders: [String], isAnonymous: Bool) -> Data {
    let dict: [String: Any] = [
        "id": UUID().uuidString,
        "identities": identityProviders.map { ["provider": $0, "id": UUID().uuidString] },
        "is_anonymous": isAnonymous
    ]
    return try! JSONSerialization.data(withJSONObject: dict)
}

// MARK: - Gate predicate

final class AppleLinkGatePredicateTests: XCTestCase {

    func test_pastOnboarding_notLinked_prompts() {
        XCTAssertTrue(AppleLinkGate.shouldEvaluate(onboardingComplete: true, locallyMarkedLinked: false),
            "an existing install with un-anchored data is exactly who the gate is for")
    }

    func test_midOnboarding_neverPrompts() {
        // Onboarding owns its own required Apple step (#597) — the gate must
        // not double-prompt a user who hasn't finished onboarding.
        XCTAssertFalse(AppleLinkGate.shouldEvaluate(onboardingComplete: false, locallyMarkedLinked: false))
    }

    func test_alreadyLinked_neverPrompts() {
        XCTAssertFalse(AppleLinkGate.shouldEvaluate(onboardingComplete: true, locallyMarkedLinked: true))
    }
}

// MARK: - Server identity state

final class SupabaseAuthIdentityStateTests: XCTestCase {

    override func tearDown() {
        UserInfoMockURLProtocol.reset()
        super.tearDown()
    }

    private func makeAuthWithSession(keychain: KeychainService, uid: UUID) async throws -> SupabaseAuth {
        try seedAnonSession(keychain, uid: uid)
        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )
        _ = await auth.awaitFirstResolution()
        return auth
    }

    func test_appleIdentityPresent_returnsLinked() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let auth = try await makeAuthWithSession(keychain: keychain, uid: UUID())

        UserInfoMockURLProtocol.handler = { path, authHeader in
            guard path.contains("/auth/v1/user") else { return (404, Data()) }
            XCTAssertEqual(authHeader, "Bearer gate-access", "the check must be session-scoped")
            return (200, userInfoJSON(identityProviders: ["apple"], isAnonymous: false))
        }

        let state = await auth.fetchIdentityState()
        XCTAssertEqual(state?.isAppleLinked, true)
        XCTAssertEqual(state?.isAnonymous, false)
        clearAuthKeys(keychain)
    }

    func test_anonymousUser_returnsUnlinked() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let auth = try await makeAuthWithSession(keychain: keychain, uid: UUID())

        UserInfoMockURLProtocol.handler = { path, _ in
            guard path.contains("/auth/v1/user") else { return (404, Data()) }
            return (200, userInfoJSON(identityProviders: [], isAnonymous: true))
        }

        let state = await auth.fetchIdentityState()
        XCTAssertEqual(state?.isAppleLinked, false)
        XCTAssertEqual(state?.isAnonymous, true)
        clearAuthKeys(keychain)
    }

    func test_serverFailure_returnsNil_failOpen() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let auth = try await makeAuthWithSession(keychain: keychain, uid: UUID())

        UserInfoMockURLProtocol.handler = { _, _ in (500, Data()) }

        let state = await auth.fetchIdentityState()
        XCTAssertNil(state, "a failed check must skip the gate this launch, never block")
        clearAuthKeys(keychain)
    }

    func test_noSession_returnsNil_withoutNetworkCall() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        // No seeded session, no resolution: nothing to check against.
        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )

        let state = await auth.fetchIdentityState()
        XCTAssertNil(state)
        XCTAssertEqual(UserInfoMockURLProtocol.requestCount, 0,
            "no session → no speculative network call at launch")
        clearAuthKeys(keychain)
    }
}
