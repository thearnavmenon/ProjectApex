// TraineeModelProfiles.swift
// ProjectApex — Models
//
// Profile types per ADR-0005 — ExerciseProfile, MuscleProfile, PatternProfile,
// ProjectionState. PatternProfile carries the derived cadence / transition-mode
// computed properties.

import Foundation

// MARK: - ExerciseProfile

/// Per-exercise capability snapshot. EWMA over the last 5 valid top sets
/// (validity 3..10 reps) per ADR-0005. `learningPhase` flips false at
/// sessionCount >= 10. `formDegradationFlag` is RAG-fed.
struct ExerciseProfile: Codable, Sendable, Hashable {
    var exerciseId: String
    var topSets: [TopSetSnapshot]
    var sessionSnapshots: [ExerciseSessionSnapshot]
    var e1rmCurrent: Double
    var e1rmMedian: Double
    var e1rmPeak: Double
    var sessionCount: Int
    var formDegradationFlag: Bool
    var confidence: AxisConfidence
    /// Consecutive sessions on this exercise without form-degradation
    /// evidence per Q9 PRD-internal lifecycle. Drives the "clear flag"
    /// transition; reset to 0 on any new degradation evidence.
    var formDegradationCleanSessions: Int

    init(
        exerciseId: String,
        topSets: [TopSetSnapshot] = [],
        sessionSnapshots: [ExerciseSessionSnapshot] = [],
        e1rmCurrent: Double = 0,
        e1rmMedian: Double = 0,
        e1rmPeak: Double = 0,
        sessionCount: Int = 0,
        formDegradationFlag: Bool = false,
        confidence: AxisConfidence = .bootstrapping,
        formDegradationCleanSessions: Int = 0
    ) {
        self.exerciseId = exerciseId
        self.topSets = topSets
        self.sessionSnapshots = sessionSnapshots
        self.e1rmCurrent = e1rmCurrent
        self.e1rmMedian = e1rmMedian
        self.e1rmPeak = e1rmPeak
        self.sessionCount = sessionCount
        self.formDegradationFlag = formDegradationFlag
        self.confidence = confidence
        self.formDegradationCleanSessions = formDegradationCleanSessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exerciseId = try c.decode(String.self, forKey: .exerciseId)
        self.topSets = try c.decode([TopSetSnapshot].self, forKey: .topSets)
        self.sessionSnapshots = try c.decode([ExerciseSessionSnapshot].self, forKey: .sessionSnapshots)
        self.e1rmCurrent = try c.decode(Double.self, forKey: .e1rmCurrent)
        self.e1rmMedian = try c.decode(Double.self, forKey: .e1rmMedian)
        self.e1rmPeak = try c.decode(Double.self, forKey: .e1rmPeak)
        self.sessionCount = try c.decode(Int.self, forKey: .sessionCount)
        self.formDegradationFlag = try c.decode(Bool.self, forKey: .formDegradationFlag)
        self.confidence = try c.decode(AxisConfidence.self, forKey: .confidence)
        self.formDegradationCleanSessions = try c.decodeIfPresent(Int.self, forKey: .formDegradationCleanSessions) ?? 0
    }

    /// True while the exercise is in its first 10 sessions per ADR-0005.
    var learningPhase: Bool { sessionCount < 10 }
}

// MARK: - MuscleProfile

/// Per-muscle-group profile. Volume metrics are queue-event-windowed
/// (last 7 training events per ADR-0002), not calendar-week-shaped.
struct MuscleProfile: Codable, Sendable, Hashable {
    var muscleGroup: MuscleGroup
    var volumeTolerance: Double
    var observedSweetSpot: Int?
    var volumeDeficit: Int
    /// #570: MRV/MAV-midpoint ceiling prior (cadence-scaled, per-7-events).
    /// Advisory only — pairs with `volumeSurplus` to surface over-volume.
    var volumeCeiling: Double
    /// #570: over-volume signal = max(0, recent sets − ceiling); 0 at/under.
    var volumeSurplus: Int
    var focusWeight: Double
    var stagnationStatus: ProgressionTrend
    var confidence: AxisConfidence

    init(
        muscleGroup: MuscleGroup,
        volumeTolerance: Double = 0,
        observedSweetSpot: Int? = nil,
        volumeDeficit: Int = 0,
        volumeCeiling: Double = 0,
        volumeSurplus: Int = 0,
        focusWeight: Double = 0,
        stagnationStatus: ProgressionTrend = .progressing,
        confidence: AxisConfidence = .bootstrapping
    ) {
        self.muscleGroup = muscleGroup
        self.volumeTolerance = volumeTolerance
        self.observedSweetSpot = observedSweetSpot
        self.volumeDeficit = volumeDeficit
        self.volumeCeiling = volumeCeiling
        self.volumeSurplus = volumeSurplus
        self.focusWeight = focusWeight
        self.stagnationStatus = stagnationStatus
        self.confidence = confidence
    }

    // Custom decoder so `volumeCeiling` / `volumeSurplus` (#570, additive)
    // default cleanly on legacy `model_json` rows written before this field
    // existed — mirrors the RecoveryProfile / PatternProfile additive-decode
    // idiom. The synthesized encoder still writes all fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.muscleGroup = try c.decode(MuscleGroup.self, forKey: .muscleGroup)
        self.volumeTolerance = try c.decode(Double.self, forKey: .volumeTolerance)
        self.observedSweetSpot = try c.decodeIfPresent(Int.self, forKey: .observedSweetSpot)
        self.volumeDeficit = try c.decode(Int.self, forKey: .volumeDeficit)
        self.volumeCeiling = try c.decodeIfPresent(Double.self, forKey: .volumeCeiling) ?? 0
        self.volumeSurplus = try c.decodeIfPresent(Int.self, forKey: .volumeSurplus) ?? 0
        self.focusWeight = try c.decode(Double.self, forKey: .focusWeight)
        self.stagnationStatus = try c.decode(ProgressionTrend.self, forKey: .stagnationStatus)
        self.confidence = try c.decode(AxisConfidence.self, forKey: .confidence)
    }
}

// MARK: - PatternProfile

/// Per-movement-pattern profile. Carries phase, recovery, transition-mode
/// state, and the recent-session date list that feeds the cadence /
/// disruption derivations.
struct PatternProfile: Codable, Sendable, Hashable {
    var pattern: MovementPattern
    var currentPhase: MesocyclePhase
    var sessionsInPhase: Int
    var lastPhaseTransitionAtSessionCount: Int
    var rpeOffset: Double
    var recovery: RecoveryProfile
    var confidence: AxisConfidence
    /// When non-nil and in the future, the pattern is in transition mode
    /// (EWMA window collapsed to 3 most-recent sessions per ADR-0005).
    var transitionModeUntil: Date?
    var trend: ProgressionTrend
    /// Recent session dates for this pattern, oldest first. Storage is
    /// bounded externally (the trainee-model update job decides how many
    /// to retain — typically the last 7..10 to support cadence and
    /// disruption derivations without unbounded growth).
    var recentSessionDates: [Date]
    /// Counter incremented on force-deload (plateau/declining + 2× phase
    /// threshold per ADR-0011 §(b)); reset to 0 on natural progressing
    /// advance. Surfaces to the LLM digest at ≥2 for exercise-rotation /
    /// programme-rebuild meta-coaching per ADR-0011 §(d).
    var consecutiveForceDeloadsOnPattern: Int

    init(
        pattern: MovementPattern,
        currentPhase: MesocyclePhase = .accumulation,
        sessionsInPhase: Int = 0,
        lastPhaseTransitionAtSessionCount: Int = 0,
        rpeOffset: Double = 0,
        recovery: RecoveryProfile = RecoveryProfile(),
        confidence: AxisConfidence = .bootstrapping,
        transitionModeUntil: Date? = nil,
        trend: ProgressionTrend = .progressing,
        recentSessionDates: [Date] = [],
        consecutiveForceDeloadsOnPattern: Int = 0
    ) {
        self.pattern = pattern
        self.currentPhase = currentPhase
        self.sessionsInPhase = sessionsInPhase
        self.lastPhaseTransitionAtSessionCount = lastPhaseTransitionAtSessionCount
        self.rpeOffset = rpeOffset
        self.recovery = recovery
        self.confidence = confidence
        self.transitionModeUntil = transitionModeUntil
        self.trend = trend
        self.recentSessionDates = recentSessionDates
        self.consecutiveForceDeloadsOnPattern = consecutiveForceDeloadsOnPattern
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pattern = try c.decode(MovementPattern.self, forKey: .pattern)
        self.currentPhase = try c.decode(MesocyclePhase.self, forKey: .currentPhase)
        self.sessionsInPhase = try c.decode(Int.self, forKey: .sessionsInPhase)
        self.lastPhaseTransitionAtSessionCount = try c.decode(Int.self, forKey: .lastPhaseTransitionAtSessionCount)
        self.rpeOffset = try c.decode(Double.self, forKey: .rpeOffset)
        self.recovery = try c.decode(RecoveryProfile.self, forKey: .recovery)
        self.confidence = try c.decode(AxisConfidence.self, forKey: .confidence)
        self.transitionModeUntil = try c.decodeIfPresent(Date.self, forKey: .transitionModeUntil)
        self.trend = try c.decode(ProgressionTrend.self, forKey: .trend)
        self.recentSessionDates = try c.decode([Date].self, forKey: .recentSessionDates)
        self.consecutiveForceDeloadsOnPattern = try c.decodeIfPresent(Int.self, forKey: .consecutiveForceDeloadsOnPattern) ?? 0
    }

    // MARK: Derived properties

    /// Pre-bucketed local-date strings (yyyy-MM-dd) for the recent
    /// session dates, oldest first. Local-date semantics per ADR-0005.
    var recentSessionDays: [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return recentSessionDates.sorted().map { formatter.string(from: $0) }
    }

    /// Mean delta in days between consecutive recent sessions.
    /// Returns nil if fewer than 2 sessions are recorded.
    var sessionsCadenceDays: Double? {
        guard recentSessionDates.count >= 2 else { return nil }
        let sorted = recentSessionDates.sorted()
        let deltas = zip(sorted.dropFirst(), sorted).map {
            $0.timeIntervalSince($1) / 86400.0
        }
        return deltas.reduce(0, +) / Double(deltas.count)
    }

    /// Whole days since the most recent session, computed against the
    /// reference date (defaulting to now). Returns nil if no recorded
    /// sessions. Negative deltas (recorded session in the future) clamp
    /// to 0.
    func daysSinceLastSession(asOf reference: Date = Date()) -> Int? {
        guard let last = recentSessionDates.max() else { return nil }
        let delta = reference.timeIntervalSince(last) / 86400.0
        return max(0, Int(delta.rounded(.down)))
    }

    /// True iff transition mode is currently active (non-nil
    /// `transitionModeUntil` in the future).
    func inTransitionMode(asOf reference: Date = Date()) -> Bool {
        guard let until = transitionModeUntil else { return false }
        return reference < until
    }
}

// MARK: - ProjectionState

/// Floor + stretch projections per pattern, set at calibration review
/// and re-derived (stretch only) on goal renegotiation per ADR-0005.
struct ProjectionState: Codable, Sendable, Hashable {
    var patternProjections: [PatternProjection]
    var calibrationReviewFiredAt: Date?
    var goalLastRenegotiatedAt: Date?
    /// #305 (ADR-0023): the session-count at which a pattern most recently
    /// re-calibrated (capability outgrew its band), and which patterns moved in
    /// that apply. EF-written; drive the re-calibration banner re-arm + copy.
    var lastRecalibratedAtSessionCount: Int?
    var lastRecalibratedPatterns: [MovementPattern]

    init(
        patternProjections: [PatternProjection] = [],
        calibrationReviewFiredAt: Date? = nil,
        goalLastRenegotiatedAt: Date? = nil,
        lastRecalibratedAtSessionCount: Int? = nil,
        lastRecalibratedPatterns: [MovementPattern] = []
    ) {
        self.patternProjections = patternProjections
        self.calibrationReviewFiredAt = calibrationReviewFiredAt
        self.goalLastRenegotiatedAt = goalLastRenegotiatedAt
        self.lastRecalibratedAtSessionCount = lastRecalibratedAtSessionCount
        self.lastRecalibratedPatterns = lastRecalibratedPatterns
    }

    // Tolerant decode: rows written before #305 lack the re-calibration keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.patternProjections =
            try c.decodeIfPresent([PatternProjection].self, forKey: .patternProjections) ?? []
        self.calibrationReviewFiredAt =
            try c.decodeIfPresent(Date.self, forKey: .calibrationReviewFiredAt)
        self.goalLastRenegotiatedAt =
            try c.decodeIfPresent(Date.self, forKey: .goalLastRenegotiatedAt)
        self.lastRecalibratedAtSessionCount =
            try c.decodeIfPresent(Int.self, forKey: .lastRecalibratedAtSessionCount)
        self.lastRecalibratedPatterns =
            try c.decodeIfPresent([MovementPattern].self, forKey: .lastRecalibratedPatterns) ?? []
    }
}
