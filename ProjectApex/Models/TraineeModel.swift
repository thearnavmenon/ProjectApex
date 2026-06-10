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
    /// Per-trigger acknowledgment of heavy-reassessment GPA fires (#258): each
    /// member is a `lastGlobalPhaseAdvanceFiredAtSessionCount` the user has
    /// acknowledged, which suppresses the signal via
    /// `TraineeModelDigest.deriveHeavyReassessmentSignal`. Grows ~1 int per GPA
    /// event (≤ ~40/yr), so no pruning is needed.
    var acknowledgedTriggeringSessionCounts: Set<Int>
    /// Whether the user has seen the one-time calibration-review display (#269).
    /// Set true once they acknowledge the read-only projection screen, which
    /// suppresses the banner via `TraineeModelDigest.deriveCalibrationReviewSignal`.
    var calibrationReviewAcknowledged: Bool
    /// #305 (ADR-0023): the highest re-calibration watermark
    /// (`ProjectionState.lastRecalibratedAtSessionCount`) the athlete has
    /// acknowledged. A watermark newer than this re-arms the calibration banner.
    /// Event-keyed (not a boolean) so a session-apply re-arm and a goal-EF ack
    /// advance disjoint values rather than clobbering one boolean.
    var acknowledgedRecalibrationSessionCount: Int?

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
        totalSessionCount: Int = 0,
        lastClassifiedNoteCreatedAt: Date? = nil,
        lastGlobalPhaseAdvanceFiredAtSessionCount: Int? = nil,
        acknowledgedTriggeringSessionCounts: Set<Int> = [],
        calibrationReviewAcknowledged: Bool = false,
        acknowledgedRecalibrationSessionCount: Int? = nil
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
        self.totalSessionCount = totalSessionCount
        self.lastClassifiedNoteCreatedAt = lastClassifiedNoteCreatedAt
        self.lastGlobalPhaseAdvanceFiredAtSessionCount = lastGlobalPhaseAdvanceFiredAtSessionCount
        self.acknowledgedTriggeringSessionCounts = acknowledgedTriggeringSessionCounts
        self.calibrationReviewAcknowledged = calibrationReviewAcknowledged
        self.acknowledgedRecalibrationSessionCount = acknowledgedRecalibrationSessionCount
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
        case totalSessionCount
        case lastClassifiedNoteCreatedAt
        case lastGlobalPhaseAdvanceFiredAtSessionCount
        case acknowledgedTriggeringSessionCounts
        // #309: camelCase — matches what the goal EF writes
        // (`model_json.calibrationReviewAcknowledged`) and the dominant model_json
        // convention (totalSessionCount / projections.*). Was snake_case, which
        // silently never decoded the SERVER ack (no snake decoding strategy on the
        // sync path); a legacy snake fallback in init(from:) preserves prior
        // local-cache acks.
        case calibrationReviewAcknowledged
        case acknowledgedRecalibrationSessionCount
    }

    /// #309: decode-only key for the pre-fix snake_case spelling, so a prior ack
    /// cached locally under the old key is not dropped on upgrade.
    private enum LegacyCodingKeys: String, CodingKey {
        case calibrationReviewAcknowledged = "calibration_review_acknowledged"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.activeProgramId = try c.decodeIfPresent(UUID.self, forKey: .activeProgramId)
        // Defensive decode per #146 — Edge Function's applySession has no
        // write path for `goal` (onboarding owns hydration via a separate
        // flow not yet wired). Decode-if-present + `.placeholder` sentinel
        // unblocks the rest of the model rather than throwing keyNotFound
        // and silently dropping the whole TraineeModel via the parseResponse
        // `try?` at TraineeModelUpdateJob:188.
        self.goal = try c.decodeIfPresent(GoalState.self, forKey: .goal)
            ?? GoalState.placeholder
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
        // Legacy JSONB rows may carry a `reassessmentRecords` key from
        // before #178 (the field was declared but never written by any
        // production path). The key is intentionally absent from CodingKeys
        // now, so the decoder silently ignores it.
        self.totalSessionCount = try c.decodeIfPresent(
            Int.self, forKey: .totalSessionCount
        ) ?? 0
        self.lastClassifiedNoteCreatedAt = try c.decodeIfPresent(
            Date.self, forKey: .lastClassifiedNoteCreatedAt
        )
        self.lastGlobalPhaseAdvanceFiredAtSessionCount = try c.decodeIfPresent(
            Int.self, forKey: .lastGlobalPhaseAdvanceFiredAtSessionCount
        )
        // Tolerant decode (#258): older rows / server JSON lack the key — mirror
        // the model's other collections defaulting to empty.
        self.acknowledgedTriggeringSessionCounts = Set(try c.decodeIfPresent(
            [Int].self, forKey: .acknowledgedTriggeringSessionCounts
        ) ?? [])
        // Tolerant decode (#269 / #309): read the camelCase key the EF writes;
        // fall back to the legacy snake_case key so a prior local-cache ack
        // survives the #309 key-casing fix; default false (banner still eligible).
        let legacyAck = try decoder.container(keyedBy: LegacyCodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .calibrationReviewAcknowledged)
        self.calibrationReviewAcknowledged = try c.decodeIfPresent(
            Bool.self, forKey: .calibrationReviewAcknowledged
        ) ?? legacyAck ?? false
        // Tolerant decode (#305): absent on rows predating re-calibration → nil
        // (no watermark acknowledged yet, so a re-calibration is eligible to fire).
        self.acknowledgedRecalibrationSessionCount = try c.decodeIfPresent(
            Int.self, forKey: .acknowledgedRecalibrationSessionCount
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
        try c.encode(totalSessionCount, forKey: .totalSessionCount)
        try c.encodeIfPresent(lastClassifiedNoteCreatedAt, forKey: .lastClassifiedNoteCreatedAt)
        try c.encodeIfPresent(lastGlobalPhaseAdvanceFiredAtSessionCount, forKey: .lastGlobalPhaseAdvanceFiredAtSessionCount)
        // Encode SORTED for deterministic JSONB — Swift `Set` Codable is
        // hash-ordered (randomized per-process), which breaks model_json parity
        // (cf. prescriptionAccuracy / recentlyAdvancedPatterns sorting). #258.
        try c.encode(acknowledgedTriggeringSessionCounts.sorted(), forKey: .acknowledgedTriggeringSessionCounts)
        try c.encode(calibrationReviewAcknowledged, forKey: .calibrationReviewAcknowledged)
        try c.encodeIfPresent(acknowledgedRecalibrationSessionCount, forKey: .acknowledgedRecalibrationSessionCount)
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
