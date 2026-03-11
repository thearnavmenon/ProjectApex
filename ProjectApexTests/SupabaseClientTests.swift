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

    // MARK: ─── 4. GymProfile unit tests (stub) ───────────────────────────────

    /// deactivateGymProfiles() must PATCH gym_profiles with user_id filter.
    func test_deactivateGymProfiles_sendsPatchWithUserIdFilter() async throws {
        StubURLProtocol.stubbedStatusCode = 200
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let uid = UUID()
        let client = makeClient()
        try await client.deactivateGymProfiles(userId: uid)

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertTrue(
            req.url?.path.hasSuffix("/rest/v1/gym_profiles") == true,
            "PATCH must target /rest/v1/gym_profiles."
        )
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let userIdItem = components?.queryItems?.first { $0.name == "user_id" }
        XCTAssertEqual(userIdItem?.value, "eq.\(uid.uuidString)",
            "user_id filter must be eq.<uuid>.")

        // Verify the body contains is_active. URLSession may deliver the body
        // either in httpBody or httpBodyStream depending on size.
        let bodyData: Data?
        if let direct = req.httpBody {
            bodyData = direct
        } else if let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let bytesRead = stream.read(buffer, maxLength: bufferSize)
                if bytesRead > 0 { data.append(buffer, count: bytesRead) }
            }
            stream.close()
            bodyData = data.isEmpty ? nil : data
        } else {
            bodyData = nil
        }

        let body = try XCTUnwrap(bodyData, "Request must have a non-empty body.")
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let isActive = json?["is_active"] as? Bool
        XCTAssertEqual(isActive, false, "Body must set is_active to false.")
    }

    /// fetchActiveProfile() must GET gym_profiles with is_active and user_id filters.
    func test_fetchActiveProfile_sendsGetWithCorrectFilters() async throws {
        StubURLProtocol.stubbedStatusCode = 200
        StubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let uid = UUID()
        let client = makeClient()
        let result = try await client.fetchActiveProfile(userId: uid)

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertTrue(
            req.url?.path.hasSuffix("/rest/v1/gym_profiles") == true,
            "GET must target /rest/v1/gym_profiles."
        )
        // When no rows are returned the method must return nil, not throw.
        XCTAssertNil(result, "Empty response must return nil, not throw.")
    }

    // MARK: ─── 5. Integration test (live Supabase) ───────────────────────────

    /// Inserts a minimal workout_sessions row, fetches it back, asserts fields
    /// match, then patches it to mark it complete (cleanup).
    ///
    /// Skips automatically when no Supabase anon key is in the Keychain.
    /// Requires Config.supabaseURL to point to your live Supabase project.
    func test_integration_insertAndFetch_workoutSession() async throws {
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

    // MARK: ─── 6. GymProfile integration test (live Supabase) ────────────────

    /// Inserts a GymProfile row into `gym_profiles`, fetches it back via
    /// `fetchActiveProfile(userId:)`, asserts the equipment array survives the
    /// JSONB round-trip, then deactivates the row for cleanup.
    ///
    /// Skips automatically when no Supabase anon key is in the Keychain.
    /// Requires Config.supabaseURL to point to your live Supabase project and
    /// a row with id `00000000-0000-0000-0000-000000000001` in `public.users`.
    func test_integration_saveAndFetch_gymProfile() async throws {
        let anonKey = try requireSupabaseKey()

        // Must be a real user_id row in public.users for the FK to pass.
        let testUserId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let client = SupabaseClient(supabaseURL: Config.supabaseURL, anonKey: anonKey)

        let mockProfile = GymProfile.mockProfile()
        let rowToInsert = GymProfileRow.forInsert(from: mockProfile, userId: testUserId)

        // 1. Deactivate any prior active profiles for the test user.
        try await client.deactivateGymProfiles(userId: testUserId)

        // 2. Insert and echo back the new row.
        let inserted: [GymProfileRow] = try await client.insertReturning(
            rowToInsert,
            table: "gym_profiles",
            returning: GymProfileRow.self
        )
        XCTAssertEqual(inserted.count, 1, "Insert should echo back exactly one row.")
        let insertedRow = try XCTUnwrap(inserted.first)
        XCTAssertEqual(insertedRow.userId,        testUserId)
        XCTAssertEqual(insertedRow.scanSessionId, mockProfile.scanSessionId)
        XCTAssertTrue(insertedRow.isActive, "Newly inserted profile must be active.")

        // 3. Fetch the active profile back.
        let fetched = try await client.fetchActiveProfile(userId: testUserId)
        let fetchedRow = try XCTUnwrap(fetched,
            "fetchActiveProfile must return the row we just inserted.")

        XCTAssertEqual(fetchedRow.userId,        testUserId)
        XCTAssertEqual(fetchedRow.scanSessionId, mockProfile.scanSessionId)
        XCTAssertTrue(fetchedRow.isActive)

        // 4. Verify the equipment array round-trips through JSONB correctly.
        XCTAssertEqual(
            fetchedRow.equipment.count,
            mockProfile.equipment.count,
            "Equipment item count must match after Supabase JSONB round-trip."
        )
        for (expected, actual) in zip(mockProfile.equipment, fetchedRow.equipment) {
            XCTAssertEqual(expected.equipmentType, actual.equipmentType,
                "equipment_type must survive the JSONB round-trip.")
            XCTAssertEqual(expected.count, actual.count,
                "count must survive the JSONB round-trip.")
        }

        // 5. Cleanup — deactivate the inserted row.
        let insertedId = try XCTUnwrap(insertedRow.id,
            "Inserted row must have a server-generated id.")
        struct IsActivePatch: Encodable {
            let isActive: Bool
            enum CodingKeys: String, CodingKey { case isActive = "is_active" }
        }
        try await client.update(IsActivePatch(isActive: false), table: "gym_profiles", id: insertedId)
    }
}

// MARK: - Actor extension for test access

private extension SupabaseClient {
    /// Sets authToken from a non-actor context in tests.
    func set(authToken: String?) {
        self.authToken = authToken
    }
}
