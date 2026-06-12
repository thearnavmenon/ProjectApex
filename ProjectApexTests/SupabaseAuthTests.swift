// SupabaseAuthTests.swift
// ProjectApexTests — #369 auth slice 1
//
// Unit tests for the hand-rolled GoTrue client (SupabaseAuth) and the
// SupabaseClient token-refresh / 401-retry path. All network calls are mocked
// via URLProtocol; nothing here hits the live Supabase project.
//
// Coverage:
//   1. Anonymous sign-in success → session persisted to Keychain + token set.
//   2. Stored-session restore on launch → no signup call; token from Keychain.
//   3. Sign-in failure (non-2xx) → no crash, no hang, session stays nil.
//   4. Refresh on near-expiry; 401 → refresh once and retry.

import XCTest
@testable import ProjectApex

// MARK: - Path-routing URLProtocol mock

/// Routes responses by URL path prefix so GoTrue (signup/token/logout) and
/// PostgREST requests can be stubbed independently within one URLSession.
final class GoTrueMockURLProtocol: URLProtocol {

    struct Stub {
        let statusCode: Int
        let data: Data
    }

    /// Keyed by a substring of the request path. First match wins.
    static var stubs: [(match: String, stub: Stub)] = []
    /// Recorded request paths in order, for "no signup call" assertions.
    static var recordedPaths: [String] = []
    /// Recorded Authorization header values in order (for retry assertions).
    static var recordedAuthHeaders: [String] = []

    static func reset() {
        stubs = []
        recordedPaths = []
        recordedAuthHeaders = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        GoTrueMockURLProtocol.recordedPaths.append(path)
        GoTrueMockURLProtocol.recordedAuthHeaders.append(
            request.value(forHTTPHeaderField: "Authorization") ?? ""
        )

        let match = GoTrueMockURLProtocol.stubs.first { path.contains($0.match) }
        let stub = match?.stub ?? Stub(statusCode: 404, data: Data())

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GoTrueMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// A throwaway KeychainService scoped to a per-test service name so tests never
/// touch the real app Keychain namespace and don't collide with each other.
private func makeScopedKeychain() -> KeychainService {
    KeychainService(serviceName: "com.projectapex.tests.auth.\(UUID().uuidString)")
}

private func clearAuthKeys(_ keychain: KeychainService) {
    try? keychain.delete(.supabaseAccessToken)
    try? keychain.delete(.supabaseRefreshToken)
    try? keychain.delete(.supabaseSessionExpiry)
    try? keychain.delete(.supabaseAuthUserId)
}

/// Builds a GoTrue token JSON body with an absolute `expires_at`.
private func tokenJSON(
    access: String,
    refresh: String,
    expiresAt: Int,
    userId: UUID = UUID()
) -> Data {
    let dict: [String: Any] = [
        "access_token": access,
        "refresh_token": refresh,
        "expires_at": expiresAt,
        "user": ["id": userId.uuidString]
    ]
    return try! JSONSerialization.data(withJSONObject: dict)
}

private let testURL = URL(string: "https://test.supabase.co")!

// MARK: - SupabaseAuthTests

final class SupabaseAuthTests: XCTestCase {

    override func tearDown() {
        GoTrueMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: 1. Anonymous sign-in success

    func test_signInAnonymously_success_persistsSessionAndReturnsToken() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let uid = UUID()
        GoTrueMockURLProtocol.reset()
        GoTrueMockURLProtocol.stubs = [
            ("/auth/v1/signup", .init(
                statusCode: 200,
                data: tokenJSON(access: "access-1", refresh: "refresh-1",
                                expiresAt: Int(Date().timeIntervalSince1970) + 3600,
                                userId: uid)
            ))
        ]

        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )

        let session = try await auth.signInAnonymously()

        XCTAssertEqual(session.accessToken, "access-1")
        XCTAssertEqual(session.userId, uid)
        // Persisted to the Keychain.
        XCTAssertEqual(try keychain.retrieve(.supabaseAccessToken), "access-1")
        XCTAssertEqual(try keychain.retrieve(.supabaseRefreshToken), "refresh-1")
        XCTAssertEqual(try keychain.retrieve(.supabaseAuthUserId), uid.uuidString)
        clearAuthKeys(keychain)
    }

    func test_awaitFirstResolution_freshLaunch_signsInAndSetsToken() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        GoTrueMockURLProtocol.reset()
        GoTrueMockURLProtocol.stubs = [
            ("/auth/v1/signup", .init(
                statusCode: 200,
                data: tokenJSON(access: "fresh-access", refresh: "r",
                                expiresAt: Int(Date().timeIntervalSince1970) + 3600)
            ))
        ]

        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )

        let resolved = await auth.awaitFirstResolution()
        XCTAssertEqual(resolved?.accessToken, "fresh-access")
        XCTAssertTrue(GoTrueMockURLProtocol.recordedPaths.contains { $0.contains("/auth/v1/signup") })
        clearAuthKeys(keychain)
    }

    // MARK: 2. Stored-session restore

    func test_awaitFirstResolution_restoresStoredSession_noSignupCall() async throws {
        let keychain = makeScopedKeychain()
        let uid = UUID()
        let futureExpiry = Int(Date().timeIntervalSince1970) + 3600
        try keychain.store("stored-access", for: .supabaseAccessToken)
        try keychain.store("stored-refresh", for: .supabaseRefreshToken)
        try keychain.store(String(futureExpiry), for: .supabaseSessionExpiry)
        try keychain.store(uid.uuidString, for: .supabaseAuthUserId)

        GoTrueMockURLProtocol.reset()
        // No stubs registered: any network call would 404. Restore must not call out.

        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )

        let resolved = await auth.awaitFirstResolution()
        XCTAssertEqual(resolved?.accessToken, "stored-access")
        XCTAssertEqual(resolved?.userId, uid)
        XCTAssertTrue(
            GoTrueMockURLProtocol.recordedPaths.isEmpty,
            "Restore must not hit the network; got \(GoTrueMockURLProtocol.recordedPaths)."
        )
        clearAuthKeys(keychain)
    }

    // MARK: 3. Sign-in failure degrades gracefully

    func test_awaitFirstResolution_signInFailure_returnsNil_noHang() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        GoTrueMockURLProtocol.reset()
        GoTrueMockURLProtocol.stubs = [
            // Anonymous provider not enabled → 422 (or any non-2xx).
            ("/auth/v1/signup", .init(statusCode: 422,
                data: Data(#"{"error":"anonymous sign-ins disabled"}"#.utf8)))
        ]

        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession(),
            signInTimeout: 5
        )

        let resolved = await auth.awaitFirstResolution()
        XCTAssertNil(resolved, "Non-2xx sign-in must resolve to nil (anon behavior), not throw or hang.")
        let stored = try keychain.retrieve(.supabaseAccessToken)
        XCTAssertNil(stored, "Failed sign-in must not persist any token.")
        clearAuthKeys(keychain)
    }

    func test_awaitFirstResolution_timesOut_returnsNil() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        GoTrueMockURLProtocol.reset()
        // No stub for signup AND a tiny timeout — but to deterministically force
        // the timeout branch we use a hanging URLProtocol that never completes.
        let hangingSession = makeHangingSession()

        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: hangingSession,
            signInTimeout: 0.2
        )

        let start = Date()
        let resolved = await auth.awaitFirstResolution()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(resolved, "A hung sign-in must time out to nil.")
        XCTAssertLessThan(elapsed, 3.0, "Timeout must bound the wait well under the 5s default.")
        clearAuthKeys(keychain)
    }

    // MARK: 4. Refresh + 401 retry

    func test_validAccessToken_refreshesWhenNearExpiry() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        GoTrueMockURLProtocol.reset()
        // Sign-in returns an already-expired token, refresh returns a fresh one.
        GoTrueMockURLProtocol.stubs = [
            ("/auth/v1/signup", .init(
                statusCode: 200,
                data: tokenJSON(access: "expiring", refresh: "refresh-x",
                                expiresAt: Int(Date().timeIntervalSince1970) - 10)
            )),
            ("/auth/v1/token", .init(
                statusCode: 200,
                data: tokenJSON(access: "refreshed", refresh: "refresh-y",
                                expiresAt: Int(Date().timeIntervalSince1970) + 3600)
            ))
        ]

        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )
        _ = try await auth.signInAnonymously()

        let token = await auth.validAccessToken()
        XCTAssertEqual(token, "refreshed", "Near-expiry token must be refreshed before use.")
        XCTAssertTrue(GoTrueMockURLProtocol.recordedPaths.contains { $0.contains("/auth/v1/token") })
        clearAuthKeys(keychain)
    }

    func test_supabaseClient_401_refreshesOnceAndRetries() async throws {
        // Drive the SupabaseClient refresh/401-retry path directly. The first
        // PostgREST GET returns 401; the forceRefresh hook hands back a new
        // token; the retry succeeds.
        GoTrueMockURLProtocol.reset()
        var rest401Served = false
        // Custom stub logic: the rest endpoint returns 401 the first time, 200 after.
        final class Counting: URLProtocol {
            static var restCallCount = 0
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let path = request.url?.path ?? ""
                let status: Int
                let body: Data
                if path.contains("/rest/v1/") {
                    Counting.restCallCount += 1
                    if Counting.restCallCount == 1 {
                        status = 401; body = Data(#"{"message":"JWT expired"}"#.utf8)
                    } else {
                        status = 200; body = Data("[]".utf8)
                    }
                } else {
                    status = 404; body = Data()
                }
                let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        Counting.restCallCount = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Counting.self]
        let restSession = URLSession(configuration: config)

        let client = SupabaseClient(supabaseURL: testURL, anonKey: "anon", urlSession: restSession)
        await client.setAuthToken("stale-token")
        let counter = ForceRefreshCounter()
        await client.setRefreshHooks(
            refreshIfNeeded: { nil }, // not near expiry from the client's POV
            forceRefresh: {
                await counter.increment()
                return "new-token"
            }
        )

        struct Row: Decodable {}
        let rows: [Row] = try await client.fetch(Row.self, table: "workout_sessions")
        XCTAssertEqual(rows.count, 0, "Retry must succeed and decode the empty array.")
        let calls = await counter.count
        XCTAssertEqual(calls, 1, "401 must trigger exactly one forced refresh.")
        XCTAssertEqual(Counting.restCallCount, 2, "Request must be retried exactly once after 401.")
        _ = rest401Served
    }

    // MARK: - Hanging session helper (for timeout test)

    private func makeHangingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Thread-safe counter for the 401-retry force-refresh assertion (lets the
/// @Sendable hook mutate shared state without data-race warnings).
actor ForceRefreshCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A URLProtocol that never completes its load — used to deterministically
/// exercise the sign-in timeout branch.
final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* intentionally never finishes */ }
    override func stopLoading() {}
}

// MARK: - UserIdentityResolver (#369 slice 3: repoint resolvedUserId to auth.uid())

/// Locks the identity-resolution precedence that `AppDependencies.resolvedUserId`
/// and onboarding's user-insert both delegate to. Uses a per-test scoped
/// `KeychainService` so the Keychain state is injected deterministically.
final class UserIdentityResolverTests: XCTestCase {

    private let placeholder = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func makeScopedKeychain() -> KeychainService {
        KeychainService(serviceName: "com.projectapex.tests.identity.\(UUID().uuidString)")
    }

    private func clearIdentityKeys(_ keychain: KeychainService) {
        try? keychain.delete(.supabaseAuthUserId)
        try? keychain.delete(.userId)
    }

    // MARK: resolve — auth uid is the primary source

    func test_resolve_returnsAuthUid_whenSessionExists() throws {
        let keychain = makeScopedKeychain()
        clearIdentityKeys(keychain)
        let authUid = UUID()
        try keychain.store(authUid.uuidString, for: .supabaseAuthUserId)

        let resolved = UserIdentityResolver.resolve(keychain: keychain, placeholder: placeholder)

        XCTAssertEqual(resolved, authUid,
            "resolvedUserId must be the persisted auth.uid() when a session exists")
        clearIdentityKeys(keychain)
    }

    func test_resolve_authUid_winsOverUserIdMirror() throws {
        let keychain = makeScopedKeychain()
        clearIdentityKeys(keychain)
        let authUid = UUID()
        let mirrored = UUID()
        try keychain.store(authUid.uuidString, for: .supabaseAuthUserId)
        try keychain.store(mirrored.uuidString, for: .userId)

        let resolved = UserIdentityResolver.resolve(keychain: keychain, placeholder: placeholder)

        XCTAssertEqual(resolved, authUid,
            "the auth uid takes precedence over the .userId mirror")
        clearIdentityKeys(keychain)
    }

    // MARK: resolve — first-launch fallback

    func test_resolve_fallsBackToPlaceholder_whenNoSessionAndNoMirror() {
        let keychain = makeScopedKeychain()
        clearIdentityKeys(keychain)

        let resolved = UserIdentityResolver.resolve(keychain: keychain, placeholder: placeholder)

        XCTAssertEqual(resolved, placeholder,
            "with no auth uid and no .userId, the transitional placeholder is the fallback")
        clearIdentityKeys(keychain)
    }

    func test_resolve_fallsBackToUserIdMirror_whenNoAuthUidYet() throws {
        // A pre-slice-1 install (or mid-launch before the session restores) that
        // already minted a .userId keeps reading it rather than the placeholder.
        let keychain = makeScopedKeychain()
        clearIdentityKeys(keychain)
        let mirrored = UUID()
        try keychain.store(mirrored.uuidString, for: .userId)

        let resolved = UserIdentityResolver.resolve(keychain: keychain, placeholder: placeholder)

        XCTAssertEqual(resolved, mirrored,
            "with no auth uid but an existing .userId, the mirror is the fallback (not placeholder)")
        clearIdentityKeys(keychain)
    }

    // MARK: onboardingUserId — never the placeholder

    func test_onboardingUserId_isAuthUid_whenSessionExists() throws {
        let keychain = makeScopedKeychain()
        clearIdentityKeys(keychain)
        let authUid = UUID()
        try keychain.store(authUid.uuidString, for: .supabaseAuthUserId)

        let onboardingId = UserIdentityResolver.onboardingUserId(
            keychain: keychain, placeholder: placeholder
        )

        XCTAssertEqual(onboardingId, authUid,
            "onboarding writes users.id = auth.uid() so slice 5's RLS policy matches")
        clearIdentityKeys(keychain)
    }

    func test_onboardingUserId_isNil_whenNoSessionYet() {
        // The guard that prevents writing a placeholder-keyed users row: with no
        // resolved identity, onboarding must skip the insert (returns nil).
        let keychain = makeScopedKeychain()
        clearIdentityKeys(keychain)

        let onboardingId = UserIdentityResolver.onboardingUserId(
            keychain: keychain, placeholder: placeholder
        )

        XCTAssertNil(onboardingId,
            "no auth session yet → onboarding must NOT write a placeholder-keyed users row")
        clearIdentityKeys(keychain)
    }
}
