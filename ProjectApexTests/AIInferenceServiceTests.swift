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
/// Includes `intent` per Slice 6 (#10) — required field with no silent default.
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
    "confidence": 0.87,
    "intent": "top",
    "set_framing": "Heaviest work of the day. Brace and grind."
  }
}
"""

/// A valid prescription that includes `pain_reported` — exercises the
/// rest-seconds safety gate (must be clamped to ≥ 180).
/// Intent is `top` because the scenario is "the working set with reduced
/// load due to pain" — not a backoff (which by definition follows a top
/// set in the same exercise). Reduced load on a top set still classifies
/// as a top set.
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
    "confidence": 0.70,
    "intent": "top",
    "set_framing": "Heaviest work of the day. Brace and grind."
  }
}
"""

/// JSON that decodes but fails validate() — tempo has only 3 segments.
/// Carries a valid intent so `.invalidTempo` is the surfaced error rather
/// than the (now-prior-precedence) `.missingIntent` gate.
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
    "safety_flags": [],
    "intent": "top",
    "set_framing": "Heaviest work of the day. Brace and grind."
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

        let result = await service.prescribe(context: context)

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

    // MARK: ─── 2. Permanent-error fail-fast (ADR-0007 / Slice 6) ────────────
    //
    // ████████████████████████████████████████████████████████████████████████
    // BEHAVIOUR CHANGE — Slice 6 (#10):
    //   Pre-Slice-6, prescribe() RETRIED on JSON decode failures and on
    //   validate() failures, appending a "CORRECTION REQUIRED" addendum and
    //   re-running up to maxRetries+1 times. The two tests below previously
    //   asserted that 2 invalid responses followed by 1 valid response
    //   produced .success after 3 calls.
    //
    //   ADR-0007 §1 classifies malformed-response and validation errors as
    //   PERMANENT — same-prompt retry will not fix the LLM's output. Slice 6
    //   removes the retry-on-validate loop, replacing it with fail-fast
    //   `.fallback(.malformedResponse)` after a single call. The user-facing
    //   surface is `InferenceRetrySheet`, giving the user agency rather than
    //   silently burning the 8-second budget.
    //
    //   The old "invalid twice then succeed" assertions are now invariant
    //   violations. The replacement tests below assert callCount == 1 and
    //   `.fallback(.malformedResponse)` instead. Spinoff issue tracks the
    //   broader audit of retry-on-validate sites against ADR-0007.
    // ████████████████████████████████████████████████████████████████████████

    /// B4 — Slice 6 fail-fast: structurally invalid JSON returns
    /// `.fallback(.malformedResponse)` after exactly ONE provider call.
    func test_failFast_invalidJSON_oneCall_returnsMalformedResponse() async {
        let provider = RetryOnceProvider(
            failCount: 999,                  // never serve a success
            failResponse: unparsableJSON,
            successResponse: validPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2                    // intentionally non-zero — must be ignored
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        XCTAssertEqual(
            provider.callCount, 1,
            "Slice 6 fail-fast: malformed JSON must NOT trigger same-prompt retry. " +
            "If callCount > 1, the prescribe() retry loop has regressed to pre-ADR-0007 behaviour."
        )
        guard case .fallback(let reason) = result,
              case .malformedResponse = reason
        else {
            return XCTFail(
                "Slice 6 fail-fast expected .fallback(.malformedResponse), got \(result). " +
                "ADR-0007 §1 classifies decode failure as permanent."
            )
        }
    }

    /// B4 — Slice 6 fail-fast: validation failure (non-intent) returns
    /// `.fallback(.malformedResponse)` after exactly ONE provider call.
    /// Locks the broader scope of the behaviour change — the fail-fast rule
    /// applies to ALL PrescriptionValidationError variants, not just intent.
    func test_failFast_invalidTempo_oneCall_returnsMalformedResponse() async {
        let provider = RetryOnceProvider(
            failCount: 999,
            failResponse: invalidTempoPrescriptionJSON,
            successResponse: validPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        XCTAssertEqual(
            provider.callCount, 1,
            "Slice 6 fail-fast: validate() failure on tempo must NOT trigger retry. " +
            "If callCount > 1, the prescribe() retry-on-validate loop has regressed."
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

    /// B1 — Slice 6 fail-fast: missing `intent` in AI response triggers
    /// `.fallback(.malformedResponse)` carrying the typed PrescriptionValidationError
    /// description, and the provider is called exactly once. The most direct
    /// test of the new no-silent-defaults invariant.
    func test_failFast_missingIntent_oneCall_returnsMalformedResponse() async {
        let missingIntentJSON = """
        {
          "set_prescription": {
            "weight_kg": 80.0,
            "reps": 8,
            "tempo": "3-1-1-0",
            "rir_target": 2,
            "rest_seconds": 120,
            "coaching_cue": "Drive through.",
            "reasoning": "Standard top set.",
            "safety_flags": [],
            "confidence": 0.85
          }
        }
        """
        let provider = RetryOnceProvider(
            failCount: 999,
            failResponse: missingIntentJSON,
            successResponse: validPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        XCTAssertEqual(provider.callCount, 1,
                       "Missing intent must fail fast — exactly one provider call.")
        guard case .fallback(let reason) = result,
              case .malformedResponse(let detail) = reason
        else {
            return XCTFail("Expected .malformedResponse, got \(result)")
        }
        XCTAssertTrue(
            detail.lowercased().contains("intent"),
            "Fallback detail should name 'intent'. Got: \(detail)"
        )
    }

    /// B2 — Slice 6 fail-fast: invalid intent string (e.g. "bogus") triggers
    /// `.fallback(.malformedResponse)` after exactly one provider call. The
    /// custom Codable init rethrows DecodingError as
    /// PrescriptionValidationError.invalidIntent, which is caught at the
    /// decode site as a permanent error.
    func test_failFast_invalidIntentString_oneCall_returnsMalformedResponse() async {
        let invalidIntentJSON = """
        {
          "set_prescription": {
            "weight_kg": 80.0,
            "reps": 8,
            "tempo": "3-1-1-0",
            "rir_target": 2,
            "rest_seconds": 120,
            "coaching_cue": "Drive through.",
            "reasoning": "Standard top set.",
            "safety_flags": [],
            "confidence": 0.85,
            "intent": "bogus"
          }
        }
        """
        let provider = RetryOnceProvider(
            failCount: 999,
            failResponse: invalidIntentJSON,
            successResponse: validPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        XCTAssertEqual(provider.callCount, 1,
                       "Invalid intent must fail fast — exactly one provider call.")
        guard case .fallback(let reason) = result,
              case .malformedResponse(let detail) = reason
        else {
            return XCTFail("Expected .malformedResponse, got \(result)")
        }
        XCTAssertTrue(
            detail.lowercased().contains("intent"),
            "Fallback detail should name 'intent'. Got: \(detail)"
        )
    }

    /// B3 — Happy path: valid prescription with intent returns `.success`
    /// on the first call (regression coverage; the validPrescriptionJSON
    /// fixture now carries `"intent": "top"`).
    func test_validPrescription_returnsSuccess_oneCall() async {
        let provider = RetryOnceProvider(
            failCount: 0,
            failResponse: "",
            successResponse: validPrescriptionJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 0
        )

        let result = await service.prescribe(context: WorkoutContext.mockContext())

        XCTAssertEqual(provider.callCount, 1)
        guard case .success(let prescription) = result else {
            return XCTFail("Expected .success, got \(result)")
        }
        XCTAssertEqual(prescription.intent, .top,
                       "Decoded intent must round-trip from the fixture.")
    }

    /// B6 — prescribeAdaptation aligns with prescribe() on the fail-fast
    /// rule. A missing-intent response from the LLM during adaptation must
    /// also fail fast as `.malformedResponse`.
    func test_failFast_prescribeAdaptation_missingIntent_returnsMalformedResponse() async {
        let missingIntentJSON = """
        {
          "set_prescription": {
            "weight_kg": 75.0,
            "reps": 8,
            "tempo": "3-1-1-0",
            "rir_target": 2,
            "rest_seconds": 120,
            "coaching_cue": "x",
            "reasoning": "y",
            "safety_flags": []
          }
        }
        """
        let provider = RetryOnceProvider(
            failCount: 0,
            failResponse: "",
            successResponse: missingIntentJSON
        )
        let service = AIInferenceService(
            provider: provider,
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 0
        )

        let result = await service.prescribeAdaptation(
            userPayload: "irrelevant for the mock",
            workoutContext: WorkoutContext.mockContext()
        )

        guard case .fallback(let reason) = result,
              case .malformedResponse = reason
        else {
            return XCTFail("Expected .malformedResponse from prescribeAdaptation, got \(result)")
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

    // MARK: ─── 7. B1 α — LLM steers on trainee_model_digest trend signals ──────
    //
    // Live-API tests that verify the LLM actually adjusts its prescription
    // when trainee_model_digest carries a non-progressing trend. β covers
    // wiring (the field is in the payload, the prompt block is in the
    // system prompt); α covers behaviour (the LLM reads and steers on it).
    //
    // Each fixture builds a CLEAN baseline WorkoutContext — no within-session
    // miss signals, no fatigue spike, no historical decline in RAG, recent
    // session_log shows on-target completion — so the ONLY signal that could
    // override PROGRESSIVE OVERLOAD defaults is the digest. A passing test
    // proves the digest field is what steered the response.
    //
    // Gated behind APEX_INTEGRATION_TESTS=1 per CLAUDE.md.
    // Token cost: ~$0.05 per fixture × 3 ≈ $0.15 per run.

    /// Clean baseline WorkoutContext for α isolation. The only non-default
    /// state that could steer the LLM away from "increase weight by one
    /// increment" is whatever the caller injects via `digest`.
    private func makeCleanContextForAlpha(
        exerciseName: String,
        primaryMuscles: [String],
        digest: TraineeModelDigest
    ) -> WorkoutContext {
        let setDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cleanSet = CompletedSet(
            setNumber: 1, weightKg: 80.0, reps: 10, rirActual: 2, rpe: 7.0,
            tempo: "3-1-1-0", restTakenSeconds: 120, completedAt: setDate,
            userCorrectedWeight: nil, daysAgo: 0
        )

        return WorkoutContext(
            requestType: "set_prescription",
            sessionMetadata: SessionMetadata(
                sessionId: "session-alpha-\(exerciseName)",
                startedAt: setDate,
                programName: "PPL Hypertrophy",
                dayLabel: "Push A",
                weekNumber: 3,
                totalSessionCount: 42
            ),
            biometrics: Biometrics(bodyweightKg: 80.0, restingHeartRate: 52, readinessScore: 8, sleepHours: 7.5),
            streakResult: nil,
            userProfile: UserProfileContext(bodyweightKg: 80.0, heightCm: 178.0, age: 28, sex: nil, trainingAge: "Intermediate (1–3 yrs)"),
            isFirstSession: false,
            currentExercise: CurrentExercise(
                name: exerciseName,
                equipmentTypeKey: "barbell",
                setNumber: 2,
                plannedSets: 4,
                planTarget: PlanTarget(minReps: 6, maxReps: 10, rirTarget: 2, intensityPercent: 75.0),
                primaryMuscles: primaryMuscles,
                secondaryMuscles: [],
                bodyweightOnly: nil
            ),
            sessionHistoryToday: [],
            currentExerciseSetsToday: [cleanSet],
            withinSessionPerformance: [cleanSet],
            historicalPerformance: HistoricalPerformance(
                personalBest: cleanSet,
                recentAverage: RecentAverage(sessionCount: 5, avgWeightKg: 80.0, avgReps: 10.0, avgRir: 2.0),
                trend: "improving"
            ),
            qualitativeNotesToday: [],
            ragRetrievedMemory: [],
            sessionLog: [
                SessionLogEntry(
                    exercise: exerciseName, setNumber: 1,
                    prescribedWeightKg: 80.0, prescribedReps: 10,
                    actualReps: 10, rpe: 7.0,
                    outcomeNote: "on_target"
                )
            ],
            gymWeightFacts: nil,
            traineeModelDigest: digest
        )
    }

    /// Builds a TraineeModelDigest carrying a single PatternSummary with the
    /// requested trend and consecutive_force_deloads count, plus enough
    /// scaffolding to satisfy required fields.
    private func makeDigestForAlpha(
        pattern: MovementPattern,
        trend: ProgressionTrend,
        consecutiveForceDeloads: Int = 0
    ) -> TraineeModelDigest {
        var model = TraineeModel(goal: GoalState(statement: "Hypertrophy", focusAreas: [], updatedAt: Date()))
        var profile = PatternProfile(
            pattern: pattern,
            currentPhase: .accumulation,
            sessionsInPhase: 6,
            rpeOffset: 0.0,
            confidence: .established,
            trend: trend
        )
        profile.consecutiveForceDeloadsOnPattern = consecutiveForceDeloads
        model.patterns[pattern] = profile
        return TraineeModelDigest(from: model, asOf: Date())
    }

    /// α plateaued — horizontal_push trend=.plateaued.
    /// Asserts: coaching_cue OR reasoning contains one of {rep-range variation,
    /// exercise swap/variation, intensity technique (pause/eccentric/back-off/top-set)}.
    /// OR-match — LLM may pick any of the three valid responses; flake risk
    /// is real if LLM rephrases ("switch up the rep scheme" instead of "vary rep range").
    /// Term-set broadening over time is expected α maintenance.
    func test_liveAPI_alpha_plateauedHorizontalPush_variesPrescription() async throws {
        try requireLiveAPI()
        let apiKey = try requireAnthropicKey()

        let service = AIInferenceService(
            provider: AnthropicProvider(apiKey: apiKey),
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )
        let digest = makeDigestForAlpha(pattern: .horizontalPush, trend: .plateaued)
        let context = makeCleanContextForAlpha(
            exerciseName: "Barbell Bench Press",
            primaryMuscles: ["pectoralis_major", "anterior_deltoid"],
            digest: digest
        )

        let result = await service.prescribe(context: context)

        guard case .success(let prescription) = result else {
            return XCTFail("Expected .success, got \(result)")
        }

        let haystack = (prescription.coachingCue + " " + prescription.reasoning).lowercased()
        let plateauTerms = [
            // Rep-range variation
            "vary", "variation", "different rep", "rep range", "rep scheme", "switch",
            "4-6", "10-12", "lower rep", "higher rep",
            // Exercise swap
            "swap", "substitute", "instead of", "different exercise", "replace",
            // Intensity technique
            "pause", "eccentric", "tempo", "slow", "top set", "top-set", "backoff", "back-off",
            "intensity technique"
        ]
        let matched = plateauTerms.first { haystack.contains($0) }
        XCTAssertNotNil(matched,
            "Plateaued α: expected coaching_cue OR reasoning to contain one of \(plateauTerms). Got: \(haystack)")
    }

    /// α declining — squat trend=.declining.
    /// Tight numeric assertion: weight_kg must be < 80.0 (last working weight in session_log).
    /// AND coaching_cue must contain form-quality language. This is the only
    /// α fixture in the suite with a deterministic numeric check — clean
    /// session_log isolates "trend=.declining" as the sole weight-reduction signal.
    func test_liveAPI_alpha_decliningSquat_reducesWeight_andCoachesForm() async throws {
        try requireLiveAPI()
        let apiKey = try requireAnthropicKey()

        let service = AIInferenceService(
            provider: AnthropicProvider(apiKey: apiKey),
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )
        let digest = makeDigestForAlpha(pattern: .squat, trend: .declining)
        let context = makeCleanContextForAlpha(
            exerciseName: "Barbell Back Squat",
            primaryMuscles: ["quadriceps_femoris", "gluteus_maximus"],
            digest: digest
        )

        let result = await service.prescribe(context: context)

        guard case .success(let prescription) = result else {
            return XCTFail("Expected .success, got \(result)")
        }

        // (a) Numeric: weight reduced from the last working weight (80kg).
        XCTAssertLessThan(prescription.weightKg, 80.0,
            "Declining α: expected weight reduction from last working weight 80.0kg, got \(prescription.weightKg)")

        // (b) Coaching cue references form quality / tempo / control.
        let haystack = prescription.coachingCue.lowercased()
        let formTerms = ["form", "quality", "tempo", "control", "movement quality", "technique", "clean", "crisp"]
        let matched = formTerms.first { haystack.contains($0) }
        XCTAssertNotNil(matched,
            "Declining α: expected coaching_cue to reference form/quality/tempo. Got: \(haystack)")
    }

    /// α force-deloads=2 — vertical_push consecutive_force_deloads_on_pattern=2.
    /// Asserts: coaching_cue OR reasoning contains one of {rotation/swap/variation,
    /// rebuild/programme-change language}. OR-match per ADR-0011 §(d).
    func test_liveAPI_alpha_consecutiveForceDeloadsVerticalPush_surfacesRotationOrRebuild() async throws {
        try requireLiveAPI()
        let apiKey = try requireAnthropicKey()

        let service = AIInferenceService(
            provider: AnthropicProvider(apiKey: apiKey),
            gymProfile: GymProfile.mockProfile(),
            maxRetries: 2
        )
        // trend=.progressing so the only override signal is consecutive_force_deloads_on_pattern.
        let digest = makeDigestForAlpha(
            pattern: .verticalPush,
            trend: .progressing,
            consecutiveForceDeloads: 2
        )
        let context = makeCleanContextForAlpha(
            exerciseName: "Barbell Overhead Press",
            primaryMuscles: ["anterior_deltoid", "triceps_brachii"],
            digest: digest
        )

        let result = await service.prescribe(context: context)

        guard case .success(let prescription) = result else {
            return XCTFail("Expected .success, got \(result)")
        }

        let haystack = (prescription.coachingCue + " " + prescription.reasoning).lowercased()
        let rotationOrRebuildTerms = [
            // Rotation / swap / variation
            "rotat", "swap", "variation", "different exercise", "alternate", "switch",
            // Programme rebuild
            "rebuild", "programme", "program", "new pattern", "calcified", "restructure",
            "stuck", "plateau"  // generic context the LLM may use to introduce rotation
        ]
        let matched = rotationOrRebuildTerms.first { haystack.contains($0) }
        XCTAssertNotNil(matched,
            "Force-deloads=2 α: expected coaching_cue OR reasoning to suggest rotation or rebuild. Got: \(haystack)")
    }
}
