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
    let streakResult: StreakResult?   // Training consistency — modulates AI intensity ceiling
    /// User biometric and training profile — used for first-session calibration (FB-003).
    let userProfile: UserProfileContext?
    /// True when this is the user's very first session (session_count == 0).
    /// Signals the AI to prescribe conservative calibration weights (FB-005).
    let isFirstSession: Bool
    let currentExercise: CurrentExercise
    let sessionHistoryToday: [ExerciseHistoryItem]
    let currentExerciseSetsToday: [CompletedSet]
    /// All prior set logs for the current exercise in this session.
    /// Enables the AI to recalibrate weight on significant rep misses (FB-006).
    let withinSessionPerformance: [CompletedSet]
    let historicalPerformance: HistoricalPerformance?
    let qualitativeNotesToday: [QualitativeNote]
    let ragRetrievedMemory: [RAGMemoryItem]
    /// Append-only log of every set completed so far this session, across all exercises.
    /// The AI's primary working memory for free-reasoning about weight/rep adjustments (FB-009).
    let sessionLog: [SessionLogEntry]
    /// Rolling 7-day fatigue picture. The AI reads this and decides voluntarily whether
    /// to reduce volume/intensity — no hardcoded threshold triggers it (FB-009).
    let weeklyFatigueSummary: WeeklyFatigueSummary?
    /// Confirmed unavailable weights for the current equipment type, sourced from
    /// GymFactStore. E.g. ["16.0kg not available — use 15.0kg instead"].
    /// The AI treats these as hard constraints — never prescribe the unavailable weight.
    let gymWeightFacts: [String]?

    enum CodingKeys: String, CodingKey {
        case requestType                = "request_type"
        case sessionMetadata            = "session_metadata"
        case biometrics
        case streakResult               = "streak_result"
        case userProfile                = "user_profile"
        case isFirstSession             = "is_first_session"
        case currentExercise            = "current_exercise"
        case sessionHistoryToday        = "session_history_today"
        case currentExerciseSetsToday   = "current_exercise_sets_today"
        case withinSessionPerformance   = "within_session_performance"
        case historicalPerformance      = "historical_performance"
        case qualitativeNotesToday      = "qualitative_notes_today"
        case ragRetrievedMemory         = "rag_retrieved_memory"
        case sessionLog                 = "session_log"
        case weeklyFatigueSummary       = "weekly_fatigue_summary"
        case gymWeightFacts             = "gym_weight_facts"
    }
}

// MARK: UserProfileContext (FB-003)

/// User biometric and training profile included in every WorkoutContext payload.
/// Populated from UserDefaults (written during onboarding) and editable from Settings.
nonisolated struct UserProfileContext: Codable, Sendable {
    /// Bodyweight in kilograms. Optional — calibrates relative loading estimates.
    let bodyweightKg: Double?
    /// Height in centimetres. Used for leverage-based adjustments.
    let heightCm: Double?
    /// Age in years. Informs rest duration and conservative RIR targets for older users.
    let age: Int?
    /// Training age label: "Beginner (< 1 yr)", "Intermediate (1–3 yrs)", "Advanced (3+ yrs)".
    let trainingAge: String?

    enum CodingKeys: String, CodingKey {
        case bodyweightKg  = "bodyweight_kg"
        case heightCm      = "height_cm"
        case age
        case trainingAge   = "training_age"
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
    /// True when this equipment is purely bodyweight (pull-up bar, dip station).
    /// When true, the AI must prescribe weight_kg: 0 and focus coaching on reps/tempo/bands.
    let bodyweightOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case equipmentTypeKey  = "equipment_type_key"
        case setNumber         = "set_number"
        case plannedSets       = "planned_sets"
        case planTarget        = "plan_target"
        case primaryMuscles    = "primary_muscles"
        case secondaryMuscles  = "secondary_muscles"
        case bodyweightOnly    = "bodyweight_only"
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
    /// True when the user manually overrode the AI-suggested weight for this set.
    let userCorrectedWeight: Bool?
    /// How many days ago this set was completed (0 = today, 1 = yesterday, etc.).
    /// Used by the AI to weight recent performance more heavily than older sets.
    let daysAgo: Int?
    /// What the user actually did on this set (Slice 6 / #10). For AI-prescribed
    /// sets without deviation: equals `prescribedIntent`. For deviated sets: the
    /// user's explicit pick. For freestyle sets: the user's pick. Nil only for
    /// pre-Slice-6 historical rows that were never tagged.
    let intent: String?
    /// What the AI prescribed for this set, captured for in-prompt deviation
    /// reasoning. Nil for freestyle (no prescription). Slice 6 / #10.
    let prescribedIntent: String?
    /// Materialized boolean — true when `intent != prescribedIntent` and both
    /// are non-nil. Derivable from the two fields above; carried explicitly so
    /// the AI prompt has unambiguous deviation signal without having to compare
    /// strings. Nil for freestyle (no prescription to deviate from).
    let isDeviation: Bool?
    /// User-raised flags on the rep/RPE sheet immediately post-set.
    /// Empty array (or nil) = no flags raised. Slice 6 / #10. Cross-session
    /// persistence via DB column tracked separately as #43.
    let completionFlags: [String]?

    enum CodingKeys: String, CodingKey {
        case setNumber              = "set_number"
        case weightKg               = "weight_kg"
        case reps
        case rirActual              = "rir_actual"
        case rpe
        case tempo
        case restTakenSeconds       = "rest_taken_seconds"
        case completedAt            = "completed_at"
        case userCorrectedWeight    = "user_corrected_weight"
        case daysAgo                = "days_ago"
        case intent
        case prescribedIntent       = "prescribed_intent"
        case isDeviation            = "is_deviation"
        case completionFlags        = "completion_flags"
    }

    /// Memberwise init with the four Slice 6 (#10) fields defaulted to nil so
    /// existing call sites that don't yet know about intent/deviation/flags
    /// continue to compile. New call sites supply them explicitly.
    nonisolated init(
        setNumber: Int,
        weightKg: Double,
        reps: Int,
        rirActual: Int?,
        rpe: Double?,
        tempo: String?,
        restTakenSeconds: Int?,
        completedAt: Date?,
        userCorrectedWeight: Bool?,
        daysAgo: Int?,
        intent: String? = nil,
        prescribedIntent: String? = nil,
        isDeviation: Bool? = nil,
        completionFlags: [String]? = nil
    ) {
        self.setNumber = setNumber
        self.weightKg = weightKg
        self.reps = reps
        self.rirActual = rirActual
        self.rpe = rpe
        self.tempo = tempo
        self.restTakenSeconds = restTakenSeconds
        self.completedAt = completedAt
        self.userCorrectedWeight = userCorrectedWeight
        self.daysAgo = daysAgo
        self.intent = intent
        self.prescribedIntent = prescribedIntent
        self.isDeviation = isDeviation
        self.completionFlags = completionFlags
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

// MARK: SessionLogEntry

/// One entry in the append-only session log — every set completed so far this session,
/// across all exercises. The AI uses this as its working memory for free reasoning.
nonisolated struct SessionLogEntry: Codable, Sendable {
    /// Canonical exercise name, e.g. "Barbell Bench Press".
    let exercise: String
    /// 1-based set number within this exercise.
    let setNumber: Int
    /// Weight prescribed by the AI (or fallback) for this set.
    let prescribedWeightKg: Double
    /// Reps prescribed.
    let prescribedReps: Int
    /// Reps the user actually completed.
    let actualReps: Int
    /// RPE reported by the user (1–10), nil if not logged.
    let rpe: Double?
    /// Short note: "completed", "near_miss", "moderate_miss", "significant_miss", "pr".
    let outcomeNote: String

    enum CodingKeys: String, CodingKey {
        case exercise
        case setNumber          = "set_number"
        case prescribedWeightKg = "prescribed_weight_kg"
        case prescribedReps     = "prescribed_reps"
        case actualReps         = "actual_reps"
        case rpe
        case outcomeNote        = "outcome_note"
    }
}

// MARK: WeeklyFatigueSummary

/// Rolling weekly fatigue picture fed into every WorkoutContext.
/// No thresholds are applied here — the AI reads this data and decides what to do.
nonisolated struct WeeklyFatigueSummary: Codable, Sendable {
    /// Number of sessions completed in the rolling 7-day window.
    let sessionsThisWeek: Int
    /// Average RPE across all sets in the rolling 7-day window. Nil if no data.
    let avgRpeThisWeek: Double?
    /// Exercise names that have had 2 or more rep misses (actual < prescribed) this week.
    let exercisesWithMultipleMisses: [String]
    /// Total sets logged this week across all exercises.
    let totalSetsThisWeek: Int

    enum CodingKeys: String, CodingKey {
        case sessionsThisWeek           = "sessions_this_week"
        case avgRpeThisWeek             = "avg_rpe_this_week"
        case exercisesWithMultipleMisses = "exercises_with_multiple_misses"
        case totalSetsThisWeek          = "total_sets_this_week"
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
    /// True when the user has manually overridden the AI-suggested weight inline.
    /// Propagated into WorkoutContext so the AI knows the weight was user-corrected.
    var userCorrectedWeight: Bool?
    /// True when the user tapped "Continue with last weights" on InferenceRetrySheet
    /// because AI inference was unavailable. Stored in the ai_prescribed JSONB blob.
    var isManualFallback: Bool?
    /// Required field per ADR-0005 Slice 6 — gates which sets contribute to e1RM,
    /// volume aggregation, and RPE calibration. Codable-optional so a missing key
    /// surfaces as a typed `PrescriptionValidationError.missingIntent` from
    /// `validate()` rather than a raw `DecodingError`. An invalid raw string
    /// (e.g. `"intent": "bogus"`) is rethrown from `init(from:)` as
    /// `PrescriptionValidationError.invalidIntent`.
    var intent: SetIntent?
    /// 1-line mental-set framing for this specific set, distinct from
    /// `coachingCue`. Sets the user's frame BEFORE they lift; rendered on the
    /// active set view's prescription card as a brief italic line under the
    /// intent label. Required (no silent default), max 80 chars. Slice 6 / #10.
    /// Same Codable-optional shape as `intent` so `validate()` produces a
    /// typed `.missingSetFraming` rather than a raw `DecodingError`.
    var setFraming: String?

    enum CodingKeys: String, CodingKey {
        case weightKg            = "weight_kg"
        case reps
        case tempo
        case rirTarget           = "rir_target"
        case restSeconds         = "rest_seconds"
        case coachingCue         = "coaching_cue"
        case reasoning
        case safetyFlags         = "safety_flags"
        case confidence
        case userCorrectedWeight = "user_corrected_weight"
        case isManualFallback    = "is_manual_fallback"
        case intent
        case setFraming          = "set_framing"
    }

    nonisolated init(
        weightKg: Double,
        reps: Int,
        tempo: String,
        rirTarget: Int,
        restSeconds: Int,
        coachingCue: String,
        reasoning: String,
        safetyFlags: [SafetyFlag],
        confidence: Double? = nil,
        userCorrectedWeight: Bool? = nil,
        isManualFallback: Bool? = nil,
        intent: SetIntent? = nil,
        setFraming: String? = nil
    ) {
        self.weightKg            = weightKg
        self.reps                = reps
        self.tempo               = tempo
        self.rirTarget           = rirTarget
        self.restSeconds         = restSeconds
        self.coachingCue         = coachingCue
        self.reasoning           = reasoning
        self.safetyFlags         = safetyFlags
        self.confidence          = confidence
        self.userCorrectedWeight = userCorrectedWeight
        self.isManualFallback    = isManualFallback
        self.intent              = intent
        self.setFraming          = setFraming
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weightKg            = try c.decode(Double.self,        forKey: .weightKg)
        reps                = try c.decode(Int.self,           forKey: .reps)
        tempo               = try c.decode(String.self,        forKey: .tempo)
        rirTarget           = try c.decode(Int.self,           forKey: .rirTarget)
        restSeconds         = try c.decode(Int.self,           forKey: .restSeconds)
        coachingCue         = try c.decode(String.self,        forKey: .coachingCue)
        reasoning           = try c.decode(String.self,        forKey: .reasoning)
        safetyFlags         = try c.decode([SafetyFlag].self,  forKey: .safetyFlags)
        confidence          = try c.decodeIfPresent(Double.self, forKey: .confidence)
        userCorrectedWeight = try c.decodeIfPresent(Bool.self,   forKey: .userCorrectedWeight)
        isManualFallback    = try c.decodeIfPresent(Bool.self,   forKey: .isManualFallback)

        // Intent: decode as Optional<String> so we can route a missing key to
        // `nil` (caught by `validate()` as `.missingIntent`) and a present-but-
        // invalid value to a typed `.invalidIntent`. Both are permanent errors
        // per ADR-0007 §1 — the LLM's response was malformed and a same-prompt
        // retry will not fix it.
        if c.contains(.intent) {
            // contains(.intent) is true even when the value is JSON null;
            // decodeIfPresent returns nil only on missing-key OR null, so
            // pull the raw String through decode(...) to surface a type
            // mismatch (e.g. `"intent": 42`) as `.invalidIntent` rather
            // than a raw DecodingError.
            let raw: String
            do {
                raw = try c.decode(String.self, forKey: .intent)
            } catch {
                throw PrescriptionValidationError.invalidIntent("<non-string>")
            }
            guard let parsed = SetIntent(rawValue: raw) else {
                throw PrescriptionValidationError.invalidIntent(raw)
            }
            intent = parsed
        } else {
            intent = nil
        }

        // setFraming: same Codable-optional shape as intent. Missing surfaces
        // as nil → caught by validate() as `.missingSetFraming`. Non-string
        // surfaces as a typed `.invalidSetFraming` so the AIInferenceService
        // fail-fast path treats it as a permanent error per ADR-0007 §1.
        if c.contains(.setFraming) {
            let raw: String
            do {
                raw = try c.decode(String.self, forKey: .setFraming)
            } catch {
                throw PrescriptionValidationError.invalidSetFraming
            }
            setFraming = raw
        } else {
            setFraming = nil
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weightKg,                forKey: .weightKg)
        try c.encode(reps,                    forKey: .reps)
        try c.encode(tempo,                   forKey: .tempo)
        try c.encode(rirTarget,               forKey: .rirTarget)
        try c.encode(restSeconds,             forKey: .restSeconds)
        try c.encode(coachingCue,             forKey: .coachingCue)
        try c.encode(reasoning,               forKey: .reasoning)
        try c.encode(safetyFlags,             forKey: .safetyFlags)
        try c.encodeIfPresent(confidence,          forKey: .confidence)
        try c.encodeIfPresent(userCorrectedWeight, forKey: .userCorrectedWeight)
        try c.encodeIfPresent(isManualFallback,    forKey: .isManualFallback)
        try c.encodeIfPresent(intent,              forKey: .intent)
        try c.encodeIfPresent(setFraming,          forKey: .setFraming)
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

nonisolated enum PrescriptionValidationError: LocalizedError, Equatable {
    case invalidWeight(Double)
    case invalidReps(Int)
    case invalidTempo(String)
    case invalidRestSeconds(Int)
    case coachingCueTooLong(Int)
    case reasoningTooLong(Int)
    case confidenceOutOfRange(Double)
    /// `intent` field absent from the AI's JSON response. Permanent per
    /// ADR-0007 §1 — same-prompt retry will not fix.
    case missingIntent
    /// `intent` field present but unparseable (unknown raw value or wrong
    /// JSON type). Permanent per ADR-0007 §1.
    case invalidIntent(String)
    /// `set_framing` field absent from the AI's JSON response. Permanent per
    /// ADR-0007 §1. Slice 6 / #10.
    case missingSetFraming
    /// `set_framing` field present but wrong type (e.g. number instead of
    /// string). Permanent per ADR-0007 §1.
    case invalidSetFraming
    /// `set_framing` longer than 80 chars. Permanent per ADR-0007 §1 —
    /// retry without prompt change won't fix.
    case setFramingTooLong(Int)

    var errorDescription: String? {
        switch self {
        case .invalidWeight(let v):
            return "weightKg \(v) is out of range (must be >= 0 and <= 500)."
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
        case .missingIntent:
            return "intent field missing — required per ADR-0005 with no silent default."
        case .invalidIntent(let raw):
            return "intent '\(raw)' is not one of warmup/top/backoff/technique/amrap."
        case .missingSetFraming:
            return "set_framing field missing — required per Slice 6 with no silent default."
        case .invalidSetFraming:
            return "set_framing must be a string."
        case .setFramingTooLong(let v):
            return "set_framing is \(v) chars (max 80)."
        }
    }
}

extension SetPrescription {
    // Compiled once at file scope to avoid repeated regex construction.
    private nonisolated static let tempoRegex = try! NSRegularExpression(pattern: #"^\d-\d-\d-\d$"#)

    nonisolated func validate() throws {
        // Intent gate fires first per Slice 6 / ADR-0005 — the no-silent-defaults
        // contract is the load-bearing invariant for this slice. A missing-intent
        // failure is a permanent malformed-response per ADR-0007 §1; the caller
        // (`AIInferenceService.prescribe`) treats it as fail-fast.
        guard intent != nil else {
            throw PrescriptionValidationError.missingIntent
        }
        // Set-framing gate fires next, before field-level checks. Same
        // no-silent-default regime as intent.
        guard let framing = setFraming else {
            throw PrescriptionValidationError.missingSetFraming
        }
        guard framing.count <= 80 else {
            throw PrescriptionValidationError.setFramingTooLong(framing.count)
        }
        guard weightKg >= 0, weightKg <= 500 else {
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
    /// LLM returned a response that cannot be turned into a valid
    /// SetPrescription — JSON decode failure, missing intent, invalid
    /// intent, or any other validation rule. Permanent per ADR-0007 §1;
    /// no same-prompt retry. Surfaced via `InferenceRetrySheet` so the
    /// user gets agency rather than a silent default.
    case malformedResponse(String)
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
            completedAt: setDate,
            userCorrectedWeight: nil,
            daysAgo: 0
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
            streakResult: StreakResult.compute(currentStreakDays: 7, longestStreak: 10),
            userProfile: UserProfileContext(
                bodyweightKg: 80.0,
                heightCm: 178.0,
                age: 28,
                trainingAge: "Intermediate (1–3 yrs)"
            ),
            isFirstSession: false,
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
                secondaryMuscles: ["triceps_brachii"],
                bodyweightOnly: nil
            ),
            sessionHistoryToday: [
                ExerciseHistoryItem(
                    exerciseName: "Overhead Press",
                    sets: [completedSet]
                )
            ],
            currentExerciseSetsToday: [completedSet],
            withinSessionPerformance: [completedSet],
            historicalPerformance: HistoricalPerformance(
                personalBest: CompletedSet(
                    setNumber: 1,
                    weightKg: 100.0,
                    reps: 5,
                    rirActual: 0,
                    rpe: 9.5,
                    tempo: "2-0-1-0",
                    restTakenSeconds: 180,
                    completedAt: setDate,
                    userCorrectedWeight: nil,
                    daysAgo: nil
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
            ],
            sessionLog: [
                SessionLogEntry(
                    exercise: "Barbell Bench Press",
                    setNumber: 1,
                    prescribedWeightKg: 80.0,
                    prescribedReps: 10,
                    actualReps: 8,
                    rpe: 8.5,
                    outcomeNote: "moderate_miss"
                )
            ],
            weeklyFatigueSummary: WeeklyFatigueSummary(
                sessionsThisWeek: 3,
                avgRpeThisWeek: 7.8,
                exercisesWithMultipleMisses: [],
                totalSetsThisWeek: 42
            ),
            gymWeightFacts: nil
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
    /// The user's gym profile — used to scope the AI's equipment awareness.
    /// Stored for future use in payload construction; currently included in
    /// the WorkoutContext via the caller.
    let gymProfile: GymProfile?

    // MARK: Init

    init(
        provider: any LLMProvider,
        gymProfile: GymProfile? = nil,
        maxRetries: Int = 2
    ) {
        self.provider = provider
        self.gymProfile = gymProfile
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
        let userPayload = contextJSON

        // Per ADR-0007 §1: malformed-response and validation errors are
        // PERMANENT — same-prompt retry will not fix the LLM's output. Slice 6
        // (#10) removed the prior maxRetries-on-validate loop; transient
        // HTTP errors are still retried inside `TransientRetryPolicy`, but
        // any decode/validate failure here returns `.fallback(.malformedResponse)`
        // immediately and surfaces `InferenceRetrySheet` to the user.
        // History: the prior loop appended a "CORRECTION REQUIRED" addendum and
        // re-ran. Sometimes worked for malformed JSON; ADR-0007 §1 nevertheless
        // classes malformed responses as permanent because the same prompt is
        // unlikely to yield a different shape, and a fail-fast surface gives
        // the user agency rather than burning the 8-second budget on a
        // probably-doomed retry. See spinoff issue for the broader audit.
        // 2. Call LLM with 8-second timeout (transient HTTP retries happen
        //    inside the timeout per ADR-0007 §2).
        let rawResponse: String
        do {
            rawResponse = try await withTimeout(seconds: 8.0) {
                try await TransientRetryPolicy.execute {
                    try await self.provider.complete(
                        systemPrompt: systemPrompt,
                        userPayload: userPayload
                    )
                }
            }
        } catch is TimeoutError {
            FallbackLogRecord(
                callSite: FallbackLogRecord.prescribeCallSite,
                reason: "timeout (8s)",
                sessionId: context.sessionMetadata.sessionId
            ).emit()
            return .fallback(reason: .timeout)
        } catch {
            if let llmError = error as? LLMProviderError {
                FallbackLogRecord.from(
                    callSite: FallbackLogRecord.prescribeCallSite,
                    error: llmError,
                    sessionId: context.sessionMetadata.sessionId
                ).emit()
            } else {
                FallbackLogRecord(
                    callSite: FallbackLogRecord.prescribeCallSite,
                    reason: error.localizedDescription,
                    sessionId: context.sessionMetadata.sessionId
                ).emit()
            }
            return .fallback(reason: .llmProviderError(error.localizedDescription))
        }

        // 3. Strip ```json … ``` markdown fences if present
        let stripped = Self.stripMarkdownFences(rawResponse)

        // 4. Decode {"set_prescription": SetPrescription}
        guard let responseData = stripped.data(using: .utf8) else {
            return failPermanent(
                "Response could not be converted to UTF-8 data.",
                sessionId: context.sessionMetadata.sessionId,
                callSite: FallbackLogRecord.prescribeCallSite
            )
        }

        let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
        let wrapper: SetPrescriptionWrapper
        do {
            wrapper = try decoder.decode(SetPrescriptionWrapper.self, from: responseData)
        } catch let validationError as PrescriptionValidationError {
            // Custom `init(from:)` rethrows invalid-intent shapes as a typed
            // PrescriptionValidationError. Same fail-fast treatment.
            return failPermanent(
                "decode/validate: \(validationError.errorDescription ?? "\(validationError)")",
                sessionId: context.sessionMetadata.sessionId,
                callSite: FallbackLogRecord.prescribeCallSite
            )
        } catch {
            return failPermanent(
                "JSON decode failed: \(error.localizedDescription). Raw: \(stripped.prefix(300))",
                sessionId: context.sessionMetadata.sessionId,
                callSite: FallbackLogRecord.prescribeCallSite
            )
        }

        var prescription = wrapper.setPrescription

        // 5. Validate
        do {
            try prescription.validate()
        } catch {
            return failPermanent(
                error.localizedDescription,
                sessionId: context.sessionMetadata.sessionId,
                callSite: FallbackLogRecord.prescribeCallSite
            )
        }

        // 6. Safety gate: pain reported → rest ≥ 180 s
        if prescription.safetyFlags.contains(.painReported) {
            prescription.restSeconds = max(prescription.restSeconds, 180)
        }

        // 7. Return successful prescription.
        return .success(prescription)
    }

    /// Maps the ADR-0007 fail-fast hook (`emitPermanentFailureFallback`,
    /// declared at file scope in `FallbackLogRecord.swift`) onto this
    /// service's `PrescriptionResult`. The hook does the emission; this
    /// wrapper builds the typed result.
    ///
    /// Audit hook for the spinoff "Audit retry-on-validate sites against
    /// ADR-0007" — `emitPermanentFailureFallback` is the canonical
    /// greppable inventory of fail-fast adoptions across services.
    private func failPermanent(
        _ description: String,
        sessionId: String,
        callSite: String
    ) -> PrescriptionResult {
        emitPermanentFailureFallback(
            callSite: callSite,
            description: description,
            sessionId: sessionId
        )
        return .fallback(reason: .malformedResponse(description))
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
                try await TransientRetryPolicy.execute {
                    try await self.provider.complete(
                        systemPrompt: systemPrompt,
                        userPayload: userPayload
                    )
                }
            }

            let stripped = Self.stripMarkdownFences(rawResponse)
            guard let responseData = stripped.data(using: .utf8) else {
                return failPermanent(
                    "Adaptation response could not be decoded.",
                    sessionId: workoutContext.sessionMetadata.sessionId,
                    callSite: FallbackLogRecord.prescribeAdaptationCallSite
                )
            }

            let decoder: JSONDecoder = {
                let d = JSONDecoder()
                d.dateDecodingStrategy = .iso8601
                return d
            }()

            // Per ADR-0007 §1: malformed-response and validation errors are
            // PERMANENT. prescribeAdaptation aligns with prescribe() — any
            // decode or validate failure returns `.fallback(.malformedResponse)`
            // immediately so the foreground call site surfaces an error UI
            // rather than silently degrading.
            let wrapper: SetPrescriptionWrapper
            do {
                wrapper = try decoder.decode(SetPrescriptionWrapper.self, from: responseData)
            } catch let validationError as PrescriptionValidationError {
                return failPermanent(
                    "Adaptation decode/validate: \(validationError.errorDescription ?? "\(validationError)")",
                    sessionId: workoutContext.sessionMetadata.sessionId,
                    callSite: FallbackLogRecord.prescribeAdaptationCallSite
                )
            } catch {
                return failPermanent(
                    "Adaptation decode failed: \(error.localizedDescription)",
                    sessionId: workoutContext.sessionMetadata.sessionId,
                    callSite: FallbackLogRecord.prescribeAdaptationCallSite
                )
            }

            var prescription = wrapper.setPrescription
            do {
                try prescription.validate()
            } catch {
                return failPermanent(
                    "Adaptation validation failed: \(error.localizedDescription)",
                    sessionId: workoutContext.sessionMetadata.sessionId,
                    callSite: FallbackLogRecord.prescribeAdaptationCallSite
                )
            }

            if prescription.safetyFlags.contains(.painReported) {
                prescription.restSeconds = max(prescription.restSeconds, 180)
            }

            return .success(prescription)

        } catch is TimeoutError {
            FallbackLogRecord(
                callSite: FallbackLogRecord.prescribeAdaptationCallSite,
                reason: "timeout (8s)"
            ).emit()
            return .fallback(reason: .timeout)
        } catch {
            if let llmError = error as? LLMProviderError {
                FallbackLogRecord.from(
                    callSite: FallbackLogRecord.prescribeAdaptationCallSite,
                    error: llmError
                ).emit()
            } else {
                FallbackLogRecord(
                    callSite: FallbackLogRecord.prescribeAdaptationCallSite,
                    reason: error.localizedDescription
                ).emit()
            }
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
            "weight_kg": <number, >= 0, ≤ 500>,
            "reps": <integer, 1–30>,
            "tempo": "<eccentric>-<pause>-<concentric>-<pause>, e.g. 3-1-1-0",
            "rir_target": <integer, 0–4>,
            "rest_seconds": <integer, 30–600>,
            "coaching_cue": "<string, max 100 chars>",
            "reasoning": "<string, max 200 chars>",
            "safety_flags": ["shoulder_caution"|"joint_concern"|"fatigue_high"|"pain_reported"|"deload_recommended"],
            "confidence": <number 0.0–1.0, optional>,
            "intent": "warmup"|"top"|"backoff"|"technique"|"amrap",
            "set_framing": "<string, max 80 chars>"
          }
        }

        CORE RULES:
        - No prose, no markdown fences, no explanation outside the JSON.
        - tempo must match exactly the pattern \\d-\\d-\\d-\\d.
        - weight_kg must be achievable on the equipment described in current_exercise.equipment_type_key.
        - coaching_cue must be ≤ 100 characters. reasoning must be ≤ 200 characters.
        - Always consider safety flags from qualitative notes (pain → slow down, fatigue → reduce load).
        - intent is REQUIRED on every prescription. No silent default. Choose deliberately:
            * top:       the working set that drives capability (3–10 reps, max effort within RIR target).
            * warmup:    sub-maximal preparation set; lighter load, higher reps, low RIR risk.
            * backoff:   secondary working set following a top set, typically 70–85% of top weight.
            * technique: tempo/form-focused practice; load is incidental, may be light.
            * amrap:     last-set-as-many-reps-as-possible at the prescribed weight.
        - set_framing is REQUIRED. A 1-line mental-set framing for THIS specific set, distinct from
          coaching_cue. Sets the user's frame BEFORE they lift; not a form reminder during. Max 80 chars.

        GOOD set_framings (set the mental frame, typed by intent):
            top:       "Heaviest work of the day. Brace and grind."
            top:       "This is the set that moves the needle. Treat it that way."
            warmup:    "Groove the pattern. Don't fight the bar."
            warmup:    "Wake up the muscles. Save the effort for later."
            backoff:   "Build volume on a manageable load."
            backoff:   "More reps, less weight. Stay tight throughout."
            technique: "Slow the tempo. Quality over load."
            technique: "Feel the right muscles working. Forget the number."
            amrap:     "Push to genuine failure with form intact."
            amrap:     "Last set, no reservations. Stop only when reps break."

        BAD set_framings to avoid:
            - Generic encouragement: "You got this!", "Make it count!", "Crush it!"
              These add no information and condescend.
            - Form cues that belong in coaching_cue: "Drive through your heels",
              "Retract your scapulae", "Brace your core".
              coaching_cue is the form note for the reps; set_framing is the frame for the set.
            - Long sentences. Hard cap 80 chars; aim for ~50–70.
            - Restating reps/weight: "Do 8 reps at 80kg." The user can already see those numbers.
            - Repeating the intent word: "This is your top set." The intent label is already shown.

        EQUIPMENT-AWARE WEIGHT INCREMENTS:
        - barbell: minimum 5 kg increment. Use 2.5 kg only near a natural plate boundary (20/60/100 kg).
        - dumbbell / kettlebell / cable / machine: minimum 2.5 kg increment.

        ANTI-OSCILLATION: Do not reverse a weight direction within an exercise unless user_corrected_weight is true.

        BODYWEIGHT-ONLY EXERCISES:
        When current_exercise.bodyweight_only is true (pull-up bar, dip station, etc.):
        - ALWAYS prescribe weight_kg: 0.
        - Do NOT suggest adding external weight unless the user explicitly mentions one.
        - coaching_cue: focus on rep quality, tempo, ROM, or band-assisted progression.
        - Struggling with reps → suggest band-assisted variation in coaching_cue.
        - All reps easy → suggest pause at top, slower tempo, or more reps.

        REASONING FROM THE SESSION LOG (primary working memory):
        The context includes a session_log: an append-only list of every set this session across all exercises.
        Use it to diagnose what is actually happening — not just the most recent set:
        - Missing reps: is this a one-off, accumulating fatigue, or a calibration problem? Decide accordingly.
        - Multiple misses at the same weight → drop the weight. How much depends on how badly they're missing.
        - First set of exercise with a big miss → calibration problem; drop to where they can actually complete the reps.
        - All reps complete at low RPE / high RIR → increase weight by one minimum increment.
        - Never make mechanical percentage adjustments. Read the actual numbers and reason from them.

        CROSS-SESSION MEMORY: Check rag_retrieved_memory for exercise_outcome events.
        - overloaded → open 5–10% BELOW the prior weight_used.
        - on_target → open at or slightly above. Continue progressive overload.
        - underloaded → open at or above. Push harder.
        Session log takes priority; RAG provides the cross-session baseline.

        DELOAD DETECTION: Read weekly_fatigue_summary (sessions_this_week, avg_rpe_this_week,
        exercises_with_multiple_misses, total_sets_this_week). Make a coaching judgement — no fixed
        threshold triggers this. If the picture warrants it, reduce volume/intensity voluntarily and
        say so in the coaching_cue. Add deload_recommended to safety_flags if appropriate.

        PROGRESSIVE OVERLOAD (default when all reps completed):
        - ≥ 2 RIR: increase weight by one minimum increment.
        - 1–0 RIR: maintain weight, reduce RIR target.

        FIRST-SESSION CALIBRATION: If is_first_session is true, prescribe ~60% estimated 1RM.
        Use user_profile.bodyweight_kg and training_age as anchors.

        USER PROFILE: Use bodyweight_kg, training_age, age, height_cm to calibrate absolute weights.
        Beginner bench: ~50–60% BW. Intermediate: ~80–100% BW. Advanced: ~100–130%+ BW.

        EXERCISE SWAPS: The session_log may contain sets tagged with exercise_swap from a previously
        swapped exercise. These sets belong to the old exercise — do NOT use them to calibrate weight
        for the new (current) exercise. Use RAG memory for the new exercise's first set anchor.
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
