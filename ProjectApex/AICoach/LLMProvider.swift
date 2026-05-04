// LLMProvider.swift
// ProjectApex — AICoach Feature
//
// Defines the LLMProvider protocol and two concrete implementations:
//   • AnthropicProvider  — Claude claude-3-5-sonnet / Messages API
//   • OpenAIProvider     — GPT-4o / Chat Completions API
//
// Both implementations use URLSession async/await with no third-party dependencies.
// HTTP non-2xx responses are surfaced as LLMProviderError.httpError(statusCode:body:).
//
// ISOLATION NOTE:
// This target has SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
// All types here are marked `nonisolated` so their methods can be called from
// the background AIInferenceService actor without @MainActor isolation.

import Foundation

// MARK: - LLMProviderError

nonisolated enum LLMProviderError: LocalizedError {
    case httpError(statusCode: Int, body: String)
    case emptyResponse
    case malformedResponse(detail: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "LLM API returned HTTP \(code): \(body.prefix(200))"
        case .emptyResponse:
            return "LLM API returned an empty response."
        case .malformedResponse(let detail):
            return "LLM API response could not be parsed: \(detail)"
        }
    }

    // MARK: Classification (ADR-0007)

    /// Compiler-checked transient/permanent split. Callers branch on this
    /// rather than re-deriving from raw HTTP codes — that pattern was the
    /// root cause of #24.2's stale assertion.
    nonisolated enum Classification: Sendable, Equatable {
        case transient
        case permanent
    }

    /// HTTP status codes that classify as transient per ADR-0007.
    /// Source of truth — `TransientRetryPolicy.transientCodes` aliases this.
    nonisolated static let transientHTTPCodes: Set<Int> = [429, 502, 503, 504, 529]

    nonisolated var classification: Classification {
        switch self {
        case .httpError(let code, _):
            return Self.transientHTTPCodes.contains(code) ? .transient : .permanent
        case .emptyResponse, .malformedResponse:
            return .permanent
        }
    }
}

// MARK: - LLMErrorClassifier

/// Maps any `Error` (LLMProviderError, URLError, or unknown) to a
/// `LLMProviderError.Classification`. Per ADR-0007 — network errors classify
/// as transient so the retry policy can recover from a brief disconnect; all
/// other unknown errors classify as permanent so the policy fails fast rather
/// than silently looping on something it doesn't understand.
nonisolated enum LLMErrorClassifier {

    /// `URLError` codes that represent a transient network condition where
    /// retrying is the right behaviour. Other URLError codes (e.g. cancelled,
    /// userAuthenticationRequired) are permanent.
    nonisolated static let transientURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .timedOut,
        .cannotConnectToHost,
        .dnsLookupFailed
    ]

    /// Returns the classification for any `Error`. Unknown error types
    /// classify as `.permanent` — silent retry of an unclassified failure
    /// would be a no-silent-fallback violation in the other direction.
    nonisolated static func classify(_ error: Error) -> LLMProviderError.Classification {
        if let llm = error as? LLMProviderError {
            return llm.classification
        }
        if let urlError = error as? URLError,
           transientURLErrorCodes.contains(urlError.code) {
            return .transient
        }
        return .permanent
    }
}

// MARK: - LLMProvider Protocol

/// Abstraction over an LLM API endpoint.
/// Implementations must handle auth, request construction, and response extraction.
protocol LLMProvider: Sendable {
    /// Sends a system prompt and a user-turn payload to the LLM and returns the
    /// raw text content of the model's first response message.
    func complete(systemPrompt: String, userPayload: String) async throws -> String
}

// MARK: - AnthropicProvider

/// Calls the Anthropic Messages API (claude-3-5-sonnet-* and later models).
/// Reference: https://docs.anthropic.com/en/api/messages
nonisolated struct AnthropicProvider: LLMProvider {

    let apiKey: String
    let model: String
    /// Maximum tokens in the completion. Defaults to 1024 (set inference).
    /// Use 32000 for macro-program generation.
    let maxTokens: Int
    /// URLSession request timeout in seconds.
    /// Set inference uses 30s; program generation uses 600s (Opus + 32k tokens can take 2+ min).
    let requestTimeout: TimeInterval

    private let session: URLSession

    init(
        apiKey: String,
        model: String = "claude-sonnet-4-5",
        maxTokens: Int = 1024,
        requestTimeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.requestTimeout = requestTimeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        // Resource timeout must be at least as large as the request timeout.
        config.timeoutIntervalForResource = max(requestTimeout, 660)
        self.session = URLSession(configuration: config)
    }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPayload]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.malformedResponse(detail: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
            // Encode optional Anthropic response headers as bracket-prefixes so
            // TransientRetryPolicy and FallbackLogRecord can parse them without
            // requiring changes to the LLMProvider protocol.
            var metadataPrefix = ""
            if let rid = http.value(forHTTPHeaderField: "request-id") {
                metadataPrefix += "[request-id:\(rid)]"
            }
            if let retryAfter = http.value(forHTTPHeaderField: "retry-after") {
                metadataPrefix += "[retry-after:\(retryAfter)]"
            }
            if !metadataPrefix.isEmpty { bodyString = metadataPrefix + " " + bodyString }
            throw LLMProviderError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        // Anthropic envelope: {"content": [{"type": "text", "text": "..."}], ...}
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArray = json["content"] as? [[String: Any]],
            let firstTextBlock = contentArray.first(where: { $0["type"] as? String == "text" }),
            let text = firstTextBlock["text"] as? String
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMProviderError.malformedResponse(detail: raw)
        }

        guard !text.isEmpty else { throw LLMProviderError.emptyResponse }
        return text
    }
}

// MARK: - OpenAIProvider

/// Calls the OpenAI Chat Completions API (gpt-4o and compatible models).
/// Reference: https://platform.openai.com/docs/api-reference/chat/create
nonisolated struct OpenAIProvider: LLMProvider {

    let apiKey: String
    let model: String

    private let session: URLSession

    init(apiKey: String, model: String = "gpt-4o") {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPayload]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.malformedResponse(detail: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMProviderError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        // OpenAI envelope: {"choices": [{"message": {"content": "..."}}], ...}
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMProviderError.malformedResponse(detail: raw)
        }

        guard !content.isEmpty else { throw LLMProviderError.emptyResponse }
        return content
    }
}
