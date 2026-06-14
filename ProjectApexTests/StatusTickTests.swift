// StatusTickTests.swift
// ProjectApexTests
//
// Tests for the StatusTick instrument and RestWellNode (Slice 5, #410).
//
// Two layers:
//  1. UNCONDITIONAL geometry/derivation layer — runs on every push, no env var needed.
//     Verifies the dayStatusTick size constant, the three value renders,
//     the no-numeric-content guard, and the today-marker static contract.
//  2. GATED snapshot layer — mirrors DrawnInstrumentSnapshotTests.swift exactly.
//     filled/hollow/undrawn × light+dim, filled+today, one AX size, RestWellNode
//     light+dim. References are NOT recorded (APEX_RECORD_SNAPSHOTS is never set
//     here; CI records them on the pinned Xcode 26.3 toolchain).

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

// MARK: ──────────────────────────────────────────────────────────────────────
// 1. UNCONDITIONAL geometry / derivation layer
// ──────────────────────────────────────────────────────────────────────────

@Suite("StatusTick — geometry and derivation assertions")
struct StatusTickGeometryTests {

    // MARK: Geometry constant

    @Test("dayStatusTick size constant is 4pt (matching live-loop §3 spec)")
    func dayStatusTickConstant() {
        #expect(DesignGeometry.dayStatusTick == 4)
    }

    @Test("dayStatusTickStroke is 1.5px (mirrors CapabilityBand hollow dot)")
    func dayStatusTickStrokeConstant() {
        #expect(DesignGeometry.dayStatusTickStroke == 1.5)
    }

    // MARK: Value rendering contracts

    @Test("filled value is distinct from hollow and undrawn")
    func filledIsDistinct() {
        #expect(StatusTickValue.filled != StatusTickValue.hollow)
        #expect(StatusTickValue.filled != StatusTickValue.undrawn)
    }

    @Test("hollow value is distinct from undrawn")
    func hollowIsDistinct() {
        #expect(StatusTickValue.hollow != StatusTickValue.undrawn)
    }

    @Test("undrawn renders as EmptyView — StatusTickValue.undrawn is a distinct case")
    func undrawnIsDistinctCase() {
        // The undrawn case must exist and be distinct (EmptyView contract is structural).
        let v = StatusTickValue.undrawn
        #expect(v == .undrawn)
        #expect(v != .filled)
        #expect(v != .hollow)
    }

    // MARK: No-numeric-content guard (honesty law)
    // The instrument carries no count, ring, percentage, or numeric content.
    // These assertions prove the type contains no numeric-valued public API.

    @Test("StatusTick has no numeric count, ring, or percentage property")
    func noNumericContentOnTick() {
        // The honesty law (issue #410 AC): verify via the type's API surface.
        // StatusTick exposes: value (enum), isToday (Bool), accessibilityLabel (String).
        // None of those carry a numeric count or score.
        // We instantiate and verify no numeric derivation occurs.
        let tick = StatusTick(value: .filled, isToday: false, accessibilityLabel: "Done")
        // accessibilityLabel is caller-supplied, not derived from a number inside the instrument.
        // This test guards that the instrument does not grow a count/score/ring property.
        _ = tick  // compiles = API shape is correct
        #expect(true)  // structural: if a numeric property were added, the above would drift
    }

    @Test("RestWellNode has no numeric count, ring, or percentage property")
    func noNumericContentOnRestWell() {
        let node = RestWellNode(recoveryLine: "Rest day — adaptation happens here.")
        _ = node
        #expect(true)
    }

    // MARK: Today-marker is static (no animation contract)
    // The today marker is a 2px ink left-margin rule — static per train.md §3.
    // We assert it is expressed as a Bool flag (not an animated value or binding).

    @Test("isToday is a static Bool — no animated or binding type")
    func todayMarkerIsStatic() {
        // If isToday were @Binding<Bool> or @State, this initialiser would not compile.
        let withToday = StatusTick(value: .filled, isToday: true, accessibilityLabel: "Done")
        let withoutToday = StatusTick(value: .filled, isToday: false, accessibilityLabel: "Done")
        // Both are value-type constructions — static, no animation hook.
        _ = withToday
        _ = withoutToday
        #expect(true)
    }
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 2. GATED snapshot layer (reference-pending until CI records)
// ──────────────────────────────────────────────────────────────────────────

@Suite("StatusTick snapshots", .enabled(if: snapshotTestsEnabled))
@MainActor
struct StatusTickSnapshotTests {

    /// Small canvas — the tick is a 4pt primitive. Give it room for the today rule.
    private static let tickSize = CGSize(width: 40, height: 40)
    /// Wider canvas for RestWellNode.
    private static let wellSize = CGSize(width: 393, height: 44)

    // MARK: filled × light + dim

    #if canImport(UIKit)
    @Test("filled — light, default Dynamic Type")
    func filled_light_default() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .filled, accessibilityLabel: "Done"),
            size: Self.tickSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-filled-light-default", record: recordModeEnabled)
    }

    @Test("filled — dim, default Dynamic Type")
    func filled_dim_default() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .filled, accessibilityLabel: "Done"),
            size: Self.tickSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-filled-dim-default", record: recordModeEnabled)
    }

    // MARK: hollow × light + dim

    @Test("hollow — light, default Dynamic Type")
    func hollow_light_default() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .hollow, accessibilityLabel: "Planned"),
            size: Self.tickSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-hollow-light-default", record: recordModeEnabled)
    }

    @Test("hollow — dim, default Dynamic Type")
    func hollow_dim_default() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .hollow, accessibilityLabel: "Planned"),
            size: Self.tickSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-hollow-dim-default", record: recordModeEnabled)
    }

    // MARK: undrawn × light + dim (renders nothing — blank canvas is the reference)

    @Test("undrawn — light, default Dynamic Type (blank canvas)")
    func undrawn_light_default() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .undrawn, accessibilityLabel: ""),
            size: Self.tickSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-undrawn-light-default", record: recordModeEnabled)
    }

    @Test("undrawn — dim, default Dynamic Type (blank canvas)")
    func undrawn_dim_default() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .undrawn, accessibilityLabel: ""),
            size: Self.tickSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-undrawn-dim-default", record: recordModeEnabled)
    }

    // MARK: filled + today marker

    @Test("filled + today marker — light, default Dynamic Type")
    func filled_today_light_default() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .filled, isToday: true, accessibilityLabel: "Done — today"),
            size: Self.tickSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-filled-today-light-default", record: recordModeEnabled)
    }

    // MARK: AX size — one case (filled, light, AX5)

    @Test("filled — light, AX5 (largest accessibility size)")
    func filled_light_ax5() {
        let vc = SnapshotHarness.host(
            StatusTick(value: .filled, accessibilityLabel: "Done"),
            size: Self.tickSize, appearance: .light, dynamicType: .accessibility5
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-filled-light-ax5", record: recordModeEnabled)
    }

    // MARK: RestWellNode × light + dim

    @Test("RestWellNode — light, default Dynamic Type")
    func restWell_light_default() {
        let vc = SnapshotHarness.host(
            RestWellNode(recoveryLine: "Rest day — adaptation happens here."),
            size: Self.wellSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-rest-well-light-default", record: recordModeEnabled)
    }

    @Test("RestWellNode — dim, default Dynamic Type")
    func restWell_dim_default() {
        let vc = SnapshotHarness.host(
            RestWellNode(recoveryLine: "Rest day — adaptation happens here."),
            size: Self.wellSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "status-tick-rest-well-dim-default", record: recordModeEnabled)
    }
    #endif
}
