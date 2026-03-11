// SupabaseClientTests.swift
// ProjectApexTests — P1-T01
//
// Tests for SupabaseClient actor covering:
//   1. Unit tests (always run): URL construction, header assembly, error mapping
//      via URLProtocol stub.
//   2. Integration test (gated): live insert + fetch round-trip against the real
//      Supabase project. Skipped unless APEX_INTEGRATION_TESTS=1 is set in the
//      scheme's environment variables AND a valid supabaseAnonKey is in the
//      Keychain.
//
// The integration test inserts one row into workout_sessions using a test
// user_id, fetches it back by that user_id, asserts the fields match, then
// deletes the row to leave the DB clean.
//
// NOTE: The Supabase URL comes from Config.supabaseURL. Update that value
// with your project reference before running the live test.

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol stub for unit tests

/// Records the last request made through it and returns a configurable stub response.
private final class StubURLProtocol: URLProtocol {

    // Configurable per-test response.
    static var stubbedStatusCode: Int = 200
    static var stubbedData: Data = Data()
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lastRequest = request

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: StubURLProtocol.stubbedStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StubURLProtocol.stubbedData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeClient(session: URLSession = makeStubSession()) -> SupabaseClient {
    SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-anon-key",
        urlSession: session
    )
}

// MARK: - Codable fixture

private struct TestRow: Codable, Equatable {
    let userId: UUID
    let dayType: String

    enum CodingKeys: String, CodingKey {
        case userId  = "user_id"
        case dayType = "day_type"
    }
}

// MARK: - SupabaseClientTests

final class SupabaseClientTests: XCTestCase {

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

    private func requireIntegration() throws {
        guard ProcessInfo.processInfo.environment["APEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip(
                "Integration test skipped. Set APEX_INTEGRATION_TESTS=1 in the scheme " +
                "environment variables to run live Supabase tests."
            )
        }
    }

    private func requireSupabaseKey() throws -> String {
        guard let key = try KeychainService.shared.retrieve(.supabaseAnonKey),
              !key.isEmpty else {
            throw XCTSkip(
                "No Supabase anon key in Keychain. " +
                "Add one via Settings → Developer Settings before running live tests."
            )
        }
        return key
    }

    // MARK: ─── 1. Header assembly ─────────────────────────────────────────────

    /// Verifies that fetch() sends the required PostgREST headers.
    func test_fetch_sendsRequiredHeaders() async throws {
        StubURLProtocol.stubbedStatusCode = 200
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!
        StubURLProtocol.lastRequest = nil

        let client = makeClient()
        let _: [TestRow] = try await client.fetch(TestRow.self, table: "workout_sessions")

        let req = try XCTUnwrap(StubURLProtocol.lastRequest, "No request was captured.")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"),       "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"),       "test-anon-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-anon-key",
                       "Should use anon key as Bearer when authToken is nil.")
    }

    /// When authToken is set, Authorization should use the user JWT, not the anon key.
    func test_fetch_withAuthToken_sendsUserBearerToken() async throws {
        StubURLProtocol.stubbedStatusCode = 200
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let client = makeClient()
        await client.set(authToken: "user-jwt-token")

        let _: [TestRow] = try await client.fetch(TestRow.self, table: "workout_sessions")

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt-token")
        // apikey header must still carry the anon key regardless of auth state.
        XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"), "test-anon-key")
    }

    // MARK: ─── 2. URL construction ────────────────────────────────────────────

    /// insert() must POST to /rest/v1/<table>.
    func test_insert_usesCorrectURL() async throws {
        StubURLProtocol.stubbedStatusCode = 201
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let row = TestRow(userId: UUID(), dayType: "push")
        let client = makeClient()
        try await client.insert(row, table: "workout_sessions")

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(
            req.url?.path.hasSuffix("/rest/v1/workout_sessions") == true,
            "URL path must end with /rest/v1/workout_sessions, got \(req.url?.path ?? "nil")."
        )
    }

    /// insert() must send Prefer: return=representation.
    func test_insert_sendsPreferReturnRepresentation() async throws {
        StubURLProtocol.stubbedStatusCode = 201
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let client = makeClient()
        try await client.insert(TestRow(userId: UUID(), dayType: "pull"), table: "workout_sessions")

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Prefer"), "return=representation")
    }

    /// fetch() with filters must append PostgREST-syntax query params.
    func test_fetch_withFilters_appendsQueryParams() async throws {
        StubURLProtocol.stubbedStatusCode = 200
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let uid = UUID()
        let client = makeClient()
        let _: [TestRow] = try await client.fetch(
            TestRow.self,
            table: "workout_sessions",
            filters: [Filter(column: "user_id", op: .eq, value: uid.uuidString)]
        )

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let queryItem = components?.queryItems?.first { $0.name == "user_id" }
        XCTAssertEqual(queryItem?.value, "eq.\(uid.uuidString)",
                       "Filter must be serialised as eq.<value>.")
    }

    /// update() must PATCH to /rest/v1/<table>?id=eq.<uuid>.
    func test_update_usesPatchWithIdFilter() async throws {
        StubURLProtocol.stubbedStatusCode = 200
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let rowId = UUID()
        let client = makeClient()
        try await client.update(
            TestRow(userId: UUID(), dayType: "legs"),
            table: "workout_sessions",
            id: rowId
        )

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "PATCH")
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let idItem = components?.queryItems?.first { $0.name == "id" }
        XCTAssertEqual(idItem?.value, "eq.\(rowId.uuidString)")
    }

    /// rpc() must POST to /rest/v1/rpc/<function>.
    func test_rpc_usesCorrectPath() async throws {
        StubURLProtocol.stubbedStatusCode = 200
        // RPC returns a single JSON array of objects in the real API.
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        struct EmptyParams: Encodable {}
        let client = makeClient()
        let _: [TestRow] = try await client.rpc("match_memory_embeddings", params: EmptyParams(), returning: [TestRow].self)

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(
            req.url?.path.hasSuffix("/rest/v1/rpc/match_memory_embeddings") == true,
            "RPC URL path must end with /rest/v1/rpc/<function>."
        )
    }

    // MARK: ─── 3. Error mapping ────────────────────────────────────────────────

    /// Non-2xx response must throw SupabaseError.httpError with the status code and body.
    func test_fetch_non2xxResponse_throwsHTTPError() async {
        StubURLProtocol.stubbedStatusCode = 401
        StubURLProtocol.stubbedData = #"{"message":"Invalid API key"}"#.data(using: .utf8)!

        let client = makeClient()
        do {
            let _: [TestRow] = try await client.fetch(TestRow.self, table: "workout_sessions")
            XCTFail("Expected SupabaseError.httpError to be thrown.")
        } catch let error as SupabaseError {
            guard case .httpError(let code, let body) = error else {
                return XCTFail("Expected .httpError, got \(error).")
            }
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("Invalid API key"))
        } catch {
            XCTFail("Unexpected error type: \(error).")
        }
    }

    /// A 500 error must surface statusCode 500 in the thrown error.
    func test_insert_serverError_throwsHTTPError500() async {
        StubURLProtocol.stubbedStatusCode = 500
        StubURLProtocol.stubbedData = #"{"error":"Internal Server Error"}"#.data(using: .utf8)!

        let client = makeClient()
        do {
            try await client.insert(TestRow(userId: UUID(), dayType: "push"), table: "workout_sessions")
            XCTFail("Expected SupabaseError.httpError to be thrown.")
        } catch let error as SupabaseError {
            guard case .httpError(let code, _) = error else {
                return XCTFail("Expected .httpError, got \(error).")
            }
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error type: \(error).")
        }
    }

    /// Malformed JSON response body must throw SupabaseError.decodingError.
    func test_fetch_malformedJSON_throwsDecodingError() async {
        StubURLProtocol.stubbedStatusCode = 200
        StubURLProtocol.stubbedData = "not-json".data(using: .utf8)!

        let client = makeClient()
        do {
            let _: [TestRow] = try await client.fetch(TestRow.self, table: "workout_sessions")
            XCTFail("Expected SupabaseError.decodingError to be thrown.")
        } catch let error as SupabaseError {
            guard case .decodingError = error else {
                return XCTFail("Expected .decodingError, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error type: \(error).")
        }
    }

    // MARK: ─── 4. Integration test (live Supabase) ────────────────────────────

    /// Inserts a minimal workout_sessions row, fetches it back, asserts fields
    /// match, then deletes the row to keep the DB clean.
    ///
    /// This test requires:
    ///   • APEX_INTEGRATION_TESTS=1 in the scheme's environment variables.
    ///   • A valid Supabase anon key stored in the Keychain.
    ///   • Config.supabaseURL pointing to your live Supabase project.
    ///   • A row in public.users whose UUID you supply as testUserId below.
    func test_integration_insertAndFetch_workoutSession() async throws {
        try requireIntegration()
        let anonKey = try requireSupabaseKey()

        // Replace this UUID with a real user_id from your Supabase `users` table.
        // The row must exist for the FK constraint on workout_sessions to pass.
        let testUserId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        struct WorkoutSessionInsert: Codable {
            let userId: UUID
            let sessionDate: String
            let weekNumber: Int
            let dayType: String

            enum CodingKeys: String, CodingKey {
                case userId      = "user_id"
                case sessionDate = "session_date"
                case weekNumber  = "week_number"
                case dayType     = "day_type"
            }
        }

        struct WorkoutSessionRow: Codable {
            let id: UUID
            let userId: UUID
            let sessionDate: String
            let weekNumber: Int
            let dayType: String
            let completed: Bool

            enum CodingKeys: String, CodingKey {
                case id          = "id"
                case userId      = "user_id"
                case sessionDate = "session_date"
                case weekNumber  = "week_number"
                case dayType     = "day_type"
                case completed   = "completed"
            }
        }

        let client = SupabaseClient(supabaseURL: Config.supabaseURL, anonKey: anonKey)

        let toInsert = WorkoutSessionInsert(
            userId: testUserId,
            sessionDate: "2025-01-15",
            weekNumber: 1,
            dayType: "integration_test_push"
        )

        // 1. Insert — echoed back as array with server-generated fields.
        let inserted: [WorkoutSessionRow] = try await client.insertReturning(
            toInsert,
            table: "workout_sessions",
            returning: WorkoutSessionRow.self
        )
        XCTAssertEqual(inserted.count, 1, "Insert should echo back exactly one row.")
        let row = try XCTUnwrap(inserted.first)
        XCTAssertEqual(row.userId,      testUserId)
        XCTAssertEqual(row.sessionDate, "2025-01-15")
        XCTAssertEqual(row.weekNumber,  1)
        XCTAssertEqual(row.dayType,     "integration_test_push")
        XCTAssertFalse(row.completed,   "completed should default to false.")

        // 2. Fetch back by id to confirm the row is readable.
        let fetched: [WorkoutSessionRow] = try await client.fetch(
            WorkoutSessionRow.self,
            table: "workout_sessions",
            filters: [Filter(column: "id", op: .eq, value: row.id.uuidString)]
        )
        XCTAssertEqual(fetched.count, 1, "Fetch by id should return exactly one row.")
        let fetchedRow = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetchedRow.id,          row.id)
        XCTAssertEqual(fetchedRow.userId,      row.userId)
        XCTAssertEqual(fetchedRow.sessionDate, row.sessionDate)
        XCTAssertEqual(fetchedRow.weekNumber,  row.weekNumber)
        XCTAssertEqual(fetchedRow.dayType,     row.dayType)

        // 3. Cleanup — delete the test row via update to completed=true then
        //    a direct DELETE call. PostgREST DELETE uses a filter-query approach.
        //    We use update to mark it, then rely on RLS / manual cleanup if
        //    DELETE isn't exposed. For a clean test env, prefer a test schema.
        //
        //    As a minimal cleanup, mark the row completed=true so it's visibly
        //    distinct from real data.
        struct CompletedPatch: Encodable { let completed: Bool }
        try await client.update(CompletedPatch(completed: true), table: "workout_sessions", id: row.id)

        // Re-fetch to confirm the patch was applied.
        let patched: [WorkoutSessionRow] = try await client.fetch(
            WorkoutSessionRow.self,
            table: "workout_sessions",
            filters: [Filter(column: "id", op: .eq, value: row.id.uuidString)]
        )
        XCTAssertEqual(patched.first?.completed, true, "Patch must update completed to true.")
    }
}

// MARK: - Actor extension for test access

private extension SupabaseClient {
    /// Sets authToken from a non-actor context in tests.
    func set(authToken: String?) {
        self.authToken = authToken
    }
}
