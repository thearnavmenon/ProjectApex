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
    /// Watermark for the trainee-model classifier stage per ADR-0013. The
    /// classifier processes notes WHERE created_at > this watermark; nil on
    /// brand-new users triggers bootstrap (last 5 sessions / 20 notes).
    var lastClassifiedNoteCreatedAt: Date?
    /// Session-count at which the most recent global-phase-advance event
    /// fired per ADR-0012. nil for users that have never triggered the
    /// 6-session cooldown gate.
    var lastGlobalPhaseAdvanceFiredAtSessionCount: Int?

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
        totalSessionCount: Int = 0,
        lastClassifiedNoteCreatedAt: Date? = nil,
        lastGlobalPhaseAdvanceFiredAtSessionCount: Int? = nil
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
        self.lastClassifiedNoteCreatedAt = lastClassifiedNoteCreatedAt
        self.lastGlobalPhaseAdvanceFiredAtSessionCount = lastGlobalPhaseAdvanceFiredAtSessionCount
    }

    // MARK: Custom Codable for JSONB shape parity (slice A12 / #83)

    // Per ADR-0006 §"Implementation consequences", the trainee-model JSONB
    // column is a contract between the TS Edge Function orchestrator (writer)
    // and the Swift client (reader for digest assembly). Swift's synthesized
    // Dictionary Codable encodes enum-keyed dicts as flat alternating arrays
    // (`["squat", {...}, "horizontal_push", {...}]`), which the TS orchestrator
    // can't produce idiomatically and which makes JSONB unintelligible to
    // Studio inspection. This custom Codable encodes `patterns`, `muscles`,
    // and `prescriptionAccuracy` as JSON objects keyed by enum rawValue; the
    // shape parity is locked by docs/fixtures/trainee-model-snapshot.json and
    // its cross-platform tests on both TS and Swift sides.

    enum CodingKeys: String, CodingKey {
        case activeProgramId
        case goal
        case projections
        case patterns
        case muscles
        case exercises
        case activeLimitations
        case clearedLimitations
        case fatigueInteractions
        case prescriptionAccuracy
        case prescriptionIntentMismatches
        case transfers
        case bodyweight
        case lifeContextEvents
        case reassessmentRecords
        case totalSessionCount
        case lastClassifiedNoteCreatedAt
        case lastGlobalPhaseAdvanceFiredAtSessionCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.activeProgramId = try c.decodeIfPresent(UUID.self, forKey: .activeProgramId)
        self.goal = try c.decode(GoalState.self, forKey: .goal)
        self.projections = try c.decodeIfPresent(ProjectionState.self, forKey: .projections)
        self.patterns = try c.decodeEnumKeyedDictIfPresent(
            PatternProfile.self, forKey: .patterns
        )
        self.muscles = try c.decodeEnumKeyedDictIfPresent(
            MuscleProfile.self, forKey: .muscles
        )
        self.exercises = try c.decodeIfPresent(
            [String: ExerciseProfile].self, forKey: .exercises
        ) ?? [:]
        self.activeLimitations = try c.decodeIfPresent(
            [ActiveLimitation].self, forKey: .activeLimitations
        ) ?? []
        self.clearedLimitations = try c.decodeIfPresent(
            [ClearedLimitation].self, forKey: .clearedLimitations
        ) ?? []
        self.fatigueInteractions = try c.decodeIfPresent(
            [FatigueInteraction].self, forKey: .fatigueInteractions
        ) ?? []
        // Doubly-nested dict: outer key MovementPattern (rawValue), inner key
        // SetIntent (rawValue). Both layers must decode as JSON objects so the
        // shape matches the TS orchestrator's per-pattern × per-intent table.
        if c.contains(.prescriptionAccuracy) {
            let outer = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .prescriptionAccuracy)
            var prescriptionAccuracy: [MovementPattern: [SetIntent: PrescriptionAccuracy]] = [:]
            for outerKey in outer.allKeys {
                guard let pattern = MovementPattern(rawValue: outerKey.stringValue) else { continue }
                let inner = try outer.nestedContainer(keyedBy: AnyCodingKey.self, forKey: outerKey)
                var byIntent: [SetIntent: PrescriptionAccuracy] = [:]
                for innerKey in inner.allKeys {
                    guard let intent = SetIntent(rawValue: innerKey.stringValue) else { continue }
                    byIntent[intent] = try inner.decode(PrescriptionAccuracy.self, forKey: innerKey)
                }
                prescriptionAccuracy[pattern] = byIntent
            }
            self.prescriptionAccuracy = prescriptionAccuracy
        } else {
            self.prescriptionAccuracy = [:]
        }
        self.prescriptionIntentMismatches = try c.decodeIfPresent(
            [PrescriptionIntentMismatch].self, forKey: .prescriptionIntentMismatches
        ) ?? []
        self.transfers = try c.decodeIfPresent(
            [ExerciseTransfer].self, forKey: .transfers
        ) ?? []
        self.bodyweight = try c.decodeIfPresent(
            BodyweightHistory.self, forKey: .bodyweight
        ) ?? BodyweightHistory()
        self.lifeContextEvents = try c.decodeIfPresent(
            [LifeContextEvent].self, forKey: .lifeContextEvents
        ) ?? []
        self.reassessmentRecords = try c.decodeIfPresent(
            [ReassessmentRecord].self, forKey: .reassessmentRecords
        ) ?? []
        self.totalSessionCount = try c.decodeIfPresent(
            Int.self, forKey: .totalSessionCount
        ) ?? 0
        self.lastClassifiedNoteCreatedAt = try c.decodeIfPresent(
            Date.self, forKey: .lastClassifiedNoteCreatedAt
        )
        self.lastGlobalPhaseAdvanceFiredAtSessionCount = try c.decodeIfPresent(
            Int.self, forKey: .lastGlobalPhaseAdvanceFiredAtSessionCount
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(activeProgramId, forKey: .activeProgramId)
        try c.encode(goal, forKey: .goal)
        try c.encodeIfPresent(projections, forKey: .projections)
        try c.encodeEnumKeyedDict(patterns, forKey: .patterns)
        try c.encodeEnumKeyedDict(muscles, forKey: .muscles)
        try c.encode(exercises, forKey: .exercises)
        try c.encode(activeLimitations, forKey: .activeLimitations)
        try c.encode(clearedLimitations, forKey: .clearedLimitations)
        try c.encode(fatigueInteractions, forKey: .fatigueInteractions)
        // Doubly-nested encode mirroring the decoder above. Outer + inner
        // sorted by rawValue for deterministic output.
        var pac = c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .prescriptionAccuracy)
        for (pattern, byIntent) in prescriptionAccuracy.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var inner = pac.nestedContainer(
                keyedBy: AnyCodingKey.self,
                forKey: AnyCodingKey(pattern.rawValue)
            )
            for (intent, accuracy) in byIntent.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                try inner.encode(accuracy, forKey: AnyCodingKey(intent.rawValue))
            }
        }
        try c.encode(prescriptionIntentMismatches, forKey: .prescriptionIntentMismatches)
        try c.encode(transfers, forKey: .transfers)
        try c.encode(bodyweight, forKey: .bodyweight)
        try c.encode(lifeContextEvents, forKey: .lifeContextEvents)
        try c.encode(reassessmentRecords, forKey: .reassessmentRecords)
        try c.encode(totalSessionCount, forKey: .totalSessionCount)
        try c.encodeIfPresent(lastClassifiedNoteCreatedAt, forKey: .lastClassifiedNoteCreatedAt)
        try c.encodeIfPresent(lastGlobalPhaseAdvanceFiredAtSessionCount, forKey: .lastGlobalPhaseAdvanceFiredAtSessionCount)
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
