// Layout.swift
// ProjectApex — DesignSystem
//
// Spacing, shape, elevation, and the shared drawn-instrument geometry
// (DESIGN.md §Spacing & Shape + §Data visualization). Static namespaced enums —
// these never vary at runtime, so they live outside the Environment-injected Theme.

import SwiftUI

/// DESIGN.md §spacing.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

/// DESIGN.md §rounded — friendly-but-engineered corner radii.
enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let pill: CGFloat = 999
}

/// DESIGN.md §elevation.card — only the active/coach surface lifts (light mode);
/// in dim, depth comes from surface lightness, not shadow. SwiftUI's shadow
/// `radius` ≈ blur/2, so "blur12" maps to radius 6.
enum Elevation {
    static let cardColor = TokenColor(0x14151A, opacity: 0.06)   // rgba(20,21,26,0.06)
    static let cardRadius: CGFloat = 6                           // blur12 → radius 6
    static let cardX: CGFloat = 0
    static let cardY: CGFloat = 2
}

/// Shared geometric constants for the drawn instruments — the capability band
/// (one component, three contexts) and the data-viz series (DESIGN.md
/// §Data visualization + the ADR-0024 capstone amendment). One home so the three
/// band contexts and every chart stay dimensionally identical.
enum DesignGeometry {
    /// `series-primary` / `series-compare` stroke width.
    static let seriesLineWidth: CGFloat = 2
    /// Floor tick — full ink, 2px.
    static let floorTick: CGFloat = 2
    /// Stretch tick — hairline, 1px.
    static let stretchTick: CGFloat = 1
    /// List-scale reduction dot — 5pt (Progress rows; no bracket).
    static let listScaleDot: CGFloat = 5
    /// `projection` — dashed 4-2; anything projected/estimated is dashed.
    static let projectionDash: [CGFloat] = [4, 2]
    /// Day-status tick diameter — 4pt, matching the live-loop set-position tick.
    static let dayStatusTick: CGFloat = 4
    /// Day-status hollow tick stroke width — 1.5px, mirroring CapabilityBand's hollow dot.
    static let dayStatusTickStroke: CGFloat = 1.5

    // MARK: - Drafting-rule system (#411 / ADR-0028)
    // The committed-vs-provisional drawing vocabulary: a structural hairline + a
    // drawn boundary (rule + hatch) between what the model has placed and what is
    // still shape-only. One home so Today's hairlines, Train's horizon datum, and
    // Progress's register stay dimensionally identical.

    /// Drafting-rule structural hairline — 1px (splash-today.md §The drawing;
    /// train.md §3 horizon datum). The same weight as a band hairline edge.
    static let draftingRuleWidth: CGFloat = 1
    /// Left-margin tick on the top rule — 4pt (splash-today.md §The drawing:
    /// "4pt tick marks at the left margin").
    static let marginTickLength: CGFloat = 4

    /// To-be-placed hatch (train.md §3 skeleton zone): a sparse diagonal hairline
    /// hatch in `ink-muted`, distinct from the band's dashed *edges* so the two
    /// confidence marks never collide on the same drawing.
    /// Spacing between hatch lines, measured along the perpendicular.
    static let hatchSpacing: CGFloat = 8
    /// Hatch line weight — hairline, matching the structural rule.
    static let hatchLineWidth: CGFloat = 0.5
    /// Hatch diagonal angle, in degrees from horizontal (a shallow draughting cant).
    static let hatchAngleDegrees: CGFloat = 45

    /// Commitment gradient — DISCRETE tiers, not a continuous fade (train.md §3:
    /// "a commitment gradient … increasing with distance"; ratified as discrete tiers
    /// so it reads as calendar-furniture compression, NOT a confidence-on-a-chart
    /// gradient — the no-slope carve-out, ADR-0028). These day thresholds bucket a
    /// day's distance-from-now into the three render tiers.
    /// ≤ this many days out → `.thisWeek` (full row detail).
    static let commitmentThisWeekMaxDay: Int = 7
    /// ≤ this many days out (and beyond this-week) → `.compressed` (brief shape).
    /// Beyond it → `.glyphPerDay` (one pencil glyph per day).
    static let commitmentCompressedMaxDay: Int = 14
}

// MARK: - BandDatum (the shared floor-x helper, #408 / #411)

/// The single source of truth for *where the floor sits* across the drawn
/// instruments that share one vertical datum: the capability band's left edge,
/// the Progress root spine, and Train's generation-horizon spine.
///
/// Before this helper, `BandLayout` computed `floorX` and `ProgressRootLedger`
/// *re-derived* it inline from a hardcoded representative band — so a row whose
/// band width differed (the 48pt minimum-width expansion) landed its floor tick
/// off the spine. Routing both through `floorX(width:)` fuses every row onto one
/// datum (the #408 fix).
enum BandDatum {

    /// Fraction of the available width at which the floor sits, for the canonical
    /// representative band (floor 100 → stretch 115, no dot). This is the spine's
    /// position: `BandLayout` plots each row's own floor here too (same domain
    /// margin), so a same-shaped row's floor tick lands exactly on the spine.
    ///
    /// Derivation (matching `BandLayout`): domain = band ± 20%. For 100→115:
    /// bandWidth 15, margin 3, domainMin 97, domainMax 118, span 21 →
    /// floor fraction = (100 − 97) / 21.
    static let floorFraction: CGFloat = 3.0 / 21.0

    /// The x-position (points) of the floor datum for a strip of the given width.
    /// The band, the Progress spine, and the horizon all call this — one floor x.
    static func floorX(width: CGFloat) -> CGFloat {
        floorFraction * width
    }
}
