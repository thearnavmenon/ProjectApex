// AIInferenceService.swift
// ProjectApex — AICoach Feature
//
// Orchestrates the full "set prescription" inference pipeline:
//   WorkoutContext → JSON → LLM → SetPrescription → caller
//
// Key design decisions:
//   • Swift actor for safe concurrent LLM calls (no data races on callCount, etc.)
//   • 8-second per-call timeout enforced via Task.detached + withTaskCancellationHandler
//   • Retries up to `maxRetries` times on decode / validation failure, appending
//     the previous error to the follow-up prompt for in-context correction.
//   • Safety gate: if safetyFlags contains .painReported, rest is raised to ≥180 s.
//   • Weight rounding is NOT done here — the GymFactStore + WeightCorrectionView
//     handle unavailable weights at runtime during active sets.
//
// ISOLATION NOTE:
// All DTO types (WorkoutContext, SetPrescription, …) are `nonisolated` to opt
// out of the target-wide SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor. This keeps
// their synthesised Codable conformances callable from this background actor.

import Foundation

// MARK: ─── WorkoutContext ────────────────────────────────────────────────────

nonisolated struct WorkoutContext: Codable, Sendable {
    let requestType: String           // always "set_prescription"
    let sessionMetadata: SessionMetadata
    let biometrics: Biometrics?
    let currentExercise: CurrentExercise
    let sessionHistoryToday: [ExerciseHistoryItem]
    let currentExerciseSetsToday: [CompletedSet]
    let historicalPerformance: HistoricalPerformance?
    let qualitativeNotesToday: [QualitativeNote]
    let ragRetrievedMemory: [RAGMemoryItem]

    enum CodingKeys: String, CodingKey {
        case requestType                = "request_type"
        case sessionMetadata            = "session_metadata"
        case biometrics
        case currentExercise            = "current_exercise"
        case sessionHistoryToday        = "session_history_today"
        case currentExerciseSetsToday   = "current_exercise_sets_today"
        case historicalPerformance      = "historical_performance"
        case qualitativeNotesToday      = "qualitative_notes_today"
        case ragRetrievedMemory         = "rag_retrieved_memory"
    }
}

// MARK: SessionMetadata

nonisolated struct SessionMetadata: Codable, Sendable {
    /// UUID string for the current workout session.
    let sessionId: String
    /// ISO 8601 timestamp the session started.
    let startedAt: Date
    /// User's training program name, e.g. "PPL Hypertrophy".
    let programName: String?
    /// E.g. "Push A", "Pull B".
    let dayLabel: String?
    /// 1-based week number within the current program block.
    let weekNumber: Int?
    /// Sequential session count since the user started using the app.
    let totalSessionCount: Int

    enum CodingKeys: String, CodingKey {
        case sessionId        = "session_id"
        case startedAt        = "started_at"
        case programName      = "program_name"
        case dayLabel         = "day_label"
        case weekNumber       = "week_number"
        case totalSessionCount = "total_session_count"
    }
}

// MARK: Biometrics

nonisolated struct Biometrics: Codable, Sendable {
    let bodyweightKg: Double?
    /// Resting heart rate in bpm, e.g. from HealthKit.
    let restingHeartRate: Int?
    /// Subjective readiness score 1–10.
    let readinessScore: Int?
    /// Hours of sleep last night.
    let sleepHours: Double?

    enum CodingKeys: String, CodingKey {
        case bodyweightKg      = "bodyweight_kg"
        case restingHeartRate  = "resting_heart_rate"
        case readinessScore    = "readiness_score"
        case sleepHours        = "sleep_hours"
    }
}

// MARK: CurrentExercise

nonisolated struct CurrentExercise: Codable, Sendable {
    /// Canonical exercise name, e.g. "Barbell Bench Press".
    let name: String
    /// Snake-case equipment type key matching EquipmentType, e.g. "barbell".
    let equipmentTypeKey: String
    /// Set number being prescribed (1-based).
    let setNumber: Int
    /// Total sets planned for this exercise.
    let plannedSets: Int
    /// Rep target from the training plan.
    let planTarget: PlanTarget?
    /// Primary muscle groups, e.g. ["pectoralis_major", "anterior_deltoid"].
    let primaryMuscles: [String]
    /// Secondary muscle groups.
    let secondaryMuscles: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case equipmentTypeKey  = "equipment_type_key"
        case setNumber         = "set_number"
        case plannedSets       = "planned_sets"
        case planTarget        = "plan_target"
        case primaryMuscles    = "primary_muscles"
        case secondaryMuscles  = "secondary_muscles"
    }
}

// MARK: PlanTarget

nonisolated struct PlanTarget: Codable, Sendable {
    let minReps: Int
    let maxReps: Int
    /// Reps-in-reserve target from the plan, e.g. 1–2.
    let rirTarget: Int?
    /// Intensity as % of 1RM if the plan uses percentage-based loading.
    let intensityPercent: Double?

    enum CodingKeys: String, CodingKey {
        case minReps          = "min_reps"
        case maxReps          = "max_reps"
        case rirTarget        = "rir_target"
        case intensityPercent = "intensity_percent"
    }
}

// MARK: ExerciseHistoryItem

nonisolated struct ExerciseHistoryItem: Codable, Sendable {
    let exerciseName: String
    let sets: [CompletedSet]

    enum CodingKeys: String, CodingKey {
        case exerciseName = "exercise_name"
        case sets
    }
}

// MARK: CompletedSet

nonisolated struct CompletedSet: Codable, Sendable {
    let setNumber: Int
    let weightKg: Double
    let reps: Int
    /// Actual reps-in-reserve reported by the user post-set.
    let rirActual: Int?
    /// Subjective RPE 1–10.
    let rpe: Double?
    let tempo: String?
    let restTakenSeconds: Int?
    /// ISO 8601 timestamp the set was logged.
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case setNumber          = "set_number"
        case weightKg           = "weight_kg"
        case reps
        case rirActual          = "rir_actual"
        case rpe
        case tempo
        case restTakenSeconds   = "rest_taken_seconds"
        case completedAt        = "completed_at"
    }
}

// MARK: HistoricalPerformance

nonisolated struct HistoricalPerformance: Codable, Sendable {
    /// Best single set performance for this exercise across all time.
    let personalBest: CompletedSet?
    /// Performance stats averaged over the last N sessions.
    let recentAverage: RecentAverage?
    /// Trend direction: "improving", "plateauing", "declining".
    let trend: String?

    enum CodingKeys: String, CodingKey {
        case personalBest   = "personal_best"
        case recentAverage  = "recent_average"
        case trend
    }
}

nonisolated struct RecentAverage: Codable, Sendable {
    let sessionCount: Int
    let avgWeightKg: Double
    let avgReps: Double
    let avgRir: Double?

    enum CodingKeys: String, CodingKey {
        case sessionCount = "session_count"
        case avgWeightKg  = "avg_weight_kg"
        case avgReps      = "avg_reps"
        case avgRir       = "avg_rir"
    }
}

// MARK: QualitativeNote

nonisolated struct QualitativeNote: Codable, Sendable {
    /// Category: "pain", "energy", "motivation", "general", etc.
    let category: String
    let text: String
    let loggedAt: Date

    enum CodingKeys: String, CodingKey {
        case category
        case text
        case loggedAt = "logged_at"
    }
}

// MARK: RAGMemoryItem

nonisolated struct RAGMemoryItem: Codable, Sendable {
    /// Similarity score (0–1) from the vector search.
    let relevanceScore: Double
    let summary: String
    let sourceDate: Date?

    enum CodingKeys: String, CodingKey {
        case relevanceScore = "relevance_score"
        case summary
        case sourceDate     = "source_date"
    }
}

// MARK: ─── SetPrescription ───────────────────────────────────────────────────

nonisolated struct SetPrescription: Codable, Sendable {
    var weightKg: Double
    var reps: Int
    /// Eccentric-pause-concentric-pause tempo string, e.g. "3-1-1-0".
    var tempo: String
    var rirTarget: Int
    var restSeconds: Int
    /// Short coaching instruction ≤100 chars.
    var coachingCue: String
    /// Brief reasoning for this prescription ≤200 chars.
    var reasoning: String
    var safetyFlags: [SafetyFlag]
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case weightKg      = "weight_kg"
        case reps
        case tempo
        case rirTarget     = "rir_target"
        case restSeconds   = "rest_seconds"
        case coachingCue   = "coaching_cue"
        case reasoning
        case safetyFlags   = "safety_flags"
        case confidence
    }
}

// MARK: SafetyFlag

nonisolated enum SafetyFlag: String, Codable, Sendable {
    case shoulderCaution      = "shoulder_caution"
    case jointConcern         = "joint_concern"
    case fatigueHigh          = "fatigue_high"
    case painReported         = "pain_reported"
    case deloadRecommended    = "deload_recommended"
}

// MARK: Validation

nonisolated enum PrescriptionValidationError: LocalizedError {
    case invalidWeight(Double)
    case invalidReps(Int)
    case invalidTempo(String)
    case invalidRestSeconds(Int)
    case coachingCueTooLong(Int)
    case reasoningTooLong(Int)
    case confidenceOutOfRange(Double)

    var errorDescription: String? {
        switch self {
        case .invalidWeight(let v):
            return "weightKg \(v) is out of range (must be > 0 and ≤ 500)."
        case .invalidReps(let v):
            return "reps \(v) is out of range (must be 1–30)."
        case .invalidTempo(let v):
            return "tempo '\(v)' does not match required format ^\\d-\\d-\\d-\\d$."
        case .invalidRestSeconds(let v):
            return "restSeconds \(v) is out of range (must be 30–600)."
        case .coachingCueTooLong(let v):
            return "coachingCue is \(v) chars (max 100)."
        case .reasoningTooLong(let v):
            return "reasoning is \(v) chars (max 200)."
        case .confidenceOutOfRange(let v):
            return "confidence \(v) is outside 0.0...1.0."
        }
    }
}

extension SetPrescription {
    // Compiled once at file scope to avoid repeated regex construction.
    private nonisolated static let tempoRegex = try! NSRegularExpression(pattern: #"^\d-\d-\d-\d$"#)

    nonisolated func validate() throws {
        guard weightKg > 0, weightKg <= 500 else {
            throw PrescriptionValidationError.invalidWeight(weightKg)
        }
        guard (1...30).contains(reps) else {
            throw PrescriptionValidationError.invalidReps(reps)
        }
        let range = NSRange(tempo.startIndex..., in: tempo)
        guard SetPrescription.tempoRegex.firstMatch(in: tempo, range: range) != nil else {
            throw PrescriptionValidationError.invalidTempo(tempo)
        }
        guard (30...600).contains(restSeconds) else {
            throw PrescriptionValidationError.invalidRestSeconds(restSeconds)
        }
        guard coachingCue.count <= 100 else {
            throw PrescriptionValidationError.coachingCueTooLong(coachingCue.count)
        }
        guard reasoning.count <= 200 else {
            throw PrescriptionValidationError.reasoningTooLong(reasoning.count)
        }
        if let c = confidence {
            guard (0.0...1.0).contains(c) else {
                throw PrescriptionValidationError.confidenceOutOfRange(c)
            }
        }
    }
}

// MARK: ─── PrescriptionResult ────────────────────────────────────────────────

nonisolated enum FallbackReason: Sendable {
    case timeout
    case maxRetriesExceeded(lastError: String)
    case llmProviderError(String)
    case encodingFailed(String)
}

nonisolated enum PrescriptionResult: Sendable {
    case success(SetPrescription)
    case fallback(reason: FallbackReason)
}

// MARK: ─── WorkoutContext Mock ───────────────────────────────────────────────

extension WorkoutContext {
    /// Returns a fully populated `WorkoutContext` suitable for tests and previews.
    /// Every optional field is non-nil so that round-trip tests exercise all paths.
    nonisolated static func mockContext() -> WorkoutContext {
        let setDate = Date(timeIntervalSince1970: 1_700_000_000)

        let completedSet = CompletedSet(
            setNumber: 1,
            weightKg: 80.0,
            reps: 8,
            rirActual: 2,
            rpe: 7.5,
            tempo: "3-1-1-0",
            restTakenSeconds: 120,
            completedAt: setDate
        )

        return WorkoutContext(
            requestType: "set_prescription",
            sessionMetadata: SessionMetadata(
                sessionId: "session-mock-001",
                startedAt: setDate,
                programName: "PPL Hypertrophy",
                dayLabel: "Push A",
                weekNumber: 3,
                totalSessionCount: 42
            ),
            biometrics: Biometrics(
                bodyweightKg: 80.0,
                restingHeartRate: 52,
                readinessScore: 8,
                sleepHours: 7.5
            ),
            currentExercise: CurrentExercise(
                name: "Barbell Bench Press",
                equipmentTypeKey: "barbell",
                setNumber: 2,
                plannedSets: 4,
                planTarget: PlanTarget(
                    minReps: 6,
                    maxReps: 10,
                    rirTarget: 2,
                    intensityPercent: 75.0
                ),
                primaryMuscles: ["pectoralis_major", "anterior_deltoid"],
                secondaryMuscles: ["triceps_brachii"]
            ),
            sessionHistoryToday: [
                ExerciseHistoryItem(
                    exerciseName: "Overhead Press",
                    sets: [completedSet]
                )
            ],
            currentExerciseSetsToday: [completedSet],
            historicalPerformance: HistoricalPerformance(
                personalBest: CompletedSet(
                    setNumber: 1,
                    weightKg: 100.0,
                    reps: 5,
                    rirActual: 0,
                    rpe: 9.5,
                    tempo: "2-0-1-0",
                    restTakenSeconds: 180,
                    completedAt: setDate
                ),
                recentAverage: RecentAverage(
                    sessionCount: 5,
                    avgWeightKg: 82.5,
                    avgReps: 8.2,
                    avgRir: 1.8
                ),
                trend: "improving"
            ),
            qualitativeNotesToday: [
                QualitativeNote(
                    category: "energy",
                    text: "Feeling strong today, slept well.",
                    loggedAt: setDate
                )
            ],
            ragRetrievedMemory: [
                RAGMemoryItem(
                    relevanceScore: 0.91,
                    summary: "Last week bench felt heavy; reduced weight by 5 kg.",
                    sourceDate: setDate
                )
            ]
        )
    }
}

// MARK: ─── AIInferenceService ────────────────────────────────────────────────

/// Orchestrates the full set-prescription pipeline.
///
/// Usage:
/// ```swift
/// let service = AIInferenceService(
///     provider: AnthropicProvider(apiKey: "sk-…"),
///     gymProfile: loadedProfile
/// )
/// let result = await service.prescribe(context: ctx)
/// ```
actor AIInferenceService {

    // MARK: Dependencies

    private let provider: any LLMProvider
    let maxRetries: Int

    // MARK: Init

    init(
        provider: any LLMProvider,
        maxRetries: Int = 2
    ) {
        self.provider = provider
        self.maxRetries = maxRetries
    }

    // MARK: Public API

    /// Produces a `SetPrescription` for the given `WorkoutContext`.
    /// Retries up to `maxRetries` times on validation failure before returning
    /// a `.fallback` result.
    func prescribe(context: WorkoutContext) async -> PrescriptionResult {

        // 1. Encode context to JSON (user payload for the LLM)
        // Construct encoder inline to avoid accessing the @MainActor-isolated
        // JSONEncoder.gymProfile static property from this background actor.
        let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            return e
        }()
        guard let contextData = try? encoder.encode(context),
              let contextJSON = String(data: contextData, encoding: .utf8)
        else {
            return .fallback(reason: .encodingFailed("Failed to encode WorkoutContext to JSON."))
        }

        let systemPrompt = Self.systemPrompt
        var userPayload = contextJSON
        var lastErrorDescription: String = ""

        for attempt in 0...maxRetries {
            // Append correction instruction on retries
            if attempt > 0 {
                userPayload = """
                    \(contextJSON)

                    --- CORRECTION REQUIRED ---
                    Your previous response failed validation with this error:
                    \(lastErrorDescription)
                    Please fix the issue and return only the corrected JSON object.
                    """
            }

            // 2. Call LLM with 8-second timeout
            // Snapshot `userPayload` into an immutable let so the closure
            // captures a value rather than a mutable variable (Swift 6 safety).
            let payloadSnapshot = userPayload
            let rawResponse: String
            do {
                rawResponse = try await withTimeout(seconds: 8.0) {
                    try await self.provider.complete(
                        systemPrompt: systemPrompt,
                        userPayload: payloadSnapshot
                    )
                }
            } catch is TimeoutError {
                return .fallback(reason: .timeout)
            } catch {
                return .fallback(reason: .llmProviderError(error.localizedDescription))
            }

            // 3. Strip ```json … ``` markdown fences if present
            let stripped = Self.stripMarkdownFences(rawResponse)

            // 4. Decode {"set_prescription": SetPrescription}
            guard let responseData = stripped.data(using: .utf8) else {
                lastErrorDescription = "Response could not be converted to UTF-8 data."
                continue
            }

            // Construct decoder inline (same reason as encoder above).
            let decoder: JSONDecoder = {
                let d = JSONDecoder()
                d.dateDecodingStrategy = .iso8601
                return d
            }()
            let wrapper: SetPrescriptionWrapper
            do {
                wrapper = try decoder.decode(SetPrescriptionWrapper.self, from: responseData)
            } catch {
                lastErrorDescription = "JSON decode failed: \(error.localizedDescription). Raw: \(stripped.prefix(300))"
                continue
            }

            var prescription = wrapper.setPrescription

            // 5. Validate
            do {
                try prescription.validate()
            } catch {
                lastErrorDescription = error.localizedDescription
                continue
            }

            // 6. Safety gate: pain reported → rest ≥ 180 s
            if prescription.safetyFlags.contains(.painReported) {
                prescription.restSeconds = max(prescription.restSeconds, 180)
            }

            // 7. Return successful prescription.
            // Note: weight availability is handled at runtime via GymFactStore
            // + WeightCorrectionView — not here.
            return .success(prescription)
        }

        return .fallback(reason: .maxRetriesExceeded(lastError: lastErrorDescription))
    }

    // MARK: - Public API: Weight Adaptation

    /// Produces a re-prescribed `SetPrescription` given a weight adaptation payload.
    /// Used by `WorkoutSessionManager.handleWeightCorrection()` when the user
    /// reports a prescribed weight is unavailable.
    ///
    /// The `userPayload` is the full adaptation instruction string; `workoutContext`
    /// provides the system context. Returns `.fallback` if the LLM call fails or
    /// times out (the caller should apply the client-side formula fallback).
    func prescribeAdaptation(
        userPayload: String,
        workoutContext: WorkoutContext
    ) async -> PrescriptionResult {
        let systemPrompt = Self.systemPrompt

        do {
            let rawResponse = try await withTimeout(seconds: 8.0) {
                try await self.provider.complete(
                    systemPrompt: systemPrompt,
                    userPayload: userPayload
                )
            }

            let stripped = Self.stripMarkdownFences(rawResponse)
            guard let responseData = stripped.data(using: .utf8) else {
                return .fallback(reason: .encodingFailed("Adaptation response could not be decoded."))
            }

            let decoder: JSONDecoder = {
                let d = JSONDecoder()
                d.dateDecodingStrategy = .iso8601
                return d
            }()

            guard let wrapper = try? decoder.decode(SetPrescriptionWrapper.self, from: responseData) else {
                return .fallback(reason: .maxRetriesExceeded(lastError: "Adaptation decode failed."))
            }

            var prescription = wrapper.setPrescription
            do {
                try prescription.validate()
            } catch {
                return .fallback(reason: .maxRetriesExceeded(lastError: "Adaptation validation failed: \(error.localizedDescription)"))
            }

            if prescription.safetyFlags.contains(.painReported) {
                prescription.restSeconds = max(prescription.restSeconds, 180)
            }

            return .success(prescription)

        } catch is TimeoutError {
            return .fallback(reason: .timeout)
        } catch {
            return .fallback(reason: .llmProviderError(error.localizedDescription))
        }
    }

    // MARK: - Private: Timeout Wrapper

    private struct TimeoutError: Error {}

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            // Return first to complete (success or timeout)
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private: Markdown fence stripping

    /// Strips ```json … ``` and bare ``` … ``` fences that LLMs sometimes wrap responses in.
    private static func stripMarkdownFences(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove opening fence: ```json or ```
        if s.hasPrefix("```") {
            if let newline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: newline)...])
            }
        }
        // Remove closing fence
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: System Prompt

    private static let systemPrompt = """
        You are an elite AI strength and hypertrophy coach embedded in a workout app. \
        Your sole job is to prescribe the next set for the user based on the provided WorkoutContext JSON.

        RESPONSE FORMAT — you must return ONLY a JSON object with this exact structure:
        {
          "set_prescription": {
            "weight_kg": <number, > 0, ≤ 500>,
            "reps": <integer, 1–30>,
            "tempo": "<eccentric>-<pause>-<concentric>-<pause>, e.g. 3-1-1-0",
            "rir_target": <integer, 0–4>,
            "rest_seconds": <integer, 30–600>,
            "coaching_cue": "<string, max 100 chars>",
            "reasoning": "<string, max 200 chars>",
            "safety_flags": ["shoulder_caution"|"joint_concern"|"fatigue_high"|"pain_reported"|"deload_recommended"],
            "confidence": <number 0.0–1.0, optional>
          }
        }

        Rules:
        - No prose, no markdown fences, no explanation outside the JSON.
        - Progressive overload: prescribe a small increase if last set was performed at ≥ 2 RIR.
        - Conservative loading: prescribe maintenance or slight decrease if RIR ≤ 0 or RPE ≥ 9.
        - Always consider safety flags from qualitative notes (pain = slow down, fatigue = reduce).
        - tempo must match exactly the pattern \\d-\\d-\\d-\\d.
        """
}

// MARK: - JSON response wrapper

/// Decodes the {"set_prescription": …} envelope from the LLM response.
private nonisolated struct SetPrescriptionWrapper: Codable {
    let setPrescription: SetPrescription

    enum CodingKeys: String, CodingKey {
        case setPrescription = "set_prescription"
    }
}

// MARK: - EquipmentType rawString init (bridge from WorkoutContext key)

extension EquipmentType {
    /// Constructs an EquipmentType from a snake_case key stored in WorkoutContext.
    /// Forwards to the canonical typeKey initialiser in GymProfile.swift.
    nonisolated init(rawString: String) {
        self.init(typeKey: rawString)
    }
}

// MARK: - GymProfileConstraints

/// Equipment constraints injected into every WorkoutContext payload.
/// Tells the AI what equipment is present and what weight corrections are known.
nonisolated struct GymProfileConstraints: Codable, Sendable {

    /// List of equipment type keys available in this gym.
    /// e.g. ["dumbbell_set", "barbell", "cable_machine_single"]
    let availableEquipment: [String]

    /// Confirmed weight facts from GymFactStore, injected per exercise.
    /// e.g. ["16.0kg not available — use 15.0kg instead"]
    let confirmedWeightFacts: [String]

    enum CodingKeys: String, CodingKey {
        case availableEquipment  = "available_equipment"
        case confirmedWeightFacts = "confirmed_weight_facts"
    }
}
