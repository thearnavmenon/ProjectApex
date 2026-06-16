// ProgressDesignTokens.swift
// ProjectApex — Features/Progress
//
// Local design-token set for the redesigned Progress tab — a premium dark
// "strength instrument". The Phase-3 global tokens were deleted in PR #426;
// these are scoped to Progress only. Palette: mint accent + an isolated gold
// reserved for PRs, on near-black. Direction chosen by the multi-agent design
// panel (lens A — premium dashboard).

import SwiftUI

enum ProgressDesignTokens {

    // MARK: - Colours
    static let bg       = Color(red: 0.039, green: 0.043, blue: 0.051) // #0A0B0D screen
    static let surface1 = Color(red: 0.082, green: 0.090, blue: 0.106) // #15171B hero card
    static let surface2 = Color(red: 0.118, green: 0.129, blue: 0.153) // #1E2127 other cards
    static let accent   = Color(red: 0.212, green: 0.878, blue: 0.627) // #36E0A0 mint
    static let up       = Color(red: 0.212, green: 0.878, blue: 0.627) // positive / progressing
    static let down     = Color(red: 1.000, green: 0.420, blue: 0.420) // #FF6B6B negative / declining
    static let neutral  = Color(red: 0.541, green: 0.565, blue: 0.600) // #8A9099 muted text / plateau
    static let prGold   = Color(red: 0.961, green: 0.769, blue: 0.318) // #F5C451 PR markers only
    static let amber    = Color(red: 0.910, green: 0.690, blue: 0.294) // #E8B04B force-deload caution

    /// Faint fill for empty heatmap cells (must read against `surface2`).
    static let emptyCell = Color.white.opacity(0.06)
    /// Hairline grid lines inside charts.
    static let gridLine  = Color.white.opacity(0.06)

    // MARK: - Radii
    static let cardRadius: CGFloat = 20
    static let chipRadius: CGFloat = 12
    static let cellRadius: CGFloat = 3

    // MARK: - Spacing
    static let screenPadding: CGFloat = 16
    static let sectionGap:    CGFloat = 28
    static let cardPadding:   CGFloat = 18
    static let heroPadding:   CGFloat = 20

    // MARK: - Type scale (SF; rounded + monospacedDigit for numerics)
    static let screenTitle = Font.system(size: 34, weight: .bold)
    static let hero        = Font.system(size: 48, weight: .bold,     design: .rounded).monospacedDigit()
    static let heroUnit    = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let cardTitle   = Font.system(size: 20, weight: .semibold)
    static let statNumber  = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    static let bodyText    = Font.system(size: 15, weight: .regular)
    static let caption     = Font.system(size: 12, weight: .medium)
}
