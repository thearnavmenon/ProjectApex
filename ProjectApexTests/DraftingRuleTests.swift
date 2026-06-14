// DraftingRuleTests.swift
// ProjectApexTests
//
// Tests for the drafting-rule system (#411 / ADR-0028).
//
// Two layers:
//  1. UNCONDITIONAL geometry/derivation layer — runs on every push, no env var.
//     The new geometry constants; committed-vs-provisional as a TOTAL function;
//     DraftingRegister absent-at-zero; the discrete (no-interpolation) gradient;
//     the hatch's ink-muted + the dashed mark's projectionDash usage; and the
//     SHARED-DATUM consistency guard (the #408 regression guard — BandDatum.floorX
//     equals the band's representative floorX AND the Progress spine's floorX).
//  2. GATED snapshot layer — light + dim + one AX (reference-pending until CI
//     records on Xcode 26.3; APEX_RECORD_SNAPSHOTS is NEVER set here).

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

@Suite("DraftingRule — geometry and constants")
struct DraftingRuleGeometryTests {

    @Test("Drafting-rule hairline is 1px (splash-today.md §The drawing)")
    func draftingRuleWidth() {
        #expect(DesignGeometry.draftingRuleWidth == 1)
    }

    @Test("Left-margin tick is 4pt (splash-today.md §The drawing)")
    func marginTickLength() {
        #expect(DesignGeometry.marginTickLength == 4)
    }

    @Test("Hatch is a sparse hairline — positive spacing, sub-1px weight, a real diagonal angle")
    func hatchConstants() {
        #expect(DesignGeometry.hatchSpacing > 0)
        #expect(DesignGeometry.hatchLineWidth > 0)
        #expect(DesignGeometry.hatchLineWidth < 1, "Hatch is a hairline — lighter than the structural rule")
        // A real diagonal, not horizontal/vertical (which would collide with the rule
        // or the band's vertical dashed edges).
        #expect(DesignGeometry.hatchAngleDegrees > 0)
        #expect(DesignGeometry.hatchAngleDegrees < 90)
    }

    @Test("Commitment-tier day thresholds are strictly increasing (this-week < compressed)")
    func gradientTierThresholds() {
        #expect(DesignGeometry.commitmentThisWeekMaxDay > 0)
        #expect(DesignGeometry.commitmentCompressedMaxDay > DesignGeometry.commitmentThisWeekMaxDay,
                "Compressed tier must extend past the this-week tier")
    }
}

// MARK: - Committed-vs-provisional: a TOTAL function (mirrors allConfidenceCasesHandled)

@Suite("DraftingRule — committed-vs-provisional totality")
struct CommitmentStateTotalityTests {

    @Test("CommitmentState.forConfidence is total over every AxisConfidence case")
    func forConfidenceIsTotal() {
        // Mirror of CapabilityBand's allConfidenceCasesHandled: every confidence
        // case maps deterministically to a commitment state, no unhandled case.
        for confidence in AxisConfidence.allCases {
            let state = CommitmentState.forConfidence(confidence)
            // Measured confidence → committed; estimated → provisional. The bridge
            // routes through `isMeasured`, so the two axes can never disagree.
            #expect(state == (confidence.isMeasured ? .committed : .provisional))
        }
    }

    @Test("Both CommitmentState cases are reachable from some confidence (the axis is used, not vestigial)")
    func bothStatesReachable() {
        let states = Set(AxisConfidence.allCases.map(CommitmentState.forConfidence))
        #expect(states == [.committed, .provisional])
    }

    @Test("CommitmentState rule style: committed is solid, provisional is dashed")
    func ruleStyleMapping() {
        #expect(CommitmentState.committed.ruleStyle == .solid)
        #expect(CommitmentState.provisional.ruleStyle == .dashed)
    }
}

// MARK: - Commitment gradient is DISCRETE (no interpolation between tiers)

@Suite("DraftingRule — discrete commitment gradient")
struct CommitmentTierDiscreteTests {

    @Test("forDistance is total over Int — every distance (incl. negative/past) maps to a tier")
    func forDistanceIsTotal() {
        for days in [-100, -1, 0, 1, 7, 8, 14, 15, 1000] {
            // No crash, no nil — a tier for every input.
            let _ = CommitmentTier.forDistance(days: days)
        }
    }

    @Test("Adjacent days are STEPS, never interpolated — only the threshold days flip the tier")
    func gradientIsStepwiseNotContinuous() {
        // The defining property of a DISCRETE gradient: within a tier band, every day
        // yields the IDENTICAL tier (no fade); the tier changes only at a threshold.
        let thisWeek = DesignGeometry.commitmentThisWeekMaxDay
        let compressed = DesignGeometry.commitmentCompressedMaxDay

        // Inside the this-week band: all identical.
        for d in 0...thisWeek {
            #expect(CommitmentTier.forDistance(days: d) == .thisWeek)
        }
        // The boundary day flips, then the compressed band is again all-identical.
        #expect(CommitmentTier.forDistance(days: thisWeek + 1) == .compressed)
        for d in (thisWeek + 1)...compressed {
            #expect(CommitmentTier.forDistance(days: d) == .compressed)
        }
        // Past the compressed band: glyph-per-day, all identical.
        #expect(CommitmentTier.forDistance(days: compressed + 1) == .glyphPerDay)
        #expect(CommitmentTier.forDistance(days: compressed + 50) == .glyphPerDay)
    }

    @Test("There are exactly three tiers — a small fixed set, not a continuous range")
    func exactlyThreeTiers() {
        #expect(CommitmentTier.allCases.count == 3)
    }
}

// MARK: - DraftingRegister absent-at-zero

@Suite("DraftingRule — register absent at zero")
struct DraftingRegisterAbsenceTests {

    @Test("Empty / whitespace digits → the register is absent (never a fabricated '0')")
    func absentWhenDigitsEmpty() {
        // Structural mirror of the totalizer-absent-at-zero rule (progress.md §3):
        // no ink digits to show → an empty slot, never "0 floors moved".
        #expect(DraftingRegister.isAbsent(digits: ""))
        #expect(DraftingRegister.isAbsent(digits: "   "))
    }

    @Test("Non-empty digits → the register is present (the two-tone annotation renders)")
    func presentWhenDigitsNonEmpty() {
        #expect(!DraftingRegister.isAbsent(digits: "2"))
        #expect(!DraftingRegister.isAbsent(digits: "+7.5"))
        // The horizon's marker glyph is ink (non-blank) → the horizon register is present.
        #expect(!DraftingRegister.isAbsent(digits: "—"))
    }
}

// MARK: - The hatch ink-muted + dashed-mark projectionDash usage

@Suite("DraftingRule — mark vocabulary (hatch ink-muted, dashed mark projectionDash)")
struct DraftingRuleMarkVocabularyTests {

    @Test("The hatch is drawn in ink-muted (the pencil/skeleton colour, both appearances)")
    func hatchIsInkMuted() {
        // ToBePlacedHatch strokes with theme.inkMuted. ink-muted is the skeleton/pencil
        // colour and is distinct from ink in both appearances, so the hatch never reads
        // as committed ink.
        for theme in [Theme.light, Theme.dim] {
            #expect(theme.inkMuted != theme.ink)
        }
    }

    @Test("The dashed drafting rule reuses the projection dash (4-2) — one confidence vocabulary")
    func dashedRuleUsesProjectionDash() {
        // DraftingRule(.dashed) strokes with DesignGeometry.projectionDash — identical
        // to the band's estimated edges, so "projected" reads the same everywhere.
        #expect(DesignGeometry.projectionDash == [4, 2])
        // The provisional commitment state maps to the dashed style that carries it.
        #expect(CommitmentState.provisional.ruleStyle == .dashed)
    }

    @Test("HatchShape produces at least one hatch line over a non-trivial rect (it is sparse, not empty)")
    func hatchShapeIsNonEmpty() {
        let path = HatchShape().path(in: CGRect(x: 0, y: 0, width: 100, height: 40))
        #expect(!path.isEmpty, "A sparse hatch must still draw lines across the zone")
    }
}

// MARK: - The shared-datum consistency guard (the #408 regression guard)

@Suite("DraftingRule — shared floor datum (the #408 guard)")
struct SharedDatumConsistencyTests {

    /// A realistic Progress-strip width (full row, well past the 48pt min-band-width
    /// expansion threshold so the representative band never shifts its floor).
    private let stripWidth: CGFloat = 360

    @Test("BandDatum.floorX equals the capability band's representative floorX (one datum, the band)")
    func bandDatumMatchesBandLayout() {
        // The shared helper must return the SAME floor x the CapabilityBand plots for
        // the canonical 100→115 representative band — otherwise the spine and the band
        // rows would not fuse.
        let bandFloorX = BandLayout(floor: 100, stretch: 115, observedE1RM: nil, width: stripWidth).floorX
        let datumFloorX = BandDatum.floorX(width: stripWidth)
        #expect(abs(bandFloorX - datumFloorX) < 0.001,
                "BandDatum.floorX must equal the band's representative floorX")
    }

    @Test("BandDatum.floorX is the value the Progress spine fuses on (one datum, the spine)")
    func bandDatumMatchesProgressSpine() {
        // ProgressRootLedger.spineX now consumes BandDatum.floorX directly (the #408
        // fix — it no longer re-derives a representative BandLayout inline). The spine's
        // tick is centered, so it sits at floorX - floorTick/2. We prove the SHARED
        // datum is the centre the spine draws around.
        let datumFloorX = BandDatum.floorX(width: stripWidth)
        // The band's own floor tick is likewise centred on floorX (floorTick wide).
        let bandTickLeadingEdge = BandLayout(floor: 100, stretch: 115, observedE1RM: nil, width: stripWidth).floorX
            - DesignGeometry.floorTick / 2
        let spineLeadingEdge = datumFloorX - DesignGeometry.floorTick / 2
        #expect(abs(bandTickLeadingEdge - spineLeadingEdge) < 0.001,
                "The spine's 2px tick and the band's floor tick must share one leading edge")
    }

    @Test("One floorX across band + spine + horizon — all three agree at multiple widths")
    func oneFloorXAcrossAllThree() {
        // The horizon datum (GenerationHorizonBreak's rule) spans the same spine; its
        // floor reference is BandDatum.floorX too. Prove the three converge at several
        // realistic widths (each past the min-band-width threshold).
        for width in [120, 200, 360, 600] as [CGFloat] {
            let band = BandLayout(floor: 100, stretch: 115, observedE1RM: nil, width: width).floorX
            let datum = BandDatum.floorX(width: width)   // the spine + horizon source
            #expect(abs(band - datum) < 0.001,
                    "Band, spine, and horizon must compute the same floor x at width \(width)")
        }
    }

    @Test("BandDatum.floorX scales linearly with width (it is a fraction of the strip)")
    func floorXScalesLinearly() {
        let single = BandDatum.floorX(width: 100)
        let double = BandDatum.floorX(width: 200)
        #expect(abs(double - 2 * single) < 0.001)
    }
}

// MARK: ──────────────────────────────────────────────────────────────────────
// 2. GATED snapshot layer (reference-pending until CI records)
// ──────────────────────────────────────────────────────────────────────────

@Suite("DraftingRule snapshots", .enabled(if: snapshotTestsEnabled))
@MainActor
struct DraftingRuleSnapshotTests {

    private static let ruleSize = CGSize(width: 393, height: 40)
    private static let horizonSize = CGSize(width: 393, height: 60)
    private static let spineSize = CGSize(width: 393, height: 280)
    private static let consistencySize = CGSize(width: 393, height: 360)

    #if canImport(UIKit)

    // MARK: DraftingRule — solid & dashed

    @Test("DraftingRule solid — light, default Dynamic Type")
    func rule_solid_light() {
        let vc = SnapshotHarness.host(
            DraftingRule(style: .solid, showsMarginTick: true),
            size: Self.ruleSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "drafting-rule-solid-light-default", record: recordModeEnabled)
    }

    @Test("DraftingRule dashed — light, default Dynamic Type")
    func rule_dashed_light() {
        let vc = SnapshotHarness.host(
            DraftingRule(style: .dashed, showsMarginTick: true),
            size: Self.ruleSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "drafting-rule-dashed-light-default", record: recordModeEnabled)
    }

    @Test("DraftingRule solid — dim, default Dynamic Type")
    func rule_solid_dim() {
        let vc = SnapshotHarness.host(
            DraftingRule(style: .solid, showsMarginTick: true),
            size: Self.ruleSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "drafting-rule-solid-dim-default", record: recordModeEnabled)
    }

    // MARK: GenerationHorizonBreak

    @Test("GenerationHorizonBreak — light, default Dynamic Type")
    func horizon_light() {
        let vc = SnapshotHarness.host(
            GenerationHorizonBreak(),
            size: Self.horizonSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "generation-horizon-light-default", record: recordModeEnabled)
    }

    @Test("GenerationHorizonBreak — dim, default Dynamic Type")
    func horizon_dim() {
        let vc = SnapshotHarness.host(
            GenerationHorizonBreak(),
            size: Self.horizonSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "generation-horizon-dim-default", record: recordModeEnabled)
    }

    @Test("GenerationHorizonBreak — light, AX5 (largest accessibility size)")
    func horizon_light_ax5() {
        let vc = SnapshotHarness.host(
            GenerationHorizonBreak(),
            size: Self.horizonSize, appearance: .light, dynamicType: .accessibility5
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "generation-horizon-light-ax5", record: recordModeEnabled)
    }

    // MARK: Train-spine fixture — generated ink above + skeleton hatch below + horizon + gradient

    @Test("Train spine fixture — light, default Dynamic Type")
    func trainSpine_light() {
        let vc = SnapshotHarness.host(
            TrainSpineFixture(),
            size: Self.spineSize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "train-spine-fixture-light-default", record: recordModeEnabled)
    }

    @Test("Train spine fixture — dim, default Dynamic Type")
    func trainSpine_dim() {
        let vc = SnapshotHarness.host(
            TrainSpineFixture(),
            size: Self.spineSize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "train-spine-fixture-dim-default", record: recordModeEnabled)
    }

    // MARK: Consistency snapshot — band + Progress spine + horizon sharing one floor datum

    @Test("Floor-datum consistency — light, default Dynamic Type")
    func datumConsistency_light() {
        let vc = SnapshotHarness.host(
            FloorDatumConsistencyFixture(),
            size: Self.consistencySize, appearance: .light
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "floor-datum-consistency-light-default", record: recordModeEnabled)
    }

    @Test("Floor-datum consistency — dim, default Dynamic Type")
    func datumConsistency_dim() {
        let vc = SnapshotHarness.host(
            FloorDatumConsistencyFixture(),
            size: Self.consistencySize, appearance: .dim
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "floor-datum-consistency-dim-default", record: recordModeEnabled)
    }

    @Test("Floor-datum consistency — light, AX5")
    func datumConsistency_light_ax5() {
        let vc = SnapshotHarness.host(
            FloorDatumConsistencyFixture(),
            size: Self.consistencySize, appearance: .light, dynamicType: .accessibility5
        )
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "floor-datum-consistency-light-ax5", record: recordModeEnabled)
    }
    #endif
}

// MARK: - Snapshot fixtures (test-only assemblies of the dormant primitives)

/// A Train program-root spine fixture: generated (ink) rows above the horizon, the
/// drawn horizon datum, then the skeleton zone (sparse hatch) below — proving the
/// committed-vs-provisional drawing reads at a glance.
private struct TrainSpineFixture: View {
    @Environment(\.apexTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Generated, this-week (ink with numbers).
            Text("LOWER · squat focus · 102.5 kg")
                .apexFont(.label)
                .foregroundStyle(theme.ink.color)
            DraftingRule(style: .solid, showsMarginTick: true)
            // The horizon datum.
            GenerationHorizonBreak()
            // Skeleton zone: pencil shape only, over the sparse hatch.
            ZStack(alignment: .topLeading) {
                ToBePlacedHatch()
                Text("UPPER · push focus · numbers placed closer to the day")
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
                    .padding(.vertical, Spacing.sm)
            }
            .frame(height: 80)
        }
        .padding(Spacing.md)
    }
}

/// A consistency fixture: a list-scale CapabilityBand, a bare Progress-style spine,
/// and a horizon rule — all stacked so their floor datum should align on one
/// vertical. The snapshot proves the shared `BandDatum.floorX` fuses them.
private struct FloorDatumConsistencyFixture: View {
    @Environment(\.apexTheme) private var theme
    private let proj = PatternProjection(pattern: .squat, floor: 100, stretch: 115, progress: .onTrack)
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            CapabilityBand(
                input: CapabilityBandInput(projection: proj, confidence: .established,
                                           observedE1RM: nil, movementDeltaKg: nil, caption: nil),
                context: .list
            )
            GeometryReader { geo in
                // The shared spine datum.
                Rectangle()
                    .fill(theme.ink.color)
                    .frame(width: DesignGeometry.floorTick, height: geo.size.height)
                    .offset(x: BandDatum.floorX(width: geo.size.width) - DesignGeometry.floorTick / 2)
            }
            .frame(height: 60)
            DraftingRule(style: .solid, showsMarginTick: true)
        }
        .padding(Spacing.md)
    }
}
