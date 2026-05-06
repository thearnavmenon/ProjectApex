// FallbackLogRecord.swift
// ProjectApex — Services
//
// Structured diagnostic record emitted whenever an LLM service returns a fallback
// (non-AI) result, either due to a transient error, timeout, or encoding failure.
//
// Emission target: os.Logger (subsystem: "com.projectapex", category: "Fallback").
// TODO: Also enqueue to Supabase `fallback_logs` table via WriteAheadQueue once
//       WAQ is injected into the relevant services.
//
// ISOLATION NOTE: nonisolated struct — callable from any actor context.

import Foundation
import OSLog

nonisolated struct FallbackLogRecord: Codable, Sendable {

    // MARK: - Fields

    /// String constant identifying the service method that fell back (see statics below).
    let callSite: String
    /// HTTP status code, if the fallback was caused by an HTTP error response.
    let httpStatus: Int?
    /// Anthropic's `request-id` response header, if captured from the error body.
    let anthropicRequestId: String?
    /// Human-readable description of the fallback cause.
    let reason: String
    /// Active workout session UUID at the time of the fallback, if available.
    let sessionId: String?
    /// Wall-clock time of the fallback event.
    let timestamp: Date

    // MARK: - Call site constants

    static let prescribeCallSite           = "AIInferenceService.prescribe"
    static let prescribeAdaptationCallSite = "AIInferenceService.prescribeAdaptation"
    static let sessionPlanCallSite         = "SessionPlanService.generateSession"
    static let exerciseSwapCallSite        = "ExerciseSwapService.sendMessage"
    static let memoryClassifyCallSite      = "MemoryService.classifyTags"

    // MARK: - Init

    init(
        callSite: String,
        httpStatus: Int? = nil,
        anthropicRequestId: String? = nil,
        reason: String,
        sessionId: String? = nil,
        timestamp: Date = Date()
    ) {
        self.callSite = callSite
        self.httpStatus = httpStatus
        self.anthropicRequestId = anthropicRequestId
        self.reason = reason
        self.sessionId = sessionId
        self.timestamp = timestamp
    }

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.projectapex", category: "Fallback")

    // MARK: - Emission

    /// Emits this record to os.Logger. Best-effort — never throws.
    func emit() {
        let status = httpStatus.map { String($0) } ?? "nil"
        let reqId  = anthropicRequestId ?? "nil"
        let sid    = sessionId ?? "nil"
        Self.logger.warning(
            "[\(self.callSite, privacy: .public)] fallback — status=\(status, privacy: .public) requestId=\(reqId, privacy: .public) sessionId=\(sid, privacy: .public) reason=\(self.reason, privacy: .public)"
        )
    }

    // MARK: - Convenience factories

    /// Creates a record from a `LLMProviderError`, extracting http status and
    /// the Anthropic request-id if encoded in the error body by `AnthropicProvider`.
    static func from(
        callSite: String,
        error: LLMProviderError,
        sessionId: String? = nil
    ) -> FallbackLogRecord {
        var httpStatus: Int?
        var requestId: String?
        if case .httpError(let status, _) = error {
            httpStatus = status
            requestId  = TransientRetryPolicy.extractAnthropicRequestId(from: error)
        }
        return FallbackLogRecord(
            callSite: callSite,
            httpStatus: httpStatus,
            anthropicRequestId: requestId,
            reason: error.localizedDescription,
            sessionId: sessionId
        )
    }

    /// Creates a record from a `FallbackReason` (used by `AIInferenceService`).
    static func from(
        callSite: String,
        fallbackReason: FallbackReason,
        sessionId: String? = nil
    ) -> FallbackLogRecord {
        let reason: String
        switch fallbackReason {
        case .timeout:
            reason = "timeout (8s)"
        case .maxRetriesExceeded(let lastError):
            reason = "maxRetriesExceeded: \(lastError.prefix(200))"
        case .llmProviderError(let msg):
            reason = "llmProviderError: \(msg.prefix(200))"
        case .encodingFailed(let msg):
            reason = "encodingFailed: \(msg)"
        case .malformedResponse(let msg):
            reason = "malformedResponse: \(msg.prefix(200))"
        }
        return FallbackLogRecord(
            callSite: callSite,
            reason: reason,
            sessionId: sessionId
        )
    }
}

// MARK: - Permanent-failure fallback hook (Slice 6 / ADR-0007 §1) ───────────
//
// AUDIT HOOK — spinoff issue "Audit retry-on-validate sites against ADR-0007":
//   Grep for callers of `emitPermanentFailureFallback` to inventory which
//   foreground services have adopted the ADR-0007 fail-fast pattern. Sites
//   that decode/validate LLM responses but DO NOT call this helper are
//   candidates for the audit — they likely either retry-on-validate
//   (pre-Slice-6 behaviour) or silently swallow the failure.
//
// Slice 6 call sites (initial inventory):
//   - AIInferenceService.prescribe (decode failure, validate failure)
//   - AIInferenceService.prescribeAdaptation (decode failure, validate failure)
//
// Foreground call sites flagged by ADR-0007 §3 that the audit should check:
//   - SessionPlanService.callAndDecodeSession
//   - ExerciseSwapService.sendMessage
//
// Foreground services map the returned `FallbackLogRecord` (already emitted)
// onto their own fallback-result type — this helper is intentionally
// generic over result type so each service stays in control of its own
// fallback DTOs.

/// Emits a `FallbackLogRecord` for a permanent (malformed-response or
/// validation) error per ADR-0007 §1 and returns the record. The caller
/// maps to its own fallback result type.
///
/// Use this anywhere a foreground LLM call site would otherwise have to
/// decide between (wrong) silent retry and (correct) fail-fast surface.
@discardableResult
nonisolated func emitPermanentFailureFallback(
    callSite: String,
    description: String,
    sessionId: String? = nil
) -> FallbackLogRecord {
    let record = FallbackLogRecord(
        callSite: callSite,
        reason: "malformedResponse: \(description.prefix(200))",
        sessionId: sessionId
    )
    record.emit()
    return record
}
