// SupabaseAuthAppleLinkTests.swift
// ProjectApexTests — #596 (SiWA Slice A, umbrella #595)
//
// Unit tests for `SupabaseAuth.signInWithApple(idToken:rawNonce:)` — the
// hand-rolled GoTrue Apple id_token grant with anonymous-identity LINKING.
//
// The mechanism under test (Step-0-verified against the live project, GoTrue
// v2.192.0): `POST /auth/v1/token?grant_type=id_token` with the current anon
// user's `Authorization: Bearer` AND `"link_identity": true` in the body links
// the Apple identity to the anonymous user, PRESERVING `user.id` (auth.uid()).
// A bare Bearer without the flag would be ignored by GoTrue and mint a separate
// user — the uid-changing trap these tests exist to catch.
//
// Coverage:
//   1. Link success → uid preserved, permanent session persisted to Keychain,
//      request carried Bearer + link_identity:true + raw nonce.
//   2. Link 2xx with a DIFFERENT uid → hard failure (invariant violation);
//      the anon session must survive untouched.
//   3. Link 422 identity_already_exists → plain sign-in fallback (no Bearer,
//      no link_identity) → session swap to the existing Apple-bound uid,
//      `.supabaseAuthUserId` repointed so UserIdentityResolver re-resolves.
//   4. Failed exchange (5xx) → throws, anon session + Keychain untouched
//      (degradation contract: a failed Apple sign-in never bricks the anon path).
//   5. No current session → plain sign-in (no Bearer), session persisted.
//   6. Fallback sign-in returning the SAME uid (identity already linked to this
//      user, e.g. crash-before-persist retry) → treated as linked.
//   7. (gated, APEX_INTEGRATION_TESTS=1) live-project probe: the id_token grant
//      rejects a fake token and the live anon session survives. Full uid-parity
//      needs a real Apple id_token — OWNER-BLOCKED on Apple provider config
//      (see #595), then verified on-device.
//
// Security: no assertion in this file ever logs a token value.

import XCTest
@testable import ProjectApex

// MARK: - Request-inspecting URLProtocol mock

/// Handler-based mock that captures the FULL request — URL (with query),
/// Authorization header, and body — so tests can assert the linking mechanism
/// (Bearer + link_identity + nonce) rather than just the path.
///
/// URLSession reifies `httpBody` → `httpBodyStream` for transport, so the body
/// must be drained back out of the stream (the MockURLProtocol / issue #23
/// pattern — same fix as WAQMockURLProtocol).
private final class AppleGrantMockURLProtocol: URLProtocol, @unchecked Sendable {

    struct Captured {
        let url: URL
        let authorization: String?
        let bodyJSON: [String: Any]
    }

    /// Routes a captured request to (status, responseData).
    nonisolated(unsafe) static var handler: ((Captured) -> (Int, Data))?
    nonisolated(unsafe) static var captured: [Captured] = []

    static func reset() {
        handler = nil
        captured = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.drainBody(request)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let cap = Captured(
            url: request.url!,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyJSON: json
        )
        AppleGrantMockURLProtocol.captured.append(cap)

        let (status, data) = AppleGrantMockURLProtocol.handler?(cap) ?? (404, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Drain `httpBodyStream` back into Data (issue #23: `request.httpBody` is
    /// always nil at the URLProtocol layer).
    private static func drainBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Helpers

private let testURL = URL(string: "https://test.supabase.co")!

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AppleGrantMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeScopedKeychain() -> KeychainService {
    KeychainService(serviceName: "com.projectapex.tests.applelink.\(UUID().uuidString)")
}

private func clearAuthKeys(_ keychain: KeychainService) {
    try? keychain.delete(.supabaseAccessToken)
    try? keychain.delete(.supabaseRefreshToken)
    try? keychain.delete(.supabaseSessionExpiry)
    try? keychain.delete(.supabaseAuthUserId)
}

/// Seeds a restorable (non-expired) anon session into the scoped Keychain.
private func seedAnonSession(_ keychain: KeychainService, uid: UUID) throws {
    try keychain.store("anon-access", for: .supabaseAccessToken)
    try keychain.store("anon-refresh", for: .supabaseRefreshToken)
    try keychain.store(String(Int(Date().timeIntervalSince1970) + 3600), for: .supabaseSessionExpiry)
    try keychain.store(uid.uuidString, for: .supabaseAuthUserId)
}

/// GoTrue token-response JSON with an absolute `expires_at`.
private func tokenJSON(access: String, refresh: String, userId: UUID) -> Data {
    let dict: [String: Any] = [
        "access_token": access,
        "refresh_token": refresh,
        "expires_at": Int(Date().timeIntervalSince1970) + 3600,
        "user": ["id": userId.uuidString]
    ]
    return try! JSONSerialization.data(withJSONObject: dict)
}

/// GoTrue HTTPError-shape body (`apierrors.go`): {"code", "error_code", "msg"}.
private func goTrueErrorJSON(code: Int, errorCode: String, msg: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "code": code, "error_code": errorCode, "msg": msg
    ])
}

/// True when the captured request is the id_token grant.
private func isIdTokenGrant(_ cap: AppleGrantMockURLProtocol.Captured) -> Bool {
    cap.url.path.contains("/auth/v1/token")
        && (cap.url.query ?? "").contains("grant_type=id_token")
}

// MARK: - SupabaseAuthAppleLinkTests

final class SupabaseAuthAppleLinkTests: XCTestCase {

    override func tearDown() {
        AppleGrantMockURLProtocol.reset()
        super.tearDown()
    }

    private func makeAuthWithAnonSession(
        keychain: KeychainService, uid: UUID
    ) async throws -> SupabaseAuth {
        try seedAnonSession(keychain, uid: uid)
        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )
        // Restores the seeded session instantly (no network).
        let restored = await auth.awaitFirstResolution()
        XCTAssertEqual(restored?.userId, uid, "precondition: anon session restored")
        return auth
    }

    // MARK: 1. Link success — uid preserved

    func test_signInWithApple_link_preservesUid_persistsPermanentSession() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let anonUid = UUID()
        let auth = try await makeAuthWithAnonSession(keychain: keychain, uid: anonUid)

        AppleGrantMockURLProtocol.handler = { cap in
            guard isIdTokenGrant(cap) else { return (404, Data()) }
            return (200, tokenJSON(access: "apple-access", refresh: "apple-refresh", userId: anonUid))
        }

        let outcome = try await auth.signInWithApple(idToken: "apple.id.token", rawNonce: "raw-nonce-1")

        // The decisive invariant: same uid.
        guard case .linkedToCurrentUser(let session) = outcome else {
            return XCTFail("expected .linkedToCurrentUser, got \(outcome)")
        }
        XCTAssertEqual(session.userId, anonUid, "link must preserve auth.uid()")

        // The permanent session replaced the anon one, in memory and Keychain.
        let current = await auth.currentSession
        XCTAssertEqual(current?.accessToken, "apple-access")
        XCTAssertEqual(try keychain.retrieve(.supabaseAccessToken), "apple-access")
        XCTAssertEqual(try keychain.retrieve(.supabaseRefreshToken), "apple-refresh")
        XCTAssertEqual(try keychain.retrieve(.supabaseAuthUserId), anonUid.uuidString)

        // The request carried the verified linking mechanism.
        let grant = AppleGrantMockURLProtocol.captured.first(where: isIdTokenGrant)
        XCTAssertNotNil(grant, "an id_token grant must have been sent")
        XCTAssertEqual(grant?.authorization, "Bearer anon-access",
            "link must authenticate as the CURRENT anon user")
        XCTAssertEqual(grant?.bodyJSON["link_identity"] as? Bool, true,
            "link_identity:true is the mechanism that makes GoTrue link instead of minting a new user")
        XCTAssertEqual(grant?.bodyJSON["provider"] as? String, "apple")
        XCTAssertEqual(grant?.bodyJSON["id_token"] as? String, "apple.id.token")
        XCTAssertEqual(grant?.bodyJSON["nonce"] as? String, "raw-nonce-1",
            "the RAW nonce is sent; GoTrue hashes it server-side")
        clearAuthKeys(keychain)
    }

    // MARK: 2. Link 2xx with a different uid — hard failure

    func test_signInWithApple_linkReturnsDifferentUid_throws_keepsAnonSession() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let anonUid = UUID()
        let otherUid = UUID()
        let auth = try await makeAuthWithAnonSession(keychain: keychain, uid: anonUid)

        AppleGrantMockURLProtocol.handler = { cap in
            guard isIdTokenGrant(cap) else { return (404, Data()) }
            // A "successful" link that violates the uid-parity invariant.
            return (200, tokenJSON(access: "wrong-access", refresh: "wrong-refresh", userId: otherUid))
        }

        do {
            _ = try await auth.signInWithApple(idToken: "apple.id.token", rawNonce: "n")
            XCTFail("a link response with a different uid must be a hard failure")
        } catch {
            // Expected. The mismatched session must NOT have been adopted.
        }

        let current = await auth.currentSession
        XCTAssertEqual(current?.userId, anonUid, "anon session must survive the invariant violation")
        XCTAssertEqual(current?.accessToken, "anon-access")
        XCTAssertEqual(try keychain.retrieve(.supabaseAccessToken), "anon-access",
            "Keychain must not adopt the mismatched session")
        XCTAssertEqual(try keychain.retrieve(.supabaseAuthUserId), anonUid.uuidString)
        clearAuthKeys(keychain)
    }

    // MARK: 3. identity_already_exists — returning-user session swap

    func test_signInWithApple_identityAlreadyExists_swapsToExistingUser_repointsIdentity() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let anonUid = UUID()
        let existingUid = UUID()
        let auth = try await makeAuthWithAnonSession(keychain: keychain, uid: anonUid)

        AppleGrantMockURLProtocol.handler = { cap in
            guard isIdTokenGrant(cap) else { return (404, Data()) }
            if cap.bodyJSON["link_identity"] as? Bool == true {
                // The Apple identity already belongs to another user.
                return (422, goTrueErrorJSON(
                    code: 422, errorCode: "identity_already_exists",
                    msg: "Identity is already linked to another user"))
            }
            // Plain sign-in adopts the existing Apple-bound user.
            return (200, tokenJSON(access: "existing-access", refresh: "existing-refresh", userId: existingUid))
        }

        let outcome = try await auth.signInWithApple(idToken: "apple.id.token", rawNonce: "n")

        guard case .signedInAsDifferentUser(let session, let previousUserId) = outcome else {
            return XCTFail("expected .signedInAsDifferentUser, got \(outcome)")
        }
        XCTAssertEqual(session.userId, existingUid, "returning user recovers the Apple-bound uid")
        XCTAssertEqual(previousUserId, anonUid, "caller needs the abandoned uid to re-resolve")

        // Session swapped in memory + Keychain; identity repointed so
        // UserIdentityResolver now resolves the recovered uid.
        let current = await auth.currentSession
        XCTAssertEqual(current?.userId, existingUid)
        XCTAssertEqual(try keychain.retrieve(.supabaseAuthUserId), existingUid.uuidString)
        XCTAssertEqual(
            UserIdentityResolver.resolve(keychain: keychain, placeholder: UUID()),
            existingUid,
            "resolvedUserId must re-resolve to the recovered uid after the swap"
        )

        // The fallback request must be a PLAIN sign-in: no Bearer, no link_identity.
        let grants = AppleGrantMockURLProtocol.captured.filter(isIdTokenGrant)
        XCTAssertEqual(grants.count, 2, "link attempt then plain sign-in fallback")
        XCTAssertNil(grants.last?.bodyJSON["link_identity"],
            "the fallback must not ask to link (the identity already has an owner)")
        XCTAssertNil(grants.last?.authorization,
            "the fallback signs in fresh — no anon Bearer")
        clearAuthKeys(keychain)
    }

    // MARK: 4. Failed exchange — degradation contract

    func test_signInWithApple_serverError_throws_anonPathIntact_noTokenInError() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let anonUid = UUID()
        let auth = try await makeAuthWithAnonSession(keychain: keychain, uid: anonUid)

        AppleGrantMockURLProtocol.handler = { _ in (500, Data(#"{"msg":"boom"}"#.utf8)) }

        do {
            _ = try await auth.signInWithApple(idToken: "secret.apple.token", rawNonce: "n")
            XCTFail("a failed exchange must throw")
        } catch {
            // Tokens never logged / surfaced: the error must not carry the id_token.
            let description = "\(error) \(error.localizedDescription)"
            XCTAssertFalse(description.contains("secret.apple.token"),
                "error surfaces must never contain token values")
        }

        // Anon path fully intact — nothing was mutated.
        let current = await auth.currentSession
        XCTAssertEqual(current?.userId, anonUid)
        XCTAssertEqual(current?.accessToken, "anon-access")
        XCTAssertEqual(try keychain.retrieve(.supabaseAccessToken), "anon-access")
        XCTAssertEqual(try keychain.retrieve(.supabaseAuthUserId), anonUid.uuidString)
        clearAuthKeys(keychain)
    }

    // MARK: 5. No current session — plain sign-in

    func test_signInWithApple_noSession_plainSignIn_persistsSession() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let appleUid = UUID()

        // No seeded session and no resolution run: fresh install whose anon
        // sign-in failed. Apple sign-in must still work (recovery path).
        let auth = SupabaseAuth(
            supabaseURL: testURL, anonKey: "anon",
            keychain: keychain, urlSession: makeMockSession()
        )

        AppleGrantMockURLProtocol.handler = { cap in
            guard isIdTokenGrant(cap) else { return (404, Data()) }
            return (200, tokenJSON(access: "apple-access", refresh: "apple-refresh", userId: appleUid))
        }

        let outcome = try await auth.signInWithApple(idToken: "apple.id.token", rawNonce: "n")

        guard case .signedInAsDifferentUser(let session, let previousUserId) = outcome else {
            return XCTFail("expected .signedInAsDifferentUser, got \(outcome)")
        }
        XCTAssertEqual(session.userId, appleUid)
        XCTAssertNil(previousUserId, "there was no prior identity to abandon")
        XCTAssertEqual(try keychain.retrieve(.supabaseAuthUserId), appleUid.uuidString)

        let grant = AppleGrantMockURLProtocol.captured.first(where: isIdTokenGrant)
        XCTAssertNil(grant?.authorization, "no session → plain sign-in, no Bearer")
        XCTAssertNil(grant?.bodyJSON["link_identity"], "no session → nothing to link to")
        clearAuthKeys(keychain)
    }

    // MARK: 6. Fallback returns the SAME uid — treated as linked

    func test_signInWithApple_fallbackReturnsSameUid_treatedAsLinked() async throws {
        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let anonUid = UUID()
        let auth = try await makeAuthWithAnonSession(keychain: keychain, uid: anonUid)

        AppleGrantMockURLProtocol.handler = { cap in
            guard isIdTokenGrant(cap) else { return (404, Data()) }
            if cap.bodyJSON["link_identity"] as? Bool == true {
                // Identity already linked — to THIS user (crash-before-persist retry).
                return (422, goTrueErrorJSON(
                    code: 422, errorCode: "identity_already_exists",
                    msg: "Identity is already linked"))
            }
            return (200, tokenJSON(access: "re-access", refresh: "re-refresh", userId: anonUid))
        }

        let outcome = try await auth.signInWithApple(idToken: "apple.id.token", rawNonce: "n")

        guard case .linkedToCurrentUser(let session) = outcome else {
            return XCTFail("same uid back means the identity is ours — that's a link, got \(outcome)")
        }
        XCTAssertEqual(session.userId, anonUid)
        XCTAssertEqual(try keychain.retrieve(.supabaseAuthUserId), anonUid.uuidString)
        clearAuthKeys(keychain)
    }

    // MARK: 7. Live-project probe (gated)

    /// Live probe against the real Supabase project: mints a real anonymous
    /// session, then attempts the Apple link with a syntactically-valid but
    /// unverifiable id_token. Until the owner enables the Apple provider this
    /// fails at `provider_disabled`; after enablement it fails at signature
    /// verification — EITHER WAY it must throw and the live anon session must
    /// survive (degradation contract, live).
    ///
    /// Full uid-parity verification needs a REAL Apple id_token (interactive
    /// sheet) — OWNER-BLOCKED on #595's prerequisites, then verified on-device.
    func test_liveProject_appleGrantRejected_anonSessionSurvives() async throws {
        guard ProcessInfo.processInfo.environment["APEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Live test skipped. Set APEX_INTEGRATION_TESTS=1 to run.")
        }
        guard let anonKey = BundledAPIKey.supabaseAnon()
            ?? ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] else {
            throw XCTSkip("No Supabase anon key resolvable in this environment.")
        }

        let keychain = makeScopedKeychain()
        clearAuthKeys(keychain)
        let auth = SupabaseAuth(
            supabaseURL: Config.supabaseURL, anonKey: anonKey, keychain: keychain
        )
        let session = try await auth.signInAnonymously()
        let anonUid = session.userId

        // Well-formed JWT with the Apple issuer but a garbage signature.
        let header = #"{"alg":"RS256","kid":"probe","typ":"JWT"}"#
        let payload = #"{"iss":"https://appleid.apple.com","aud":"probe","sub":"probe","exp":9999999999,"nonce":"deadbeef"}"#
        func b64u(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let fakeToken = "\(b64u(header)).\(b64u(payload)).ZmFrZQ"

        do {
            _ = try await auth.signInWithApple(idToken: fakeToken, rawNonce: "probe-nonce")
            XCTFail("an unverifiable id_token must be rejected by the live project")
        } catch {
            // Expected: provider_disabled (pre-config) or Bad ID token (post-config).
        }

        let current = await auth.currentSession
        XCTAssertEqual(current?.userId, anonUid, "live anon session must survive a failed Apple exchange")
        await auth.logout()
        clearAuthKeys(keychain)
    }
}
