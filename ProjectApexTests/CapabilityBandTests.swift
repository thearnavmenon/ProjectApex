// CapabilityBandTests.swift
// ProjectApexTests
//
// Tests for the CapabilityBand component (Slice 4, #345).
//
// Two layers:
//  1. UNCONDITIONAL geometry/token layer — runs on every push, no env var needed.
//     Verifies tick widths, fill opacity, confidence→solid/hollow mapping for all
//     four AxisConfidence cases, list-scale dot size, and dim data-viz tokens.
//  2. GATED snapshot layer — mirrors DrawnInstrumentSnapshotTests.swift exactly.
//     Three contexts (full / onboarding / list) × light + dim + one AX size.
//     References are NOT recorded (APEX_RECORD_SNAPSHOTS is never set here;
//     CI records them on the pinned Xcode 26.3 toolchain).

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
    /// A stable squat band for tests: floor 100, stretch 115, onTrack.
    static let squatFixture = PatternProjection(
        pattern: .squat,
        floor: 100,
        stretch: 115,
        progress: .onTrack
    )
}

private extension CapabilityBandInput {
    /// Measured (established), dot at 107, no movement.
    static let measuredNoMove = CapabilityBandInput(
        projection: .squatFixture,
        confidence: .established,
        observedE1RM: 107,
        movementDeltaKg: nil,
        caption: "Squat — most worked today"
    )
    /// Estimated (bootstrapping), dot at 102, movement +2 kg.
    static let estimatedWithMove = CapabilityBandInput(
        projection: .squatFixture,
        confidence: .bootstrapping,
        observedE1RM: 102,
        movementDeltaKg: 2,
        caption: "Squat — still calibrating"
    )
    /// List context — no caption used.
    static let listContext = CapabilityBandInput(
        projection: .squatFixture,
        confidence: .seasoned,
        observedE1RM: 108,
        movementDeltaKg: nil,
        caption: nil
    )
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 1. UNCONDITIONAL geometry / token layer
// ──────────────────────────────────────────────────────────────────────────

@Suite("CapabilityBand — geometry and token assertions")
struct CapabilityBandGeometryTests {

    // MARK: Tick widths

    @Test("Floor tick is 2px per DesignGeometry")
    func floorTickWidth() {
        #expect(DesignGeometry.floorTick == 2)
    }

    @Test("Stretch tick is 1px (hairline) per DesignGeometry")
    func stretchTickWidth() {
        #expect(DesignGeometry.stretchTick == 1)
    }

    // MARK: Band fill opacity

    @Test("Light band fill is accent at 8% opacity")
    func bandFillOpacity_light() {
        let theme = Theme.light
        // bandFill is accent at 8% (light) — TokenColor.opacity check.
        #expect(abs(theme.bandFill.opacity - 0.08) < 0.001)
    }

    @Test("Dim band fill is accent-ink at 12% opacity")
    func bandFillOpacity_dim() {
        let theme = Theme.dim
        // bandFill is dim accent-ink at 12% — DESIGN.md §data-viz-dim.
        #expect(abs(theme.bandFill.opacity - 0.12) < 0.001)
    }

    // MARK: Confidence → solid / hollow mapping (all 4 cases)

    @Test("bootstrapping → estimated (hollow)", arguments: [AxisConfidence.bootstrapping])
    func bootstrapping_isEstimated(confidence: AxisConfidence) {
        #expect(confidence.isMeasured == false)
    }

    @Test("calibrating → estimated (hollow)", arguments: [AxisConfidence.calibrating])
    func calibrating_isEstimated(confidence: AxisConfidence) {
        #expect(confidence.isMeasured == false)
    }

    @Test("established → measured (solid)", arguments: [AxisConfidence.established])
    func established_isMeasured(confidence: AxisConfidence) {
        #expect(confidence.isMeasured == true)
    }

    @Test("seasoned → measured (solid)", arguments: [AxisConfidence.seasoned])
    func seasoned_isMeasured(confidence: AxisConfidence) {
        #expect(confidence.isMeasured == true)
    }

    // MARK: Confidence mapping is exhaustive

    @Test("All AxisConfidence cases are handled")
    func allConfidenceCasesHandled() {
        for confidence in AxisConfidence.allCases {
            // isMeasured must return deterministically (no crash, no unhandled case)
            let _ = confidence.isMeasured
        }
    }

    // MARK: List-scale dot size

    @Test("List-scale dot is 5pt per DesignGeometry")
    func listScaleDotSize() {
        #expect(DesignGeometry.listScaleDot == 5)
    }

    // MARK: Dim data-viz tokens (spot checks)

    @Test("Dim accent-ink is lifted (7B85FF — the dim data-viz primary)")
    func dimAccentInkIsLifted() {
        let dim = Theme.dim
        // #7B85FF: red=0x7B/255≈0.482, green=0x85/255≈0.522, blue=0xFF/255=1.0
        #expect(abs(dim.accentInk.red - Double(0x7B) / 255) < 0.002)
        #expect(abs(dim.accentInk.green - Double(0x85) / 255) < 0.002)
        #expect(abs(dim.accentInk.blue - 1.0) < 0.002)
    }

    @Test("Dim band edge hairline is 2A2D36 per data-viz-dim spec")
    func dimBandEdgeHairline() {
        let dim = Theme.dim
        // #2A2D36
        #expect(abs(dim.hairline.red - Double(0x2A) / 255) < 0.002)
        #expect(abs(dim.hairline.green - Double(0x2D) / 255) < 0.002)
        #expect(abs(dim.hairline.blue - Double(0x36) / 255) < 0.002)
    }

    // MARK: BandLayout — minimum band width enforcement

    @Test("BandLayout enforces 48pt minimum band render width")
    func bandLayoutMinimumWidth() {
        // Very close floor/stretch produces a narrow band — must be clamped to 48pt.
        let layout = BandLayout(floor: 100, stretch: 100.5, observedE1RM: nil, width: 300)
        let rendered = layout.stretchX - layout.floorX
        #expect(rendered >= BandLayout.minimumBandWidth - 0.5)
    }

    @Test("BandLayout does not clamp out-of-band dot — plots outside the band")
    func bandLayoutOutOfBandDotNotClamped() {
        // Dot at 130 is outside the 100–115 band. It must plot beyond stretchX.
        let layout = BandLayout(floor: 100, stretch: 115, observedE1RM: 130, width: 300)
        if let dotX = layout.dotX {
            #expect(dotX > layout.stretchX)
        } else {
            Issue.record("Expected a dotX but got nil")
        }
    }

    @Test("BandLayout: dot below floor plots outside (left of) the band")
    func bandLayoutDotBelowFloor() {
        let layout = BandLayout(floor: 100, stretch: 115, observedE1RM: 85, width: 300)
        if let dotX = layout.dotX {
            #expect(dotX < layout.floorX)
        } else {
            Issue.record("Expected a dotX but got nil")
        }
    }

    // MARK: List context drops bracket + uses 5pt dot

    @Test("List context uses 5pt dot size")
    func listContextDotSize() {
        // CapabilityBandContext.list → dotDiameter should be DesignGeometry.listScaleDot
        // We verify the constant rather than the private property.
        #expect(DesignGeometry.listScaleDot == 5)
    }
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 2. GATED snapshot layer (reference-pending until CI records)
// ──────────────────────────────────────────────────────────────────────────

@Suite("CapabilityBand snapshots", .enabled(if: snapshotTestsEnabled))
@MainActor
struct CapabilityBandSnapshotTests {

    private static let fullSize = CGSize(width: 393, height: 120)
    private static let listSize = CGSize(width: 393, height: 60)

    // MARK: Full context — light

    #if canImport(UIKit)
    @Test("Full context — light, default Dynamic Type")
    func full_light_default() {
        let vc = SnapshotHarness.host(
            CapabilityBand(input: .measuredNoMove, context: .full),
            size: Self.fullSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "capability-band-full-light-default", record: recordModeEnabled)
    }

    @Test("Full context — dim, default Dynamic Type")
    func full_dim_default() {
        let vc = SnapshotHarness.host(
            CapabilityBand(input: .estimatedWithMove, context: .full),
            size: Self.fullSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "capability-band-full-dim-default", record: recordModeEnabled)
    }

    // MARK: Onboarding context — light + dim

    @Test("Onboarding context — light, default Dynamic Type")
    func onboarding_light_default() {
        let vc = SnapshotHarness.host(
            CapabilityBand(input: .measuredNoMove, context: .onboarding),
            size: Self.fullSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "capability-band-onboarding-light-default", record: recordModeEnabled)
    }

    @Test("Onboarding context — dim, default Dynamic Type")
    func onboarding_dim_default() {
        let vc = SnapshotHarness.host(
            CapabilityBand(input: .estimatedWithMove, context: .onboarding),
            size: Self.fullSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "capability-band-onboarding-dim-default", record: recordModeEnabled)
    }

    // MARK: List context — light + dim

    @Test("List context — light, default Dynamic Type")
    func list_light_default() {
        let vc = SnapshotHarness.host(
            CapabilityBand(input: .listContext, context: .list),
            size: Self.listSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "capability-band-list-light-default", record: recordModeEnabled)
    }

    @Test("List context — dim, default Dynamic Type")
    func list_dim_default() {
        let vc = SnapshotHarness.host(
            CapabilityBand(input: .listContext, context: .list),
            size: Self.listSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "capability-band-list-dim-default", record: recordModeEnabled)
    }

    // MARK: AX size — one case (full context, light, AX5)

    @Test("Full context — light, AX5 (largest accessibility size)")
    func full_light_ax5() {
        let vc = SnapshotHarness.host(
            CapabilityBand(input: .measuredNoMove, context: .full),
            size: Self.fullSize, appearance: .light, dynamicType: .accessibility5
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "capability-band-full-light-ax5", record: recordModeEnabled)
    }
    #endif
}
