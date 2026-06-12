// DesignSystemGeometryTests.swift
// ProjectApexTests
//
// The non-image layer of the snapshot/visual-regression harness (#342 / ADR-0025).
// A pixel test proves an instrument is correct at exactly one Dynamic-Type size and
// one appearance; these cheap deterministic `@Test` assertions prove the *geometric*
// and *token-precise* honesty invariants that DESIGN.md encodes — the part of the
// drawn instruments that is invisible in code review and that the image references
// can only spot-check.
//
// This file deliberately needs NO reference PNGs and NO `swift-snapshot-testing`
// dependency: it runs in the mandatory `xcodebuild test -scheme ProjectApex` path,
// ungated, on every push. (The image layer lives in DrawnInstrumentSnapshotTests
// behind APEX_SNAPSHOT_TESTS.)
//
// Covers the shared instrument geometry (DesignGeometry), the spacing/shape/
// elevation scales (Spacing/Radius/Elevation), the motion durations and the
// Reduce-Motion crossfade law (Motion), and the InkPencil two-tone work-is-ink /
// time-is-pencil split. The colour/type token fixtures already live in
// DesignSystemTokensTests; this file is the geometry sibling, not a duplicate.

import Testing
import SwiftUI
@testable import ProjectApex

@Suite("DesignSystem geometry & instrument constants")
struct DesignSystemGeometryTests {

    // MARK: - Drawn-instrument geometry (DESIGN.md §Data visualization)

    @Test("Tick weights carry the floor-vs-stretch honesty: floor is 2px, stretch is 1px hairline")
    func tickWeights() {
        // The whole point of the floor/stretch distinction: the floor (a hard,
        // earned boundary) reads heavier than the stretch (aspirational, hairline).
        #expect(DesignGeometry.floorTick == 2)
        #expect(DesignGeometry.stretchTick == 1)
        #expect(DesignGeometry.floorTick > DesignGeometry.stretchTick)
    }

    @Test("Series stroke width is 2pt (series-primary / series-compare)")
    func seriesLineWidth() {
        #expect(DesignGeometry.seriesLineWidth == 2)
    }

    @Test("Projection is dashed 4-2 — anything projected / estimated is dashed, never solid")
    func projectionDash() {
        #expect(DesignGeometry.projectionDash == [4, 2])
        // A solid line is the absence of a dash; the projection pattern must be a
        // real two-element dash so a projected segment can never render as measured.
        #expect(DesignGeometry.projectionDash.count == 2)
        #expect(DesignGeometry.projectionDash.allSatisfy { $0 > 0 })
    }

    @Test("List-scale reduction dot is 5pt (Progress rows, no bracket)")
    func listScaleDot() {
        #expect(DesignGeometry.listScaleDot == 5)
    }

    // MARK: - Spacing scale (DESIGN.md §spacing)

    @Test("Spacing is a strictly increasing 4-8-16-24-32-48 scale")
    func spacingScale() {
        let scale = [Spacing.xs, Spacing.sm, Spacing.md, Spacing.lg, Spacing.xl, Spacing.xxl]
        #expect(scale == [4, 8, 16, 24, 32, 48])
        #expect(scale == scale.sorted())
        // Strictly increasing — no two steps collapse to the same value.
        #expect(Set(scale).count == scale.count)
    }

    // MARK: - Corner radii (DESIGN.md §rounded)

    @Test("Radii are the locked 8/16/24 scale with a pill sentinel")
    func radiusScale() {
        #expect(Radius.sm == 8)
        #expect(Radius.md == 16)
        #expect(Radius.lg == 24)
        // The pill radius is a large sentinel that fully rounds any reasonable height.
        #expect(Radius.pill == 999)
        #expect(Radius.sm < Radius.md && Radius.md < Radius.lg && Radius.lg < Radius.pill)
    }

    // MARK: - Elevation (DESIGN.md §elevation.card)

    @Test("Card elevation: 6% ink shadow, radius 6 (blur12), offset (0, 2)")
    func cardElevation() {
        // blur12 → SwiftUI shadow radius ≈ blur/2 = 6.
        #expect(Elevation.cardRadius == 6)
        #expect(Elevation.cardX == 0)
        #expect(Elevation.cardY == 2)
        // The shadow ink is the page ink at 6% — a whisper, not a drop shadow.
        #expect(Elevation.cardColor.opacity == 0.06)
        #expect(Elevation.cardColor == TokenColor(0x14151A, opacity: 0.06))
    }

    // MARK: - Motion durations + the Reduce-Motion law (DESIGN.md §Motion)

    @Test("Reduce-Motion crossfade is the 150ms easeInOut every expressive transition collapses to")
    func reduceMotionCrossfade() {
        // The contract asserted byte-identically in the snapshot layer ("frame-1 ==
        // end-state, Reduce Motion is a 150ms crossfade to the same destination")
        // is grounded by this duration existing and matching the routine-nav tempo.
        #expect(Motion.reduceMotionCrossfade == Animation.easeInOut(duration: 0.15))
    }

    @Test("Routine nav is the 150ms 'feels like nothing' tempo; expressive bookends are slower springs")
    func motionTempos() {
        // Workhorse transitions are fast easings; the ≤4 expressive bookends are springs.
        #expect(Motion.nav == Animation.easeOut(duration: 0.15))
        #expect(Motion.logSettle == Animation.easeOut(duration: 0.2))
        #expect(Motion.cardMorph == Animation.easeInOut(duration: 0.35))
        // The spring bookends are distinct from the workhorse easings.
        #expect(Motion.bookend != Motion.nav)
        #expect(Motion.celebrateRatchet != Motion.nav)
    }

    // MARK: - InkPencil two-tone (DESIGN.md system law: work is ink, time is pencil)

    @Test("InkPencil.run splits ink (work) from pencil (time/plan) — the colours differ")
    func inkPencilTwoTone() {
        // The contract is colour, not text: the ink segment renders in `ink`, the
        // pencil segment in `ink-muted`. In both appearances those roles are distinct,
        // so the two-tone split is always visible.
        for theme in [Theme.light, Theme.dim] {
            #expect(theme.ink != theme.inkMuted)
        }
    }

    @Test("actualVersusPlan threads the plan into the pencil segment with the ' · plan ' separator")
    func inkPencilActualVersusPlan() {
        // Done work (actual) is the most-true data → ink; the plan it diverged from is
        // pencil. The helper builds a single two-tone run whose visible string is
        // actual + " · plan " + plan. `Text` isn't structurally Equatable (and its
        // debug description embeds an unstable storage pointer), so we assert on the
        // visible composed string the description carries — the load-bearing contract
        // is the " · plan " separator threading the plan onto the actual; the ink/pencil
        // colour split itself is pinned visually in the token-gallery snapshot.
        let theme = Theme.light
        let composed = InkPencil.actualVersusPlan(actual: "100 kg × 6", plan: "5", theme: theme)
        #expect(String(describing: composed).contains("100 kg × 6 · plan 5"))
    }
}
