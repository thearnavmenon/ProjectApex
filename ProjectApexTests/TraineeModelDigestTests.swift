// TraineeModelDigestTests.swift
// ProjectApexTests
//
// Unit tests for TraineeModelDigest assembly (Phase 1 / Slice 10, issue #11).
//
// Behaviours covered:
//   • Goal + projections passed through verbatim from the source model.
//   • per-pattern summary projects each PatternProfile across all four
//     AxisConfidence states (bootstrapping, calibrating, established, seasoned).
//   • per-muscle summary projects each MuscleProfile across all four
//     AxisConfidence states.
//   • Active fatigue interactions filter by confidence ≥ 0.7
//     (FatigueInteraction.confidence — derived from consistencyFactor ×
//     countFactor per ADR-0005).
//   • Active limitations are passed through.
//   • Prescription accuracy entries are flattened from the [pattern: [intent: …]]
//     map into a list (Phase 1 — no per-context filtering, see PR notes).
//   • Disrupted patterns are computed from the per-pattern recent-session
//     dates against the supplied reference date.
//   • Cold-start is handled by the actor (digest returning nil); this file
//     only exercises the assembly fn given a present model.
//
// The summary types (PatternSummary, MuscleSummary) carry only the prompt-
// relevant fields — the digest is narrower than the full model for token
// economics per ADR-0005.

import XCTest
@testable import ProjectApex

final class TraineeModelDigestTests: XCTestCase {

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

    private let ref = Date(timeIntervalSinceReferenceDate: 800_000_000) // mid-2026

    private func makeGoal() -> GoalState {
        GoalState(statement: "Hypertrophy", focusAreas: [.legs], updatedAt: ref)
    }

    private func makeBaselineModel() -> TraineeModel {
        TraineeModel(goal: makeGoal())
    }

    /// Returns a PatternProfile with the given confidence and a 7-day cadence
    /// (two recorded sessions one week apart). Used to verify digest assembly
    /// projects each per-axis confidence state through unchanged.
    private func makePattern(_ pattern: MovementPattern, confidence: AxisConfidence) -> PatternProfile {
        PatternProfile(
            pattern: pattern,
            currentPhase: .accumulation,
            sessionsInPhase: 4,
            rpeOffset: -0.25,
            confidence: confidence,
            trend: .progressing,
            recentSessionDates: [ref.addingTimeInterval(-14 * 86400),
                                 ref.addingTimeInterval(-7 * 86400)]
        )
    }

    private func makeMuscle(_ group: MuscleGroup, confidence: AxisConfidence) -> MuscleProfile {
        MuscleProfile(
            muscleGroup: group,
            volumeTolerance: 12,
            observedSweetSpot: 10,
            volumeDeficit: 2,
            focusWeight: 0.5,
            stagnationStatus: .progressing,
            confidence: confidence
        )
    }

    // MARK: ─── Cycle 1: goal + projections pass through ──────────────────────

    func test_digest_passesThroughGoalAndProjections() {
        var model = makeBaselineModel()
        let projection = PatternProjection(
            pattern: .squat, floor: 100, stretch: 120, progress: .onTrack
        )
        model.projections = ProjectionState(
            patternProjections: [projection],
            calibrationReviewFiredAt: ref,
            goalLastRenegotiatedAt: nil
        )

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.goal, model.goal)
        XCTAssertEqual(digest.projections, model.projections)
    }

    // MARK: ─── Cycle 2: per-pattern summary across confidence states ──────────

    func test_digest_perPatternSummary_includesAllConfidenceStates() {
        var model = makeBaselineModel()
        model.patterns = [
            .squat:          makePattern(.squat,          confidence: .bootstrapping),
            .horizontalPush: makePattern(.horizontalPush, confidence: .calibrating),
            .horizontalPull: makePattern(.horizontalPull, confidence: .established),
            .verticalPush:   makePattern(.verticalPush,   confidence: .seasoned),
        ]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.perPatternSummary.count, 4)
        let byPattern = Dictionary(uniqueKeysWithValues:
            digest.perPatternSummary.map { ($0.pattern, $0.confidence) })
        XCTAssertEqual(byPattern[.squat],          .bootstrapping)
        XCTAssertEqual(byPattern[.horizontalPush], .calibrating)
        XCTAssertEqual(byPattern[.horizontalPull], .established)
        XCTAssertEqual(byPattern[.verticalPush],   .seasoned)
    }

    func test_digest_perPatternSummary_carriesPromptRelevantFields() {
        var model = makeBaselineModel()
        var profile = makePattern(.squat, confidence: .calibrating)
        profile.currentPhase = .intensification
        profile.rpeOffset = -0.5
        profile.trend = .plateaued
        profile.transitionModeUntil = ref.addingTimeInterval(7 * 86400) // active
        model.patterns[.squat] = profile

        let digest = TraineeModelDigest(from: model, asOf: ref)

        let summary = try! XCTUnwrap(digest.perPatternSummary.first { $0.pattern == .squat })
        XCTAssertEqual(summary.currentPhase,   .intensification)
        XCTAssertEqual(summary.confidence,     .calibrating)
        XCTAssertEqual(summary.rpeOffset,      -0.5)
        XCTAssertEqual(summary.trend,          .plateaued)
        XCTAssertTrue(summary.inTransitionMode)
    }

    func test_digest_perPatternSummary_inTransitionMode_falseWhenExpired() {
        var model = makeBaselineModel()
        var profile = makePattern(.squat, confidence: .established)
        profile.transitionModeUntil = ref.addingTimeInterval(-86400) // expired
        model.patterns[.squat] = profile

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let summary = try! XCTUnwrap(digest.perPatternSummary.first { $0.pattern == .squat })

        XCTAssertFalse(summary.inTransitionMode)
    }

    // MARK: ─── Cycle 3: per-muscle summary across confidence states ───────────

    func test_digest_perMuscleSummary_includesAllConfidenceStates() {
        var model = makeBaselineModel()
        model.muscles = [
            .legs:      makeMuscle(.legs,      confidence: .bootstrapping),
            .back:      makeMuscle(.back,      confidence: .calibrating),
            .chest:     makeMuscle(.chest,     confidence: .established),
            .shoulders: makeMuscle(.shoulders, confidence: .seasoned),
        ]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.perMuscleSummary.count, 4)
        let byGroup = Dictionary(uniqueKeysWithValues:
            digest.perMuscleSummary.map { ($0.muscleGroup, $0.confidence) })
        XCTAssertEqual(byGroup[.legs],      .bootstrapping)
        XCTAssertEqual(byGroup[.back],      .calibrating)
        XCTAssertEqual(byGroup[.chest],     .established)
        XCTAssertEqual(byGroup[.shoulders], .seasoned)
    }

    func test_digest_perMuscleSummary_carriesPromptRelevantFields() {
        var model = makeBaselineModel()
        model.muscles[.legs] = MuscleProfile(
            muscleGroup: .legs,
            volumeTolerance: 14.0,
            observedSweetSpot: 11,
            volumeDeficit: 3,
            focusWeight: 0.7,
            stagnationStatus: .declining,
            confidence: .calibrating
        )

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let summary = try! XCTUnwrap(digest.perMuscleSummary.first { $0.muscleGroup == .legs })

        XCTAssertEqual(summary.volumeTolerance,   14.0)
        XCTAssertEqual(summary.volumeDeficit,     3)
        XCTAssertEqual(summary.focusWeight,       0.7)
        XCTAssertEqual(summary.stagnationStatus,  .declining)
        XCTAssertEqual(summary.confidence,        .calibrating)
    }

    // MARK: ─── Cycle 4: fatigue-interaction filtering by confidence ≥ 0.7 ─────

    func test_digest_filtersFatigueInteractions_belowThreshold() {
        // 14 paired observations → countFactor = 0.5 (cap below 15).
        // Even with perfect consistency, confidence = 0.5 × 1.0 = 0.5 < 0.7.
        var model = makeBaselineModel()
        model.fatigueInteractions = [
            FatigueInteraction(
                fromPattern: .squat,
                toPattern:   .hipHinge,
                observations: Array(repeating: -0.05, count: 10), // perfect consistency
                totalCount:   14
            )
        ]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertTrue(
            digest.activeFatigueInteractions.isEmpty,
            "Below-threshold fatigue interactions must be excluded from the digest"
        )
    }

    func test_digest_includesFatigueInteractions_atOrAboveThreshold() {
        // 15 observations → countFactor = 1.0; all-equal observations →
        // consistencyFactor = 1.0; confidence = 1.0 ≥ 0.7.
        var model = makeBaselineModel()
        let included = FatigueInteraction(
            fromPattern: .horizontalPush,
            toPattern:   .verticalPush,
            observations: Array(repeating: -0.05, count: 10),
            totalCount:   15
        )
        // 14 observations → confidence = 0.5 (excluded).
        let excluded = FatigueInteraction(
            fromPattern: .squat,
            toPattern:   .hipHinge,
            observations: Array(repeating: -0.05, count: 10),
            totalCount:   14
        )
        model.fatigueInteractions = [included, excluded]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.activeFatigueInteractions.count, 1)
        XCTAssertEqual(digest.activeFatigueInteractions.first?.fromPattern, .horizontalPush)
        XCTAssertEqual(digest.activeFatigueInteractions.first?.toPattern,   .verticalPush)
    }

    // MARK: ─── Cycle 5: active limitations passed through ────────────────────

    func test_digest_passesThroughActiveLimitations() {
        var model = makeBaselineModel()
        let limitation = ActiveLimitation(
            subject: .joint(.shoulder),
            severity: .mild,
            onsetDate: ref.addingTimeInterval(-30 * 86400),
            evidenceCount: 3,
            userConfirmed: false,
            notes: "AI-inferred — left shoulder mentioned 3× in 6 sessions"
        )
        model.activeLimitations = [limitation]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.activeLimitations, [limitation])
    }

    // MARK: ─── Cycle 6: prescription accuracy flattened from nested map ───────

    func test_digest_prescriptionAccuracy_flattensNestedMap() {
        var model = makeBaselineModel()
        let squatTop = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: -0.05, rmse: 0.08, sampleCount: 12
        )
        let squatBackoff = PrescriptionAccuracy(
            pattern: .squat, intent: .backoff, bias: 0.02, rmse: 0.06, sampleCount: 18
        )
        let pushTop = PrescriptionAccuracy(
            pattern: .horizontalPush, intent: .top, bias: 0.0, rmse: 0.04, sampleCount: 9
        )
        model.prescriptionAccuracy = [
            .squat:          [.top: squatTop, .backoff: squatBackoff],
            .horizontalPush: [.top: pushTop],
        ]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.prescriptionAccuracy.count, 3)
        let entries = Set(digest.prescriptionAccuracy.map { "\($0.pattern.rawValue):\($0.intent.rawValue)" })
        XCTAssertEqual(entries, ["squat:top", "squat:backoff", "horizontal_push:top"])
    }

    // MARK: ─── Cycle 7: disrupted patterns derived from cadence ──────────────

    func test_digest_disruptedPatterns_derivedFromCadence() {
        var model = makeBaselineModel()
        // Cadence: two sessions 7 days apart; last 30 days ago → 4.3× cadence
        var disrupted = PatternProfile(pattern: .squat, confidence: .calibrating)
        disrupted.recentSessionDates = [
            ref.addingTimeInterval(-37 * 86400),
            ref.addingTimeInterval(-30 * 86400),
        ]
        // Cadence: two sessions 7 days apart; last 5 days ago → not disrupted
        var fresh = PatternProfile(pattern: .horizontalPush, confidence: .calibrating)
        fresh.recentSessionDates = [
            ref.addingTimeInterval(-12 * 86400),
            ref.addingTimeInterval(-5 * 86400),
        ]
        model.patterns = [.squat: disrupted, .horizontalPush: fresh]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.disruptedPatterns, [.squat])
    }

    // MARK: ─── Cycle 8: empty-input edge cases ───────────────────────────────

    func test_digest_emptyModel_yieldsEmptyCollections() {
        let model = makeBaselineModel()

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.goal, model.goal)
        XCTAssertNil(digest.projections)
        XCTAssertTrue(digest.perPatternSummary.isEmpty)
        XCTAssertTrue(digest.perMuscleSummary.isEmpty)
        XCTAssertTrue(digest.activeFatigueInteractions.isEmpty)
        XCTAssertTrue(digest.activeLimitations.isEmpty)
        XCTAssertTrue(digest.prescriptionAccuracy.isEmpty)
        XCTAssertTrue(digest.disruptedPatterns.isEmpty)
    }
}
