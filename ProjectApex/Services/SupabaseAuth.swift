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

// MARK: - SupabaseAuthError

enum SupabaseAuthError: LocalizedError {
    case httpError(statusCode: Int)
    case decodingError
    case invalidURL
    case noRefreshToken

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "GoTrue HTTP \(code)"
        case .decodingError:        return "GoTrue response could not be decoded"
        case .invalidURL:           return "Could not construct a GoTrue request URL"
        case .noRefreshToken:       return "No refresh token available"
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
            currentSession = restored
            return restored
        }

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
                return try await signInAnonymously()
            } catch {
                await SupabaseAuth.log("anonymous sign-in attempt \(attempt)/\(maxAttempts) failed", error)
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s backoff
                }
            }
        }
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
        guard let url = makeURL(path: path, query: query) else { throw SupabaseAuthError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = body
        // Bound a single attempt so a stalled (e.g. QUIC-hung) connection fails
        // fast and the caller's retry can force a fresh, TCP-fallback connection
        // rather than hanging on URLSession's 60s default.
        request.timeoutInterval = perAttemptTimeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseAuthError.httpError(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SupabaseAuthError.httpError(statusCode: http.statusCode)
        }
        do {
            return try decoder.decode(GoTrueTokenResponse.self, from: data)
        } catch {
            throw SupabaseAuthError.decodingError
        }
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
