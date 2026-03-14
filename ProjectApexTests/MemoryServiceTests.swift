// MemoryServiceTests.swift
// ProjectApexTests — P4-T04 / P4-T07
//
// Tests for MemoryService.
//
// Network calls are stubbed via URLProtocol so no real API keys are needed.
// Covers (P4-T04):
//   1. Pain keyword detection (static helper)
//   2. MemoryEmbeddingRow encodes with correct snake_case keys
//   3. embed() completes without crash when API returns valid 1536-dim embedding
//   4. embed() swallows errors gracefully (no throws to caller)
//   5. embed() injects "injury_concern" tag when pain keyword present
//   6. embedThrowing() throws .missingAPIKey when key is empty
//   7. embedThrowing() throws .unexpectedEmbeddingDimension for wrong vector size
//   8. MemoryServiceError descriptions are non-empty
//   9. retrieveMemory returns empty array when embedding API key is missing
//
// Covers (P4-T07 — Memory Event Taxonomy):
//  10. PR auto-event: embed called with correct text and pr_achieved tag
//  11. Performance drop auto-event: embed called with correct text and performance_drop tag
//  12. Pre-classified tags bypass Haiku classification (no Anthropic call made)

import Testing
import Foundation
@testable import ProjectApex

// MARK: - URLProtocol stub helpers

/// A simple URLProtocol subclass that returns a pre-configured response.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    // Per-test handler: (URLRequest) → (HTTPURLResponse, Data)
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeEmbeddingJSON(dims: Int = 1536) -> Data {
    let vector = Array(repeating: 0.001, count: dims)
    let json: [String: Any] = [
        "data": [["embedding": vector, "index": 0, "object": "embedding"]],
        "model": "text-embedding-3-small",
        "object": "list"
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func makeSupabaseInsertJSON() -> Data {
    // Supabase returns an array of inserted rows; we just need a valid 2xx.
    return "[]".data(using: .utf8)!
}

private func httpOK(url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

private func http500(url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
}

// MARK: - MemoryServiceTests

@Suite("MemoryService")
struct MemoryServiceTests {

    // MARK: Pain keyword detection

    @Test("containsPainKeyword returns true for each pain keyword")
    func painKeywordsDetected() {
        let keywords = ["pain", "hurt", "tweaky", "clicking", "popping",
                        "tight", "impinged", "pulling", "straining", "sore"]
        for kw in keywords {
            #expect(
                MemoryService.containsPainKeyword("My shoulder is \(kw) today."),
                "Expected '\(kw)' to be detected as a pain keyword"
            )
        }
    }

    @Test("containsPainKeyword is case-insensitive")
    func painKeywordCaseInsensitive() {
        #expect(MemoryService.containsPainKeyword("PAIN in my knee"))
        #expect(MemoryService.containsPainKeyword("Feeling TIGHT"))
    }

    @Test("containsPainKeyword returns false for non-pain text")
    func noPainKeywordNotDetected() {
        #expect(!MemoryService.containsPainKeyword("Great workout, feeling strong!"))
        #expect(!MemoryService.containsPainKeyword("Energy levels are good today."))
    }

    // MARK: MemoryEmbeddingRow encoding

    @Test("MemoryEmbeddingRow encodes with correct snake_case keys")
    func embeddingRowSnakeCaseKeys() throws {
        let row = MemoryEmbeddingRow(
            userId: "user-1",
            sessionId: "session-1",
            exerciseId: "bench_press",
            muscleGroups: ["pectoralis_major"],
            tags: ["fatigue"],
            rawTranscript: "Felt heavy today",
            embedding: [0.1, 0.2, 0.3],
            metadata: nil
        )
        let data = try JSONEncoder().encode(row)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["user_id"] is String)
        #expect(json["session_id"] is String)
        #expect(json["exercise_id"] is String)
        #expect(json["muscle_groups"] is [String])
        #expect(json["tags"] is [String])
        #expect(json["raw_transcript"] is String)
        #expect(json["embedding"] is [Double])
    }

    @Test("MemoryEmbeddingRow nil metadata omitted from JSON")
    func embeddingRowNilMetadata() throws {
        let row = MemoryEmbeddingRow(
            userId: "u", sessionId: nil, exerciseId: nil,
            muscleGroups: [], tags: [], rawTranscript: "x",
            embedding: [], metadata: nil
        )
        let data = try JSONEncoder().encode(row)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["metadata"] == nil)
    }

    // MARK: embedThrowing — missing API key

    @Test("embedThrowing throws .missingAPIKey when embeddingAPIKey is empty")
    func embedThrowingMissingKey() async {
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon",
            urlSession: makeMockSession()
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "",
            anthropicAPIKey: nil,
            urlSession: makeMockSession()
        )
        do {
            try await service.embedThrowing(
                text: "test", sessionId: nil, exerciseId: nil,
                muscleGroups: [], userId: "user-1"
            )
            Issue.record("Expected MemoryServiceError.missingAPIKey")
        } catch MemoryServiceError.missingAPIKey {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: embedThrowing — wrong embedding dimension

    @Test("embedThrowing throws .unexpectedEmbeddingDimension for wrong vector size")
    func embedThrowingWrongDimension() async {
        let embeddingURL = URL(string: "https://api.openai.com/v1/embeddings")!

        MockURLProtocol.requestHandler = { request in
            (httpOK(url: embeddingURL), makeEmbeddingJSON(dims: 512))
        }

        let mockSession = makeMockSession()
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon",
            urlSession: mockSession
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "sk-test",
            anthropicAPIKey: nil,
            urlSession: mockSession
        )

        do {
            try await service.embedThrowing(
                text: "bench press felt good",
                sessionId: "s1", exerciseId: "bp",
                muscleGroups: ["pectoralis_major"],
                userId: "user-1"
            )
            Issue.record("Expected .unexpectedEmbeddingDimension")
        } catch MemoryServiceError.unexpectedEmbeddingDimension(let n) {
            #expect(n == 512)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: embed — swallows errors

    @Test("embed() does not propagate errors to caller")
    func embedSwallowsErrors() async {
        // Providing an empty key should cause an error internally, but embed() must not throw.
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            urlSession: makeMockSession()
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "",
            urlSession: makeMockSession()
        )
        // Must complete without throwing — callers use fire-and-forget Task.detached
        await service.embed(text: "test", userId: "user-1")
    }

    // MARK: embed — injury_concern injection

    @Test("embed injects injury_concern tag when pain keyword detected")
    func embedInjectsInjuryConcernTag() async throws {
        var capturedRequestBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.host == "api.openai.com" {
                return (httpOK(url: url), makeEmbeddingJSON(dims: 1536))
            }
            // Supabase insert — capture body
            if let body = request.httpBody {
                if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    capturedRequestBody = json
                } else if let jsonArr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] {
                    capturedRequestBody = jsonArr.first
                }
            }
            return (httpOK(url: url), makeSupabaseInsertJSON())
        }

        let mockSession = makeMockSession()
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            urlSession: mockSession
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "sk-test",
            anthropicAPIKey: nil,     // skip Haiku call
            urlSession: mockSession
        )

        try await service.embedThrowing(
            text: "My shoulder is sore and in pain",
            sessionId: "s1",
            exerciseId: "overhead_press",
            muscleGroups: ["deltoid"],
            userId: "user-1"
        )

        let tags = capturedRequestBody?["tags"] as? [String]
        #expect(tags?.contains("injury_concern") == true, "Expected injury_concern in tags: \(String(describing: tags))")
    }

    // MARK: retrieveMemory — empty key

    @Test("retrieveMemory returns empty array when embeddingAPIKey is empty")
    func retrieveMemoryEmptyKey() async {
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            urlSession: makeMockSession()
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "",
            urlSession: makeMockSession()
        )
        let results = await service.retrieveMemory(queryText: "bench press", userId: "user-1")
        #expect(results.isEmpty)
    }

    // MARK: MemoryServiceError descriptions

    @Test("All MemoryServiceError cases have non-empty descriptions")
    func errorDescriptions() {
        let cases: [MemoryServiceError] = [
            .missingAPIKey,
            .embeddingAPIError("detail"),
            .tagClassificationError("detail"),
            .supabaseWriteError("detail"),
            .unexpectedEmbeddingDimension(512)
        ]
        for error in cases {
            let desc = error.errorDescription ?? ""
            #expect(!desc.isEmpty, "Error \(error) has empty description")
        }
    }

    // MARK: embed(text:metadata:) legacy overload

    @Test("embed(text:metadata:) parses metadata keys correctly and completes")
    func embedMetadataOverload() async {
        // No API key — just verify the legacy overload doesn't crash
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            urlSession: makeMockSession()
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "",
            urlSession: makeMockSession()
        )
        // Should complete silently (missing API key causes internal swallowed error)
        await service.embed(
            text: "felt strong",
            metadata: [
                "session_id": "s1",
                "exercise_id": "bench_press",
                "user_id": "user-1",
                "muscle_groups": "pectoralis_major, triceps_brachii"
            ]
        )
    }

    // MARK: - P4-T07: Memory Event Taxonomy Tests

    /// Test 10: PR auto-event stores "pr_achieved" tag and correct transcript text.
    @Test("PR event embed writes pr_achieved tag and correct transcript")
    func prEventHasCorrectTagAndText() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.host == "api.openai.com" {
                return (httpOK(url: url), makeEmbeddingJSON(dims: 1536))
            }
            // Supabase insert — capture body
            if let body = request.httpBody {
                capturedBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                    ?? (try? JSONSerialization.jsonObject(with: body) as? [[String: Any]])?.first
            }
            return (httpOK(url: url), makeSupabaseInsertJSON())
        }

        let mockSession = makeMockSession()
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            urlSession: mockSession
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "sk-test",
            anthropicAPIKey: nil,   // no Haiku call
            urlSession: mockSession
        )

        // Simulate the auto-generated PR event text as WorkoutSessionManager produces it
        let prText = "PR on Barbell Bench Press: 100kg x 8"
        try await service.embedThrowing(
            text: prText,
            sessionId: "s1",
            exerciseId: "barbell_bench_press",
            preclassifiedTags: ["pr_achieved", "pectoralis_major"],
            muscleGroups: ["pectoralis_major", "triceps_brachii"],
            userId: "user-1"
        )

        let tags = capturedBody?["tags"] as? [String]
        let transcript = capturedBody?["raw_transcript"] as? String

        #expect(tags?.contains("pr_achieved") == true, "Expected pr_achieved tag, got: \(String(describing: tags))")
        #expect(transcript == prText, "Expected PR transcript, got: \(String(describing: transcript))")
    }

    /// Test 11: Performance drop event stores "performance_drop" tag and correct transcript.
    @Test("Performance drop event writes performance_drop tag and correct transcript")
    func performanceDropEventHasCorrectTagAndText() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.host == "api.openai.com" {
                return (httpOK(url: url), makeEmbeddingJSON(dims: 1536))
            }
            if let body = request.httpBody {
                capturedBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                    ?? (try? JSONSerialization.jsonObject(with: body) as? [[String: Any]])?.first
            }
            return (httpOK(url: url), makeSupabaseInsertJSON())
        }

        let mockSession = makeMockSession()
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            urlSession: mockSession
        )
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "sk-test",
            anthropicAPIKey: nil,
            urlSession: mockSession
        )

        // Simulate the performance drop event (actual=4, target=8 → 4 below = performance drop)
        let dropText = "Performance drop on Squat: 4/8 reps"
        try await service.embedThrowing(
            text: dropText,
            sessionId: "s2",
            exerciseId: "squat",
            preclassifiedTags: ["performance_drop", "fatigue"],
            muscleGroups: ["quadriceps", "gluteus_maximus"],
            userId: "user-1"
        )

        let tags = capturedBody?["tags"] as? [String]
        let transcript = capturedBody?["raw_transcript"] as? String

        #expect(tags?.contains("performance_drop") == true, "Expected performance_drop tag, got: \(String(describing: tags))")
        #expect(tags?.contains("fatigue") == true, "Expected fatigue tag, got: \(String(describing: tags))")
        #expect(transcript == dropText, "Expected drop transcript, got: \(String(describing: transcript))")
    }

    /// Test 12: Pre-classified tags bypass Haiku — no Anthropic API call is made.
    @Test("Pre-classified tags skip Haiku classification (no Anthropic call)")
    func preclassifiedTagsSkipHaiku() async throws {
        var anthropicCallCount = 0

        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.host == "api.anthropic.com" {
                anthropicCallCount += 1
                // Return a valid Haiku response — but we assert this is never called
                let haikuResponse: [String: Any] = [
                    "content": [["type": "text", "text": "{\"muscle_groups\":[],\"tags\":[],\"sentiment\":\"neutral\"}"]]
                ]
                return (httpOK(url: url), try! JSONSerialization.data(withJSONObject: haikuResponse))
            }
            if url.host == "api.openai.com" {
                return (httpOK(url: url), makeEmbeddingJSON(dims: 1536))
            }
            return (httpOK(url: url), makeSupabaseInsertJSON())
        }

        let mockSession = makeMockSession()
        let mockSupabase = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            urlSession: mockSession
        )
        // Provide anthropicAPIKey — but pre-classified tags should prevent the call
        let service = MemoryService(
            supabase: mockSupabase,
            embeddingAPIKey: "sk-test",
            anthropicAPIKey: "sk-ant-test",
            urlSession: mockSession
        )

        try await service.embedThrowing(
            text: "PR on Deadlift: 140kg x 5",
            sessionId: "s3",
            exerciseId: "deadlift",
            preclassifiedTags: ["pr_achieved", "erector_spinae"],
            muscleGroups: ["erector_spinae"],
            userId: "user-1"
        )

        #expect(anthropicCallCount == 0, "Haiku should not be called when pre-classified tags provided; called \(anthropicCallCount) times")
    }
}
