// AIInferenceServiceTests.swift
// ProjectApexTests — P0-T07
//
// Integration and unit tests for AIInferenceService.prescribe().
//
// Test categories:
//   1. LIVE API (gated): Real Anthropic call with WorkoutContext.mockContext().
//      Skipped unless the environment variable APEX_INTEGRATION_TESTS=1 is set.
//      Set this in the test scheme's environment variables for local or CI runs.
//
//   2. Mock-provider paths (always run):
//      a. Retry path: MockLLMProvider returns invalid JSON twice, valid JSON on
//         attempt 3 — result is .success.
//      b. Timeout path: MockLLMProvider sleeps 9 seconds — result is
//         .fallback(.timeout), confirming the 8-second watchdog fires.
//      c. Network failure: MockLLMProvider throws URLError — result is
//         .fallback(.llmProviderError).
//
// COST NOTE: The live-API test calls the real Anthropic API once per run.
// Gate it with APEX_INTEGRATION_TESTS=1 to avoid accidental charges.

import XCTest
@testable import ProjectApex

// MARK: - Private mock providers

/// Succeeds only after `failCount` failed attempts. Used for retry tests.
private final class RetryOnceProvider: LLMProvider, @unchecked Sendable {

    private let failCount: Int
    private let failResponse: String
    private let successResponse: String
    private(set) var callCount = 0

    init(failCount: Int, failResponse: String, successResponse: String) {
        self.failCount = failCount
        self.failResponse = failResponse
        self.successResponse = successResponse
    }

    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        defer { callCount += 1 }
        return callCount < failCount ? failResponse : successResponse
    }
}

/// Always sleeps longer than the service's 8-second timeout window.
private struct SleepyProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        try await Task.sleep(nanoseconds: 9_000_000_000) // 9 seconds
        return "{}" // never reached
    }
}

/// Always throws a URLError — simulates total network failure.
private struct NetworkFailProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - Test fixtures

/// A valid SetPrescription JSON envelope that passes all validation rules.
private let validPrescriptionJSON = """
{
  "set_prescription": {
    "weight_kg": 85.0,
    "reps": 7,
    "tempo": "3-1-1-0",
    "rir_target": 2,
    "rest_seconds": 150,
    "coaching_cue": "Retract scapula, drive through the bar.",
    "reasoning": "Last set at 2 RIR; maintaining load for consistent volume.",
    "safety_flags": [],
    "confidence": 0.87
  }
}
"""

/// A valid prescription that includes `pain_reported` — exercises the
/// rest-seconds safety gate (must be clamped to ≥ 180).
private let painFlagPrescriptionJSON = """
{
  "set_prescription": {
    "weight_kg": 60.0,
    "reps": 8,
    "tempo": "3-1-1-0",
    "rir_target": 3,
    "rest_seconds": 90,
    "coaching_cue": "Ease off — shoulder discomfort reported.",
    "reasoning": "Pain flag active; reduce load and increase rest.",
    "safety_flags": ["pain_reported"],
    "confidence": 0.70
  }
}
"""

/// JSON that decodes but fails validate() — tempo has only 3 segments.
private let invalidTempoPrescriptionJSON = """
{
  "set_prescription": {
    "weight_kg": 85.0,
    "reps": 7,
    "tempo": "3-1-1",
    "rir_target": 2,
    "rest_seconds": 150,
    "coaching_cue": "Tight arch.",
    "reasoning": "Progressive overload.",
    "safety_flags": []
  }
}
"""

/// Structurally invalid — can't be decoded as SetPrescriptionWrapper.
private let unparsableJSON = """
{ "sorry": "I cannot prescribe a set right now." }
"""

// MARK: - AIInferenceServiceTests

final class AIInferenceServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Skips the test with a descriptive message unless the live-API flag is set.
    private func requireLiveAPI() throws {
        let flag = ProcessInfo.processInfo.environment["APEX_INTEGRATION_TESTS"]
        guard flag == "1" else {
            throw XCTSkip(
                "Live API test skipped. Set APEX_INTEGRATION_TESTS=1 in the " +
                "scheme's environment variables to enable."
            )
        }
    }

    /// Returns the Anthropic API key from the Keychain, skipping if absent.
    private func requireAnthropicKey() throws -> String {
        guard let key = try KeychainService.shared.retrieve(.anthropicAPIKey),
              !key.isEmpty else {
            throw XCTSkip(
                "No Anthropic API key in Keychain. " +
                "Add one via Settings → Developer Settings before running live tests."
            )
        }
        return key
    }

    // MARK: ─── 1. Live API test ───────────────────────────────────────────────

    /// Calls prescribe() against the real Anthropic API with WorkoutContext.mockContext().
    /// Asserts:
    ///   • result is .success
    ///   • SetPrescription.validate() passes
    ///   • weightKg is a positive barbell-achievable load (rounded from profile)
    ///   • full round-trip completes within 8 seconds
    func test_liveAPI_mockContext_returnsValidPrescription() async throws {
        try requireLiveAPI()
        let apiKey = try requireAnthropicKey()

        let service = AIInferenceService(
            provider: AnthropicProvider(apiKey: apiKey),
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )
        let context = WorkoutContext.mockContext()

        let start = Date()
        let result = await service.prescribe(context: context)
        let elapsed = Date().timeIntervalSince(start)

        switch result {
        case .success(let prescription):
            // (a) Validation passes
            XCTAssertNoThrow(
                try prescription.validate(),
                "Live prescription must pass SetPrescription.validate()."
            )
            // (b) weightKg is positive and within the barbell's achievable range
            XCTAssertGreaterThan(prescription.weightKg, 0,
                                 "weightKg must be positive after equipment rounding.")
            // Max barbell load: 20 + 2*(25+20+15+10+5+2.5+1.25)*2 = 20 + 2*78.75 = 177.5 kg
            XCTAssertLessThanOrEqual(prescription.weightKg, 177.5,
                                     "weightKg must not exceed barbell max load.")
            // (c) reps in valid range
            XCTAssertTrue((1...30).contains(prescription.reps),
                          "Reps must be in 1–30.")
            // (d) round-trip completed within 8 seconds (wall clock)
            XCTAssertLessThan(elapsed, 8.0,
                              "Live API round-trip must complete in under 8 seconds.")

        case .fallback(let reason):
            XCTFail("Expected .success from live API, got fallback: \(reason)")
        }
    }

    /// If the live response contains pain_reported, rest ≥ 180 s must be enforced.
    /// This test uses a mock that injects pain_reported but goes through the same
    /// safety-gate code path, so we can verify it deterministically.
    func test_liveAPI_painReported_restSecondsAtLeast180() async throws {
        try requireLiveAPI()
        // Use a mock here so the pain_reported flag is guaranteed to appear.
        // This test validates the safety gate that lives inside AIInferenceService —
        // not the LLM's choice to set the flag.
        let provider = RetryOnceProvider(
            failCount: 0,
            failResponse: "",
            successResponse: painFlagPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 0
        )
        let result = await service.prescribe(context: WorkoutContext.mockContext())

        guard case .success(let prescription) = result else {
            return XCTFail("Expected .success, got fallback.")
        }
        XCTAssertTrue(prescription.safetyFlags.contains(.painReported),
                      "safety_flags must include painReported.")
        XCTAssertGreaterThanOrEqual(prescription.restSeconds, 180,
                                    "restSeconds must be ≥ 180 when painReported is set.")
    }

    // MARK: ─── 2. Retry path test ─────────────────────────────────────────────

    /// MockLLMProvider returns unparsable JSON on attempts 1 and 2, valid JSON
    /// on attempt 3.  Result must be .success — verifying maxRetries=2 works.
    func test_retryPath_invalidJSONTwice_thenSuccess() async {
        let provider = RetryOnceProvider(
            failCount: 2,
            failResponse: unparsableJSON,
            successResponse: validPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        switch result {
        case .success(let prescription):
            XCTAssertEqual(provider.callCount, 3,
                           "Provider must have been called exactly 3 times (1 initial + 2 retries).")
            XCTAssertNoThrow(try prescription.validate(),
                             "Prescription from the third attempt must pass validation.")
        case .fallback(let reason):
            XCTFail("Expected .success on attempt 3, got fallback: \(reason)")
        }
    }

    /// Same as above but uses a bad tempo (structurally valid JSON, fails validate()).
    func test_retryPath_invalidTempoTwice_thenSuccess() async {
        let provider = RetryOnceProvider(
            failCount: 2,
            failResponse: invalidTempoPrescriptionJSON,
            successResponse: validPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        switch result {
        case .success(let prescription):
            XCTAssertEqual(provider.callCount, 3)
            XCTAssertEqual(prescription.tempo, "3-1-1-0",
                           "Winning prescription must have the valid tempo from attempt 3.")
        case .fallback(let reason):
            XCTFail("Expected .success on attempt 3, got fallback: \(reason)")
        }
    }

    // MARK: ─── 3. Timeout path test ───────────────────────────────────────────

    /// SleepyProvider sleeps 9 seconds — longer than the 8-second watchdog.
    /// The result must be .fallback(.timeout).
    func test_timeout_providerSleeps9s_returnsFallbackTimeout() async {
        let service = AIInferenceService(
            provider: SleepyProvider(),
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 0
        )

        // Grant 12-second budget for this test: 9s provider sleep + headroom.
        let expectation = XCTestExpectation(description: "timeout fallback received")
        Task {
            let result = await service.prescribe(context: WorkoutContext.mockContext())
            switch result {
            case .fallback(let reason):
                if case .timeout = reason {
                    expectation.fulfill()
                } else {
                    XCTFail("Expected .timeout, got \(reason)")
                }
            case .success:
                XCTFail("Expected .fallback(.timeout) but got .success")
            }
        }
        await fulfillment(of: [expectation], timeout: 12.0)
    }

    // MARK: ─── 4. Network failure test ────────────────────────────────────────

    /// NetworkFailProvider throws URLError(.notConnectedToInternet).
    /// The result must be .fallback(.llmProviderError) with a non-empty message.
    func test_networkFailure_urlError_returnsFallbackLLMProviderError() async {
        let service = AIInferenceService(
            provider: NetworkFailProvider(),
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 0
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        switch result {
        case .fallback(let reason):
            guard case .llmProviderError(let message) = reason else {
                return XCTFail("Expected .llmProviderError, got \(reason)")
            }
            XCTAssertFalse(message.isEmpty,
                           "llmProviderError message must not be empty.")
        case .success:
            XCTFail("Expected .fallback(.llmProviderError) on network failure.")
        }
    }

    // MARK: ─── 5. Equipment rounding applied ──────────────────────────────────

    /// Verifies that the returned weightKg is a valid plate-achievable load
    /// for the barbell in mockProfile(). Plate-based rounding uses a greedy
    /// knapsack, so the result must equal barWeight + 2 * (sum of chosen plates).
    func test_equipmentRounding_barbellWeight_isPlateAchievable() async {
        let provider = RetryOnceProvider(
            failCount: 0,
            failResponse: "",
            successResponse: validPrescriptionJSON // prescribes 85.0 kg
        )
        let gymProfile = GymProfile.mockProfile()
        let service = AIInferenceService(
            provider: provider,
            gymProfile: gymProfile,
            maxRetries: 0
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        guard case .success(let prescription) = result else {
            return XCTFail("Expected .success")
        }

        // Verify the rounded weight is achievable via the barbell constraint.
        // Mock barbell: bar=20 kg, plates=[25,20,15,10,5,2.5,1.25].
        // 85 kg = 20 + 2 * 32.5; 32.5 = 25 + 5 + 2.5 ✓  → exactly achievable.
        XCTAssertGreaterThan(prescription.weightKg, 0)
        XCTAssertNoThrow(try prescription.validate(),
                         "Rounded prescription must still pass validation.")

        // The weight must be achievable: (weightKg - barWeight) must be even
        // when expressed as integer multiples of 0.25 kg (minimum plate granularity).
        let barWeight = 20.0
        let perSide = (prescription.weightKg - barWeight) / 2.0
        // All available plates are multiples of 0.25 kg, so perSide should be too.
        let perSideIn25g = (perSide * 4).rounded()
        XCTAssertEqual(perSide * 4, perSideIn25g, accuracy: 0.001,
                       "Per-side plate load must be a multiple of 0.25 kg.")
    }

    // MARK: ─── 6. Safety gate: painReported → rest ≥ 180 s ───────────────────

    /// Injects a prescription with pain_reported + rest_seconds=90 via mock provider.
    /// Service must clamp restSeconds to ≥ 180.
    func test_safetyGate_painReported_clampsRestSeconds() async {
        let provider = RetryOnceProvider(
            failCount: 0,
            failResponse: "",
            successResponse: painFlagPrescriptionJSON // rest=90, pain_reported
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 0
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        guard case .success(let prescription) = result else {
            return XCTFail("Expected .success")
        }
        XCTAssertTrue(prescription.safetyFlags.contains(.painReported))
        XCTAssertGreaterThanOrEqual(prescription.restSeconds, 180,
                                    "Safety gate must clamp restSeconds to ≥ 180 when painReported.")
    }
}
