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

    /// HTTP status codes that represent transient server-side errors eligible for retry.
    static let transientCodes: Set<Int> = [429, 502, 503, 504, 529]

    /// Maximum number of retry attempts after the initial call (4 total attempts).
    static let maxRetries: Int = 3

    /// Base delay in seconds; doubles on each attempt (1 s, 2 s, 4 s, 8 s).
    static let baseDelay: TimeInterval = 1.0

    /// Maximum random jitter added to the calculated delay.
    static let maxJitter: TimeInterval = 0.5

    /// Executes `operation`, automatically retrying up to `maxRetries` times when it
    /// throws `LLMProviderError.httpError` with a transient status code.
    ///
    /// Non-transient errors and non-LLMProviderError errors are re-thrown immediately.
    /// Cooperative `Task` cancellation is checked between retries.
    static func execute<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error = LLMProviderError.emptyResponse
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let err as LLMProviderError {
                switch err {
                case .httpError(let status, _) where transientCodes.contains(status):
                    // Transient — record and fall through to backoff logic below.
                    lastError = err
                default:
                    // Non-transient (emptyResponse, malformedResponse, non-transient httpError).
                    throw err
                }
            }
            // NOTE: Non-LLMProviderError errors (e.g. URLError, CancellationError) are NOT
            // caught above — they propagate out of the do-catch and exit the for loop,
            // surfacing directly to the caller without any retry.

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
