// SupabaseClient.swift
// ProjectApex — Services
//
// Actor wrapping Supabase PostgREST HTTP API calls.
// All feature modules use this actor for database reads and writes so that
// URL construction and auth header logic are never duplicated.
//
// Usage:
//   let client = SupabaseClient(supabaseURL: Config.supabaseURL, anonKey: key)
//   try await client.insert(session, table: "workout_sessions")
//   let rows: [WorkoutSession] = try await client.fetch(.self, table: "workout_sessions", filters: [
//       Filter(column: "user_id", op: .eq, value: userId.uuidString)
//   ])
//
// Auth:
//   After Supabase sign-in, set client.authToken = jwt to include the
//   Authorization: Bearer header on all subsequent requests.

import Foundation

// MARK: - Filter

/// A single PostgREST query filter applied as a URL query parameter.
///
/// PostgREST filter format: `column=op.value`
/// Example: `user_id=eq.550e8400-e29b-41d4-a716-446655440000`
struct Filter: Sendable {
    let column: String
    let op: FilterOperator
    let value: String

    enum FilterOperator: String, Sendable {
        case eq  = "eq"
        case neq = "neq"
        case gt  = "gt"
        case gte = "gte"
        case lt  = "lt"
        case lte = "lte"
        case like = "like"
        case ilike = "ilike"
        case `is` = "is"
        case `in` = "in"
    }
}

// MARK: - SupabaseError

/// Errors thrown by SupabaseClient operations.
enum SupabaseError: LocalizedError, Equatable {
    /// The server returned a non-2xx HTTP status.
    case httpError(statusCode: Int, body: String)
    /// The response data could not be decoded into the expected type.
    case decodingError(String)
    /// A URL could not be constructed from the provided components.
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingError(let detail):
            return "Decoding error: \(detail)"
        case .invalidURL:
            return "Could not construct a valid request URL."
        }
    }

    static func == (lhs: SupabaseError, rhs: SupabaseError) -> Bool {
        switch (lhs, rhs) {
        case (.httpError(let lCode, let lBody), .httpError(let rCode, let rBody)):
            return lCode == rCode && lBody == rBody
        case (.decodingError(let l), .decodingError(let r)):
            return l == r
        case (.invalidURL, .invalidURL):
            return true
        default:
            return false
        }
    }
}

// MARK: - SupabaseClient

/// Actor that wraps Supabase PostgREST HTTP calls.
///
/// All methods are isolated to this actor, making them safe to call from any
/// concurrency context. The `authToken` property can be set after sign-in so
/// that RLS-protected tables are accessible with the user's JWT.
actor SupabaseClient {

    // MARK: - Properties

    private let baseURL: URL
    let anonKey: String

    /// Set this after a successful Supabase Auth sign-in.
    /// When non-nil it is sent as `Authorization: Bearer <token>` on every
    /// request instead of (not in addition to) the anon key.
    var authToken: String?

    // MARK: - Private helpers

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Init

    init(supabaseURL: URL, anonKey: String, urlSession: URLSession = .shared) {
        self.baseURL = supabaseURL
        self.anonKey = anonKey
        self.session = urlSession

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Public API

    /// Inserts `item` into `table`.
    ///
    /// Sends `Prefer: return=representation` so Supabase echoes back the
    /// inserted row (including server-generated fields such as `id` and
    /// `created_at`).
    ///
    /// - Parameters:
    ///   - item: An `Encodable` value whose JSON representation matches the
    ///           table columns.
    ///   - table: The PostgREST table name (e.g. `"workout_sessions"`).
    /// - Throws: `SupabaseError` on HTTP or encoding failure.
    func insert<T: Encodable>(_ item: T, table: String) async throws {
        let url = try tableURL(table: table)
        var request = baseRequest(url: url, method: "POST")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(item)
        try await perform(request)
    }

    /// Inserts `item` into `table` and returns the echoed-back row.
    ///
    /// - Parameters:
    ///   - item: An `Encodable` value.
    ///   - table: The PostgREST table name.
    ///   - returning: The `Decodable` type to decode from the response.
    /// - Returns: An array of the inserted rows (PostgREST always returns an array).
    /// - Throws: `SupabaseError` on HTTP, encoding, or decoding failure.
    func insertReturning<T: Encodable, R: Decodable>(_ item: T, table: String, returning: R.Type) async throws -> [R] {
        let url = try tableURL(table: table)
        var request = baseRequest(url: url, method: "POST")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(item)
        let data = try await performReturningData(request)
        return try decodeArray(R.self, from: data)
    }

    /// Fetches rows from `table`, optionally filtered by `filters`.
    ///
    /// Each `Filter` in `filters` is appended as a URL query parameter using
    /// PostgREST syntax: `column=op.value`.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type each row should be decoded into.
    ///   - table: The PostgREST table name.
    ///   - filters: Zero or more column filters to narrow the result set.
    /// - Returns: An array of decoded rows (empty array if none match).
    /// - Throws: `SupabaseError` on HTTP or decoding failure.
    func fetch<T: Decodable>(_ type: T.Type, table: String, filters: [Filter] = []) async throws -> [T] {
        var components = URLComponents(url: try tableURL(table: table), resolvingAgainstBaseURL: false)
        if !filters.isEmpty {
            components?.queryItems = filters.map { filter in
                URLQueryItem(name: filter.column, value: "\(filter.op.rawValue).\(filter.value)")
            }
        }
        guard let url = components?.url else { throw SupabaseError.invalidURL }
        let request = baseRequest(url: url, method: "GET")
        let data = try await performReturningData(request)
        return try decodeArray(T.self, from: data)
    }

    /// Updates the row in `table` identified by `id` with the fields in `item`.
    ///
    /// Uses `PATCH` semantics — only the keys present in the encoded JSON are
    /// updated; columns absent from the payload are left unchanged.
    ///
    /// - Parameters:
    ///   - item: An `Encodable` value containing the fields to update.
    ///   - table: The PostgREST table name.
    ///   - id: The UUID primary key of the row to update.
    /// - Throws: `SupabaseError` on HTTP or encoding failure.
    func update<T: Encodable>(_ item: T, table: String, id: UUID) async throws {
        var components = URLComponents(url: try tableURL(table: table), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
        guard let url = components?.url else { throw SupabaseError.invalidURL }
        var request = baseRequest(url: url, method: "PATCH")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(item)
        try await perform(request)
    }

    // MARK: - GymProfile helpers

    /// Deactivates all currently active gym profiles for `userId` by patching
    /// `is_active = false` on every row that matches.
    ///
    /// Called immediately before inserting a new active profile so the user
    /// always has at most one `is_active = true` profile at a time.
    ///
    /// - Parameter userId: The authenticated user's UUID.
    /// - Throws: `SupabaseError` on HTTP or encoding failure.
    func deactivateGymProfiles(userId: UUID) async throws {
        struct IsActivePatch: Encodable {
            let isActive: Bool
            enum CodingKeys: String, CodingKey {
                case isActive = "is_active"
            }
        }
        var components = URLComponents(url: try tableURL(table: "gym_profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId.uuidString)")]
        guard let url = components?.url else { throw SupabaseError.invalidURL }
        var request = baseRequest(url: url, method: "PATCH")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(IsActivePatch(isActive: false))
        try await perform(request)
    }

    /// Fetches the most recent `is_active = true` gym profile for `userId`.
    ///
    /// Returns `nil` when no active profile exists (e.g. first-time user).
    ///
    /// - Parameter userId: The authenticated user's UUID.
    /// - Returns: The most recently created active `GymProfileRow`, or `nil`.
    /// - Throws: `SupabaseError` on HTTP or decoding failure.
    func fetchActiveProfile(userId: UUID) async throws -> GymProfileRow? {
        let filters = [
            Filter(column: "user_id", op: .eq,  value: userId.uuidString),
            Filter(column: "is_active", op: .is, value: "true")
        ]
        var components = URLComponents(url: try tableURL(table: "gym_profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = filters.map { URLQueryItem(name: $0.column, value: "\($0.op.rawValue).\($0.value)") }
        // Order by created_at descending; take only the most recent row.
        components?.queryItems?.append(URLQueryItem(name: "order", value: "created_at.desc"))
        components?.queryItems?.append(URLQueryItem(name: "limit", value: "1"))
        guard let url = components?.url else { throw SupabaseError.invalidURL }
        let request = baseRequest(url: url, method: "GET")
        let data = try await performReturningData(request)
        let rows = try decodeArray(GymProfileRow.self, from: data)
        return rows.first
    }

    /// Calls a PostgREST RPC function and decodes the result.
    ///
    /// Sends a `POST` to `/rest/v1/rpc/<function>` with `params` encoded as the
    /// JSON body.
    ///
    /// - Parameters:
    ///   - function: The SQL function name (e.g. `"match_memory_embeddings"`).
    ///   - params: A `Codable` value that encodes to the function's named arguments.
    ///   - returning: The expected `Decodable` return type.
    /// - Returns: The decoded result.
    /// - Throws: `SupabaseError` on HTTP, encoding, or decoding failure.
    func rpc<P: Encodable, R: Decodable>(_ function: String, params: P, returning: R.Type) async throws -> R {
        guard let url = URL(string: "/rest/v1/rpc/\(function)", relativeTo: baseURL)?.absoluteURL else {
            throw SupabaseError.invalidURL
        }
        var request = baseRequest(url: url, method: "POST")
        request.httpBody = try encoder.encode(params)
        let data = try await performReturningData(request)
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw SupabaseError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    /// Returns the base URL for a PostgREST table endpoint.
    private func tableURL(table: String) throws -> URL {
        guard let url = URL(string: "/rest/v1/\(table)", relativeTo: baseURL)?.absoluteURL else {
            throw SupabaseError.invalidURL
        }
        return url
    }

    /// Builds a `URLRequest` with common headers for all PostgREST calls.
    private func baseRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Use the user auth token when available; fall back to the anon key.
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        return request
    }

    /// Performs a request, throwing `SupabaseError` on non-2xx responses.
    /// Discards the response body on success.
    private func perform(_ request: URLRequest) async throws {
        _ = try await performReturningData(request)
    }

    /// Performs a request and returns the response body on success.
    /// Throws `SupabaseError.httpError` on non-2xx responses.
    private func performReturningData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.httpError(statusCode: 0, body: "Non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }
        return data
    }

    /// Decodes a JSON array from `data`, wrapping any Swift decoding error in
    /// `SupabaseError.decodingError`.
    private func decodeArray<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        do {
            return try decoder.decode([T].self, from: data)
        } catch {
            throw SupabaseError.decodingError(error.localizedDescription)
        }
    }
}
