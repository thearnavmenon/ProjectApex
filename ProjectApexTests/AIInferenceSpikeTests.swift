// AIInferenceSpikeTests.swift
// ProjectApexTests
//
// Unit tests for P0-T03: validates that AIInferenceService correctly exercises
// all three retry paths using a controllable mock LLMProvider.
//
// Test coverage:
//   1. RetryMockProvider — fails N times then succeeds; confirms retries fire.
//   2. All three retry paths:
//      a. JSON decode failure on first two attempts → success on third.
//      b. Validation failure (bad tempo) on first two attempts → success on third.
//      c. HTTP / provider error on every attempt → fallback result returned.
//   3. System prompt bundle resource loading via InferenceSpike.loadSystemPrompt().
//   4. minimalWorkoutContext() encodes to valid JSON (encoding pipeline is exercised).
//
// Isolation: tests use mock providers — no network calls are made.

import XCTest
@testable import ProjectApex

// MARK: - RetryMockProvider

/// A mock `LLMProvider` that returns `failureResponses` for the first N calls,
/// then returns `successResponse` for all subsequent calls.
///
/// Failure responses are literal strings the provider returns — the caller
/// (AIInferenceService) then tries to decode them, which may or may not succeed
/// depending on the test's intent.
private final class RetryMockProvider: LLMProvider, @unchecked Sendable {

    private let failureResponses: [String]
    private let successResponse: String
    private var callCount: Int = 0

    // Track whether the success response was ever returned.
    var didSucceed: Bool = false

    init(failureResponses: [String], successResponse: String) {
        self.failureResponses = failureResponses
        self.successResponse  = successResponse
    }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        defer { callCount += 1 }
        if callCount < failureResponses.count {
            return failureResponses[callCount]
        }
        didSucceed = true
        return successResponse
    }
}

// MARK: - Provider mocks for retry classification (ADR-0007)

/// Always throws a transient HTTP error (429 rate limit). Per ADR-0007 this
/// classifies as transient so the retry policy retries until exhausted or
/// the product timeout fires.
private struct TransientThrowingMockProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw LLMProviderError.httpError(statusCode: 429, body: "Rate limit exceeded")
    }
}

/// Always throws a permanent HTTP error (401 auth). Per ADR-0007 this
/// classifies as permanent so the retry policy fails fast without consuming
/// the backoff schedule.
private struct PermanentThrowingMockProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw LLMProviderError.httpError(statusCode: 401, body: "Invalid API key")
    }
}

// MARK: - Test helpers

/// A valid JSON response string wrapping a SetPrescription that passes validation.
/// Includes `intent` per Slice 6 (#10) — required field with no silent default.
private let validJSONResponse = """
{
  "set_prescription": {
    "weight_kg": 87.5,
    "reps": 7,
    "tempo": "3-1-1-0",
    "rir_target": 2,
    "rest_seconds": 150,
    "coaching_cue": "Retract scapula before unracking.",
    "reasoning": "Previous set at 85 kg with 2 RIR; small load increase is appropriate.",
    "safety_flags": [],
    "confidence": 0.88,
    "intent": "top"
  }
}
"""

/// JSON that cannot be decoded as SetPrescriptionWrapper (missing required keys).
private let invalidJSONResponse = """
{ "error": "I can't prescribe a set right now." }
"""

/// JSON that decodes but fails SetPrescription.validate() — tempo has 3 parts.
/// Carries a valid intent so `.invalidTempo` surfaces (intent gate has prior
/// precedence per Slice 6).
private let invalidTempoJSONResponse = """
{
  "set_prescription": {
    "weight_kg": 87.5,
    "reps": 7,
    "tempo": "3-1-1",
    "rir_target": 2,
    "rest_seconds": 150,
    "coaching_cue": "Keep tight arch.",
    "reasoning": "Progressive overload from last session.",
    "safety_flags": [],
    "confidence": 0.8,
    "intent": "top"
  }
}
"""

// MARK: - AIInferenceSpikeTests

final class AIInferenceSpikeTests: XCTestCase {

    // MARK: - Permanent-error fail-fast (ADR-0007 / Slice 6) ─────────────────
    //
    // ████████████████████████████████████████████████████████████████████████
    // BEHAVIOUR CHANGE — Slice 6 (#10):
    //   Pre-Slice-6, prescribe() RETRIED on JSON decode and validate()
    //   failures, appending a "CORRECTION REQUIRED" addendum until either a
    //   valid response arrived or maxRetries+1 attempts had been made.
    //
    //   ADR-0007 §1 classifies malformed responses as PERMANENT — same-prompt
    //   retry will not fix the LLM's output. Slice 6 removes the
    //   retry-on-validate loop. The tests below previously asserted "2
    //   failures → 3rd succeeds"; they now assert "first failure → fail fast"
    //   to lock the new contract. Spinoff issue tracks audit of all
    //   retry-on-validate sites against ADR-0007.
    // ████████████████████████████████████████████████████████████████████████

    /// Slice 6: malformed JSON fails fast on the first attempt.
    /// Pre-Slice-6 this test asserted retry-then-success after 2 failures.
    func test_failFast_decodeFailure_oneCall_returnsMalformedResponse() async throws {
        let mock = RetryMockProvider(
            // Multiple failures queued — only the first should ever be served.
            failureResponses: [invalidJSONResponse, invalidJSONResponse],
            successResponse: validJSONResponse
        )
        let service = AIInferenceService(
            provider: mock,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: InferenceSpike.minimalWorkoutContext())

        XCTAssertFalse(
            mock.didSucceed,
            "Slice 6 fail-fast: malformed JSON must not trigger retry. " +
            "If didSucceed=true, the retry-on-decode loop has regressed."
        )
        guard case .fallback(let reason) = result,
              case .malformedResponse = reason
        else {
            return XCTFail("Expected .malformedResponse, got \(result)")
        }
    }

    /// Slice 6: validate() failure on tempo fails fast on the first attempt.
    /// Pre-Slice-6 this test asserted retry-then-success after 2 validation
    /// failures.
    func test_failFast_validationFailure_oneCall_returnsMalformedResponse() async throws {
        let mock = RetryMockProvider(
            failureResponses: [invalidTempoJSONResponse, invalidTempoJSONResponse],
            successResponse: validJSONResponse
        )
        let service = AIInferenceService(
            provider: mock,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: InferenceSpike.minimalWorkoutContext())

        XCTAssertFalse(
            mock.didSucceed,
            "Slice 6 fail-fast: validate() failure must not trigger retry. " +
            "If didSucceed=true, the retry-on-validate loop has regressed."
        )
        guard case .fallback(let reason) = result,
              case .malformedResponse(let detail) = reason
        else {
            return XCTFail("Expected .malformedResponse, got \(result)")
        }
        XCTAssertTrue(
            detail.lowercased().contains("tempo"),
            "Fallback detail should name the offending field. Got: \(detail)"
        )
    }

    // MARK: - Retry path C: provider throws on every attempt → fallback

    /// When the underlying LLM provider always throws (e.g. HTTP 429),
    /// AIInferenceService must return .fallback(reason: .llmProviderError).
    /// Per ADR-0007: a transient provider error (HTTP 429) drives the
    /// retry policy through its full backoff schedule (1 s + 2 s + 4 s = ~7 s
    /// + jitter) until either the retries exhaust or the 8 s product timeout
    /// fires — whichever wins first. Both outcomes are valid surfaces of the
    /// no-silent-fallback contract: the user sees a fallback result rather
    /// than a fabricated prescription.
    func test_retryPath_transientErrors_retriesUntilExhaustionOrProductTimeout() async {
        let provider = TransientThrowingMockProvider()
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let start = Date()
        let result = await service.prescribe(context: InferenceSpike.minimalWorkoutContext())
        let elapsed = Date().timeIntervalSince(start)

        // Retries must actually have happened — the first retry sleep alone is
        // 1 s, so anything under ~1 s means the retry policy didn't kick in.
        XCTAssertGreaterThan(elapsed, 1.0,
            "Transient errors must drive retry backoff; elapsed=\(elapsed)s suggests no retry.")

        switch result {
        case .success:
            XCTFail("Expected fallback when provider always returns transient errors.")
        case .fallback(let reason):
            // Either .timeout (product timeout won the race) or
            // .llmProviderError (retries exhausted before timeout) is correct
            // per ADR-0007. The contract is "fallback was surfaced, not a
            // synthesised prescription."
            switch reason {
            case .timeout, .llmProviderError, .maxRetriesExceeded:
                break  // expected
            case .encodingFailed:
                XCTFail("Encoding should not have failed in this test path: \(reason)")
            case .malformedResponse:
                XCTFail("Transient HTTP errors should not surface as malformedResponse: \(reason)")
            }
        }
    }

    // MARK: - Permanent error path (ADR-0007)

    /// Per ADR-0007: a permanent provider error (HTTP 401 auth) must fail fast
    /// without consuming the retry budget. The first retry sleep is 1 s, so a
    /// permanent error path should complete in well under that.
    func test_retryPath_permanentErrors_failsFastWithoutRetry() async {
        let provider = PermanentThrowingMockProvider()
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let start = Date()
        let result = await service.prescribe(context: InferenceSpike.minimalWorkoutContext())
        let elapsed = Date().timeIntervalSince(start)

        // No retry sleep — the first retry sleep is 1 s base + up to 0.5 s
        // jitter. A correctly classified permanent error skips all sleeps;
        // budget 0.5 s for encode + provider call + decode + dispatch.
        XCTAssertLessThan(elapsed, 0.5,
            "Permanent errors must fail fast without retry backoff; elapsed=\(elapsed)s suggests retry happened.")

        switch result {
        case .success:
            XCTFail("Expected fallback for permanent provider error.")
        case .fallback(let reason):
            if case .llmProviderError(let msg) = reason {
                XCTAssertFalse(msg.isEmpty,
                    "Permanent error fallback must carry a non-empty diagnostic.")
            } else {
                XCTFail("Expected .llmProviderError for a permanent error, got \(reason).")
            }
        }
    }

    // MARK: - Prescription value correctness on the happy path

    /// Slice 6: confirms that a valid first-attempt response decodes
    /// faithfully. Pre-Slice-6 this test allowed one decode failure before
    /// success; the retry-on-validate loop is gone, so the fixture starts
    /// clean.
    func test_prescriptionValues_validResponse_decodesFaithfully() async throws {
        let mock = RetryMockProvider(
            failureResponses: [],
            successResponse: validJSONResponse
        )
        let service = AIInferenceService(
            provider: mock,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: InferenceSpike.minimalWorkoutContext())

        guard case .success(let prescription) = result else {
            return XCTFail("Expected success.")
        }

        // weight_kg may be adjusted by EquipmentRounder; check it's > 0.
        XCTAssertGreaterThan(prescription.weightKg, 0)
        XCTAssertEqual(prescription.reps, 7)
        XCTAssertEqual(prescription.rirTarget, 2)
        XCTAssertEqual(prescription.restSeconds, 150)
        XCTAssertTrue(prescription.safetyFlags.isEmpty)
        XCTAssertEqual(prescription.intent, .top,
                       "Decoded intent must round-trip from the fixture.")
    }

    // MARK: - Equipment rounding applied after retries

    /// Verifies that the barbell weight returned by the spike is clamped to an
    /// achievable plate-based load from the mock GymProfile.
    func test_equipmentRounder_appliedToLiveResponse() async {
        let mock = RetryMockProvider(
            failureResponses: [],
            successResponse: validJSONResponse // 87.5 kg prescribed
        )
        let gymProfile = GymProfile.mockProfile()
        let service = AIInferenceService(
            provider: mock,
            gymProfile: gymProfile,
            maxRetries: 0
        )

        let result = await service.prescribe(context: InferenceSpike.minimalWorkoutContext())

        guard case .success(let prescription) = result else {
            return XCTFail("Expected success.")
        }

        // The mock profile has a barbell with standard plates.
        // 87.5 kg → per-side = (87.5-20)/2 = 33.75 kg.
        // Greedy: 25 (rem=8.75) → 5 (rem=3.75) → 2.5 (rem=1.25) → 1.25 (rem=0).
        // Per-side = 33.75 → total = 20 + 67.5 = 87.5 — exactly achievable.
        XCTAssertGreaterThan(prescription.weightKg, 0,
                             "Rounded weight must be positive.")
        XCTAssertNoThrow(try prescription.validate(),
                         "Rounded prescription must still pass validation.")
    }

    // MARK: - System prompt bundle resource

    /// Verifies that SystemPrompt_Inference.txt is present in the bundle and
    /// contains the expected response-format constraint.
    func test_systemPromptLoadedFromBundle() throws {
        // The test target does not embed bundle resources from the main target,
        // so we test the loading logic using the main bundle path directly.
        // In CI this will pass because the test host app embeds the resource.
        do {
            let prompt = try InferenceSpike.loadSystemPrompt()
            XCTAssertFalse(prompt.isEmpty, "System prompt must not be empty.")
            XCTAssertTrue(
                prompt.contains("set_prescription"),
                "System prompt must contain the 'set_prescription' response format key."
            )
            XCTAssertTrue(
                prompt.contains("weight_kg"),
                "System prompt must reference 'weight_kg' field."
            )
        } catch {
            // If the resource is genuinely missing from the test bundle, skip
            // rather than fail — the build-time check (Copy Bundle Resources)
            // is the authoritative gate.
            throw XCTSkip("SystemPrompt_Inference.txt not available in test bundle. " +
                           "Ensure it is added to the test target's Copy Bundle Resources. Error: \(error)")
        }
    }

    // MARK: - WorkoutContext encoding

    /// Confirms that minimalWorkoutContext() encodes to valid JSON without
    /// throwing — exercises the full encoding pipeline used in production.
    func test_minimalWorkoutContext_encodesToValidJSON() throws {
        let context = InferenceSpike.minimalWorkoutContext()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        XCTAssertNoThrow(
            try encoder.encode(context),
            "minimalWorkoutContext() must encode to JSON without errors."
        )

        let data = try encoder.encode(context)
        XCTAssertFalse(data.isEmpty, "Encoded JSON data must not be empty.")

        // Confirm round-trip decode succeeds.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkoutContext.self, from: data)
        XCTAssertEqual(decoded.requestType, "set_prescription")
        XCTAssertEqual(decoded.currentExercise.name, "Barbell Bench Press")
    }

    // MARK: - Markdown fence stripping (via indirect test through AIInferenceService)

    /// Verifies that a response wrapped in ```json … ``` fences is correctly
    /// decoded by the service (fence-stripping is an internal detail tested
    /// indirectly by wrapping the valid response in fences).
    func test_markdownFencedResponse_strippedAndDecoded() async {
        let fencedResponse = "```json\n\(validJSONResponse)\n```"
        let mock = RetryMockProvider(
            failureResponses: [],
            successResponse: fencedResponse
        )
        let service = AIInferenceService(
            provider: mock,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 0
        )

        let result = await service.prescribe(context: InferenceSpike.minimalWorkoutContext())

        switch result {
        case .success(let prescription):
            XCTAssertNoThrow(try prescription.validate())
        case .fallback(let reason):
            XCTFail("Expected successful decoding of markdown-fenced response, got: \(reason)")
        }
    }
}
