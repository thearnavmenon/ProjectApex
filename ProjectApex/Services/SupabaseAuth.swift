// SupabaseAuth.swift
// ProjectApex — Services
//
// Hand-rolled Supabase Auth (GoTrue) REST client. Mirrors the hand-rolled style
// of `SupabaseClient` rather than pulling in the supabase-swift SPM dependency.
//
// Slice 1 of the auth/RLS workstream (#369). PURELY ADDITIVE: this establishes
// an anonymous GoTrue session and surfaces its access token (JWT) so the
// SupabaseClient can send `Authorization: Bearer <jwt>`. It does NOT repoint the
// app's user id (`AppDependencies.resolvedUserId` is unchanged) and RLS is still
// off, so every read/write works whether or not a session is established.
//
// Degradation contract (critical): if anonymous sign-in fails (e.g. the
// dashboard Anonymous provider is not enabled yet → non-2xx) or times out, we
// log it and proceed with NO session. SupabaseClient then falls back to today's
// anon-key behavior. The readiness gate (`awaitFirstResolution`) must NEVER
// block the app or a test indefinitely.
//
// GoTrue endpoints used (all relative to Config.supabaseURL):
//   POST /auth/v1/signup                              — anonymous sign-up
//   POST /auth/v1/token?grant_type=refresh_token      — refresh
//   POST /auth/v1/token?grant_type=id_token           — Apple sign-in / identity link (#596)
//   POST /auth/v1/logout                              — logout
//
// Security: token values are never logged.

import Foundation
import OSLog

// MARK: - SupabaseSession

/// A resolved GoTrue session. Persisted to the Keychain so a relaunch restores
/// the same anonymous user (a fresh anonymous sign-up would mint a NEW uid and
/// orphan the previous user's data).
struct SupabaseSession: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// Absolute access-token expiry.
    let expiresAt: Date
    /// The GoTrue `user.id`.
    let userId: UUID

    /// True when the access token is within `leeway` of expiry (or already past).
    func isNearExpiry(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

// MARK: - AppleSignInOutcome

/// Result of `signInWithApple` (#596, ADR-0032). Two shapes because the caller
/// must behave differently:
///   - `linkedToCurrentUser`: the Apple identity now anchors the CURRENT uid —
///     `auth.uid()` is unchanged, nothing to re-resolve.
///   - `signedInAsDifferentUser`: the session was swapped to an existing
///     Apple-bound user (returning-user recovery) — the caller must re-resolve
///     `resolvedUserId` and route on an RLS-scoped existence check.
enum AppleSignInOutcome: Equatable, Sendable {
    case linkedToCurrentUser(SupabaseSession)
    case signedInAsDifferentUser(SupabaseSession, previousUserId: UUID?)
}

// MARK: - SupabaseAuthError

enum SupabaseAuthError: LocalizedError {
    case httpError(statusCode: Int)
    case decodingError
    case invalidURL
    case noRefreshToken
    /// A "successful" link response carried a DIFFERENT uid than the session it
    /// was meant to anchor — the uid-parity invariant (#595) was violated. The
    /// mismatched session is never adopted. Carries uids only, never tokens.
    case appleLinkUidMismatch(expected: UUID, received: UUID)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "GoTrue HTTP \(code)"
        case .decodingError:        return "GoTrue response could not be decoded"
        case .invalidURL:           return "Could not construct a GoTrue request URL"
        case .noRefreshToken:       return "No refresh token available"
        case .appleLinkUidMismatch(let expected, let received):
            return "Apple link violated uid parity (expected \(expected), got \(received))"
        }
    }
}

// MARK: - GoTrue wire shapes

/// GoTrue token response shape (signup, refresh). `expires_at` is preferred
/// (absolute epoch seconds); `expires_in` (seconds-from-now) is the fallback.
private struct GoTrueTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int?
    let expiresIn: Int?
    let user: GoTrueUser

    struct GoTrueUser: Decodable {
        let id: UUID
    }

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt    = "expires_at"
        case expiresIn    = "expires_in"
        case user
    }

    func session(now: Date = Date()) -> SupabaseSession {
        let expiry: Date
        if let expiresAt {
            expiry = Date(timeIntervalSince1970: TimeInterval(expiresAt))
        } else if let expiresIn {
            expiry = now.addingTimeInterval(TimeInterval(expiresIn))
        } else {
            // GoTrue access tokens default to a 1-hour lifetime.
            expiry = now.addingTimeInterval(3600)
        }
        return SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiry,
            userId: user.id
        )
    }
}

/// GoTrue HTTPError body shape (`apierrors.go`): `{"code", "error_code", "msg"}`.
/// Only `error_code` is read — it discriminates the returning-user case
/// (`identity_already_exists`) from genuine failures on the link path (#596).
private struct GoTrueErrorBody: Decodable {
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
    }
}

// MARK: - SupabaseAuth

/// Actor that owns the GoTrue session lifecycle: restore-or-sign-in on launch,
/// refresh near expiry, logout. Persists the session in the Keychain.
actor SupabaseAuth {

    // MARK: - Dependencies

    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private let keychain: KeychainService
    /// Hard ceiling on the first-resolution wait so a fresh launch can never
    /// hang the app waiting on a slow/hung sign-in. Sized to allow a few bounded
    /// sign-in attempts (see `signInAnonymouslyWithRetry`) — resolution runs in a
    /// background Task (AppDependencies), so this never blocks the UI; it only
    /// bounds how long onboarding's user-row provisioning waits for a session.
    private let signInTimeout: TimeInterval

    /// Per-attempt inactivity timeout for a single GoTrue call. Kept short so a
    /// stalled connection (e.g. an HTTP/3 / QUIC handshake that hangs on an
    /// otherwise-healthy network) fails fast and the retry can force a fresh
    /// connection that falls back to HTTP/2 over TCP, instead of burning the
    /// whole ceiling on one hung request.
    private let perAttemptTimeout: TimeInterval = 8

    private let decoder: JSONDecoder
    private static let logger = Logger(subsystem: "com.projectapex", category: "SupabaseAuth")

    // MARK: - State

    private(set) var currentSession: SupabaseSession?

    /// The single in-flight first-resolution task (sign-in or restore). All
    /// callers of `awaitFirstResolution` await this one task; it always
    /// completes (success → session; failure/timeout → nil) and never throws.
    private var firstResolution: Task<SupabaseSession?, Never>?

    // MARK: - Init

    init(
        supabaseURL: URL,
        anonKey: String,
        keychain: KeychainService = .shared,
        urlSession: URLSession = .shared,
        signInTimeout: TimeInterval = 30
    ) {
        self.baseURL = supabaseURL
        self.anonKey = anonKey
        self.keychain = keychain
        self.session = urlSession
        self.signInTimeout = signInTimeout

        let dec = JSONDecoder()
        self.decoder = dec
    }

    // MARK: - Launch resolution

    /// Kicks off (once) the first session resolution: restore from Keychain if a
    /// stored session exists, otherwise anonymous sign-in. Returns immediately;
    /// callers await the result via `awaitFirstResolution`. Idempotent.
    func startResolution() {
        guard firstResolution == nil else { return }
        firstResolution = Task { [weak self] in
            guard let self else { return nil }
            return await self.resolveFirstSession()
        }
    }

    /// Awaits the first session resolution, bounded so it can never hang. A
    /// restored session resolves instantly; a fresh launch resolves on sign-in
    /// return or `signInTimeout`, then falls through to `nil` (anon behavior).
    ///
    /// Returns the resolved session, or `nil` when resolution failed/timed out
    /// (the caller should proceed with no auth token = today's anon-key path).
    func awaitFirstResolution() async -> SupabaseSession? {
        startResolution()
        guard let firstResolution else { return nil }
        return await firstResolution.value
    }

    /// Restore-or-sign-in, with a timeout guard on the network path. Never throws.
    private func resolveFirstSession() async -> SupabaseSession? {
        // 1. Restore a stored session instantly (no network) if present.
        if let restored = restoreFromKeychain() {
            print("[SupabaseAuth] restored persisted session — uid: \(restored.userId)")
            currentSession = restored
            return restored
        }
        print("[SupabaseAuth] no stored session — starting fresh anonymous sign-in")

        // 2. Fresh launch → anonymous sign-in, bounded by signInTimeout so a
        //    hung/slow endpoint (or an unreachable network) can't block launch.
        let timeout = signInTimeout
        let result = await withTaskGroup(of: SupabaseSession?.self) { group -> SupabaseSession? in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await self.signInAnonymouslyWithRetry()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            // First task to finish wins; cancel the rest.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if result == nil {
            print("[SupabaseAuth] first-resolution returned NO session after \(timeout)s ceiling — proceeding as anon (placeholder)")
            SupabaseAuth.logger.log("anonymous sign-in timed out after \(timeout, privacy: .public)s; proceeding as anon")
        }
        return result
    }

    /// Anonymous sign-in with bounded retries. The first connection on a fresh
    /// launch can stall on an HTTP/3 / QUIC handshake even when the network is
    /// healthy (the PostgREST path having taught `URLSession.shared` that the
    /// host speaks HTTP/3); each attempt is inactivity-bounded by
    /// `perAttemptTimeout`, and a failed attempt makes URLSession mark HTTP/3
    /// broken for the host, so the retry typically completes over HTTP/2/TCP.
    /// Returns `nil` only after every attempt fails (caller falls back to anon).
    private func signInAnonymouslyWithRetry(maxAttempts: Int = 3) async -> SupabaseSession? {
        for attempt in 1...maxAttempts {
            do {
                let session = try await signInAnonymously()
                print("[SupabaseAuth] anonymous sign-in succeeded on attempt \(attempt)/\(maxAttempts) — uid: \(session.userId)")
                return session
            } catch {
                print("[SupabaseAuth] anonymous sign-in attempt \(attempt)/\(maxAttempts) FAILED: \(error.localizedDescription) — \(error)")
                await SupabaseAuth.log("anonymous sign-in attempt \(attempt)/\(maxAttempts) failed", error)
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s backoff
                }
            }
        }
        print("[SupabaseAuth] anonymous sign-in EXHAUSTED all \(maxAttempts) attempts — no session (app falls back to placeholder; owned writes will RLS-403)")
        return nil
    }

    // MARK: - GoTrue calls

    /// `POST /auth/v1/signup` with an anonymous body. Persists + caches on success.
    func signInAnonymously() async throws -> SupabaseSession {
        // GoTrue treats a signup with no email/password as an anonymous sign-up.
        let body = Data("{}".utf8)
        let response = try await postToken(path: "/auth/v1/signup", query: nil, body: body)
        let newSession = response.session()
        persist(newSession)
        currentSession = newSession
        return newSession
    }

    /// `POST /auth/v1/token?grant_type=refresh_token`. Persists + caches on success.
    @discardableResult
    func refresh() async throws -> SupabaseSession {
        guard let refreshToken = currentSession?.refreshToken
            ?? (try? keychain.retrieve(.supabaseRefreshToken)).flatMap({ $0 }) else {
            throw SupabaseAuthError.noRefreshToken
        }
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let response = try await postToken(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: body
        )
        let newSession = response.session()
        persist(newSession)
        currentSession = newSession
        return newSession
    }

    /// Apple sign-in / identity link via `POST /auth/v1/token?grant_type=id_token`
    /// (#596, umbrella #595, ADR-0032). Called with the Apple `identityToken`
    /// (JWT string) and the RAW nonce (GoTrue hashes it server-side to compare
    /// against the token's `nonce` claim).
    ///
    /// Mechanism (Step-0-verified against the live project, GoTrue v2.192.0):
    /// with a current session, the request carries `Authorization: Bearer` and
    /// `"link_identity": true` — GoTrue then LINKS the Apple identity to the
    /// current (anonymous) user, preserving `user.id` (= `auth.uid()`), so every
    /// RLS policy and the EF `sub`-ownership check keep matching existing rows.
    /// A bare Bearer WITHOUT the flag is ignored by GoTrue and would mint a
    /// separate user — never send one without the other.
    ///
    /// Fork on 422 `identity_already_exists`: the Apple identity already belongs
    /// to an existing user (returning-user recovery, e.g. fresh install). We then
    /// sign in plainly (no Bearer, no link_identity), adopt that user's session,
    /// and persist it — including `.supabaseAuthUserId`, so `UserIdentityResolver`
    /// re-resolves to the recovered uid.
    ///
    /// uid-parity hard failure: a 2xx link response whose uid differs from the
    /// current session's is an invariant violation — the response session is NOT
    /// adopted and `appleLinkUidMismatch` is thrown.
    ///
    /// Degradation contract: any thrown error leaves the current (anon) session
    /// and Keychain untouched — a failed/declined Apple sign-in never bricks the
    /// anon path. Precondition: launch resolution has already run (callers sit
    /// behind `awaitFirstResolution`, like every owned write).
    func signInWithApple(idToken: String, rawNonce: String) async throws -> AppleSignInOutcome {
        // A restored session's access token can be stale (Slice-C link prompts
        // run on launch) — refresh best-effort so the link Bearer is valid. A
        // failed refresh falls through; the server then rejects and we surface.
        if let current = currentSession, current.isNearExpiry() {
            _ = try? await refresh()
        }
        let previous = currentSession

        if let previous {
            // Link path: anchor the Apple identity to the CURRENT uid.
            let linkBody = try JSONSerialization.data(withJSONObject: [
                "provider": "apple",
                "id_token": idToken,
                "nonce": rawNonce,
                "link_identity": true
            ])
            let (status, data) = try await performTokenRequest(
                path: "/auth/v1/token",
                query: [URLQueryItem(name: "grant_type", value: "id_token")],
                body: linkBody,
                bearer: previous.accessToken
            )
            if (200...299).contains(status) {
                guard let response = try? decoder.decode(GoTrueTokenResponse.self, from: data) else {
                    throw SupabaseAuthError.decodingError
                }
                let newSession = response.session()
                guard newSession.userId == previous.userId else {
                    // Invariant violation — do NOT adopt the mismatched session.
                    print("[SupabaseAuth] apple link returned a DIFFERENT uid — rejecting (expected \(previous.userId), got \(newSession.userId))")
                    throw SupabaseAuthError.appleLinkUidMismatch(
                        expected: previous.userId, received: newSession.userId
                    )
                }
                persist(newSession)
                currentSession = newSession
                print("[SupabaseAuth] apple identity linked — uid preserved: \(newSession.userId)")
                return .linkedToCurrentUser(newSession)
            }
            let errorCode = (try? decoder.decode(GoTrueErrorBody.self, from: data))?.errorCode
            guard status == 422, errorCode == "identity_already_exists" else {
                print("[SupabaseAuth] apple link FAILED — HTTP \(status), error_code: \(errorCode ?? "nil")")
                throw SupabaseAuthError.httpError(statusCode: status)
            }
            print("[SupabaseAuth] apple identity already bound — falling back to plain sign-in (returning user)")
        }

        // Plain sign-in: returning user whose Apple identity has an owner, or no
        // current session at all (anon sign-in failed at launch — Apple still
        // recovers the account).
        let signInBody = try JSONSerialization.data(withJSONObject: [
            "provider": "apple",
            "id_token": idToken,
            "nonce": rawNonce
        ])
        let (status, data) = try await performTokenRequest(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: signInBody,
            bearer: nil
        )
        guard (200...299).contains(status) else {
            print("[SupabaseAuth] apple sign-in FAILED — HTTP \(status)")
            throw SupabaseAuthError.httpError(statusCode: status)
        }
        guard let response = try? decoder.decode(GoTrueTokenResponse.self, from: data) else {
            throw SupabaseAuthError.decodingError
        }
        let newSession = response.session()
        persist(newSession)
        currentSession = newSession
        if let previous, newSession.userId == previous.userId {
            // The identity was already linked to THIS user (e.g. a retry after a
            // crash between link and persist) — semantically a link.
            print("[SupabaseAuth] apple sign-in returned the current uid — treating as linked: \(newSession.userId)")
            return .linkedToCurrentUser(newSession)
        }
        print("[SupabaseAuth] apple sign-in swapped session — uid: \(newSession.userId) (was: \(previous?.userId.uuidString ?? "none"))")
        return .signedInAsDifferentUser(newSession, previousUserId: previous?.userId)
    }

    /// `POST /auth/v1/logout`. Clears the persisted + cached session regardless
    /// of the server response (best-effort sign-out).
    func logout() async {
        if let token = currentSession?.accessToken {
            if let url = makeURL(path: "/auth/v1/logout", query: nil) {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                _ = try? await session.data(for: request)
            }
        }
        clearKeychain()
        currentSession = nil
    }

    // MARK: - Token-for-request helpers (used by SupabaseClient refresh hook)

    /// Returns a valid (non-near-expiry) access token, refreshing first if
    /// needed. Returns `nil` when there is no session or refresh fails — the
    /// caller then proceeds with the anon key (no auth token).
    func validAccessToken() async -> String? {
        guard let current = currentSession else { return nil }
        guard current.isNearExpiry() else { return current.accessToken }
        return try? await refresh().accessToken
    }

    /// Forces a refresh and returns the fresh access token, or `nil` on failure.
    /// Used by the 401-retry path.
    func forceRefreshAccessToken() async -> String? {
        try? await refresh().accessToken
    }

    // MARK: - Networking

    private func postToken(path: String, query: [URLQueryItem]?, body: Data) async throws -> GoTrueTokenResponse {
        let (status, data) = try await performTokenRequest(path: path, query: query, body: body, bearer: nil)
        guard (200...299).contains(status) else {
            throw SupabaseAuthError.httpError(statusCode: status)
        }
        do {
            return try decoder.decode(GoTrueTokenResponse.self, from: data)
        } catch {
            throw SupabaseAuthError.decodingError
        }
    }

    /// Performs a GoTrue POST and returns the raw (status, body) so callers that
    /// need to discriminate error bodies (the Apple link path's 422
    /// `identity_already_exists`) can do so. `bearer` attaches an
    /// `Authorization: Bearer` header — required for identity linking.
    private func performTokenRequest(
        path: String, query: [URLQueryItem]?, body: Data, bearer: String?
    ) async throws -> (status: Int, data: Data) {
        guard let url = makeURL(path: path, query: query) else { throw SupabaseAuthError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        // Bound a single attempt so a stalled (e.g. QUIC-hung) connection fails
        // fast and the caller's retry can force a fresh, TCP-fallback connection
        // rather than hanging on URLSession's 60s default.
        request.timeoutInterval = perAttemptTimeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseAuthError.httpError(statusCode: 0)
        }
        return (http.statusCode, data)
    }

    private func makeURL(path: String, query: [URLQueryItem]?) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = query
        return components.url
    }

    // MARK: - Keychain persistence

    private func restoreFromKeychain() -> SupabaseSession? {
        guard
            let access = (try? keychain.retrieve(.supabaseAccessToken)) ?? nil, !access.isEmpty,
            let refresh = (try? keychain.retrieve(.supabaseRefreshToken)) ?? nil, !refresh.isEmpty,
            let expiryString = (try? keychain.retrieve(.supabaseSessionExpiry)) ?? nil,
            let expirySeconds = TimeInterval(expiryString),
            let userIdString = (try? keychain.retrieve(.supabaseAuthUserId)) ?? nil,
            let userId = UUID(uuidString: userIdString)
        else { return nil }
        return SupabaseSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date(timeIntervalSince1970: expirySeconds),
            userId: userId
        )
    }

    private func persist(_ s: SupabaseSession) {
        try? keychain.store(s.accessToken, for: .supabaseAccessToken)
        try? keychain.store(s.refreshToken, for: .supabaseRefreshToken)
        try? keychain.store(String(Int(s.expiresAt.timeIntervalSince1970)), for: .supabaseSessionExpiry)
        try? keychain.store(s.userId.uuidString, for: .supabaseAuthUserId)
    }

    private func clearKeychain() {
        try? keychain.delete(.supabaseAccessToken)
        try? keychain.delete(.supabaseRefreshToken)
        try? keychain.delete(.supabaseSessionExpiry)
        try? keychain.delete(.supabaseAuthUserId)
    }

    // MARK: - Logging (never logs token values)

    private static func log(_ message: String, _ error: Error) {
        logger.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}
