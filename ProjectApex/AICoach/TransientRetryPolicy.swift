// TransientRetryPolicy.swift
// ProjectApex — AICoach
//
// Shared exponential-backoff retry utility for transient LLM HTTP errors.
//
// Covered codes: 429 (rate limit), 502 (bad gateway), 503 (service unavailable),
//               504 (gateway timeout), 529 (Anthropic overload).
//
// Backoff schedule: 1 s → 2 s → 4 s → 8 s (+ up to 0.5 s random jitter each).
// Maximum 3 retries = 4 total attempts.
//
// Behaviour:
//   • LLMProviderError.httpError with a transient status code → retry with backoff.
//   • All other errors → re-thrown immediately without retrying.
//   • Cooperative cancellation is checked before each sleep.
//
// Usage:
//   let response = try await TransientRetryPolicy.execute {
//       try await provider.complete(systemPrompt: prompt, userPayload: payload)
//   }
//
// ISOLATION NOTE: nonisolated enum — callable from any actor context.

import Foundation

nonisolated enum TransientRetryPolicy {

    /// HTTP status codes that represent transient server-side errors eligible
    /// for retry. Aliased from `LLMProviderError.transientHTTPCodes` (the
    /// canonical source of truth per ADR-0007) so existing call sites that
    /// reference `TransientRetryPolicy.transientCodes` continue to work.
    static var transientCodes: Set<Int> { LLMProviderError.transientHTTPCodes }

    /// Maximum number of retry attempts after the initial call (4 total attempts).
    static let maxRetries: Int = 3

    /// Base delay in seconds; doubles on each attempt (1 s, 2 s, 4 s, 8 s).
    static let baseDelay: TimeInterval = 1.0

    /// Maximum random jitter added to the calculated delay.
    static let maxJitter: TimeInterval = 0.5

    /// Executes `operation`, automatically retrying up to `maxRetries` times
    /// when it throws an error classified as transient per ADR-0007.
    /// `LLMErrorClassifier.classify(_:)` is the single source of truth —
    /// `LLMProviderError` with a transient HTTP code AND `URLError` of the
    /// network-condition codes (notConnectedToInternet, networkConnectionLost,
    /// timedOut, cannotConnectToHost, dnsLookupFailed) all retry.
    ///
    /// Permanent errors (auth failures, malformed responses, unknown error
    /// types) re-throw immediately without consuming retries.
    /// Cooperative `Task` cancellation is checked between retries.
    static func execute<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error = LLMProviderError.emptyResponse
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch {
                switch LLMErrorClassifier.classify(error) {
                case .transient:
                    lastError = error
                case .permanent:
                    throw error
                }
            }

            if attempt < maxRetries {
                try Task.checkCancellation()
                let backoff = baseDelay * pow(2.0, Double(attempt))
                let jitter  = TimeInterval.random(in: 0...maxJitter)
                try await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
                try Task.checkCancellation()
            }
        }
        throw lastError
    }

    // MARK: - Header metadata parsing
    //
    // AnthropicProvider encodes optional response header values in the error body
    // using bracket prefixes: [request-id:<id>] and [retry-after:<seconds>].
    // These helpers extract those values for structured fallback logging.

    /// Extracts the Anthropic `request-id` response header from the body of an
    /// `httpError`, if it was encoded by `AnthropicProvider`.
    static func extractAnthropicRequestId(from error: LLMProviderError) -> String? {
        guard case .httpError(_, let body) = error else { return nil }
        return extractBracketValue(key: "request-id", from: body)
    }

    /// Extracts the `Retry-After` delay (in seconds) from the body of an `httpError`,
    /// if it was encoded by `AnthropicProvider`.
    static func extractRetryAfter(from error: LLMProviderError) -> TimeInterval? {
        guard case .httpError(_, let body) = error else { return nil }
        guard let str = extractBracketValue(key: "retry-after", from: body),
              let seconds = Double(str) else { return nil }
        return seconds
    }

    private static func extractBracketValue(key: String, from body: String) -> String? {
        let prefix = "[\(key):"
        guard let start = body.range(of: prefix),
              let end   = body.range(of: "]", range: start.upperBound..<body.endIndex)
        else { return nil }
        return String(body[start.upperBound..<end.lowerBound])
    }
}
