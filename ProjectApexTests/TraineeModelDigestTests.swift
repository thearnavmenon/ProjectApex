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

        XCTAssertEqual(digest.activeLimitations, [ActiveLimitationDigest(from: limitation)])
    }

    // MARK: ─── Cycle 6: prescription accuracy flattened + filtered ────────────
    //
    // ADR-0014 §"Digest exposure filter" — entries surface only when
    // sampleCount ≥ 5 AND ( |bias| > 0.05 OR rmse > 0.10 OR gap-bucket
    // bias divergence > 0.05 with both buckets ≥ 3 samples ).
    // Mirror of supabase/functions/_shared/prescription-accuracy.ts:shouldSurfaceInDigest.

    func test_digest_prescriptionAccuracy_flattensNestedMap() {
        var model = makeBaselineModel()
        // All three entries use surface-worthy values (|bias| > 0.05 OR rmse > 0.10).
        let squatTop = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: -0.08, rmse: 0.06, sampleCount: 12
        )
        let squatBackoff = PrescriptionAccuracy(
            pattern: .squat, intent: .backoff, bias: 0.02, rmse: 0.12, sampleCount: 18
        )
        let pushTop = PrescriptionAccuracy(
            pattern: .horizontalPush, intent: .top, bias: 0.10, rmse: 0.04, sampleCount: 9
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

    func test_digest_prescriptionAccuracy_excludes_belowMinSampleCount() {
        var model = makeBaselineModel()
        // sampleCount=4 < 5 → excluded regardless of bias/rmse.
        let entry = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: 0.20, rmse: 0.30, sampleCount: 4
        )
        model.prescriptionAccuracy = [.squat: [.top: entry]]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertTrue(digest.prescriptionAccuracy.isEmpty)
    }

    func test_digest_prescriptionAccuracy_excludes_noSignal() {
        var model = makeBaselineModel()
        // sampleCount ≥ 5, but |bias| ≤ 0.05, rmse ≤ 0.10, no gap-bucket data.
        let entry = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: 0.04, rmse: 0.08, sampleCount: 10
        )
        model.prescriptionAccuracy = [.squat: [.top: entry]]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertTrue(digest.prescriptionAccuracy.isEmpty)
    }

    func test_digest_prescriptionAccuracy_includes_onBiasThreshold() {
        var model = makeBaselineModel()
        let entry = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: 0.06, rmse: 0.04, sampleCount: 10
        )
        model.prescriptionAccuracy = [.squat: [.top: entry]]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.prescriptionAccuracy.count, 1)
    }

    func test_digest_prescriptionAccuracy_includes_onRmseThreshold() {
        var model = makeBaselineModel()
        let entry = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: 0.0, rmse: 0.11, sampleCount: 10
        )
        model.prescriptionAccuracy = [.squat: [.top: entry]]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.prescriptionAccuracy.count, 1)
    }

    func test_digest_prescriptionAccuracy_includes_onGapBucketDivergence() {
        var model = makeBaselineModel()
        // No primary-signal surfacing (|bias|≤0.05, rmse≤0.10), but
        // under48h vs over72h bias diverges by 0.10 > 0.05 with both
        // buckets ≥ 3 samples → surfaces via the gap-bucket branch.
        let entry = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: 0.0, rmse: 0.04, sampleCount: 10,
            biasByGapBucket: [.under48h: -0.05, .over72h: 0.05],
            rmseByGapBucket: [:],
            sampleCountByGapBucket: [.under48h: 4, .over72h: 4]
        )
        model.prescriptionAccuracy = [.squat: [.top: entry]]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.prescriptionAccuracy.count, 1)
    }

    func test_digest_prescriptionAccuracy_excludes_gapBucketDivergence_whenBucketsSparse() {
        var model = makeBaselineModel()
        // Divergence is large (0.10 > 0.05) but the under48h bucket has only
        // 2 samples (< 3) — suppression rule fires, entry excluded.
        let entry = PrescriptionAccuracy(
            pattern: .squat, intent: .top, bias: 0.0, rmse: 0.04, sampleCount: 10,
            biasByGapBucket: [.under48h: -0.05, .over72h: 0.05],
            rmseByGapBucket: [:],
            sampleCountByGapBucket: [.under48h: 2, .over72h: 4]
        )
        model.prescriptionAccuracy = [.squat: [.top: entry]]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertTrue(digest.prescriptionAccuracy.isEmpty)
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

    // MARK: ─── B1: digest wire shape locked to snake_case ──────────────────
    //
    // The system prompts reference fields via snake_case JSON paths
    // (`trainee_model_digest.per_pattern_summary[].trend`,
    //  `per_muscle_summary[].stagnation_status`,
    //  `per_pattern_summary[].consecutive_force_deloads_on_pattern`).
    //
    // Without explicit CodingKeys, Codable auto-synthesis emits camelCase
    // — the LLM reads a path that doesn't exist and silently degrades.
    // PR #150 lesson: snake_case ↔ camelCase drift across the wire boundary
    // must be locked at the type, not the encoder strategy.

    func test_digest_jsonShape_isAllSnakeCase() throws {
        var model = makeBaselineModel()
        var profile = makePattern(.squat, confidence: .calibrating)
        profile.trend = .plateaued
        profile.consecutiveForceDeloadsOnPattern = 2
        model.patterns[.squat] = profile
        model.muscles[.legs] = MuscleProfile(
            muscleGroup: .legs,
            volumeTolerance: 14.0,
            observedSweetSpot: 11,
            volumeDeficit: 3,
            focusWeight: 0.7,
            stagnationStatus: .declining,
            confidence: .established
        )

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let data = try JSONEncoder().encode(digest)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Top-level digest keys.
        XCTAssertNotNil(json["per_pattern_summary"], "TraineeModelDigest must emit per_pattern_summary")
        XCTAssertNotNil(json["per_muscle_summary"], "TraineeModelDigest must emit per_muscle_summary")
        XCTAssertNotNil(json["active_fatigue_interactions"], "TraineeModelDigest must emit active_fatigue_interactions")
        XCTAssertNotNil(json["active_limitations"], "TraineeModelDigest must emit active_limitations")
        XCTAssertNotNil(json["prescription_accuracy"], "TraineeModelDigest must emit prescription_accuracy")
        XCTAssertNotNil(json["disrupted_patterns"], "TraineeModelDigest must emit disrupted_patterns")

        // PatternSummary keys the B1 prompt block references.
        let patternSummaries = try XCTUnwrap(json["per_pattern_summary"] as? [[String: Any]])
        let squatSummary = try XCTUnwrap(patternSummaries.first { ($0["pattern"] as? String) == "squat" })
        XCTAssertNotNil(squatSummary["current_phase"])
        XCTAssertNotNil(squatSummary["rpe_offset"])
        XCTAssertNotNil(squatSummary["in_transition_mode"])
        XCTAssertNotNil(squatSummary["consecutive_force_deloads_on_pattern"])
        XCTAssertEqual(squatSummary["consecutive_force_deloads_on_pattern"] as? Int, 2)
        XCTAssertEqual(squatSummary["trend"] as? String, "plateaued")

        // MuscleSummary keys the B1 prompt block references.
        let muscleSummaries = try XCTUnwrap(json["per_muscle_summary"] as? [[String: Any]])
        let legsSummary = try XCTUnwrap(muscleSummaries.first { ($0["muscle_group"] as? String) == "legs" })
        XCTAssertNotNil(legsSummary["volume_tolerance"])
        XCTAssertNotNil(legsSummary["volume_deficit"])
        XCTAssertNotNil(legsSummary["focus_weight"])
        XCTAssertNotNil(legsSummary["stagnation_status"])
        XCTAssertEqual(legsSummary["stagnation_status"] as? String, "declining")
    }

    // MARK: ─── B4 (#89) cycle 9a: nested-interaction digest wire shape ────────
    //
    // PrescriptionAccuracy / ActiveLimitation / FatigueInteraction / ExerciseTransfer
    // are *persisted* types with camelCase JSONB shapes (TS edge functions write
    // and read them in camelCase — see note-classifier.ts, fatigue-interaction.ts).
    // The B1 wire-shape lock above covers digest-only projection types
    // (PatternSummary, MuscleSummary, ExerciseSummary) but the four persisted
    // types were forwarded unchanged into the digest, exposing camelCase paths
    // to the LLM (e.g., `bias_by_gap_bucket` → actually `biasByGapBucket`).
    //
    // The fix mirrors the PatternProfile→PatternSummary pattern: four new
    // digest-only projection types (…Digest) with explicit snake_case
    // CodingKeys. The persisted types keep their camelCase JSONB shape.
    func test_digest_b4_jsonShape_isSnakeCase_forNestedInteractionTypes() throws {
        var model = makeBaselineModel()

        // PrescriptionAccuracy entry loud enough to surface (bias > 0.05 floor).
        model.prescriptionAccuracy = [
            .horizontalPush: [
                .top: PrescriptionAccuracy(
                    pattern: .horizontalPush, intent: .top,
                    bias: 0.08, rmse: 0.04, sampleCount: 10,
                    biasByGapBucket: [.under48h: -0.02, .over72h: 0.06],
                    rmseByGapBucket: [.under48h: 0.08, .over72h: 0.04],
                    sampleCountByGapBucket: [.under48h: 5, .over72h: 5]
                )
            ]
        ]
        // ActiveLimitation — pass-through (no digest-side filter today).
        model.activeLimitations = [
            ActiveLimitation(
                subject: .pattern(.squat),
                severity: .mild,
                onsetDate: ref.addingTimeInterval(-7 * 86400),
                evidenceCount: 2,
                userConfirmed: false,
                sessionsWithoutReMention: 1
            )
        ]
        // FatigueInteraction — 15 observations at -0.05 → consistency 1.0,
        // countFactor 1.0, confidence ≥ 0.7 surfaces.
        model.fatigueInteractions = [
            FatigueInteraction(
                fromPattern: .squat, toPattern: .horizontalPush,
                observations: Array(repeating: -0.05, count: 15),
                totalCount: 15
            )
        ]
        // ExerciseTransfer — passes Q10 lock (R²≥0.4 ∧ pairedObs≥5).
        model.transfers = [
            ExerciseTransfer(
                fromExerciseId: "bench_press",
                toExerciseId: "incline_bench_press",
                coefficient: 0.85, rSquared: 0.6,
                pairedObservations: 10
            )
        ]

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let data = try JSONEncoder().encode(digest)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // PrescriptionAccuracyDigest — multi-word fields must be snake_case.
        let accs = try XCTUnwrap(json["prescription_accuracy"] as? [[String: Any]])
        let acc = try XCTUnwrap(accs.first)
        XCTAssertNotNil(acc["sample_count"],
            "PrescriptionAccuracyDigest must emit sample_count (snake_case) — current camelCase makes the LLM-referenced path unreachable")
        XCTAssertNotNil(acc["bias_by_gap_bucket"],
            "PrescriptionAccuracyDigest must emit bias_by_gap_bucket (snake_case)")
        XCTAssertNotNil(acc["rmse_by_gap_bucket"],
            "PrescriptionAccuracyDigest must emit rmse_by_gap_bucket (snake_case)")
        XCTAssertNotNil(acc["sample_count_by_gap_bucket"],
            "PrescriptionAccuracyDigest must emit sample_count_by_gap_bucket (snake_case)")
        XCTAssertNil(acc["sampleCount"],
            "PrescriptionAccuracyDigest must not leak the camelCase persisted shape")
        XCTAssertNil(acc["biasByGapBucket"],
            "PrescriptionAccuracyDigest must not leak the camelCase persisted shape")

        // ActiveLimitationDigest — multi-word fields must be snake_case.
        let lims = try XCTUnwrap(json["active_limitations"] as? [[String: Any]])
        let lim = try XCTUnwrap(lims.first)
        XCTAssertNotNil(lim["onset_date"],
            "ActiveLimitationDigest must emit onset_date (snake_case)")
        XCTAssertNotNil(lim["evidence_count"],
            "ActiveLimitationDigest must emit evidence_count (snake_case)")
        XCTAssertNotNil(lim["user_confirmed"],
            "ActiveLimitationDigest must emit user_confirmed (snake_case)")
        XCTAssertNotNil(lim["sessions_without_re_mention"],
            "ActiveLimitationDigest must emit sessions_without_re_mention (snake_case)")
        XCTAssertNil(lim["onsetDate"],
            "ActiveLimitationDigest must not leak the camelCase persisted shape")

        // FatigueInteractionDigest — multi-word fields must be snake_case.
        let fis = try XCTUnwrap(json["active_fatigue_interactions"] as? [[String: Any]])
        let fi = try XCTUnwrap(fis.first)
        XCTAssertNotNil(fi["from_pattern"],
            "FatigueInteractionDigest must emit from_pattern (snake_case)")
        XCTAssertNotNil(fi["to_pattern"],
            "FatigueInteractionDigest must emit to_pattern (snake_case)")
        XCTAssertNotNil(fi["total_count"],
            "FatigueInteractionDigest must emit total_count (snake_case)")
        XCTAssertNil(fi["fromPattern"],
            "FatigueInteractionDigest must not leak the camelCase persisted shape")

        // ExerciseTransferDigest — multi-word fields must be snake_case.
        let trs = try XCTUnwrap(json["transfers"] as? [[String: Any]])
        let tr = try XCTUnwrap(trs.first)
        XCTAssertNotNil(tr["from_exercise_id"],
            "ExerciseTransferDigest must emit from_exercise_id (snake_case)")
        XCTAssertNotNil(tr["to_exercise_id"],
            "ExerciseTransferDigest must emit to_exercise_id (snake_case)")
        XCTAssertNotNil(tr["r_squared"],
            "ExerciseTransferDigest must emit r_squared (snake_case)")
        XCTAssertNotNil(tr["paired_observations"],
            "ExerciseTransferDigest must emit paired_observations (snake_case)")
        XCTAssertNil(tr["fromExerciseId"],
            "ExerciseTransferDigest must not leak the camelCase persisted shape")
        XCTAssertNil(tr["rSquared"],
            "ExerciseTransferDigest must not leak the camelCase persisted shape")
    }

    // MARK: ─── B1: PatternSummary surfaces consecutiveForceDeloadsOnPattern ──
    //
    // Per ADR-0011 §(d), the digest exposes a per-pattern counter that
    // increments on force-deload and resets on natural progressing-advance.
    // The system prompts read it to surface exercise-rotation / programme-
    // rebuild coaching cues when the counter reaches 2 (ADR-0011 watch-item).

    func test_digest_perPatternSummary_includesConsecutiveForceDeloadsOnPattern() {
        var model = makeBaselineModel()
        var profile = makePattern(.squat, confidence: .calibrating)
        profile.consecutiveForceDeloadsOnPattern = 2
        model.patterns[.squat] = profile

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let summary = try! XCTUnwrap(digest.perPatternSummary.first { $0.pattern == .squat })

        XCTAssertEqual(summary.consecutiveForceDeloadsOnPattern, 2)
    }

    func test_digest_perPatternSummary_consecutiveForceDeloadsOnPattern_roundTrips() throws {
        var model = makeBaselineModel()
        var profile = makePattern(.squat, confidence: .calibrating)
        profile.consecutiveForceDeloadsOnPattern = 3
        model.patterns[.squat] = profile

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let encoded = try JSONEncoder().encode(digest)
        let decoded = try JSONDecoder().decode(TraineeModelDigest.self, from: encoded)
        let summary = try XCTUnwrap(decoded.perPatternSummary.first { $0.pattern == .squat })

        XCTAssertEqual(summary.consecutiveForceDeloadsOnPattern, 3)
    }

    // MARK: ─── B1: β fixture suite — prompt anchors + payload per state ────
    //
    // Concern A: prompt anchors lock the production prompt text. SessionPlan
    // reads SystemPrompt_SessionPlan.txt (loaded by SessionPlanService at
    // runtime); Inference reads AIInferenceService.systemPrompt (inline
    // Swift string, the production authority — see #159 for consolidation).
    //
    // Concern B: payload-shape tests build a TraineeModelDigest for each
    // load-bearing state and assert the resulting JSON has the keys the
    // prompt block tells the LLM to read.

    // ─── Concern A: prompt anchors ────────────────────────────────────────

    private func loadSessionPlanPrompt() throws -> String {
        // #file resolves to this test source file; the .txt lives at
        // ProjectApex/Resources/Prompts/ relative to the repo root.
        let testFileURL = URL(fileURLWithPath: #file)
        let repoRoot = testFileURL
            .deletingLastPathComponent()  // ProjectApexTests/
            .deletingLastPathComponent()  // <repo root>
        let promptURL = repoRoot.appendingPathComponent(
            "ProjectApex/Resources/Prompts/SystemPrompt_SessionPlan.txt"
        )
        return try String(contentsOf: promptURL, encoding: .utf8)
    }

    func test_sessionPlanPrompt_containsPerPatternTrendBlock_andLacksLegacyStagnationPhrases() throws {
        let prompt = try loadSessionPlanPrompt()

        // Positive anchors: new PER-PATTERN TREND block per ADR-0009 + ADR-0011.
        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must carry v2.0 header (cache-bust)")
        XCTAssertTrue(prompt.contains("PER-PATTERN TREND"),
                      "SessionPlan must include the PER-PATTERN TREND section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.per_pattern_summary[].trend"),
                      "SessionPlan must reference the trend JSON path")
        XCTAssertTrue(prompt.contains("\"plateaued\""),
                      "SessionPlan must include the plateaued interpretation rule")
        XCTAssertTrue(prompt.contains("\"declining\""),
                      "SessionPlan must include the declining interpretation rule")
        XCTAssertTrue(prompt.contains("\"progressing\""),
                      "SessionPlan must include the progressing default rule")
        XCTAssertTrue(prompt.contains("consecutive_force_deloads_on_pattern >= 2"),
                      "SessionPlan must include the force-deload surfacing rule (ADR-0011 §d)")

        // Negative anchors: legacy STAGNATION SIGNALS phrasing removed.
        XCTAssertFalse(prompt.contains("STAGNATION SIGNALS"),
                       "Legacy STAGNATION SIGNALS section header must not reappear")
        XCTAssertFalse(prompt.contains("stagnation_signals contains exercises"),
                       "Legacy stagnation_signals interpretation prose must not reappear")
    }

    func test_sessionPlanPrompt_containsHeavyReassessmentBlock() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("HEAVY REASSESSMENT (ADR-0005 / ADR-0012)"),
                      "SessionPlan must include the HEAVY REASSESSMENT section header per #178")
        XCTAssertTrue(prompt.contains("trainee_model_digest.heavy_reassessment_signal"),
                      "SessionPlan must reference the heavy_reassessment_signal digest path so the LLM reads the correct field")
        XCTAssertTrue(prompt.contains("recently_advanced_patterns"),
                      "SessionPlan must direct the LLM to name the recently advanced patterns")
        XCTAssertTrue(prompt.contains("sessions_since_triggered"),
                      "SessionPlan must direct the LLM to calibrate emphasis from sessions_since_triggered")
        XCTAssertTrue(prompt.contains("Do NOT\ngenerate new numerical targets"),
                      "SessionPlan must explicitly prohibit inventing numerical goal targets — goal renegotiation is a UI flow per ADR-0005")
        XCTAssertTrue(prompt.contains("Block absent → no reassessment commentary"),
                      "SessionPlan must include the absent-block negative anchor — the LLM should not invent the trigger when the signal is missing")
    }

    func test_inferencePrompt_containsPerPatternTrendBlock() {
        // Production Inference reads AIInferenceService.systemPrompt — now a
        // computed accessor backed by SystemPrompt_Inference.txt loaded from
        // the bundle resource at call time (per #159 consolidation).
        let prompt = AIInferenceService.systemPrompt

        XCTAssertTrue(prompt.contains("PER-PATTERN TREND"),
                      "Inference prompt must include the PER-PATTERN TREND section header")
        XCTAssertTrue(prompt.contains("overrides PROGRESSIVE OVERLOAD when non-progressing"),
                      "Inference prompt must explicitly mark trend as an override on the default progression")
        XCTAssertTrue(prompt.contains("trainee_model_digest.per_pattern_summary[]"),
                      "Inference prompt must reference the digest JSON path")
        XCTAssertTrue(prompt.contains("\"plateaued\""),
                      "Inference must include the plateaued interpretation rule")
        XCTAssertTrue(prompt.contains("\"declining\""),
                      "Inference must include the declining interpretation rule")
        XCTAssertTrue(prompt.contains("\"progressing\""),
                      "Inference must include the progressing default rule")
        XCTAssertTrue(prompt.contains("consecutive_force_deloads_on_pattern >= 2"),
                      "Inference must include the force-deload surfacing rule (ADR-0011 §d)")
        XCTAssertTrue(prompt.contains("a regressing user does not get a weight increase"),
                      "Inference must include the asymmetric-error override clause")
    }

    // MARK: ─── B2 (#87): VOLUME DEFICIT block — prompt-shape anchors ──────────

    func test_sessionPlanPrompt_containsVolumeDeficitBlock_andLacksLegacyVolumeDeficitsPhrases() throws {
        let prompt = try loadSessionPlanPrompt()

        // Positive anchors: new VOLUME DEFICIT block — MEV-calibrated per
        // #156's Q1 lock (supabase/functions/_shared/per-muscle-rules.ts:7-11),
        // queue-event-windowed per ADR-0002, consuming the digest path.
        XCTAssertTrue(prompt.contains("VOLUME DEFICIT\n"),
                      "SessionPlan must include the VOLUME DEFICIT section header (new form, not legacy …SIGNALS)")
        XCTAssertTrue(prompt.contains("trainee_model_digest.per_muscle_summary[].volume_deficit"),
                      "SessionPlan must reference the digest volume_deficit JSON path")
        XCTAssertTrue(prompt.contains("MEV"),
                      "SessionPlan must frame the deficit as MEV-relative (matches #156 Q1 semantic lock)")
        XCTAssertTrue(prompt.contains("growth threshold"),
                      "SessionPlan must use the growth-threshold framing per Q1 MEV semantic")
        XCTAssertTrue(prompt.contains("last 7 training events"),
                      "SessionPlan must surface the queue-event-windowed semantic per ADR-0002")
        XCTAssertTrue(prompt.contains("+3 sets"),
                      "SessionPlan must preserve the +3-sets cap from the legacy block")
        XCTAssertTrue(prompt.contains("day_focus"),
                      "SessionPlan must preserve the day_focus respect rule")

        // Header bullet (cycle 3): version header records B2's cumulative change.
        XCTAssertTrue(prompt.contains("Replaced legacy volume_deficits consumption"),
                      "SessionPlan v2.0 header must record the B2 cumulative change")

        // Negative anchors: legacy VOLUME DEFICIT SIGNALS phrasing removed.
        XCTAssertFalse(prompt.contains("VOLUME DEFICIT SIGNALS"),
                       "Legacy VOLUME DEFICIT SIGNALS section header must not reappear")
        XCTAssertFalse(prompt.contains("volume_deficits flags muscle groups"),
                       "Legacy volume_deficits interpretation prose must not reappear")
        XCTAssertFalse(prompt.contains("≥20% below the"),
                       "Legacy 20%-below-target framing must not reappear (replaced with MEV-relative integer count)")
    }

    // MARK: ─── B3 (#88): PER-PATTERN PHASE STATE block — prompt-shape anchors ───
    //
    // B3 replaces the legacy `temporal_context.pattern_phases` consumption with
    // `trainee_model_digest.per_pattern_summary[].current_phase` +
    // `in_transition_mode` + `disrupted_patterns` (ADR-0005, ADR-0011).
    // Each β anchor below drives one chunk of the new block.

    func test_sessionPlanPrompt_b3_teachesDeloadPhasePrescription_fromDigestCurrentPhase() throws {
        let prompt = try loadSessionPlanPrompt()

        // New section header replaces legacy "PER-PATTERN PHASE TRACKING".
        XCTAssertTrue(prompt.contains("PER-PATTERN PHASE STATE"),
                      "SessionPlan must include the PER-PATTERN PHASE STATE section header (B3 replaces legacy PER-PATTERN PHASE TRACKING)")
        // Digest path replaces legacy temporal_context.pattern_phases.
        XCTAssertTrue(prompt.contains("trainee_model_digest.per_pattern_summary[].current_phase"),
                      "SessionPlan must reference the digest current_phase JSON path")
        // Phase enum surfaces in the new block so the LLM knows .deload is a valid value.
        XCTAssertTrue(prompt.contains("\"deload\""),
                      "SessionPlan must enumerate the deload phase in the new PER-PATTERN PHASE STATE block")
    }

    func test_sessionPlanPrompt_b3_teachesTransitionModeInterpretation_fromDigestInTransitionMode() throws {
        let prompt = try loadSessionPlanPrompt()

        // Digest field reference — transition-mode is surfaced per-pattern.
        XCTAssertTrue(prompt.contains("in_transition_mode"),
                      "SessionPlan must reference the digest in_transition_mode field (ADR-0005)")
        // ADR-0005's transition-mode formula collapses to 3 most recent sessions.
        XCTAssertTrue(prompt.contains("3 most recent sessions"),
                      "SessionPlan must surface the collapsed 3-session window semantic so the LLM does not anchor on stale pre-transition data")
    }

    func test_sessionPlanPrompt_b3_teachesDisruptedPatternsReintroduction_fromDigestDisruptedPatterns() throws {
        let prompt = try loadSessionPlanPrompt()

        // Per Q2 resolution: digest-based, cadence-relative (replaces the legacy
        // ≥21-day absolute-day override that used to live inside the per-pattern
        // phase block).
        XCTAssertTrue(prompt.contains("DISRUPTED PATTERNS"),
                      "SessionPlan must include a DISRUPTED PATTERNS subsection")
        XCTAssertTrue(prompt.contains("trainee_model_digest.disrupted_patterns"),
                      "SessionPlan must reference the digest disrupted_patterns array")
        XCTAssertTrue(prompt.contains("2× typical cadence"),
                      "SessionPlan must surface ADR-0005's cadence-relative semantic (current absence > 2× typical cadence)")
    }

    func test_sessionPlanPrompt_b3_teachesPatternOverGlobalDivergence_whenPatternPhaseLagsGlobalPhase() throws {
        let prompt = try loadSessionPlanPrompt()

        // Earlier-than-global and later-than-global divergence rules — preserved
        // from the legacy PER-PATTERN PHASE TRACKING block, restated against the
        // new digest contract.
        XCTAssertTrue(prompt.contains("EARLIER phase than the global"),
                      "SessionPlan must teach that a pattern in an EARLIER phase than global is undertrained")
        XCTAssertTrue(prompt.contains("LATER phase than the global"),
                      "SessionPlan must teach that a pattern in a LATER phase than global is ahead")
        // Session-notes divergence threshold — keep noisy notes off when divergence is small.
        XCTAssertTrue(prompt.contains("2 or more phases behind"),
                      "SessionPlan must include the 2-phase-divergence session_notes threshold")
    }

    func test_sessionPlanPrompt_b3_versionHeaderRecordsB3CumulativeChange() throws {
        let prompt = try loadSessionPlanPrompt()

        // Per Q L6 lock: stay at v2.0 (cumulative bullet, not version bump — minor
        // edits within v2.0 are cache-compatible per PromptCachingProvider).
        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must remain at v2.0 (no version bump in B3)")
        XCTAssertTrue(prompt.contains("Replaced legacy temporal_context.pattern_phases"),
                      "SessionPlan v2.0 header must record the B3 cumulative change")
    }

    func test_sessionPlanPrompt_b3_teachesPhaseCycling_postDeloadResumesAccumulation() throws {
        let prompt = try loadSessionPlanPrompt()

        // ADR-0011 (c): mesocycle is cyclic — deload → accumulation, no terminal phase.
        // Without the cue, the LLM may treat post-deload as "programme ended" rather
        // than as the start of the next accumulation cycle.
        XCTAssertTrue(prompt.contains("PHASE-CYCLING"),
                      "SessionPlan must include a PHASE-CYCLING subsection (ADR-0011 (c))")
        XCTAssertTrue(prompt.contains("ADR-0011"),
                      "SessionPlan must cite ADR-0011 as the source of the cyclic mesocycle decision")
        XCTAssertTrue(prompt.contains("deload → accumulation"),
                      "SessionPlan must describe the deload → accumulation cycling (no terminal phase)")
        XCTAssertTrue(prompt.contains("lower end of accumulation"),
                      "SessionPlan must teach post-deload prescription at the lower end of accumulation rep ranges (lifted but restored capability)")
    }

    // MARK: ─── B4 (#89) cycle 9b: PRESCRIPTION ACCURACY block — prompt anchors ───
    //
    // ADR-0014 §"Digest exposure filter" — an entry surfaces only when
    // sampleCount ≥ 5 AND ( |bias| > 0.05 OR rmse > 0.10 OR gap-bucket
    // divergence > 0.05 ). Sign convention (rep-error = (reps_completed -
    // reps_prescribed) / reps_prescribed): positive bias = AI under-prescribed,
    // negative = AI over-prescribed. The gap-bucket divergence ties to ADR-0010
    // (fatigue-stacking detection).

    func test_sessionPlanPrompt_b4_9b_referencesPrescriptionAccuracyDigestPath() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("PRESCRIPTION ACCURACY"),
                      "SessionPlan must include the PRESCRIPTION ACCURACY section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.prescription_accuracy"),
                      "SessionPlan must reference the digest prescription_accuracy JSON path")
        XCTAssertTrue(prompt.contains("ADR-0014"),
                      "SessionPlan must cite ADR-0014 (digest exposure filter — every surfaced entry is a loud signal)")
    }

    func test_sessionPlanPrompt_b4_9b_teachesPositiveBiasMeansUnderPrescribed() throws {
        let prompt = try loadSessionPlanPrompt()

        // Rep-error sign convention (ADR-0014 §"Error metric"): positive bias =
        // user exceeded prescribed reps = AI under-prescribed → load should increase.
        XCTAssertTrue(prompt.contains("bias > 0"),
                      "SessionPlan must surface the positive-bias rule")
        XCTAssertTrue(prompt.contains("under-prescribed"),
                      "SessionPlan must explain positive bias as AI under-prescribing (load too light)")
        XCTAssertTrue(prompt.contains("increase load"),
                      "SessionPlan must instruct increasing load on positive bias")
    }

    func test_sessionPlanPrompt_b4_9b_teachesNegativeBiasMeansOverPrescribed() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("bias < 0"),
                      "SessionPlan must surface the negative-bias rule")
        XCTAssertTrue(prompt.contains("over-prescribed"),
                      "SessionPlan must explain negative bias as AI over-prescribing (load too heavy)")
        XCTAssertTrue(prompt.contains("reduce load"),
                      "SessionPlan must instruct reducing load on negative bias")
    }

    func test_sessionPlanPrompt_b4_9b_teachesRmseAsPrescriptionNoise() throws {
        let prompt = try loadSessionPlanPrompt()

        // High RMSE with low bias = prescription is noisy across observations.
        // Guidance: lean conservative, anchor on the user's most recent on-target
        // working set rather than the historical median.
        XCTAssertTrue(prompt.contains("rmse"),
                      "SessionPlan must reference the rmse field on each cell")
        XCTAssertTrue(prompt.contains("noisy"),
                      "SessionPlan must frame high rmse as noisy / inconsistent prescription")
    }

    func test_sessionPlanPrompt_b4_9b_teachesGapBucketDivergence_andCitesAdr0010() throws {
        let prompt = try loadSessionPlanPrompt()

        // Gap-bucket divergence signal — when bias differs sharply between
        // under_48h and over_72h cells, the AI isn't accounting for inter-session
        // recovery state (ADR-0010 fatigue-stacking).
        XCTAssertTrue(prompt.contains("bias_by_gap_bucket"),
                      "SessionPlan must reference the digest bias_by_gap_bucket path (snake_case — see cycle 9a wire-shape lock)")
        XCTAssertTrue(prompt.contains("ADR-0010"),
                      "SessionPlan must cite ADR-0010 for the fatigue-stacking semantic underlying gap-bucket divergence")
        XCTAssertTrue(prompt.contains("temporal_context"),
                      "SessionPlan must tie the gap-bucket calibration to temporal_context (which gap bucket applies to today's session)")
    }

    func test_sessionPlanPrompt_b4_9b_versionHeaderRecordsB4Cycle9bCumulativeChange() throws {
        let prompt = try loadSessionPlanPrompt()

        // Per the cycle 21 lock: stay at v2.0 (cumulative bullet) — major version
        // bumps are atomic at cycle 21.
        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must remain at v2.0 (no version bump mid-B4)")
        XCTAssertTrue(prompt.contains("Added PRESCRIPTION ACCURACY block"),
                      "SessionPlan v2.0 header must record the B4 cycle 9b cumulative change")
    }

    // MARK: ─── B4 (#89) cycle 10: CROSS-EXERCISE TRANSFER block — prompt anchors ──
    //
    // Reads trainee_model_digest.transfers[] (already filtered to R²≥0.4 ∧
    // pairedObservations≥5 per Q10 lock-in — entries the LLM should reason
    // from). Each entry: from_exercise_id, to_exercise_id, coefficient,
    // r_squared, paired_observations.

    func test_sessionPlanPrompt_b4_10_referencesTransfersDigestPath() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("CROSS-EXERCISE TRANSFER"),
                      "SessionPlan must include the CROSS-EXERCISE TRANSFER section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.transfers"),
                      "SessionPlan must reference the digest transfers JSON path")
        XCTAssertTrue(prompt.contains("R² ≥ 0.4"),
                      "SessionPlan must surface the Q10 R² filter floor so the LLM knows surfaced entries are vetted")
        XCTAssertTrue(prompt.contains("paired_observations"),
                      "SessionPlan must reference the digest paired_observations field (≥ 5 filter input)")
    }

    func test_sessionPlanPrompt_b4_10_teachesCoefficientAsStrengthRatio() throws {
        let prompt = try loadSessionPlanPrompt()

        // Coefficient meaning: target_weight on `to` exercise ≈ source_weight on
        // `from` exercise × coefficient (same intent / rep target). Surface the
        // multiplication so the LLM doesn't invert the relationship.
        XCTAssertTrue(prompt.contains("coefficient"),
                      "SessionPlan must reference the coefficient field")
        XCTAssertTrue(prompt.contains("from_exercise_id"),
                      "SessionPlan must reference the from_exercise_id source side")
        XCTAssertTrue(prompt.contains("to_exercise_id"),
                      "SessionPlan must reference the to_exercise_id target side")
        XCTAssertTrue(prompt.contains("× coefficient"),
                      "SessionPlan must teach the multiplication direction (target ≈ source × coefficient) so the LLM does not invert the ratio")
    }

    func test_sessionPlanPrompt_b4_10_teachesRSquaredAsConfidenceWeighting() throws {
        let prompt = try loadSessionPlanPrompt()

        // R² is the regression-fit quality. Per Q10 lock, the filter excludes
        // R² < 0.4, so any surfaced entry is at-least "moderate fit". The
        // prompt should still differentiate moderate (≈0.4–0.6) from strong
        // (≥0.7) so the LLM weights its anchor confidence.
        XCTAssertTrue(prompt.contains("r_squared"),
                      "SessionPlan must reference the r_squared field")
        XCTAssertTrue(prompt.contains("higher r_squared"),
                      "SessionPlan must teach that higher r_squared = stronger evidence (weight the anchor accordingly)")
    }

    func test_sessionPlanPrompt_b4_10_teachesWhenToUseTransfer_lowHistoryAnchoring() throws {
        let prompt = try loadSessionPlanPrompt()

        // Primary use case: anchoring starting weight on an exercise the user
        // has low lift_history depth on, when a related transferring exercise
        // has rich history. Should NOT override direct recent sets on the
        // target exercise — transfer is for cold-start, not for overriding fresh
        // signal.
        XCTAssertTrue(prompt.contains("calibration") || prompt.contains("anchor starting weight"),
                      "SessionPlan must explain when to apply the transfer (cold-start calibration / anchoring starting weight)")
        XCTAssertTrue(prompt.contains("session_count"),
                      "SessionPlan must tie the transfer use to lift_history session_count (low history on target → consult transfer)")
        XCTAssertTrue(prompt.contains("override recent direct sets"),
                      "SessionPlan must warn against using transfer to override direct recent sets on the target exercise")
    }

    func test_sessionPlanPrompt_b4_10_versionHeaderRecordsB4Cycle10CumulativeChange() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must remain at v2.0 (no version bump mid-B4)")
        XCTAssertTrue(prompt.contains("Added CROSS-EXERCISE TRANSFER block"),
                      "SessionPlan v2.0 header must record the B4 cycle 10 cumulative change")
    }

    // MARK: ─── B4 (#89) cycle 11: CROSS-PATTERN FATIGUE INTERACTIONS — anchors ──
    //
    // Reads trainee_model_digest.active_fatigue_interactions[] (already
    // filtered to confidence ≥ 0.7 per ADR-0005). FatigueInteractionDigest
    // drops the raw observations array in favour of a precomputed
    // recent_effect_mean scalar (mean of the last-10 observations window,
    // matching consistencyFactor's window) — LLM-friendly and ~10× lower
    // token cost than emitting the array.

    func test_digest_b4_11_fatigueInteractionDigest_emitsRecentEffectMean_andDropsObservations() throws {
        var model = makeBaselineModel()
        // 15 observations all -0.05 → confidence ≥ 0.7 surfaces.
        model.fatigueInteractions = [
            FatigueInteraction(
                fromPattern: .squat, toPattern: .horizontalPush,
                observations: Array(repeating: -0.05, count: 15),
                totalCount: 15
            )
        ]

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let data = try JSONEncoder().encode(digest)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let fis = try XCTUnwrap(json["active_fatigue_interactions"] as? [[String: Any]])
        let fi = try XCTUnwrap(fis.first)
        let mean = try XCTUnwrap(fi["recent_effect_mean"] as? Double)
        XCTAssertEqual(mean, -0.05, accuracy: 1e-9,
            "recent_effect_mean must equal the mean of the last-10 observations window")
        XCTAssertNil(fi["observations"],
            "FatigueInteractionDigest must not emit the raw observations array (token economy + LLM-array-math avoidance)")
    }

    func test_sessionPlanPrompt_b4_11_referencesFatigueInteractionsDigestPath() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("CROSS-PATTERN FATIGUE INTERACTIONS"),
                      "SessionPlan must include the CROSS-PATTERN FATIGUE INTERACTIONS section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.active_fatigue_interactions"),
                      "SessionPlan must reference the digest active_fatigue_interactions JSON path")
        XCTAssertTrue(prompt.contains("confidence ≥ 0.7"),
                      "SessionPlan must surface the ADR-0005 confidence filter (every surfaced pair is a vetted signal)")
    }

    func test_sessionPlanPrompt_b4_11_teachesRecentEffectMeanDirection() throws {
        let prompt = try loadSessionPlanPrompt()

        // Sign convention (delta-percent of capacity on to_pattern after
        // from_pattern): negative = fatigue carryover (capacity reduced),
        // positive = potentiation (capacity boosted).
        XCTAssertTrue(prompt.contains("recent_effect_mean"),
                      "SessionPlan must reference the recent_effect_mean field")
        XCTAssertTrue(prompt.contains("from_pattern"),
                      "SessionPlan must reference from_pattern")
        XCTAssertTrue(prompt.contains("to_pattern"),
                      "SessionPlan must reference to_pattern")
        XCTAssertTrue(prompt.contains("fatigue carryover"),
                      "SessionPlan must label negative recent_effect_mean as fatigue carryover")
        XCTAssertTrue(prompt.contains("potentiation"),
                      "SessionPlan must label positive recent_effect_mean as potentiation")
    }

    func test_sessionPlanPrompt_b4_11_tiesAdjustmentToTemporalContext() throws {
        let prompt = try loadSessionPlanPrompt()

        // Application rule: only adjust today's prescription if from_pattern
        // was trained recently enough for the carryover to apply.
        XCTAssertTrue(prompt.contains("days_since_last_trained_by_pattern"),
                      "SessionPlan must tie the fatigue-interaction adjustment to temporal_context recency for from_pattern")
        XCTAssertTrue(prompt.contains("educe prescribed load"),
                      "SessionPlan must instruct reducing prescribed load on to_pattern when carryover is active")
    }

    func test_sessionPlanPrompt_b4_11_versionHeaderRecordsB4Cycle11CumulativeChange() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must remain at v2.0 (no version bump mid-B4)")
        XCTAssertTrue(prompt.contains("Added CROSS-PATTERN FATIGUE INTERACTIONS block"),
                      "SessionPlan v2.0 header must record the B4 cycle 11 cumulative change")
    }

    // MARK: ─── B4 (#89) cycle 12: ACTIVE LIMITATIONS block — prompt anchors ──

    func test_sessionPlanPrompt_b4_12_referencesActiveLimitationsDigestPath() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("ACTIVE LIMITATIONS\n"),
                      "SessionPlan must include the ACTIVE LIMITATIONS section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.active_limitations"),
                      "SessionPlan must reference the digest active_limitations JSON path")
    }

    func test_sessionPlanPrompt_b4_12_teachesSubjectAndSeverityFields() throws {
        let prompt = try loadSessionPlanPrompt()

        // subject is a tagged union — {kind: pattern|muscle|joint, value: …}.
        XCTAssertTrue(prompt.contains("subject"),
                      "SessionPlan must reference the subject field on each entry")
        XCTAssertTrue(prompt.contains("\"pattern\"") && prompt.contains("\"muscle\"") && prompt.contains("\"joint\""),
                      "SessionPlan must enumerate the LimitationSubject kinds")
        // Severity grading.
        XCTAssertTrue(prompt.contains("severity"),
                      "SessionPlan must reference the severity field")
        XCTAssertTrue(prompt.contains("\"mild\"") && prompt.contains("\"moderate\"") && prompt.contains("\"severe\""),
                      "SessionPlan must enumerate all three Severity values")
    }

    func test_sessionPlanPrompt_b4_12_teachesUserConfirmedDistinction() throws {
        let prompt = try loadSessionPlanPrompt()

        // ADR-0005: AI-inferred limitations cap at .mild until user confirms.
        // The prompt must surface user_confirmed so the LLM weights confidence.
        XCTAssertTrue(prompt.contains("user_confirmed"),
                      "SessionPlan must reference the user_confirmed field")
        XCTAssertTrue(prompt.contains("AI-inferred"),
                      "SessionPlan must contrast AI-inferred (cap at mild) vs user-confirmed")
        XCTAssertTrue(prompt.contains("ADR-0005"),
                      "SessionPlan must cite ADR-0005 for the corroboration-threshold cap")
    }

    func test_sessionPlanPrompt_b4_12_teachesSeverityGradedActions() throws {
        let prompt = try loadSessionPlanPrompt()

        // Three severity bands have distinct programming actions: mild = scale
        // load, moderate = substitute, severe = full avoid.
        XCTAssertTrue(prompt.contains("10–15%"),
                      "SessionPlan must surface the mild-severity load-scaling magnitude")
        XCTAssertTrue(prompt.contains("ubstitute"),
                      "SessionPlan must instruct substitution on moderate-severity (case-insensitive on leading char)")
        XCTAssertTrue(prompt.contains("Full avoidance") || prompt.contains("full avoidance"),
                      "SessionPlan must instruct full avoidance on severe-severity")
    }

    func test_sessionPlanPrompt_b4_12_versionHeaderRecordsB4Cycle12CumulativeChange() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must remain at v2.0 (no version bump mid-B4)")
        XCTAssertTrue(prompt.contains("Added ACTIVE LIMITATIONS block"),
                      "SessionPlan v2.0 header must record the B4 cycle 12 cumulative change")
    }

    // MARK: ─── B4 (#89) cycle 13: FORM-DEGRADATION FLAG block — prompt anchors ──

    func test_sessionPlanPrompt_b4_13_referencesFormDegradationDigestPath() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("FORM-DEGRADATION"),
                      "SessionPlan must include the FORM-DEGRADATION section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.per_exercise_summary[].form_degradation_flag"),
                      "SessionPlan must reference the digest form_degradation_flag JSON path")
    }

    func test_sessionPlanPrompt_b4_13_teachesBackOffWhenFlagged() throws {
        let prompt = try loadSessionPlanPrompt()

        // When form_degradation_flag = true: back off — lighter load, lower
        // intensity, prioritise form. Do NOT push for a PR.
        XCTAssertTrue(prompt.contains("lighter load") || prompt.contains("reduce load"),
                      "SessionPlan must instruct lighter load on flagged exercises")
        XCTAssertTrue(prompt.contains("orm-focused") || prompt.contains("orm quality"),
                      "SessionPlan must instruct a form-focused coaching cue (case-insensitive on leading char)")
        XCTAssertTrue(prompt.contains("do not push") || prompt.contains("Do not push") || prompt.contains("not pursue a PR") || prompt.contains("not pursue PR"),
                      "SessionPlan must forbid pursuing a PR while form_degradation_flag is true")
    }

    func test_sessionPlanPrompt_b4_13_versionHeaderRecordsB4Cycle13CumulativeChange() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must remain at v2.0 (no version bump mid-B4)")
        XCTAssertTrue(prompt.contains("Added FORM-DEGRADATION FLAG block"),
                      "SessionPlan v2.0 header must record the B4 cycle 13 cumulative change")
    }

    // MARK: ─── B4 (#89) cycle 14: WEEK FATIGUE SIGNALS rewrite — redirect to digest ──

    func test_sessionPlanPrompt_b4_14_redirectsWeekFatigueToDigestPath() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("trainee_model_digest.weekly_fatigue"),
                      "SessionPlan WEEK FATIGUE SIGNALS must read trainee_model_digest.weekly_fatigue (not top-level week_fatigue)")
        // Legacy "Read week_fatigue carefully" prose must be gone — the standalone
        // top-level path was deprecated when WeeklyFatigueSummary was deleted in
        // cycle 7. Note "week_fatigue" with underscore-f does NOT appear inside
        // "weekly_fatigue", so the negative anchor is safe.
        XCTAssertFalse(prompt.contains("Read week_fatigue"),
                       "Legacy 'Read week_fatigue …' prose must be removed (replaced with the digest path)")
    }

    func test_sessionPlanPrompt_b4_14_preservesFatigueAndDeloadFlagBehaviors() throws {
        let prompt = try loadSessionPlanPrompt()

        // (I) lock: pre-derived flags in the digest. Behaviors stay identical;
        // only the path changes.
        XCTAssertTrue(prompt.contains("fatigue_management_flagged"),
                      "WEEK FATIGUE SIGNALS must keep the fatigue_management_flagged rule (pre-derived flag per (I) lock)")
        XCTAssertTrue(prompt.contains("deload_triggered"),
                      "WEEK FATIGUE SIGNALS must keep the deload_triggered rule")
        XCTAssertTrue(prompt.contains("is_fatigue_management_day = true"),
                      "WEEK FATIGUE SIGNALS must preserve the is_fatigue_management_day = true behaviour")
        XCTAssertTrue(prompt.contains("is_deload = true"),
                      "WEEK FATIGUE SIGNALS must preserve the is_deload = true behaviour")
    }

    func test_sessionPlanPrompt_b4_14_versionHeaderRecordsB4Cycle14CumulativeChange() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must remain at v2.0 (no version bump mid-B4)")
        XCTAssertTrue(prompt.contains("Redirected WEEK FATIGUE SIGNALS"),
                      "SessionPlan v2.0 header must record the B4 cycle 14 cumulative change (path redirect)")
    }

    // MARK: ─── B4 (#89) cycle 15: Inference PRESCRIPTION ACCURACY block ──

    func test_inferencePrompt_b4_15_containsPrescriptionAccuracyBlock() {
        let prompt = AIInferenceService.systemPrompt

        XCTAssertTrue(prompt.contains("PRESCRIPTION ACCURACY"),
                      "Inference must include the PRESCRIPTION ACCURACY section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.prescription_accuracy"),
                      "Inference must reference the digest prescription_accuracy JSON path")
        XCTAssertTrue(prompt.contains("ADR-0014"),
                      "Inference must cite ADR-0014 (digest exposure filter)")
        XCTAssertTrue(prompt.contains("under-prescribed"),
                      "Inference must explain positive bias as AI under-prescribing")
        XCTAssertTrue(prompt.contains("over-prescribed"),
                      "Inference must explain negative bias as AI over-prescribing")
    }

    // MARK: ─── B4 (#89) cycle 16: Inference CROSS-EXERCISE TRANSFER block ──

    func test_inferencePrompt_b4_16_containsCrossExerciseTransferBlock() {
        let prompt = AIInferenceService.systemPrompt

        XCTAssertTrue(prompt.contains("CROSS-EXERCISE TRANSFER"),
                      "Inference must include the CROSS-EXERCISE TRANSFER section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.transfers"),
                      "Inference must reference the digest transfers JSON path")
        XCTAssertTrue(prompt.contains("× coefficient"),
                      "Inference must teach the multiplication direction (target ≈ source × coefficient)")
    }

    // MARK: ─── B4 (#89) cycle 17: Inference CROSS-PATTERN FATIGUE INTERACTIONS ──

    func test_inferencePrompt_b4_17_containsFatigueInteractionsBlock() {
        let prompt = AIInferenceService.systemPrompt

        XCTAssertTrue(prompt.contains("CROSS-PATTERN FATIGUE INTERACTIONS"),
                      "Inference must include the CROSS-PATTERN FATIGUE INTERACTIONS section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.active_fatigue_interactions"),
                      "Inference must reference the digest active_fatigue_interactions JSON path")
        XCTAssertTrue(prompt.contains("recent_effect_mean"),
                      "Inference must reference the recent_effect_mean field")
        XCTAssertTrue(prompt.contains("fatigue carryover"),
                      "Inference must label negative recent_effect_mean as fatigue carryover")
    }

    // MARK: ─── B4 (#89) cycle 18: Inference ACTIVE LIMITATIONS ──

    func test_inferencePrompt_b4_18_containsActiveLimitationsBlock() {
        let prompt = AIInferenceService.systemPrompt

        XCTAssertTrue(prompt.contains("ACTIVE LIMITATIONS"),
                      "Inference must include the ACTIVE LIMITATIONS section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.active_limitations"),
                      "Inference must reference the digest active_limitations JSON path")
        XCTAssertTrue(prompt.contains("severity"),
                      "Inference must reference the severity field")
        XCTAssertTrue(prompt.contains("user_confirmed"),
                      "Inference must reference the user_confirmed field for AI-inferred vs confirmed weighting")
    }

    // MARK: ─── B4 (#89) cycle 19: Inference FORM-DEGRADATION FLAG ──

    func test_inferencePrompt_b4_19_containsFormDegradationFlagBlock() {
        let prompt = AIInferenceService.systemPrompt

        XCTAssertTrue(prompt.contains("FORM-DEGRADATION"),
                      "Inference must include the FORM-DEGRADATION section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.per_exercise_summary[].form_degradation_flag"),
                      "Inference must reference the digest form_degradation_flag JSON path")
        XCTAssertTrue(prompt.contains("not push for a PR") || prompt.contains("not pursue a PR"),
                      "Inference must forbid pursuing a PR while form_degradation_flag is true")
    }

    // MARK: ─── B4 (#89) cycle 20: Inference DELOAD DETECTION rewrite ──

    func test_inferencePrompt_b4_20_deloadDetectionReadsDigestWeeklyFatigue() {
        let prompt = AIInferenceService.systemPrompt

        // Positive anchors: new path + pre-derived flags (I) lock.
        XCTAssertTrue(prompt.contains("DELOAD DETECTION"),
                      "Inference must keep the DELOAD DETECTION section header")
        XCTAssertTrue(prompt.contains("trainee_model_digest.weekly_fatigue"),
                      "Inference DELOAD DETECTION must read trainee_model_digest.weekly_fatigue (not weekly_fatigue_summary)")
        XCTAssertTrue(prompt.contains("deload_triggered"),
                      "Inference DELOAD DETECTION must follow the pre-derived deload_triggered flag")
        XCTAssertTrue(prompt.contains("fatigue_management_flagged"),
                      "Inference DELOAD DETECTION must follow the pre-derived fatigue_management_flagged flag")
    }

    func test_inferencePrompt_b4_20_deloadDetectionStripsLegacyShape() {
        let prompt = AIInferenceService.systemPrompt

        // Negative anchors: legacy WeeklyFatigueSummary fields + "coaching
        // judgement" subjective framing must be gone per (I) lock.
        XCTAssertFalse(prompt.contains("weekly_fatigue_summary"),
                       "Legacy weekly_fatigue_summary path must be removed (WeeklyFatigueSummary type deleted in cycle 7)")
        XCTAssertFalse(prompt.contains("coaching judgement"),
                       "Legacy 'make a coaching judgement' subjective framing must be removed — pre-derived flags drive the decision (I lock)")
        XCTAssertFalse(prompt.contains("sessions_this_week"),
                       "Legacy WeeklyFatigueSummary field name sessions_this_week must be gone")
        XCTAssertFalse(prompt.contains("avg_rpe_this_week"),
                       "Legacy WeeklyFatigueSummary field name avg_rpe_this_week must be gone")
        XCTAssertFalse(prompt.contains("exercises_with_multiple_misses"),
                       "Legacy WeeklyFatigueSummary field name exercises_with_multiple_misses must be gone")
        XCTAssertFalse(prompt.contains("total_sets_this_week"),
                       "Legacy WeeklyFatigueSummary field name total_sets_this_week must be gone")
    }

    // MARK: ─── B4 (#89) cycle 21: version bumps + cumulative annotation ──

    func test_sessionPlanPrompt_b4_21_versionBumpedTo_v3() throws {
        let prompt = try loadSessionPlanPrompt()

        XCTAssertTrue(prompt.contains("VERSION: 3.0"),
                      "SessionPlan prompt must be bumped to v3.0 at cycle 21 (cache-bust for cumulative B1+B2+B3+B4)")
        XCTAssertFalse(prompt.contains("VERSION: 2.0"),
                       "SessionPlan prompt v2.0 line must be replaced (not duplicated) by v3.0")
        XCTAssertTrue(prompt.contains("CHANGES FROM v2.0"),
                      "SessionPlan v3.0 header must summarise the cumulative B1+B2+B3+B4 changes")
    }

    func test_inferencePrompt_b4_21_versionBumpedTo_v6() throws {
        // The Inference VERSION lives in a Swift // comment above the
        // systemPrompt literal — not inside the prompt string. Read the source
        // file to verify the version annotation tracks the cycle 21 bump.
        let source = try loadSourceFile("ProjectApex/AICoach/AIInferenceService.swift")

        XCTAssertTrue(source.contains("VERSION: 6.0"),
                      "AIInferenceService.systemPrompt VERSION comment must be bumped to 6.0 at cycle 21 (cumulative B1+B2+B3+B4 cache-bust)")
        XCTAssertFalse(source.contains("VERSION: 5.0"),
                       "Stale VERSION: 5.0 comment must be replaced (not duplicated)")
    }

    // ─── Concern B: payload values per digest state ───────────────────────

    func test_betaFixture_plateaued_horizontalPush_encodesTrendInPayload() throws {
        var model = makeBaselineModel()
        var profile = makePattern(.horizontalPush, confidence: .calibrating)
        profile.trend = .plateaued
        model.patterns[.horizontalPush] = profile

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let data = try JSONEncoder().encode(digest)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let summaries = try XCTUnwrap(json["per_pattern_summary"] as? [[String: Any]])
        let pushSummary = try XCTUnwrap(summaries.first { ($0["pattern"] as? String) == "horizontal_push" })
        XCTAssertEqual(pushSummary["trend"] as? String, "plateaued")
    }

    func test_betaFixture_declining_squat_encodesTrendInPayload() throws {
        var model = makeBaselineModel()
        var profile = makePattern(.squat, confidence: .calibrating)
        profile.trend = .declining
        model.patterns[.squat] = profile

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let data = try JSONEncoder().encode(digest)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let summaries = try XCTUnwrap(json["per_pattern_summary"] as? [[String: Any]])
        let squatSummary = try XCTUnwrap(summaries.first { ($0["pattern"] as? String) == "squat" })
        XCTAssertEqual(squatSummary["trend"] as? String, "declining")
    }

    func test_betaFixture_consecutiveForceDeloads_verticalPush_encodesCountInPayload() throws {
        var model = makeBaselineModel()
        var profile = makePattern(.verticalPush, confidence: .established)
        profile.consecutiveForceDeloadsOnPattern = 2
        model.patterns[.verticalPush] = profile

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let data = try JSONEncoder().encode(digest)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let summaries = try XCTUnwrap(json["per_pattern_summary"] as? [[String: Any]])
        let pushSummary = try XCTUnwrap(summaries.first { ($0["pattern"] as? String) == "vertical_push" })
        XCTAssertEqual(pushSummary["consecutive_force_deloads_on_pattern"] as? Int, 2)
    }

    func test_betaFixture_allProgressing_encodesAllProgressingInPayload() throws {
        var model = makeBaselineModel()
        model.patterns = [
            .squat:          makePattern(.squat,          confidence: .established),
            .horizontalPush: makePattern(.horizontalPush, confidence: .established),
            .verticalPull:   makePattern(.verticalPull,   confidence: .established),
        ]
        // makePattern defaults trend to .progressing — no per-test override needed.

        let digest = TraineeModelDigest(from: model, asOf: ref)
        let data = try JSONEncoder().encode(digest)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let summaries = try XCTUnwrap(json["per_pattern_summary"] as? [[String: Any]])
        XCTAssertEqual(summaries.count, 3)
        for summary in summaries {
            XCTAssertEqual(summary["trend"] as? String, "progressing",
                           "All-progressing fixture must encode trend=progressing for every pattern")
        }
    }

    // MARK: ─── B1: cleanup-reversion guards ──────────────────────────────────
    //
    // Source-grep tests that lock B1's deletions in place. Same shape as the
    // β negative anchors on prompt files — they catch lexical reversion at
    // the source level, which compile-time field deletion alone can't (e.g.,
    // someone re-adding the legacy stagnationSignals field would change the
    // type but if they forgot a renamed consumer they'd get a compile error;
    // these tests give a clearer "you reverted B1's deletion" signal).

    private func loadSourceFile(_ relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #file)
        let repoRoot = testFileURL
            .deletingLastPathComponent()  // ProjectApexTests/
            .deletingLastPathComponent()  // <repo root>
        let sourceURL = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func test_sessionPlanService_doesNotReferenceLegacyStagnationField() throws {
        let source = try loadSourceFile("ProjectApex/Services/SessionPlanService.swift")
        XCTAssertFalse(source.contains("stagnationSignals"),
            "SessionPlanService must not declare or reference stagnationSignals (removed in B1/#86 — read trend from traineeModelDigest instead)")
        XCTAssertFalse(source.contains("stagnation_signals"),
            "SessionPlanService must not emit the stagnation_signals JSON key (removed in B1/#86)")
        XCTAssertFalse(source.contains("StagnationService"),
            "SessionPlanService must not reference StagnationService (deleted in B1/#86)")
    }

    func test_workoutSessionManager_doesNotComputeStagnationSignals() throws {
        let source = try loadSourceFile("ProjectApex/Features/Workout/WorkoutSessionManager.swift")
        XCTAssertFalse(source.contains("StagnationService.computeSignals"),
            "WorkoutSessionManager must not invoke StagnationService.computeSignals (removed in B1/#86 — trend is computed server-side per ADR-0009)")
        XCTAssertFalse(source.contains("StagnationService.persist"),
            "WorkoutSessionManager must not invoke StagnationService.persist (removed in B1/#86)")
    }

    // MARK: ─── B3 (#88): cleanup-reversion guards ────────────────────────────

    func test_programViewModel_b3_doesNotAssemblePatternPhasesForTemporalContext() throws {
        let source = try loadSourceFile("ProjectApex/Features/Program/ProgramViewModel.swift")
        XCTAssertFalse(source.contains("PatternPhaseService.load"),
            "ProgramViewModel must not call PatternPhaseService.load (removed in B3/#88 — phase state is read from TraineeModelDigest)")
        XCTAssertFalse(source.contains("PatternPhaseService.computeInitialPhases"),
            "ProgramViewModel must not call PatternPhaseService.computeInitialPhases (removed in B3/#88 — phase bootstrap is server-side per #146)")
        XCTAssertFalse(source.contains("PatternPhaseService.persist"),
            "ProgramViewModel must not call PatternPhaseService.persist (removed in B3/#88 — phase mutation is server-side)")
        XCTAssertFalse(source.contains("PatternPhaseInfo"),
            "ProgramViewModel must not reference PatternPhaseInfo (type deleted with PatternPhaseService.swift in B3/#88)")
    }

    func test_programViewModel_b3_doesNotInvokePatternPhaseService_clearOnGenerate() throws {
        let source = try loadSourceFile("ProjectApex/Features/Program/ProgramViewModel.swift")
        XCTAssertFalse(source.contains("PatternPhaseService.clear"),
            "ProgramViewModel must not call PatternPhaseService.clear in generateProgram/generateMacroSkeleton (removed in B3/#88 — server-side EF handles phase reset on program regen)")
    }

    func test_workoutSessionManager_b3_doesNotAdvancePatternPhases() throws {
        let source = try loadSourceFile("ProjectApex/Features/Workout/WorkoutSessionManager.swift")
        // Mirror B1's "doesNotComputeStagnationSignals" form: match the actual hook
        // surface (specific method calls), not the bare type name — backstory
        // comments are allowed to reference the deleted service.
        XCTAssertFalse(source.contains("PatternPhaseService.load"),
            "WorkoutSessionManager must not invoke PatternPhaseService.load (removed in B3/#88 — phase advancement is server-side in the EF per ADR-0011)")
        XCTAssertFalse(source.contains("PatternPhaseService.advancePhases"),
            "WorkoutSessionManager must not invoke PatternPhaseService.advancePhases (removed in B3/#88)")
        XCTAssertFalse(source.contains("PatternPhaseService.persist"),
            "WorkoutSessionManager must not invoke PatternPhaseService.persist (removed in B3/#88)")
    }

    func test_programOverviewView_b3_readsPatternPhaseFromDigest_notPatternPhaseService() throws {
        let source = try loadSourceFile("ProjectApex/Features/Program/ProgramOverviewView.swift")
        XCTAssertFalse(source.contains("PatternPhaseService.load"),
            "ProgramOverviewView must not call PatternPhaseService.load (removed in B3/#88 — phase state is read from viewModel.patternPhaseSummaries / TraineeModelDigest)")
        XCTAssertFalse(source.contains("MovementPatternPhaseState"),
            "ProgramOverviewView must not reference MovementPatternPhaseState (type deleted with PatternPhaseService.swift in B3/#88)")
    }

    func test_appDependencies_b3_clearsPatternPhaseStatesUserDefaults() throws {
        // Mirror B1's apex.stagnation_signals + B2's apex.volume_deficits cleanup —
        // remove the legacy PatternPhaseService UserDefaults key on app launch so
        // installs that upgraded across the cutover don't carry stale data.
        let source = try loadSourceFile("ProjectApex/App/AppDependencies.swift")
        XCTAssertTrue(source.contains("apex.pattern_phase_states"),
            "AppDependencies bootstrap must include removeObject(forKey: \"apex.pattern_phase_states\") (B3 / #88 — mirrors B1's stagnation_signals + B2's volume_deficits cleanup)")
    }

    func test_patternPhaseService_b3_sourceFilesDeleted() throws {
        let testFileURL = URL(fileURLWithPath: #file)
        let repoRoot = testFileURL
            .deletingLastPathComponent()  // ProjectApexTests/
            .deletingLastPathComponent()  // <repo root>
        let serviceURL = repoRoot.appendingPathComponent("ProjectApex/Services/PatternPhaseService.swift")
        let testsURL   = repoRoot.appendingPathComponent("ProjectApexTests/PatternPhaseServiceTests.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: serviceURL.path),
            "PatternPhaseService.swift must be deleted in B3/#88 — server-side update-trainee-model EF owns phase advancement per ADR-0011")
        XCTAssertFalse(FileManager.default.fileExists(atPath: testsURL.path),
            "PatternPhaseServiceTests.swift must be deleted in B3/#88 — tests deleted alongside the service they covered")
    }

    func test_sessionPlanService_b3_doesNotCarryPatternPhasesField() throws {
        // Mirror B1's test_sessionPlanService_doesNotReferenceLegacyStagnationField:
        // assert the type no longer declares the legacy patternPhases field +
        // CodingKey + PatternPhaseInfo reference.
        let source = try loadSourceFile("ProjectApex/Services/SessionPlanService.swift")
        XCTAssertFalse(source.contains("patternPhases"),
            "SessionPlanService must not declare or reference patternPhases (TemporalContext field removed in B3/#88 — phase is read from TraineeModelDigest)")
        XCTAssertFalse(source.contains("pattern_phases"),
            "SessionPlanService must not emit the pattern_phases JSON key (TemporalContext field removed in B3/#88)")
        XCTAssertFalse(source.contains("PatternPhaseInfo"),
            "SessionPlanService must not reference PatternPhaseInfo (type deleted with PatternPhaseService.swift in B3/#88)")
    }

    func test_temporalContext_b3_encodedJsonOmitsPatternPhasesKey() throws {
        let ctx = TemporalContext(
            daysSinceLastSession: 4,
            daysSinceLastTrainedByPattern: ["squat": 7],
            skippedSessionCountLast30Days: 0,
            globalProgrammePhase: "intensification",
            globalProgrammeWeek: 5
        )
        let data = try JSONEncoder().encode(ctx)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"pattern_phases\""),
            "Encoded TemporalContext JSON must not contain the pattern_phases key (field removed in B3/#88 — phase is in TraineeModelDigest)")
    }

    func test_skipFeatureTests_b3_doesNotReferenceLegacyPatternPhaseSymbols() throws {
        // Q7 (NEW): SkipFeatureTests.swift had three legacy references — prompt-
        // content asserts, a Codable round-trip test using PatternPhaseInfo, and
        // a nil-encoding test for the absent `pattern_phases` key. All updated /
        // removed in B3/#88 since PatternPhaseInfo + the TemporalContext field +
        // the prompt section header are all gone.
        let source = try loadSourceFile("ProjectApexTests/SkipFeatureTests.swift")
        XCTAssertFalse(source.contains("PatternPhaseInfo"),
            "SkipFeatureTests must not reference PatternPhaseInfo (type deleted with PatternPhaseService.swift in B3/#88)")
        XCTAssertFalse(source.contains("patternPhases:"),
            "SkipFeatureTests must not pass patternPhases: to TemporalContext (field removed in B3/#88)")
        XCTAssertFalse(source.contains("PER-PATTERN PHASE TRACKING"),
            "SkipFeatureTests must not assert on the legacy section header (replaced by PER-PATTERN PHASE STATE in B3/#88)")
    }

    // MARK: ─── B2 (#87): cleanup-reversion guards ────────────────────────────

    func test_sessionPlanService_doesNotReferenceLegacyVolumeDeficitsField() throws {
        let source = try loadSourceFile("ProjectApex/Services/SessionPlanService.swift")
        XCTAssertFalse(source.contains("volumeDeficits"),
            "SessionPlanService must not declare or reference volumeDeficits (removed in B2/#87 — read volume_deficit from traineeModelDigest.perMuscleSummary instead)")
        XCTAssertFalse(source.contains("volume_deficits"),
            "SessionPlanService must not emit the volume_deficits JSON key (removed in B2/#87)")
        XCTAssertFalse(source.contains("VolumeValidationService"),
            "SessionPlanService must not reference VolumeValidationService (deleted in B2/#87)")
    }

    func test_progressViewModel_doesNotReferenceVolumeValidationService() throws {
        let source = try loadSourceFile("ProjectApex/Features/Progress/ProgressViewModel.swift")
        XCTAssertFalse(source.contains("VolumeValidationService"),
            "ProgressViewModel must not invoke VolumeValidationService (deleted in B2/#87 — the legacy compute+persist pipe fed only SessionPlanService, which now reads volume_deficit from the trainee-model digest)")
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
        XCTAssertTrue(digest.transfers.isEmpty)
        XCTAssertTrue(digest.perExerciseSummary.isEmpty)
        XCTAssertEqual(digest.weeklyFatigue.sessionsCompletedThisWeek, 0)
    }

    // MARK: ─── B4 (#89) cycle 3: totalSessionCount pass-through ───────────────

    func test_digest_totalSessionCount_passesThroughFromModel() {
        var model = makeBaselineModel()
        model.totalSessionCount = 42

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.totalSessionCount, 42)
    }

    // MARK: ─── B4 (#89) cycle 6: weeklyFatigue field + assembly signature ─────

    func test_digest_weeklyFatigue_surfacesCallerSuppliedValue() {
        let model = makeBaselineModel()
        let supplied = WeekFatigueSignals.compute(from: [], sessionCount: 3)
        // sessionCount 3 with no logs → empty signals carrying the session count

        let digest = TraineeModelDigest(from: model, weeklyFatigue: supplied, asOf: ref)

        XCTAssertEqual(digest.weeklyFatigue.sessionsCompletedThisWeek, 3)
        XCTAssertFalse(digest.weeklyFatigue.deloadTriggered)
        XCTAssertFalse(digest.weeklyFatigue.fatigueManagementFlagged)
    }

    func test_digest_weeklyFatigue_defaultsToEmptyWhenCallerOmits() {
        let model = makeBaselineModel()

        let digest = TraineeModelDigest(from: model, asOf: ref)
        // γ2 lock: non-optional, default-empty when caller doesn't supply

        XCTAssertEqual(digest.weeklyFatigue.sessionsCompletedThisWeek, 0)
        XCTAssertNil(digest.weeklyFatigue.weeklyAvgRPE)
        XCTAssertEqual(digest.weeklyFatigue.significantMissCount, 0)
        XCTAssertFalse(digest.weeklyFatigue.deloadTriggered)
        XCTAssertFalse(digest.weeklyFatigue.fatigueManagementFlagged)
    }

    // MARK: ─── B4 (#89) cycle 5: perExerciseSummary projection ────────────────

    func test_digest_perExerciseSummary_projectsExerciseProfileFields() {
        var model = makeBaselineModel()
        model.exercises = [
            "bench_press": ExerciseProfile(
                exerciseId: "bench_press",
                e1rmCurrent: 100, e1rmMedian: 95, e1rmPeak: 105,
                sessionCount: 15, formDegradationFlag: true,
                confidence: .established
            ),
            "squat": ExerciseProfile(
                exerciseId: "squat",
                e1rmCurrent: 140, e1rmMedian: 135, e1rmPeak: 145,
                sessionCount: 8, formDegradationFlag: false,
                confidence: .calibrating
            ),
        ]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.perExerciseSummary.count, 2)
        let byExercise = Dictionary(uniqueKeysWithValues:
            digest.perExerciseSummary.map { ($0.exerciseId, $0) })

        let bench = try? XCTUnwrap(byExercise["bench_press"])
        XCTAssertEqual(bench?.e1rmCurrent, 100)
        XCTAssertEqual(bench?.e1rmMedian, 95)
        XCTAssertEqual(bench?.e1rmPeak, 105)
        XCTAssertEqual(bench?.sessionCount, 15)
        XCTAssertEqual(bench?.learningPhase, false,
            "sessionCount=15 → learning phase ended (threshold 10 per ADR-0005)")
        XCTAssertEqual(bench?.formDegradationFlag, true)
        XCTAssertEqual(bench?.confidence, .established)

        let sq = try? XCTUnwrap(byExercise["squat"])
        XCTAssertEqual(sq?.learningPhase, true,
            "sessionCount=8 → still in learning phase (threshold 10 per ADR-0005)")
        XCTAssertEqual(sq?.formDegradationFlag, false)
    }

    // MARK: ─── B4 (#89) cycle 4: lastGlobalPhaseAdvance pass-through ──────────

    func test_digest_lastGlobalPhaseAdvanceFiredAt_passesThroughWhenSet() {
        var model = makeBaselineModel()
        model.lastGlobalPhaseAdvanceFiredAtSessionCount = 17

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertEqual(digest.lastGlobalPhaseAdvanceFiredAtSessionCount, 17)
    }

    func test_digest_lastGlobalPhaseAdvanceFiredAt_passesThroughWhenNil() {
        let model = makeBaselineModel()  // never fired

        let digest = TraineeModelDigest(from: model, asOf: ref)

        XCTAssertNil(digest.lastGlobalPhaseAdvanceFiredAtSessionCount)
    }

    // MARK: ─── B4 (#89) cycle 2: transfers filtered by R²≥0.4 ∧ pairedObs≥5 ────

    func test_digest_transfers_filtersByRSquaredAndPairedObservations() {
        var model = makeBaselineModel()
        // Q10 lock-in: surface only transfers with R²≥0.4 AND pairedObservations≥5.
        // Below either threshold → drop. Lower bounds inclusive.
        let passing  = ExerciseTransfer(fromExerciseId: "bench_press",
                                        toExerciseId:   "incline_bench_press",
                                        coefficient: 0.85, rSquared: 0.5,
                                        pairedObservations: 10)
        let lowRSq   = ExerciseTransfer(fromExerciseId: "squat",
                                        toExerciseId:   "leg_press",
                                        coefficient: 0.70, rSquared: 0.3,
                                        pairedObservations: 10)
        let lowObs   = ExerciseTransfer(fromExerciseId: "deadlift",
                                        toExerciseId:   "rdl",
                                        coefficient: 0.80, rSquared: 0.5,
                                        pairedObservations: 4)
        let boundary = ExerciseTransfer(fromExerciseId: "overhead_press",
                                        toExerciseId:   "incline_bench_press",
                                        coefficient: 0.60, rSquared: 0.4,
                                        pairedObservations: 5)
        model.transfers = [passing, lowRSq, lowObs, boundary]

        let digest = TraineeModelDigest(from: model, asOf: ref)

        let surfacedPairs = Set(digest.transfers.map { "\($0.fromExerciseId)→\($0.toExerciseId)" })
        XCTAssertEqual(surfacedPairs,
                       ["bench_press→incline_bench_press",
                        "overhead_press→incline_bench_press"],
                       "Only transfers with R²≥0.4 AND pairedObservations≥5 should surface in the digest")
    }
}
