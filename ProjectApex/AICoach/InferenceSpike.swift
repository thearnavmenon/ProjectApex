// InferenceSpike.swift
// ProjectApex — AI Integration Spike (P0-T03)
//
// Purpose: Validates the full AnthropicProvider → AIInferenceService →
//   SetPrescription pipeline against the live Anthropic API.
//
// This file is NOT production code. It is a developer spike that:
//   1. Loads the system prompt from the bundle resource.
//   2. Reads the Anthropic API key from the Keychain.
//   3. Constructs a minimal, hand-crafted WorkoutContext.
//   4. Calls AIInferenceService.prescribe() and prints the result.
//
// Usage (call from a debug button or Swift Playgrounds):
//   await InferenceSpike.run()
//
// Expected console output:
//   [Spike] System prompt loaded (N chars)
//   [Spike] API key retrieved from Keychain ✓
//   [Spike] Sending WorkoutContext to Anthropic…
//   [Spike] Raw response received in X.XXs
//   [Spike] ✅ SetPrescription validated & rounded:
//   [Spike]   weight_kg:      XX.X
//   [Spike]   reps:           X
//   [Spike]   tempo:          X-X-X-X
//   [Spike]   rir_target:     X
//   [Spike]   rest_seconds:   XXX
//   [Spike]   coaching_cue:   "…"
//   [Spike]   reasoning:      "…"
//   [Spike]   safety_flags:   []
//   [Spike]   confidence:     0.XX
//   [Spike]   wasAdjusted:    false/true
//   [Spike]   adjustmentNote: …

import Foundation

// MARK: - InferenceSpike

/// End-to-end spike runner. Call `InferenceSpike.run()` from a debug context.
enum InferenceSpike {

    // MARK: - Public entry point

    /// Runs the full inference spike and prints all results to the console.
    ///
    /// - Returns: The `PrescriptionResult` from the live API call, so callers
    ///   can assert on it in integration tests.
    @discardableResult
    static func run() async -> PrescriptionResult {
        let tag = "[Spike]"

        // 1. Load system prompt from bundle resource.
        let systemPrompt: String
        do {
            systemPrompt = try loadSystemPrompt()
            print("\(tag) System prompt loaded (\(systemPrompt.count) chars)")
        } catch {
            print("\(tag) ❌ Failed to load system prompt: \(error)")
            return .fallback(reason: .encodingFailed("System prompt missing from bundle."))
        }

        // 2. Retrieve API key from Keychain.
        let apiKey: String
        do {
            guard let key = try KeychainService.shared.retrieve(.anthropicAPIKey) else {
                print("\(tag) ❌ No Anthropic API key in Keychain.")
                print("\(tag)    → Open Settings → Developer Settings and paste your key.")
                return .fallback(reason: .llmProviderError("No Anthropic API key stored in Keychain."))
            }
            apiKey = key
            print("\(tag) API key retrieved from Keychain ✓")
        } catch {
            print("\(tag) ❌ Keychain error: \(error.localizedDescription)")
            return .fallback(reason: .llmProviderError(error.localizedDescription))
        }

        // 3. Build the provider and service.
        let provider = AnthropicProvider(apiKey: apiKey)
        let service = AIInferenceService(
            provider: provider,
            maxRetries: 2
        )

        // 4. Hand-craft a minimal WorkoutContext.
        let context = minimalWorkoutContext()

        // 5. Call the service and time the round-trip.
        print("\(tag) Sending WorkoutContext to Anthropic…")
        let start = Date()
        let result = await service.prescribe(context: context)
        let elapsed = Date().timeIntervalSince(start)
        print("\(tag) Round-trip completed in \(String(format: "%.2f", elapsed))s")

        // 6. Print result details.
        switch result {
        case .success(let prescription):
            print("\(tag) ✅ SetPrescription:")
            print("\(tag)   weight_kg:    \(prescription.weightKg)")
            print("\(tag)   reps:         \(prescription.reps)")
            print("\(tag)   tempo:        \(prescription.tempo)")
            print("\(tag)   rir_target:   \(prescription.rirTarget)")
            print("\(tag)   rest_seconds: \(prescription.restSeconds)")
            print("\(tag)   coaching_cue: \"\(prescription.coachingCue)\"")
            print("\(tag)   reasoning:    \"\(prescription.reasoning)\"")
            print("\(tag)   safety_flags: \(prescription.safetyFlags.map(\.rawValue))")
            if let c = prescription.confidence {
                print("\(tag)   confidence:   \(String(format: "%.2f", c))")
            }

        case .fallback(let reason):
            switch reason {
            case .timeout:
                print("\(tag) ❌ Fallback: timeout (> 8 s)")
            case .maxRetriesExceeded(let lastError):
                print("\(tag) ❌ Fallback: max retries exceeded — \(lastError)")
            case .llmProviderError(let msg):
                print("\(tag) ❌ Fallback: LLM provider error — \(msg)")
            case .encodingFailed(let msg):
                print("\(tag) ❌ Fallback: encoding failed — \(msg)")
            }
        }

        return result
    }

    // MARK: - Helpers

    /// Loads `SystemPrompt_Inference.txt` from the main bundle.
    static func loadSystemPrompt() throws -> String {
        guard let url = Bundle.main.url(
            forResource: "SystemPrompt_Inference",
            withExtension: "txt",
            subdirectory: "Prompts"
        ) ?? Bundle.main.url(
            forResource: "SystemPrompt_Inference",
            withExtension: "txt"
        ) else {
            throw SystemPromptError.fileNotFound
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    enum SystemPromptError: LocalizedError {
        case fileNotFound
        var errorDescription: String? {
            "SystemPrompt_Inference.txt not found in the app bundle. " +
            "Ensure the file is added to the target's Copy Bundle Resources build phase."
        }
    }

    /// Constructs the minimal `WorkoutContext` used for the spike.
    ///
    /// Values are representative of a mid-program intermediate lifter on a
    /// Push day — sufficient to produce a sensible prescription from the LLM.
    static func minimalWorkoutContext() -> WorkoutContext {
        let sessionId = UUID().uuidString
        let now = Date()

        return WorkoutContext(
            requestType: "set_prescription",
            sessionMetadata: SessionMetadata(
                sessionId: sessionId,
                startedAt: now,
                programName: "PPL Hypertrophy",
                dayLabel: "Push A",
                weekNumber: 4,
                totalSessionCount: 22
            ),
            biometrics: Biometrics(
                bodyweightKg: 82.0,
                restingHeartRate: 58,
                readinessScore: 7,
                sleepHours: 7.5
            ),
            currentExercise: CurrentExercise(
                name: "Barbell Bench Press",
                equipmentTypeKey: "barbell",
                setNumber: 2,
                plannedSets: 4,
                planTarget: PlanTarget(
                    minReps: 6,
                    maxReps: 8,
                    rirTarget: 2,
                    intensityPercent: nil
                ),
                primaryMuscles: ["pectoralis_major", "anterior_deltoid"],
                secondaryMuscles: ["triceps_brachii"]
            ),
            sessionHistoryToday: [],
            currentExerciseSetsToday: [
                CompletedSet(
                    setNumber: 1,
                    weightKg: 85.0,
                    reps: 7,
                    rirActual: 2,
                    rpe: 8.0,
                    tempo: "3-1-1-0",
                    restTakenSeconds: 150,
                    completedAt: now
                )
            ],
            historicalPerformance: HistoricalPerformance(
                personalBest: CompletedSet(
                    setNumber: 1,
                    weightKg: 95.0,
                    reps: 5,
                    rirActual: 1,
                    rpe: 9.0,
                    tempo: "3-0-1-0",
                    restTakenSeconds: 180,
                    completedAt: nil
                ),
                recentAverage: RecentAverage(
                    sessionCount: 4,
                    avgWeightKg: 82.5,
                    avgReps: 7.2,
                    avgRir: 2.1
                ),
                trend: "improving"
            ),
            qualitativeNotesToday: [],
            ragRetrievedMemory: []
        )
    }
}
