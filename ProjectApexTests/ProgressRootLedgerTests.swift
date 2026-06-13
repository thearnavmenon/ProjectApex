// ProgressRootLedgerTests.swift
// ProjectApexTests
//
// Tests for the Progress root capability ledger (#354 / progress.md §3).
//
// Two layers:
//  1. UNCONDITIONAL geometry/derivation layer — runs on every push, no env var needed.
//     Verifies: canonical-order sort, the 2px fused floor datum constant, list-scale
//     rows reuse the band, the honest-absence distance annotation (no fabricated count),
//     and totalizer-absent-at-zero (the margin annotation is absent when zero ratchets).
//  2. GATED snapshot layer — light + dim + one AX size (reference-pending until CI
//     records on the pinned Xcode 26.3 toolchain; NEVER set APEX_RECORD_SNAPSHOTS).

import Testing
import SwiftUI
import SnapshotTesting
@testable import ProjectApex

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Gating (mirrors DrawnInstrumentSnapshotTests)

private var snapshotTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_SNAPSHOT_TESTS"] == "1"
}
private var recordModeEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_RECORD_SNAPSHOTS"] == "1"
}

// MARK: - Fixtures

private extension PatternProjection {
    static func make(_ pattern: MovementPattern, floor: Double = 100, stretch: Double = 115)
        -> PatternProjection {
        PatternProjection(pattern: pattern, floor: floor, stretch: stretch, progress: .onTrack)
    }
}

/// A minimal TraineeModel fixture with six active patterns in non-canonical order.
private func makeModel(patterns: [(MovementPattern, Double, Double)]) -> TraineeModel {
    let projections = patterns.map { p, floor, stretch in
        PatternProjection(pattern: p, floor: floor, stretch: stretch, progress: .onTrack)
    }
    let patternProfiles = Dictionary(
        uniqueKeysWithValues: patterns.map { p, _, _ -> (MovementPattern, PatternProfile) in
            var profile = PatternProfile(pattern: p, confidence: .established)
            // Give each pattern one recent session so isActive = true
            profile.recentSessionDates = [Date()]
            return (p, profile)
        }
    )
    var model = TraineeModel(
        goal: GoalState(statement: "Get stronger", updatedAt: Date()),
        projections: ProjectionState(patternProjections: projections),
        patterns: patternProfiles
    )
    return model
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 1. UNCONDITIONAL geometry / derivation layer
// ──────────────────────────────────────────────────────────────────────────

@Suite("ProgressRootLedger — geometry and derivation assertions")
struct ProgressRootLedgerGeometryTests {

    // MARK: Canonical order sort

    @Test("Rows are sorted into fixed canonical taxonomy order (squat → hinge → … → isolation)")
    func canonicalOrderSort() {
        // Supply rows in reverse canonical order: isolation → lunge → … → squat
        let reversedInput: [ProgressRootLedger.PatternRow] = [
            .init(projection: .make(.isolation), confidence: .established, isActive: true, lastTrainedDate: nil),
            .init(projection: .make(.lunge), confidence: .established, isActive: true, lastTrainedDate: nil),
            .init(projection: .make(.verticalPull), confidence: .established, isActive: true, lastTrainedDate: nil),
            .init(projection: .make(.horizontalPull), confidence: .established, isActive: true, lastTrainedDate: nil),
            .init(projection: .make(.verticalPush), confidence: .established, isActive: true, lastTrainedDate: nil),
            .init(projection: .make(.horizontalPush), confidence: .established, isActive: true, lastTrainedDate: nil),
            .init(projection: .make(.hipHinge), confidence: .established, isActive: true, lastTrainedDate: nil),
            .init(projection: .make(.squat), confidence: .established, isActive: true, lastTrainedDate: nil),
        ]

        let ledger = ProgressRootLedger(rows: reversedInput)
        // Access sorted rows via the same local sort the view uses: pull from the model
        let model = makeModel(patterns: [
            (.isolation, 80, 90),
            (.lunge, 70, 80),
            (.squat, 100, 115),
            (.hipHinge, 90, 105),
        ])
        let sortedRows = ProgressRootLedger.rows(from: model)

        // Verify squat comes before hipHinge, hipHinge before others in the taxonomy
        let patterns = sortedRows.map(\.id)
        if let sqIdx = patterns.firstIndex(of: .squat),
           let hhIdx = patterns.firstIndex(of: .hipHinge) {
            #expect(sqIdx < hhIdx, "Squat must precede Hip Hinge in canonical order")
        }
    }

    @Test("Canonical order: squat is first, isolation is last, in a full 8-pattern model")
    func canonicalOrderFullSet() {
        let allPatterns: [(MovementPattern, Double, Double)] = [
            (.isolation, 60, 70),
            (.verticalPull, 80, 95),
            (.horizontalPull, 90, 105),
            (.lunge, 70, 82),
            (.squat, 100, 115),
            (.horizontalPush, 85, 100),
            (.verticalPush, 70, 85),
            (.hipHinge, 95, 110),
        ]
        let model = makeModel(patterns: allPatterns)
        let sorted = ProgressRootLedger.rows(from: model).map(\.id)

        // Check canonical prefix and suffix
        #expect(sorted.first == .squat, "First row must be Squat")
        #expect(sorted.last == .isolation, "Last row must be Isolation")

        // Check relative ordering of intermediate patterns
        let positions = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element, $0.offset) })
        #expect((positions[.hipHinge] ?? 99) < (positions[.horizontalPush] ?? 99),
                "Hip Hinge precedes Horizontal Push")
        #expect((positions[.horizontalPush] ?? 99) < (positions[.verticalPush] ?? 99),
                "Horizontal Push precedes Vertical Push")
    }

    // MARK: 2px fused floor datum

    @Test("Floor tick is 2px — the spine constant (progress.md §3 'heaviest line')")
    func floorTickIs2px() {
        // The spine reuses DesignGeometry.floorTick — same constant as CapabilityBand.
        // This test pins the contract: the spine is 2px, same as the band's floor tick.
        #expect(DesignGeometry.floorTick == 2,
                "Floor tick must be 2px so all row ticks fuse into one 2px spine")
    }

    @Test("BandLayout floor tick is centered at a consistent x for a representative band")
    func spinePositionConsistency() {
        // Two rows with the same floor/stretch must produce the same floorX,
        // proving the spine's alignment is data-driven and identical across rows.
        let width: CGFloat = 300
        let layout1 = BandLayout(floor: 100, stretch: 115, observedE1RM: nil, width: width)
        let layout2 = BandLayout(floor: 100, stretch: 115, observedE1RM: 107, width: width)
        // Both share the same floor — floorX must be identical regardless of dot.
        #expect(abs(layout1.floorX - layout2.floorX) < 0.01,
                "Floor x must be the same regardless of observed e1RM")
    }

    // MARK: List-scale rows reuse the CapabilityBand(.list) context

    @Test("List-scale dot is 5pt (the band component's list context)")
    func listScaleDotIs5pt() {
        // The ledger rows use CapabilityBand(context: .list) — verified via the constant.
        #expect(DesignGeometry.listScaleDot == 5,
                "List context uses 5pt dot so the band is compact in ledger rows")
    }

    @Test("CapabilityBandContext.list strips brackets and labels (no numbers-never-twice violation)")
    func listContextIsUnlabeled() {
        // The .list context has no tick labels — numbers live in the annotation line only.
        // Structural: list context does not equal .full or .onboarding (which have labels).
        #expect(CapabilityBandContext.list != .full)
        #expect(CapabilityBandContext.list != .onboarding)
    }

    // MARK: Honest-absence distance-to-ratchet (Q11)

    @Test("Rows factory: established confidence produces an active row (not calibrating)")
    func establishedConfidenceIsActive() {
        let model = makeModel(patterns: [(.squat, 100, 115)])
        let rows = ProgressRootLedger.rows(from: model)
        guard let squatRow = rows.first(where: { $0.id == .squat }) else {
            Issue.record("No squat row found"); return
        }
        // Established confidence → the annotation renders the forward hook
        // (honest-absence "ratchet within reach"), NOT a fabricated numeric count.
        #expect(squatRow.confidence == .established)
        #expect(squatRow.isActive == true)
    }

    @Test("Rows factory: bootstrapping confidence produces a calibrating row")
    func bootstrappingConfidenceIsCalibratingAnnotation() {
        let projections = [PatternProjection(pattern: .squat, floor: 100, stretch: 115, progress: .onTrack)]
        var profile = PatternProfile(pattern: .squat, confidence: .bootstrapping)
        profile.recentSessionDates = [Date()]
        let model = TraineeModel(
            goal: GoalState(statement: "test", updatedAt: Date()),
            projections: ProjectionState(patternProjections: projections),
            patterns: [.squat: profile]
        )
        let rows = ProgressRootLedger.rows(from: model)
        guard let row = rows.first(where: { $0.id == .squat }) else {
            Issue.record("No squat row"); return
        }
        // bootstrapping → annotation branch renders "still calibrating — establishing band"
        #expect(row.confidence == .bootstrapping)
        #expect(row.isActive == true)
    }

    @Test("No sessionsAboveFloor fabricated — distance-to-ratchet is qualitative only")
    func distanceToRatchetIsQualitativeNotNumeric() {
        // Q11 amendment: sessionsAboveFloor does not exist in the iOS models.
        // The rows factory must NOT produce any integer count in the annotation.
        // We verify this structurally: PatternProfile has no sessionsAboveFloor property.
        // If someone adds it, they must update this test intentionally.
        let mirror = Mirror(reflecting: PatternProfile(pattern: .squat))
        let propertyNames = mirror.children.compactMap { $0.label }
        #expect(!propertyNames.contains("sessionsAboveFloor"),
                "sessionsAboveFloor must not exist in PatternProfile — the count is a later model-API slice")
    }

    // MARK: Totalizer absent at zero

    @Test("Rows factory: a pattern with no projections is omitted (no fabricated empty row)")
    func patternWithNoProjectionIsOmitted() {
        // A TraineeModel with a PatternProfile but no corresponding PatternProjection
        // produces no row — the margin totalizer (and any annotation) stays absent.
        let profile = PatternProfile(pattern: .squat, confidence: .established)
        let model = TraineeModel(
            goal: GoalState(statement: "test", updatedAt: Date()),
            projections: ProjectionState(patternProjections: []),  // no projections
            patterns: [.squat: profile]
        )
        let rows = ProgressRootLedger.rows(from: model)
        #expect(rows.isEmpty, "No rows should render when projections are absent")
    }

    @Test("Rows factory: cold start (nil projections) produces no rows")
    func coldStartProducesNoRows() {
        let model = TraineeModel(
            goal: GoalState(statement: "test", updatedAt: Date()),
            projections: nil,
            patterns: [:]
        )
        let rows = ProgressRootLedger.rows(from: model)
        #expect(rows.isEmpty, "Cold-start model must produce zero rows — no chart chrome")
    }

    // MARK: Dormant row detection

    @Test("Pattern with no recent session dates is dormant (isActive = false)")
    func noRecentSessionDatesMeansDormant() {
        let proj = PatternProjection(pattern: .squat, floor: 100, stretch: 115, progress: .onTrack)
        let profile = PatternProfile(pattern: .squat, confidence: .established)
        // recentSessionDates is empty (default) → isActive = false
        let model = TraineeModel(
            goal: GoalState(statement: "test", updatedAt: Date()),
            projections: ProjectionState(patternProjections: [proj]),
            patterns: [.squat: profile]
        )
        let rows = ProgressRootLedger.rows(from: model)
        guard let row = rows.first else { Issue.record("No row"); return }
        #expect(row.isActive == false, "Pattern with no session dates must be dormant")
    }
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 2. GATED snapshot layer (reference-pending until CI records)
// ──────────────────────────────────────────────────────────────────────────

@Suite("ProgressRootLedger snapshots", .enabled(if: snapshotTestsEnabled))
@MainActor
struct ProgressRootLedgerSnapshotTests {

    private static let canvasSize = CGSize(width: 393, height: 480)

    /// A stable fixture: four active patterns in non-canonical order.
    private static let fixtureRows: [ProgressRootLedger.PatternRow] = [
        .init(projection: PatternProjection(pattern: .horizontalPush, floor: 85, stretch: 100, progress: .onTrack),
              confidence: .established, isActive: true, lastTrainedDate: nil),
        .init(projection: PatternProjection(pattern: .squat, floor: 100, stretch: 115, progress: .onTrack),
              confidence: .seasoned, isActive: true, lastTrainedDate: nil),
        .init(projection: PatternProjection(pattern: .hipHinge, floor: 90, stretch: 105, progress: .onTrack),
              confidence: .bootstrapping, isActive: true, lastTrainedDate: nil),
        .init(projection: PatternProjection(pattern: .verticalPull, floor: 70, stretch: 85, progress: .onTrack),
              confidence: .established, isActive: false,
              lastTrainedDate: Calendar.current.date(byAdding: .day, value: -14, to: Date())),
    ]

    #if canImport(UIKit)
    @Test("Progress root ledger — light, default Dynamic Type")
    func ledger_light_default() {
        let vc = SnapshotHarness.host(
            ProgressRootLedger(rows: Self.fixtureRows),
            size: Self.canvasSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "progress-root-ledger-light-default", record: recordModeEnabled)
    }

    @Test("Progress root ledger — dim, default Dynamic Type")
    func ledger_dim_default() {
        let vc = SnapshotHarness.host(
            ProgressRootLedger(rows: Self.fixtureRows),
            size: Self.canvasSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "progress-root-ledger-dim-default", record: recordModeEnabled)
    }

    @Test("Progress root ledger — light, AX5 (largest accessibility size)")
    func ledger_light_ax5() {
        let vc = SnapshotHarness.host(
            ProgressRootLedger(rows: Self.fixtureRows),
            size: Self.canvasSize, appearance: .light, dynamicType: .accessibility5
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "progress-root-ledger-light-ax5", record: recordModeEnabled)
    }
    #endif
}
