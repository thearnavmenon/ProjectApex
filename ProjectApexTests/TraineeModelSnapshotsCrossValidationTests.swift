// TraineeModelSnapshotsCrossValidationTests.swift
// ProjectApexTests
//
// Cross-platform shape-parity tests for the TS Edge Function orchestrator's
// JSONB output (slice A12 / #83). Loads the canonical fixture at
// docs/fixtures/trainee-model-snapshot.json — the same JSON that the TS
// orchestrator round-trip test asserts against — and verifies that the
// Phase 1 Swift `TraineeModel` Codable decodes it cleanly with every Phase 2
// field populated correctly.
//
// Per ADR-0006: the trainee_models.model_json column is a contract between
// the Edge Function (writer) and the Swift client (reader for digest
// assembly). Drift on either side silently corrupts user state. This test
// catches Swift-side decoder regressions; the TS-side round-trip test in
// orchestrator_test.ts catches TS-side regressions; together they pin the
// shape contract.
//
// Anchor date 2026-01-01T00:00:00Z is deterministic (no Date.now() in
// the fixture or tests).

import XCTest
@testable import ProjectApex

final class TraineeModelSnapshotsCrossValidationTests: XCTestCase {

    // MARK: ─── Fixture loading ────────────────────────────────────────────

    private static let fixtureFileURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()      // ProjectApexTests/
            .deletingLastPathComponent()      // ProjectApex/ (repo root)
            .appendingPathComponent("docs/fixtures/trainee-model-snapshot.json")
    }()

    private static let model: TraineeModel = {
        let data = try! Data(contentsOf: fixtureFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(TraineeModel.self, from: data)
    }()

    // MARK: ─── Phase 2 fields decode correctly ────────────────────────────

    /// Phase 2 added two top-level optional fields. Both must round-trip
    /// the populated values from the fixture.
    func test_phase2TopLevelFields_decodeCorrectly() {
        XCTAssertEqual(
            Self.model.lastGlobalPhaseAdvanceFiredAtSessionCount, 18,
            "lastGlobalPhaseAdvanceFiredAtSessionCount must round-trip from JSONB"
        )
        XCTAssertEqual(
            Self.model.lastClassifiedNoteCreatedAt,
            ISO8601DateFormatter().date(from: "2026-01-04T18:00:00Z"),
            "lastClassifiedNoteCreatedAt must decode as ISO-8601"
        )
        XCTAssertEqual(Self.model.totalSessionCount, 24)
    }

    /// PatternProfile gained `consecutiveForceDeloadsOnPattern` and uses
    /// `transitionModeUntil` (Phase 1 field exercised by Phase 2 rules).
    func test_patternProfilePhase2Fields_decodeCorrectly() {
        guard let squat = Self.model.patterns[.squat] else {
            return XCTFail("squat pattern must be present in fixture")
        }
        XCTAssertEqual(squat.currentPhase, .deload)
        XCTAssertEqual(squat.sessionsInPhase, 2)
        XCTAssertEqual(squat.consecutiveForceDeloadsOnPattern, 1)
        XCTAssertEqual(squat.trend, .plateaued)
        XCTAssertNotNil(squat.transitionModeUntil)
        XCTAssertEqual(
            squat.transitionModeUntil,
            ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")
        )
    }

    /// FatigueInteraction.confidence is computed; the persisted shape carries
    /// observations + totalCount (per ADR-0005). Verifies the orchestrator's
    /// JSONB shape can hydrate the value type and produce a meaningful
    /// confidence reading.
    func test_fatigueInteraction_decodesAndComputesConfidence() {
        XCTAssertEqual(Self.model.fatigueInteractions.count, 1)
        let interaction = Self.model.fatigueInteractions[0]
        XCTAssertEqual(interaction.fromPattern, .squat)
        XCTAssertEqual(interaction.toPattern, .horizontalPush)
        XCTAssertEqual(interaction.observations.count, 10)
        XCTAssertEqual(interaction.totalCount, 22)
        // Computed: countFactor=1.0 (totalCount >=15), consistency > 0
        // (variance < |mean|), confidence > 0. Specific values pinned by
        // FatigueInteractionCrossValidationTests; here we just verify the
        // shape feeds the derived properties without throw.
        XCTAssertEqual(interaction.countFactor, 1.0)
        XCTAssertGreaterThan(interaction.consistencyFactor, 0)
        XCTAssertGreaterThan(interaction.confidence, 0)
    }

    /// PrescriptionAccuracy gained gap-bucket fields in slice A9 (#80) per
    /// ADR-0014. The fixture exercises the populated dictionaries; verify
    /// the Swift Codable's `decodeIfPresent` defaults to empty-dict on
    /// missing keys but populates correctly when present.
    func test_prescriptionAccuracy_gapBucketFieldsDecodeCorrectly() {
        guard
            let squatCells = Self.model.prescriptionAccuracy[.squat],
            let topCell = squatCells[.top]
        else {
            return XCTFail("prescriptionAccuracy[.squat][.top] must be present in fixture")
        }
        XCTAssertEqual(topCell.bias, 0.04)
        XCTAssertEqual(topCell.rmse, 0.08)
        XCTAssertEqual(topCell.sampleCount, 12)
        XCTAssertEqual(topCell.biasByGapBucket[.under48h], -0.02)
        XCTAssertEqual(topCell.biasByGapBucket[.between48And72h], 0.05)
        XCTAssertEqual(topCell.biasByGapBucket[.over72h], 0.06)
        XCTAssertEqual(topCell.sampleCountByGapBucket[.under48h], 4)
        XCTAssertEqual(topCell.sampleCountByGapBucket[.over72h], 3)
    }
}
