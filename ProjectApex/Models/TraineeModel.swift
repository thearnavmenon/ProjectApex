// TraineeModel.swift
// ProjectApex — Models
//
// Top-level trainee-model value type per ADR-0005. Pure value type — no
// actors, no I/O. The Service / LocalStore / UpdateJob slices ship
// separately and consume this.
//
// Major patterns (used by isReadyForCalibrationReview and
// shouldFireGlobalPhaseAdvance) are the six most common compound-movement
// patterns: horizontal push, vertical push, horizontal pull, vertical
// pull, squat, hip hinge. Lunge and isolation are excluded — they're
// auxiliary patterns that don't carry the same calibration weight.

import Foundation

struct TraineeModel: Codable, Sendable, Hashable {
    var activeProgramId: UUID?
    var goal: GoalState
    var projections: ProjectionState?
    var patterns: [MovementPattern: PatternProfile]
    var muscles: [MuscleGroup: MuscleProfile]
    var exercises: [String: ExerciseProfile]
    var activeLimitations: [ActiveLimitation]
    var clearedLimitations: [ClearedLimitation]
    var fatigueInteractions: [FatigueInteraction]
    var prescriptionAccuracy: [MovementPattern: [SetIntent: PrescriptionAccuracy]]
    var prescriptionIntentMismatches: [PrescriptionIntentMismatch]
    var transfers: [ExerciseTransfer]
    var bodyweight: BodyweightHistory
    var lifeContextEvents: [LifeContextEvent]
    var reassessmentRecords: [ReassessmentRecord]
    /// Total completed sessions across the user's history. Drives the
    /// 6-session-window check for shouldFireGlobalPhaseAdvance.
    var totalSessionCount: Int

    init(
        activeProgramId: UUID? = nil,
        goal: GoalState,
        projections: ProjectionState? = nil,
        patterns: [MovementPattern: PatternProfile] = [:],
        muscles: [MuscleGroup: MuscleProfile] = [:],
        exercises: [String: ExerciseProfile] = [:],
        activeLimitations: [ActiveLimitation] = [],
        clearedLimitations: [ClearedLimitation] = [],
        fatigueInteractions: [FatigueInteraction] = [],
        prescriptionAccuracy: [MovementPattern: [SetIntent: PrescriptionAccuracy]] = [:],
        prescriptionIntentMismatches: [PrescriptionIntentMismatch] = [],
        transfers: [ExerciseTransfer] = [],
        bodyweight: BodyweightHistory = BodyweightHistory(),
        lifeContextEvents: [LifeContextEvent] = [],
        reassessmentRecords: [ReassessmentRecord] = [],
        totalSessionCount: Int = 0
    ) {
        self.activeProgramId = activeProgramId
        self.goal = goal
        self.projections = projections
        self.patterns = patterns
        self.muscles = muscles
        self.exercises = exercises
        self.activeLimitations = activeLimitations
        self.clearedLimitations = clearedLimitations
        self.fatigueInteractions = fatigueInteractions
        self.prescriptionAccuracy = prescriptionAccuracy
        self.prescriptionIntentMismatches = prescriptionIntentMismatches
        self.transfers = transfers
        self.bodyweight = bodyweight
        self.lifeContextEvents = lifeContextEvents
        self.reassessmentRecords = reassessmentRecords
        self.totalSessionCount = totalSessionCount
    }

    // MARK: Major patterns (calibration / phase-advance gating)

    static let majorPatterns: Set<MovementPattern> = [
        .horizontalPush, .verticalPush, .horizontalPull, .verticalPull,
        .squat, .hipHinge,
    ]

    // MARK: Derived properties

    /// True iff ≥4 of the 6 major patterns have reached `.established`
    /// per-axis confidence AND the calibration review has not yet fired.
    var isReadyForCalibrationReview: Bool {
        let establishedMajors = patterns.lazy.filter { (pattern, profile) in
            Self.majorPatterns.contains(pattern) && profile.confidence == .established
        }.count
        let calibrationAlreadyFired = projections?.calibrationReviewFiredAt != nil
        return establishedMajors >= 4 && !calibrationAlreadyFired
    }

    /// Patterns whose current absence exceeds 2× their typical cadence
    /// per ADR-0005. Patterns without enough cadence data (fewer than 2
    /// recorded sessions) are excluded.
    func disruptedPatterns(asOf reference: Date = Date()) -> [MovementPattern] {
        patterns.compactMap { (pattern, profile) -> MovementPattern? in
            guard let cadence = profile.sessionsCadenceDays,
                  let daysSince = profile.daysSinceLastSession(asOf: reference)
            else { return nil }
            return Double(daysSince) > 2 * cadence ? pattern : nil
        }
    }

    /// True when ≥4 major patterns have transitioned phase within the
    /// last 6 sessions per ADR-0005. A pattern with
    /// `lastPhaseTransitionAtSessionCount == 0` is treated as
    /// never-transitioned (the initial state).
    var shouldFireGlobalPhaseAdvance: Bool {
        let recentlyTransitioned = patterns.lazy.filter { (pattern, profile) in
            guard Self.majorPatterns.contains(pattern),
                  profile.lastPhaseTransitionAtSessionCount > 0
            else { return false }
            let delta = totalSessionCount - profile.lastPhaseTransitionAtSessionCount
            return delta >= 0 && delta <= 6
        }.count
        return recentlyTransitioned >= 4
    }
}
