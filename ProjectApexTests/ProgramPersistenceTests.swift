// ProgramPersistenceTests.swift
// ProjectApexTests — P2-T04
//
// Unit and integration tests for program persistence.
//
// Test categories:
//   1. ProgramRow — Codable round-trip, forInsert factory, toMesocycle conversion.
//   2. SupabaseClient program helpers — stubbed HTTP:
//      a. deactivatePrograms() — sends correct PATCH URL + body.
//      b. fetchActiveProgram() — decodes ProgramRow array, returns first row.
//      c. fetchActiveProgram() — returns nil when response is empty array.
//   3. Mesocycle UserDefaults cache — save/load/clear round-trip.
//   4. Integration test (gated): insert → fetch round-trip against live Supabase.

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol stub (reused pattern from SupabaseClientTests)

private final class ProgramStubURLProtocol: URLProtocol {
    static var stubbedStatusCode: Int = 200
    static var stubbedData: Data = Data()
    static var lastRequest: URLRequest?
    static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ProgramStubURLProtocol.lastRequest = request
        if let body = request.httpBody {
            ProgramStubURLProtocol.requestBodies.append(body)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: ProgramStubURLProtocol.stubbedStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ProgramStubURLProtocol.stubbedData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeProgramStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProgramStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeProgramClient() -> SupabaseClient {
    SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-anon-key",
        urlSession: makeProgramStubSession()
    )
}

// MARK: - Fixture helpers

private let testUserId = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

/// Encodes a `ProgramRow` array as a Supabase-style JSON response.
private func encodeRowsAsJSON(_ rows: [ProgramRow]) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(rows)) ?? Data()
}

// MARK: - ProgramPersistenceTests

final class ProgramPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProgramStubURLProtocol.stubbedStatusCode = 200
        ProgramStubURLProtocol.stubbedData = Data()
        ProgramStubURLProtocol.lastRequest = nil
        ProgramStubURLProtocol.requestBodies = []
    }

    // MARK: - Helpers

    private func requireLiveAPI() throws {
        let flag = ProcessInfo.processInfo.environment["APEX_INTEGRATION_TESTS"]
        guard flag == "1" else {
            throw XCTSkip("Live API test skipped. Set APEX_INTEGRATION_TESTS=1 to enable.")
        }
    }

    private func requireSupabaseKey() throws -> String {
        guard let key = try KeychainService.shared.retrieve(.supabaseAnonKey),
              !key.isEmpty else {
            throw XCTSkip("No Supabase anon key in Keychain.")
        }
        return key
    }

    // MARK: ─── 1. ProgramRow Codable round-trip ───────────────────────────────

    func test_programRow_forInsert_hasNilIdAndCreatedAt() {
        let mesocycle = Mesocycle.mockMesocycle()
        let row = ProgramRow.forInsert(from: mesocycle, userId: testUserId)

        XCTAssertNil(row.id,        "Insert row must have nil id (server-generated).")
        XCTAssertNil(row.createdAt, "Insert row must have nil createdAt (server-generated).")
        XCTAssertEqual(row.userId, testUserId)
        XCTAssertTrue(row.isActive)
        XCTAssertEqual(row.weeks, mesocycle.totalWeeks)
    }

    func test_programRow_toMesocycle_returnsOriginal() {
        let mesocycle = Mesocycle.mockMesocycle()
        let row = ProgramRow.forInsert(from: mesocycle, userId: testUserId)
        let decoded = row.toMesocycle()

        XCTAssertEqual(decoded.id, mesocycle.id)
        XCTAssertEqual(decoded.totalWeeks, mesocycle.totalWeeks)
        XCTAssertEqual(decoded.weeks.count, mesocycle.weeks.count)
        XCTAssertEqual(decoded.periodizationModel, mesocycle.periodizationModel)
    }

    func test_programRow_codableRoundTrip() throws {
        let mesocycle = Mesocycle.mockMesocycle()
        let original = ProgramRow(
            id: UUID(),
            userId: testUserId,
            mesocycleJson: mesocycle,
            weeks: 12,
            createdAt: Date(timeIntervalSince1970: 1_741_996_800),
            isActive: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProgramRow.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.userId, original.userId)
        XCTAssertEqual(decoded.weeks, original.weeks)
        XCTAssertEqual(decoded.isActive, original.isActive)
        XCTAssertEqual(decoded.mesocycleJson.id, original.mesocycleJson.id)
        XCTAssertEqual(decoded.mesocycleJson.totalWeeks, original.mesocycleJson.totalWeeks)
    }

    func test_programRow_mesocycleJson_survivesMesocycleRoundTrip() throws {
        // The mesocycle_json column stores the full Mesocycle; verify deep field survival.
        let mesocycle = Mesocycle.mockMesocycle()
        let row = ProgramRow.forInsert(from: mesocycle, userId: testUserId)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(row)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedRow = try decoder.decode(ProgramRow.self, from: data)

        let decodedMesocycle = decodedRow.toMesocycle()
        let week = decodedMesocycle.weeks[0]
        let day = week.trainingDays[0]
        let exercise = day.exercises[0]

        XCTAssertEqual(week.phase, .accumulation)
        XCTAssertEqual(day.dayLabel, "Push_A")
        XCTAssertEqual(exercise.equipmentRequired, .barbell)
        XCTAssertEqual(exercise.repRange.min, 6)
        XCTAssertEqual(exercise.repRange.max, 10)
        XCTAssertEqual(week.isDeload, false)
    }

    // MARK: ─── 2. SupabaseClient.deactivatePrograms() ─────────────────────────

    func test_deactivatePrograms_sendsPatchToCorrectURL() async throws {
        ProgramStubURLProtocol.stubbedStatusCode = 200
        ProgramStubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let client = makeProgramClient()
        try await client.deactivatePrograms(userId: testUserId)

        let req = try XCTUnwrap(ProgramStubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertTrue(
            req.url?.absoluteString.contains("programs") == true,
            "Request URL must target the programs table."
        )
        XCTAssertTrue(
            req.url?.query?.contains("user_id=eq.\(testUserId.uuidString)") == true,
            "URL must filter by user_id."
        )
    }

    func test_deactivatePrograms_bodyContainsIsActiveFalse() async throws {
        ProgramStubURLProtocol.stubbedStatusCode = 200
        ProgramStubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let client = makeProgramClient()
        try await client.deactivatePrograms(userId: testUserId)

        let bodyData = try XCTUnwrap(ProgramStubURLProtocol.requestBodies.last)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(body["is_active"] as? Bool, false,
                       "Deactivation body must set is_active = false.")
    }

    // MARK: ─── 3. SupabaseClient.fetchActiveProgram() ─────────────────────────

    func test_fetchActiveProgram_sendsGetToCorrectURL() async throws {
        ProgramStubURLProtocol.stubbedStatusCode = 200
        ProgramStubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let client = makeProgramClient()
        _ = try await client.fetchActiveProgram(userId: testUserId)

        let req = try XCTUnwrap(ProgramStubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        let urlString = req.url?.absoluteString ?? ""
        XCTAssertTrue(urlString.contains("programs"), "Must target programs table.")
        XCTAssertTrue(urlString.contains("user_id=eq.\(testUserId.uuidString)"),
                      "Must filter by user_id.")
        XCTAssertTrue(urlString.contains("is_active=is.true"),
                      "Must filter by is_active=true.")
    }

    func test_fetchActiveProgram_emptyResponse_returnsNil() async throws {
        ProgramStubURLProtocol.stubbedStatusCode = 200
        ProgramStubURLProtocol.stubbedData = "[]".data(using: .utf8)!

        let client = makeProgramClient()
        let result = try await client.fetchActiveProgram(userId: testUserId)

        XCTAssertNil(result, "Empty response must return nil (no active program).")
    }

    func test_fetchActiveProgram_validRow_returnsProgramRow() async throws {
        let mesocycle = Mesocycle.mockMesocycle()
        let row = ProgramRow(
            id: UUID(),
            userId: testUserId,
            mesocycleJson: mesocycle,
            weeks: 12,
            createdAt: Date(timeIntervalSince1970: 1_741_996_800),
            isActive: true
        )
        ProgramStubURLProtocol.stubbedStatusCode = 200
        ProgramStubURLProtocol.stubbedData = encodeRowsAsJSON([row])

        let client = makeProgramClient()
        let result = try await client.fetchActiveProgram(userId: testUserId)

        let fetched = try XCTUnwrap(result, "A valid row in the response must be returned.")
        XCTAssertEqual(fetched.userId, testUserId)
        XCTAssertTrue(fetched.isActive)
        XCTAssertEqual(fetched.weeks, 12)
        XCTAssertEqual(fetched.mesocycleJson.id, mesocycle.id)
    }

    func test_fetchActiveProgram_multipleRows_returnsFirst() async throws {
        let m1 = Mesocycle.mockMesocycle()
        var m2 = Mesocycle.mockMesocycle()
        // Give m2 a different id to distinguish it
        m2 = Mesocycle(
            id: UUID(),
            userId: m2.userId,
            createdAt: m2.createdAt,
            isActive: true,
            weeks: m2.weeks,
            totalWeeks: m2.totalWeeks,
            periodizationModel: m2.periodizationModel
        )
        let rows = [
            ProgramRow(id: UUID(), userId: testUserId, mesocycleJson: m1,
                       weeks: 12, createdAt: nil, isActive: true),
            ProgramRow(id: UUID(), userId: testUserId, mesocycleJson: m2,
                       weeks: 12, createdAt: nil, isActive: true)
        ]
        ProgramStubURLProtocol.stubbedStatusCode = 200
        ProgramStubURLProtocol.stubbedData = encodeRowsAsJSON(rows)

        let client = makeProgramClient()
        let result = try await client.fetchActiveProgram(userId: testUserId)
        let fetched = try XCTUnwrap(result)
        XCTAssertEqual(fetched.mesocycleJson.id, m1.id,
                       "fetchActiveProgram must return the first row from the response.")
    }

    // MARK: ─── 4. Mesocycle UserDefaults cache ────────────────────────────────

    func test_mesocycle_saveAndLoadFromUserDefaults() async throws {
        let mesocycle = Mesocycle.mockMesocycle()

        // Save
        await MainActor.run { mesocycle.saveToUserDefaults() }

        // Load
        let loaded = await MainActor.run { Mesocycle.loadFromUserDefaults() }
        let unwrapped = try XCTUnwrap(loaded)
        XCTAssertEqual(unwrapped.id, mesocycle.id)
        XCTAssertEqual(unwrapped.totalWeeks, mesocycle.totalWeeks)
        XCTAssertEqual(unwrapped.weeks.count, mesocycle.weeks.count)
        XCTAssertEqual(unwrapped.periodizationModel, mesocycle.periodizationModel)

        // Cleanup
        await MainActor.run { Mesocycle.clearUserDefaults() }
    }

    func test_mesocycle_loadBeforeSave_returnsNil() async {
        await MainActor.run { Mesocycle.clearUserDefaults() }
        let loaded = await MainActor.run { Mesocycle.loadFromUserDefaults() }
        XCTAssertNil(loaded, "loadFromUserDefaults must return nil before any save.")
    }

    func test_mesocycle_clearUserDefaults_removesCache() async throws {
        let mesocycle = Mesocycle.mockMesocycle()
        await MainActor.run { mesocycle.saveToUserDefaults() }
        await MainActor.run { Mesocycle.clearUserDefaults() }
        let loaded = await MainActor.run { Mesocycle.loadFromUserDefaults() }
        XCTAssertNil(loaded, "After clear, loadFromUserDefaults must return nil.")
    }

    func test_mesocycle_saveOverwritesPreviousCache() async throws {
        let first = Mesocycle.mockMesocycle()
        var second = Mesocycle.mockMesocycle()
        second = Mesocycle(
            id: UUID(), userId: second.userId, createdAt: second.createdAt,
            isActive: true, weeks: second.weeks, totalWeeks: second.totalWeeks,
            periodizationModel: "second_model"
        )

        await MainActor.run { first.saveToUserDefaults() }
        await MainActor.run { second.saveToUserDefaults() }
        let loaded = await MainActor.run { Mesocycle.loadFromUserDefaults() }

        let unwrapped = try XCTUnwrap(loaded)
        XCTAssertEqual(unwrapped.id, second.id,
                       "Second save must overwrite the first.")
        XCTAssertEqual(unwrapped.periodizationModel, "second_model")

        // Cleanup
        await MainActor.run { Mesocycle.clearUserDefaults() }
    }

    // MARK: ─── 5. Integration test (gated) ───────────────────────────────────

    /// Inserts a mock mesocycle → fetches it back → decodes → asserts week count = 12.
    func test_integration_insertAndFetch_mesocycle() async throws {
        try requireLiveAPI()
        let anonKey = try requireSupabaseKey()

        let client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            anonKey: anonKey
        )

        // Use a stable test user ID that exists in the test project
        let testUser = UUID(uuidString: "00000000-0000-0000-0000-000000000099") ?? UUID()

        // Deactivate any existing programs for this test user
        try await client.deactivatePrograms(userId: testUser)

        // Insert a mock mesocycle
        var mesocycle = Mesocycle.mockMesocycle()
        mesocycle = Mesocycle(
            id: UUID(),
            userId: testUser,
            createdAt: Date(),
            isActive: true,
            weeks: mesocycle.weeks,
            totalWeeks: mesocycle.totalWeeks,
            periodizationModel: mesocycle.periodizationModel
        )
        let row = ProgramRow.forInsert(from: mesocycle, userId: testUser)
        try await client.insert(row, table: "programs")

        // Fetch the active program back
        let fetched = try await client.fetchActiveProgram(userId: testUser)
        let fetchedRow = try XCTUnwrap(fetched, "Inserted program must be fetchable.")

        // Decode the mesocycle and assert week count
        let decoded = fetchedRow.toMesocycle()
        XCTAssertEqual(decoded.totalWeeks, 12,
                       "Fetched mesocycle must have totalWeeks = 12.")
        XCTAssertEqual(decoded.weeks.count, mesocycle.weeks.count)
        XCTAssertTrue(fetchedRow.isActive)

        // Cleanup: deactivate the test row
        try await client.deactivatePrograms(userId: testUser)
    }
}
