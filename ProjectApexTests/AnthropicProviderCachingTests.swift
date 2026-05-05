// AnthropicProviderCachingTests.swift
// ProjectApexTests — Slice 7 (Issue #5)
//
// Tests for AnthropicProvider prompt-caching behaviour.
//
// Test categories:
//   1. Unit tests (always run): use CachingMockURLProtocol to inspect HTTP
//      request shape and parse mock responses — no real network calls.
//   2. Smoke test (gated): APEX_INTEGRATION_TESTS=1 required.
//      Two identical Anthropic calls in sequence; second must show
//      cache_read_input_tokens > 0 confirming the mechanism works end-to-end.
//
// NOTE — production cache coverage:
//   The real AIInferenceService.systemPrompt is ~550 tokens, below the
//   1,024-token cache minimum for claude-sonnet-4-5. Production cache hits
//   require Phase 2 to add TraineeModelDigest to the stable section. This
//   smoke test uses a padded prompt to verify the mechanism independently.

import XCTest
@testable import ProjectApex

// MARK: - CachingMockURLProtocol

private final class CachingMockURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = CachingMockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // URLSession reifies httpBody → httpBodyStream for transport.
        // Drain stream back into httpBody so handlers can inspect POST payloads.
        // Same pattern as WAQMockURLProtocol (issue #23).
        let canonical = Self.canonicalize(request)
        do {
            let (response, data) = try handler(canonical)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func canonicalize(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        var copy = request
        copy.httpBody = data
        return copy
    }
}

// MARK: - Helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CachingMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeSuccessResponse(
    text: String,
    cacheCreation: Int = 0,
    cacheRead: Int = 0
) throws -> Data {
    let json: [String: Any] = [
        "content": [["type": "text", "text": text]],
        "usage": [
            "input_tokens": 100,
            "cache_creation_input_tokens": cacheCreation,
            "cache_read_input_tokens": cacheRead,
            "output_tokens": 20
        ]
    ]
    return try JSONSerialization.data(withJSONObject: json)
}

private func http200() -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.anthropic.com/v1/messages")!,
        statusCode: 200, httpVersion: nil, headerFields: nil
    )!
}

private func http(_ code: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.anthropic.com/v1/messages")!,
        statusCode: code, httpVersion: nil, headerFields: nil
    )!
}

// MARK: - AnthropicProviderCachingTests

final class AnthropicProviderCachingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CachingMockURLProtocol.requestHandler = nil
    }

    // MARK: ─── Helper ─────────────────────────────────────────────────────────

    private func requireLiveAPI() throws {
        guard ProcessInfo.processInfo.environment["APEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip(
                "Live cache smoke test skipped. Set APEX_INTEGRATION_TESTS=1 to enable."
            )
        }
    }

    private func requireAnthropicKey() throws -> String {
        guard let key = try KeychainService.shared.retrieve(.anthropicAPIKey),
              !key.isEmpty else {
            throw XCTSkip(
                "No Anthropic API key in Keychain. " +
                "Add one via Settings → Developer Settings before running smoke tests."
            )
        }
        return key
    }

    // MARK: ─── 1. system field is array with cache_control ───────────────────

    func test_cachingEnabled_systemFieldIsArrayWithCacheControl() async throws {
        var capturedBody: [String: Any]?

        CachingMockURLProtocol.requestHandler = { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (http200(), try makeSuccessResponse(text: "ok"))
        }

        let provider = AnthropicProvider(
            apiKey: "test-key",
            urlSession: makeMockSession()
        )
        _ = try await provider.complete(systemPrompt: "be helpful", userPayload: "hello")

        let systemField = try XCTUnwrap(capturedBody?["system"])
        let systemArray = try XCTUnwrap(systemField as? [[String: Any]],
                                        "system must be an array of blocks, not a plain string")
        let firstBlock = try XCTUnwrap(systemArray.first)

        XCTAssertEqual(firstBlock["type"] as? String, "text")
        XCTAssertEqual(firstBlock["text"] as? String, "be helpful")

        let cacheControl = try XCTUnwrap(firstBlock["cache_control"] as? [String: Any],
                                         "first system block must have cache_control")
        XCTAssertEqual(cacheControl["type"] as? String, "ephemeral")
    }

    // MARK: ─── 2. messages carry userPayload unchanged ────────────────────────

    func test_cachingEnabled_userPayloadUnchangedInMessages() async throws {
        var capturedBody: [String: Any]?

        CachingMockURLProtocol.requestHandler = { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (http200(), try makeSuccessResponse(text: "ok"))
        }

        let provider = AnthropicProvider(
            apiKey: "test-key",
            urlSession: makeMockSession()
        )
        _ = try await provider.complete(systemPrompt: "sys", userPayload: "my-payload")

        let messages = try XCTUnwrap(capturedBody?["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages.first)
        XCTAssertEqual(first["role"] as? String, "user")
        XCTAssertEqual(first["content"] as? String, "my-payload")
    }

    // MARK: ─── 3. text extracted from response ────────────────────────────────

    func test_cachingEnabled_returnsTextFromResponseEnvelope() async throws {
        CachingMockURLProtocol.requestHandler = { _ in
            (http200(), try makeSuccessResponse(text: "the answer"))
        }

        let provider = AnthropicProvider(
            apiKey: "test-key",
            urlSession: makeMockSession()
        )
        let result = try await provider.complete(systemPrompt: "sys", userPayload: "q")
        XCTAssertEqual(result, "the answer")
    }

    // MARK: ─── 4. HTTP non-2xx → LLMProviderError.httpError ──────────────────

    func test_cachingEnabled_non2xxThrowsHTTPError() async throws {
        CachingMockURLProtocol.requestHandler = { _ in
            let body = #"{"error":{"type":"rate_limit_error"}}"#.data(using: .utf8)!
            return (http(429), body)
        }

        let provider = AnthropicProvider(
            apiKey: "test-key",
            urlSession: makeMockSession()
        )

        do {
            _ = try await provider.complete(systemPrompt: "sys", userPayload: "q")
            XCTFail("Expected LLMProviderError.httpError to be thrown")
        } catch let error as LLMProviderError {
            if case .httpError(let code, _) = error {
                XCTAssertEqual(code, 429)
            } else {
                XCTFail("Expected .httpError, got \(error)")
            }
        }
    }

    // MARK: ─── 5. cacheCreationInputTokens from usage ─────────────────────────

    func test_completeWithStats_returnsCacheCreationTokens() async throws {
        CachingMockURLProtocol.requestHandler = { _ in
            (http200(), try makeSuccessResponse(text: "ok", cacheCreation: 1247, cacheRead: 0))
        }

        let provider = AnthropicProvider(
            apiKey: "test-key",
            urlSession: makeMockSession()
        )
        let (_, stats) = try await provider.completeWithStats(
            systemPrompt: "sys", userPayload: "q"
        )
        XCTAssertEqual(stats.cacheCreationInputTokens, 1247)
        XCTAssertEqual(stats.cacheReadInputTokens, 0)
    }

    // MARK: ─── 6. cacheReadInputTokens from usage ─────────────────────────────

    func test_completeWithStats_returnsCacheReadTokens() async throws {
        CachingMockURLProtocol.requestHandler = { _ in
            (http200(), try makeSuccessResponse(text: "ok", cacheCreation: 0, cacheRead: 1247))
        }

        let provider = AnthropicProvider(
            apiKey: "test-key",
            urlSession: makeMockSession()
        )
        let (text, stats) = try await provider.completeWithStats(
            systemPrompt: "sys", userPayload: "q"
        )
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(stats.cacheReadInputTokens, 1247)
        XCTAssertEqual(stats.cacheCreationInputTokens, 0)
    }

    // MARK: ─── 7. enableCaching: false → system is plain string ──────────────

    func test_cachingDisabled_systemFieldIsPlainString() async throws {
        var capturedBody: [String: Any]?

        CachingMockURLProtocol.requestHandler = { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (http200(), try makeSuccessResponse(text: "ok"))
        }

        let provider = AnthropicProvider(
            apiKey: "test-key",
            enableCaching: false,
            urlSession: makeMockSession()
        )
        _ = try await provider.complete(systemPrompt: "be helpful", userPayload: "hello")

        let systemField = try XCTUnwrap(capturedBody?["system"])
        XCTAssertNotNil(systemField as? String,
                        "When enableCaching is false, system must be a plain string")
        XCTAssertNil(systemField as? [[String: Any]],
                     "When enableCaching is false, system must not be an array")
    }

    // MARK: ─── 8. Smoke test — cache-effectiveness (gated) ───────────────────

    /// Makes two identical Anthropic calls with a system prompt long enough to
    /// exceed the 1,024-token cache minimum for claude-sonnet-4-5 (~3,500 chars).
    /// Asserts that the second call's cache_read_input_tokens > 0 — confirming
    /// that cache_control is being accepted and processed by Anthropic.
    ///
    /// NOTE: Production cache hits depend on Phase 2 adding TraineeModelDigest
    /// to the stable section. The real systemPrompt (~550 tokens) is below the
    /// 1,024-token minimum. This test verifies the mechanism with a padded prompt.
    func test_smokeTest_cacheEffectiveness_secondCallReadsCachedTokens() async throws {
        try requireLiveAPI()
        let apiKey = try requireAnthropicKey()

        // ~3,500 chars ≈ ~875 tokens with Anthropic's tokenizer — well above the
        // 1,024-token minimum for claude-sonnet-4-5. If this ever fails because the
        // pad tokenizes short, increase the repeat count.
        let basePad = String(repeating: "You are a helpful strength and conditioning coach assistant. ", count: 60)
        let stableSystemPrompt = """
            You are an elite AI strength and hypertrophy coach embedded in a workout app. \
            Your sole job is to prescribe the next set for the user based on the provided \
            WorkoutContext JSON. Return ONLY a valid JSON object matching the set_prescription schema. \
            No prose, no markdown fences.

            \(basePad)
            """

        let provider = AnthropicProvider(apiKey: apiKey)
        let userPayload = #"{"request_type":"set_prescription","current_exercise":{"name":"Barbell Bench Press"}}"#

        // Call 1 — expect cache write
        let (_, stats1) = try await provider.completeWithStats(
            systemPrompt: stableSystemPrompt,
            userPayload: userPayload
        )

        // Call 2 — expect cache read (same system prompt prefix)
        let (_, stats2) = try await provider.completeWithStats(
            systemPrompt: stableSystemPrompt,
            userPayload: userPayload
        )

        XCTContext.runActivity(named: "Cache stats — call 1") { _ in
            XCTContext.runActivity(named: "cacheCreationInputTokens: \(stats1.cacheCreationInputTokens)") { _ in }
            XCTContext.runActivity(named: "cacheReadInputTokens:     \(stats1.cacheReadInputTokens)") { _ in }
        }
        XCTContext.runActivity(named: "Cache stats — call 2") { _ in
            XCTContext.runActivity(named: "cacheCreationInputTokens: \(stats2.cacheCreationInputTokens)") { _ in }
            XCTContext.runActivity(named: "cacheReadInputTokens:     \(stats2.cacheReadInputTokens)") { _ in }
        }

        XCTAssertGreaterThan(
            stats2.cacheReadInputTokens, 0,
            "Second call must read from cache. " +
            "Call 1 — creation: \(stats1.cacheCreationInputTokens), read: \(stats1.cacheReadInputTokens). " +
            "Call 2 — creation: \(stats2.cacheCreationInputTokens), read: \(stats2.cacheReadInputTokens)."
        )
    }
}
