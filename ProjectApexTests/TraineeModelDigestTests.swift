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
        XCTAssertTrue(prompt.contains("VERSION: 2.0"),
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

    func test_inferencePrompt_containsPerPatternTrendBlock() {
        // Production Inference reads AIInferenceService.systemPrompt — the
        // inline Swift string literal, not SystemPrompt_Inference.txt (which
        // is a deprecated parallel mirror — see #159).
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
    }
}
