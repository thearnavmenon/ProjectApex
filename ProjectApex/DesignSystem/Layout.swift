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
}
