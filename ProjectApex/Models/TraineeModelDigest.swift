// TraineeModelDigest.swift
// ProjectApex — Models
//
// Request-time projection of the trainee model for inference and
// session-generation prompts (Phase 1 / Slice 10, issue #11).
//
// Per ADR-0005: "WorkoutContext payload becomes a TraineeModelDigest — a
// request-time projection of relevant trainee-model fields, narrower than
// the full model (token economics)."
//
// Phase 1 ships the shape and the assembly fn. Phase 2 wires the digest
// into prompt construction; the per-context filter on prescription
// accuracy lands at that point — the slice 10 issue's "(relevant patterns
// only)" qualifier is intentionally deferred because the request-context
// type does not yet exist. The digest emitted here carries every entry
// from the source model's prescriptionAccuracy map, flattened into a list.
//
// Filtering rules implemented now (per ADR-0005 / issue #11):
//   • activeFatigueInteractions: only entries with confidence ≥ 0.7
//     (FatigueInteraction.confidence — derived from consistencyFactor ×
//     countFactor; the 15-paired-observation gate is enforced inside the
//     same confidence value via countFactor).
//
// PatternSummary / MuscleSummary carry only the prompt-relevant fields —
// recoveryProfile, recentSessionDates, and other detail fields are
// dropped. Phase 2 may extend either summary if the prompt warrants it.

import Foundation

// MARK: - TraineeModelDigest

struct TraineeModelDigest: Codable, Sendable, Hashable {
    var goal: GoalState
    var projections: ProjectionState?
    var perPatternSummary: [PatternSummary]
    var perMuscleSummary: [MuscleSummary]
    /// Digest-only projection of FatigueInteraction — snake_case wire shape
    /// (B4 / #89 cycle 9a). The persisted type retains its camelCase JSONB
    /// shape for TS-edge-function round-trip compatibility.
    var activeFatigueInteractions: [FatigueInteractionDigest]
    /// Digest-only projection of ActiveLimitation — snake_case wire shape
    /// (B4 / #89 cycle 9a). Persisted type unchanged.
    var activeLimitations: [ActiveLimitationDigest]
    /// Unfiltered — every entry from the source model's nested map, flattened.
    /// Callers consuming this for prompt assembly must filter by request context
    /// before passing to the model; do not forward the full list verbatim.
    /// Digest-only projection of PrescriptionAccuracy — snake_case wire shape
    /// (B4 / #89 cycle 9a). Persisted type unchanged.
    var prescriptionAccuracy: [PrescriptionAccuracyDigest]
    var disruptedPatterns: [MovementPattern]
    /// Cross-exercise transfer coefficients filtered to entries the LLM should
    /// reason from per Q10 lock-in (R²≥0.4 AND pairedObservations≥5). Below
    /// either threshold the regression is too noisy to surface.
    /// Digest-only projection of ExerciseTransfer — snake_case wire shape
    /// (B4 / #89 cycle 9a). Persisted type unchanged.
    var transfers: [ExerciseTransferDigest]
    /// Total completed sessions across the user's history (pass-through from
    /// TraineeModel.totalSessionCount). Surfaced for the 6-session cooldown
    /// reasoning in coaching prompts.
    var totalSessionCount: Int
    /// Session-count at which the most recent global-phase-advance event fired
    /// per ADR-0012 (pass-through). Nil for users that have never crossed the
    /// 6-session cooldown gate.
    var lastGlobalPhaseAdvanceFiredAtSessionCount: Int?
    /// Per-exercise narrow projections sorted by exerciseId. Drops topSets,
    /// sessionSnapshots, and formDegradationCleanSessions per ADR-0005
    /// token-economy guidance.
    var perExerciseSummary: [ExerciseSummary]
    /// Aggregated 7-day fatigue projection (B4 / #89). Carries pre-derived
    /// `deloadTriggered` and `fatigueManagementFlagged` flags so both
    /// SessionPlan and Inference prompts read a single canonical signal.
    /// Non-optional with empty default (γ2 lock during B4 grilling) — when
    /// the caller omits explicit fatigue at digest assembly, an empty
    /// `WeekFatigueSignals` is substituted (both flags false → LLM falls
    /// through to normal behavior).
    var weeklyFatigue: WeekFatigueSignals
    /// Present iff the global-phase-advance trigger fired within the
    /// cooldown window per ADR-0005 / ADR-0012. When present, SessionPlan
    /// prompts surface the HEAVY REASSESSMENT block. Nil otherwise. Trigger
    /// detection is server-side (`lastGlobalPhaseAdvanceFiredAtSessionCount`);
    /// this projection is derived at iOS digest-assembly time from that
    /// persisted value plus the per-pattern transition log (#178).
    var heavyReassessmentSignal: HeavyReassessmentSignal?

    /// Threshold below which a fatigue interaction is excluded from
    /// coaching prompts per ADR-0005.
    static let fatigueInteractionConfidenceThreshold: Double = 0.7

    /// Minimum R² (inclusive) for a transfer entry to surface (Q10 lock-in).
    static let transferRSquaredThreshold: Double = 0.4

    /// Minimum paired-observation count (inclusive) for a transfer entry to
    /// surface (Q10 lock-in — guards against tiny-sample regressions).
    static let transferPairedObservationsThreshold: Int = 5

    /// Sessions after `lastGlobalPhaseAdvanceFiredAtSessionCount` during
    /// which the HEAVY REASSESSMENT block remains in the SessionPlan
    /// prompt. Matches the server-side cooldown
    /// (`GLOBAL_PHASE_ADVANCE_COOLDOWN_SESSIONS = 6` in
    /// `supabase/functions/_shared/constants.ts`). The AI may mention
    /// reassessment for up to this many consecutive sessions per fire event
    /// — unless the user acknowledges it: `TraineeModel`'s
    /// `acknowledgedTriggeringSessionCounts` suppresses the signal early via
    /// `deriveHeavyReassessmentSignal` (#258 added that iOS-side ack state).
    static let heavyReassessmentCooldownWindow: Int = 6

    enum CodingKeys: String, CodingKey {
        case goal
        case projections
        case perPatternSummary         = "per_pattern_summary"
        case perMuscleSummary          = "per_muscle_summary"
        case activeFatigueInteractions = "active_fatigue_interactions"
        case activeLimitations         = "active_limitations"
        case prescriptionAccuracy      = "prescription_accuracy"
        case disruptedPatterns         = "disrupted_patterns"
        case transfers
        case totalSessionCount         = "total_session_count"
        case lastGlobalPhaseAdvanceFiredAtSessionCount = "last_global_phase_advance_fired_at_session_count"
        case perExerciseSummary        = "per_exercise_summary"
        case weeklyFatigue             = "weekly_fatigue"
        case heavyReassessmentSignal   = "heavy_reassessment_signal"
    }
}

// MARK: - HeavyReassessmentSignal

/// Per ADR-0005: heavy reassessment is the UX event (UI screen + goal
/// renegotiation) that fires when the global-phase-advance trigger predicate
/// fires (ADR-0012: ≥4 of 6 major patterns transitioned phase within a
/// trailing 6-session window; force-deload counts per ADR-0011 §(b)). Trigger
/// detection and persistence happen server-side in the Edge Function
/// orchestrator (`shouldFireGlobalPhaseAdvance` in `_shared/global-phase-
/// advance.ts`); this digest projection is derived at iOS digest-assembly
/// time from `TraineeModel.lastGlobalPhaseAdvanceFiredAtSessionCount` plus
/// the per-pattern transition log, so SessionPlan can include the HEAVY
/// REASSESSMENT prompt block during the cooldown window.
struct HeavyReassessmentSignal: Codable, Sendable, Hashable {
    /// Session-count at which the most recent global-phase-advance event
    /// fired. Equal to `TraineeModel.lastGlobalPhaseAdvanceFiredAtSessionCount`.
    var triggeringSessionCount: Int
    /// Sessions elapsed since the trigger fired. 0 means GPA fired during
    /// this digest's source session; 1 means one session has been logged
    /// since. Always `< TraineeModelDigest.heavyReassessmentCooldownWindow`
    /// when the signal is present.
    var sessionsSinceTriggered: Int
    /// Major patterns whose phase transitioned within the cooldown window
    /// per ADR-0011 §(b) / ADR-0012 (force-deload counts as a transition).
    /// Sorted by `rawValue` for deterministic JSON ordering.
    var recentlyAdvancedPatterns: [MovementPattern]

    enum CodingKeys: String, CodingKey {
        case triggeringSessionCount   = "triggering_session_count"
        case sessionsSinceTriggered   = "sessions_since_triggered"
        case recentlyAdvancedPatterns = "recently_advanced_patterns"
    }
}

// MARK: - Assembly

extension TraineeModelDigest {
    init(from model: TraineeModel,
         weeklyFatigue: WeekFatigueSignals? = nil,
         asOf reference: Date = Date()) {
        let perPatternSummary = model.patterns
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { PatternSummary(profile: $0.value, asOf: reference) }

        let perMuscleSummary = model.muscles
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { MuscleSummary(profile: $0.value) }

        let activeFatigueInteractions = model.fatigueInteractions
            .filter { $0.confidence >= Self.fatigueInteractionConfidenceThreshold }
            .map(FatigueInteractionDigest.init(from:))

        let activeLimitations = model.activeLimitations
            .map(ActiveLimitationDigest.init(from:))

        let prescriptionAccuracy = model.prescriptionAccuracy
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { (_, byIntent) in
                byIntent
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { $0.value }
                    .filter(\.shouldSurfaceInDigest)
            }
            .map(PrescriptionAccuracyDigest.init(from:))

        let disruptedPatterns = model.disruptedPatterns(asOf: reference)
            .sorted { $0.rawValue < $1.rawValue }

        let transfers = model.transfers
            .filter {
                $0.rSquared >= Self.transferRSquaredThreshold
                && $0.pairedObservations >= Self.transferPairedObservationsThreshold
            }
            .map(ExerciseTransferDigest.init(from:))

        let perExerciseSummary = model.exercises
            .sorted { $0.key < $1.key }
            .map { ExerciseSummary(profile: $0.value) }

        // γ2 lock: substitute an empty fatigue struct when the caller doesn't
        // supply one — keeps the prompt's empty-state handling single-cased
        // (no separate null branch) and matches the existing "empty default"
        // convention used by the other digest collections.
        let resolvedWeeklyFatigue = weeklyFatigue
            ?? WeekFatigueSignals.compute(from: [], sessionCount: 0)

        let heavyReassessmentSignal = Self.deriveHeavyReassessmentSignal(from: model)

        self.init(
            goal: model.goal,
            projections: model.projections,
            perPatternSummary: perPatternSummary,
            perMuscleSummary: perMuscleSummary,
            activeFatigueInteractions: activeFatigueInteractions,
            activeLimitations: activeLimitations,
            prescriptionAccuracy: prescriptionAccuracy,
            disruptedPatterns: disruptedPatterns,
            transfers: transfers,
            totalSessionCount: model.totalSessionCount,
            lastGlobalPhaseAdvanceFiredAtSessionCount: model.lastGlobalPhaseAdvanceFiredAtSessionCount,
            perExerciseSummary: perExerciseSummary,
            weeklyFatigue: resolvedWeeklyFatigue,
            heavyReassessmentSignal: heavyReassessmentSignal
        )
    }

    /// Returns a signal iff the server-side GPA trigger fired within the
    /// cooldown window. Nil when GPA has never fired, when the cooldown has
    /// elapsed since the last fire, or when (defensively) the persisted
    /// fired-session-count is in the future relative to `totalSessionCount`.
    static func deriveHeavyReassessmentSignal(
        from model: TraineeModel
    ) -> HeavyReassessmentSignal? {
        guard let lastFired = model.lastGlobalPhaseAdvanceFiredAtSessionCount else {
            return nil
        }
        let delta = model.totalSessionCount - lastFired
        guard delta >= 0, delta < heavyReassessmentCooldownWindow else {
            return nil
        }
        // #258: an acknowledged fire-event is silenced for BOTH the banner and the
        // LLM prompt (both derive from this single function). Check the CURRENT
        // triggering count specifically — a LATER GPA fire (new count) must still surface.
        guard !model.acknowledgedTriggeringSessionCounts.contains(lastFired) else { return nil }
        let recentPatterns = model.patterns
            .filter { (pattern, profile) in
                TraineeModel.majorPatterns.contains(pattern)
                    && profile.lastPhaseTransitionAtSessionCount > 0
                    && (model.totalSessionCount - profile.lastPhaseTransitionAtSessionCount) <= heavyReassessmentCooldownWindow
            }
            .map { $0.key }
            .sorted { $0.rawValue < $1.rawValue }
        return HeavyReassessmentSignal(
            triggeringSessionCount: lastFired,
            sessionsSinceTriggered: delta,
            recentlyAdvancedPatterns: recentPatterns
        )
    }
}

// MARK: - PatternSummary

/// Narrow projection of PatternProfile carrying the fields a coaching
/// prompt actually needs. Recovery, RPE-offset history, and the recent-
/// session-date list are dropped; cadence and disruption are pre-derived
/// at the digest level.
struct PatternSummary: Codable, Sendable, Hashable {
    var pattern: MovementPattern
    var currentPhase: MesocyclePhase
    var confidence: AxisConfidence
    var rpeOffset: Double
    var trend: ProgressionTrend
    /// Pre-evaluated against the digest's reference date so the consumer
    /// doesn't need to re-derive transition-mode state at prompt-assembly
    /// time.
    var inTransitionMode: Bool
    /// Per ADR-0011 §(d): counter increments on force-deload, resets on
    /// natural progressing-advance. Surfaced so the LLM can emit exercise-
    /// rotation / programme-rebuild cues when the counter reaches 2.
    var consecutiveForceDeloadsOnPattern: Int

    init(profile: PatternProfile, asOf reference: Date = Date()) {
        self.pattern         = profile.pattern
        self.currentPhase    = profile.currentPhase
        self.confidence      = profile.confidence
        self.rpeOffset       = profile.rpeOffset
        self.trend           = profile.trend
        self.inTransitionMode = profile.inTransitionMode(asOf: reference)
        self.consecutiveForceDeloadsOnPattern = profile.consecutiveForceDeloadsOnPattern
    }

    enum CodingKeys: String, CodingKey {
        case pattern
        case currentPhase                    = "current_phase"
        case confidence
        case rpeOffset                       = "rpe_offset"
        case trend
        case inTransitionMode                = "in_transition_mode"
        case consecutiveForceDeloadsOnPattern = "consecutive_force_deloads_on_pattern"
    }
}

// MARK: - MuscleSummary

/// Narrow projection of MuscleProfile. observedSweetSpot is dropped
/// because it varies with phase (per ADR-0005) and is not stable enough
/// to surface in coaching prompts in Phase 1; it can be added in Phase 2
/// if the prompt strategy benefits.
struct MuscleSummary: Codable, Sendable, Hashable {
    var muscleGroup: MuscleGroup
    var volumeTolerance: Double
    var volumeDeficit: Int
    var focusWeight: Double
    var stagnationStatus: ProgressionTrend
    var confidence: AxisConfidence

    init(profile: MuscleProfile) {
        self.muscleGroup       = profile.muscleGroup
        self.volumeTolerance   = profile.volumeTolerance
        self.volumeDeficit     = profile.volumeDeficit
        self.focusWeight       = profile.focusWeight
        self.stagnationStatus  = profile.stagnationStatus
        self.confidence        = profile.confidence
    }

    enum CodingKeys: String, CodingKey {
        case muscleGroup       = "muscle_group"
        case volumeTolerance   = "volume_tolerance"
        case volumeDeficit     = "volume_deficit"
        case focusWeight       = "focus_weight"
        case stagnationStatus  = "stagnation_status"
        case confidence
    }
}

// MARK: - ExerciseSummary

/// Narrow projection of ExerciseProfile (B4 / #89). Drops topSets,
/// sessionSnapshots, and formDegradationCleanSessions; surfaces the
/// fields a coaching prompt actually reasons over (e1RM trio, session
/// count, form-degradation flag, learning-phase flag, confidence).
/// learningPhase is read from the source profile's computed property,
/// not redefined here — the threshold (sessionCount < 10) is locked
/// by ADR-0005.
struct ExerciseSummary: Codable, Sendable, Hashable {
    var exerciseId: String
    var e1rmCurrent: Double
    var e1rmMedian: Double
    var e1rmPeak: Double
    var sessionCount: Int
    var learningPhase: Bool
    var formDegradationFlag: Bool
    var confidence: AxisConfidence

    init(profile: ExerciseProfile) {
        self.exerciseId          = profile.exerciseId
        self.e1rmCurrent         = profile.e1rmCurrent
        self.e1rmMedian          = profile.e1rmMedian
        self.e1rmPeak            = profile.e1rmPeak
        self.sessionCount        = profile.sessionCount
        self.learningPhase       = profile.learningPhase
        self.formDegradationFlag = profile.formDegradationFlag
        self.confidence          = profile.confidence
    }

    enum CodingKeys: String, CodingKey {
        case exerciseId          = "exercise_id"
        case e1rmCurrent         = "e1rm_current"
        case e1rmMedian          = "e1rm_median"
        case e1rmPeak            = "e1rm_peak"
        case sessionCount        = "session_count"
        case learningPhase       = "learning_phase"
        case formDegradationFlag = "form_degradation_flag"
        case confidence
    }
}

// MARK: - PrescriptionAccuracy digest surfacing rule
//
// Mirror of supabase/functions/_shared/prescription-accuracy.ts:shouldSurfaceInDigest
// — keep in sync. Per ADR-0014 §"Digest exposure filter": an entry surfaces only
// when sampleCount is sufficient AND at least one signal (bias / rmse / gap-bucket
// divergence) exceeds its threshold. Numeric thresholds mirror the TS constants
// from supabase/functions/_shared/constants.ts (#80).
//
// TODO: consolidate when JSONB shape allows a single producer-side filter.

extension PrescriptionAccuracy {
    static let digestMinSamples = 5
    static let biasSurfaceThreshold = 0.05
    static let rmseSurfaceThreshold = 0.10
    static let gapBucketMinSamples = 3
    static let gapBucketDivergenceThreshold = 0.05

    var shouldSurfaceInDigest: Bool {
        if sampleCount < Self.digestMinSamples { return false }
        if abs(bias) > Self.biasSurfaceThreshold { return true }
        if rmse > Self.rmseSurfaceThreshold { return true }

        let under48hSamples = sampleCountByGapBucket[.under48h] ?? 0
        let over72hSamples = sampleCountByGapBucket[.over72h] ?? 0
        guard under48hSamples >= Self.gapBucketMinSamples,
              over72hSamples >= Self.gapBucketMinSamples else { return false }

        let under48hBias = biasByGapBucket[.under48h] ?? 0
        let over72hBias = biasByGapBucket[.over72h] ?? 0
        let divergence = abs(under48hBias - over72hBias)
        return divergence > Self.gapBucketDivergenceThreshold
    }
}

// MARK: - PrescriptionAccuracyDigest
//
// Digest-only projection of PrescriptionAccuracy (B4 / #89 cycle 9a). Persisted
// type lives in TraineeModelInteractions.swift and retains camelCase JSONB
// shape for TS-edge-function round-trip (note-classifier.ts / prescription-
// accuracy.ts write and read camelCase). Snake_case CodingKeys here own the
// wire shape the LLM reads — matches the PatternProfile→PatternSummary pattern.
struct PrescriptionAccuracyDigest: Codable, Sendable, Hashable {
    var pattern: MovementPattern
    var intent: SetIntent
    var bias: Double
    var rmse: Double
    var sampleCount: Int
    var biasByGapBucket: [InterSessionGapBucket: Double]
    var rmseByGapBucket: [InterSessionGapBucket: Double]
    var sampleCountByGapBucket: [InterSessionGapBucket: Int]

    init(from source: PrescriptionAccuracy) {
        self.pattern = source.pattern
        self.intent = source.intent
        self.bias = source.bias
        self.rmse = source.rmse
        self.sampleCount = source.sampleCount
        self.biasByGapBucket = source.biasByGapBucket
        self.rmseByGapBucket = source.rmseByGapBucket
        self.sampleCountByGapBucket = source.sampleCountByGapBucket
    }

    enum CodingKeys: String, CodingKey {
        case pattern, intent, bias, rmse
        case sampleCount             = "sample_count"
        case biasByGapBucket         = "bias_by_gap_bucket"
        case rmseByGapBucket         = "rmse_by_gap_bucket"
        case sampleCountByGapBucket  = "sample_count_by_gap_bucket"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pattern = try c.decode(MovementPattern.self, forKey: .pattern)
        self.intent = try c.decode(SetIntent.self, forKey: .intent)
        self.bias = try c.decode(Double.self, forKey: .bias)
        self.rmse = try c.decode(Double.self, forKey: .rmse)
        self.sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        self.biasByGapBucket = try c.decodeEnumKeyedDictIfPresent(Double.self, forKey: .biasByGapBucket)
        self.rmseByGapBucket = try c.decodeEnumKeyedDictIfPresent(Double.self, forKey: .rmseByGapBucket)
        self.sampleCountByGapBucket = try c.decodeEnumKeyedDictIfPresent(Int.self, forKey: .sampleCountByGapBucket)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(intent, forKey: .intent)
        try c.encode(bias, forKey: .bias)
        try c.encode(rmse, forKey: .rmse)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encodeEnumKeyedDict(biasByGapBucket, forKey: .biasByGapBucket)
        try c.encodeEnumKeyedDict(rmseByGapBucket, forKey: .rmseByGapBucket)
        try c.encodeEnumKeyedDict(sampleCountByGapBucket, forKey: .sampleCountByGapBucket)
    }
}

// MARK: - ActiveLimitationDigest
//
// Digest-only projection (B4 / #89 cycle 9a). Persisted type unchanged.
struct ActiveLimitationDigest: Codable, Sendable, Hashable {
    var subject: LimitationSubject
    var severity: Severity
    var onsetDate: Date
    var evidenceCount: Int
    var userConfirmed: Bool
    var notes: String?
    var sessionsWithoutReMention: Int

    init(from source: ActiveLimitation) {
        self.subject = source.subject
        self.severity = source.severity
        self.onsetDate = source.onsetDate
        self.evidenceCount = source.evidenceCount
        self.userConfirmed = source.userConfirmed
        self.notes = source.notes
        self.sessionsWithoutReMention = source.sessionsWithoutReMention
    }

    enum CodingKeys: String, CodingKey {
        case subject, severity, notes
        case onsetDate                = "onset_date"
        case evidenceCount            = "evidence_count"
        case userConfirmed            = "user_confirmed"
        case sessionsWithoutReMention = "sessions_without_re_mention"
    }
}

// MARK: - FatigueInteractionDigest
//
// Digest-only projection (B4 / #89 cycle 9a). Persisted type unchanged.
//
// Drops the raw observations array (up to 10 doubles per pair) in favour of
// a precomputed recentEffectMean scalar (B4 / #89 cycle 11) — LLM-friendly
// (no array-math) and ~10× lower token cost. Window matches FatigueInteraction
// .consistencyFactor — last 10 observations.
struct FatigueInteractionDigest: Codable, Sendable, Hashable {
    var fromPattern: MovementPattern
    var toPattern: MovementPattern
    /// Mean of the last-10 observations window. Δ% of capacity on to_pattern
    /// after a session containing from_pattern: negative = fatigue carryover,
    /// positive = potentiation.
    var recentEffectMean: Double
    var totalCount: Int

    init(from source: FatigueInteraction) {
        self.fromPattern = source.fromPattern
        self.toPattern = source.toPattern
        let recent = Array(source.observations.suffix(10))
        self.recentEffectMean = recent.isEmpty
            ? 0
            : recent.reduce(0, +) / Double(recent.count)
        self.totalCount = source.totalCount
    }

    enum CodingKeys: String, CodingKey {
        case fromPattern       = "from_pattern"
        case toPattern         = "to_pattern"
        case recentEffectMean  = "recent_effect_mean"
        case totalCount        = "total_count"
    }
}

// MARK: - ExerciseTransferDigest
//
// Digest-only projection (B4 / #89 cycle 9a). Persisted type unchanged.
struct ExerciseTransferDigest: Codable, Sendable, Hashable {
    var fromExerciseId: String
    var toExerciseId: String
    var coefficient: Double
    var rSquared: Double
    var pairedObservations: Int

    init(from source: ExerciseTransfer) {
        self.fromExerciseId = source.fromExerciseId
        self.toExerciseId = source.toExerciseId
        self.coefficient = source.coefficient
        self.rSquared = source.rSquared
        self.pairedObservations = source.pairedObservations
    }

    enum CodingKeys: String, CodingKey {
        case coefficient
        case fromExerciseId      = "from_exercise_id"
        case toExerciseId        = "to_exercise_id"
        case rSquared            = "r_squared"
        case pairedObservations  = "paired_observations"
    }
}
