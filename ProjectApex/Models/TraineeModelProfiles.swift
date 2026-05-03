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

    init(
        exerciseId: String,
        topSets: [TopSetSnapshot] = [],
        sessionSnapshots: [ExerciseSessionSnapshot] = [],
        e1rmCurrent: Double = 0,
        e1rmMedian: Double = 0,
        e1rmPeak: Double = 0,
        sessionCount: Int = 0,
        formDegradationFlag: Bool = false,
        confidence: AxisConfidence = .bootstrapping
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
    var focusWeight: Double
    var stagnationStatus: ProgressionTrend
    var confidence: AxisConfidence

    init(
        muscleGroup: MuscleGroup,
        volumeTolerance: Double = 0,
        observedSweetSpot: Int? = nil,
        volumeDeficit: Int = 0,
        focusWeight: Double = 0,
        stagnationStatus: ProgressionTrend = .progressing,
        confidence: AxisConfidence = .bootstrapping
    ) {
        self.muscleGroup = muscleGroup
        self.volumeTolerance = volumeTolerance
        self.observedSweetSpot = observedSweetSpot
        self.volumeDeficit = volumeDeficit
        self.focusWeight = focusWeight
        self.stagnationStatus = stagnationStatus
        self.confidence = confidence
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
        recentSessionDates: [Date] = []
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

    init(
        patternProjections: [PatternProjection] = [],
        calibrationReviewFiredAt: Date? = nil,
        goalLastRenegotiatedAt: Date? = nil
    ) {
        self.patternProjections = patternProjections
        self.calibrationReviewFiredAt = calibrationReviewFiredAt
        self.goalLastRenegotiatedAt = goalLastRenegotiatedAt
    }
}
