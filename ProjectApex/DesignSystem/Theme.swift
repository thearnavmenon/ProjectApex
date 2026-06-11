// Theme.swift
// ProjectApex — DesignSystem
//
// The colour layer of the Phase 3 UI overhaul, translated from DESIGN.md.
// Pure-Swift tokens (no role colorsets): the dim variant is a non-uniform remap
// of the SAME role names, so a single source of truth in code beats two
// desyncable asset catalogs — and pure Swift exposes sRGB components to headless
// unit tests, turning DESIGN.md's hex values into executable fixtures (ADR-0024).
//
// Colour is the only token family that varies at runtime, so it travels through
// the Environment as a `Theme`; everything else (spacing, type, motion, haptics)
// is a static namespaced enum elsewhere in this module.

import SwiftUI

// MARK: - TokenColor

/// An sRGB colour value held as components, so it is readable by headless tests
/// and carries DESIGN.md's exact hex. `DESIGN.md` is the source of truth for
/// every literal in this file.
struct TokenColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// Build from a 24-bit hex literal, e.g. `TokenColor(0xF6F2E8)`.
    init(_ hex: UInt32, opacity: Double = 1) {
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
        self.opacity = opacity
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// The same colour at a different alpha — for band fills and the compare series.
    func withOpacity(_ o: Double) -> TokenColor {
        TokenColor(red: red, green: green, blue: blue, opacity: o)
    }

    /// WCAG relative luminance (alpha ignored — contrast is defined on opaque colours).
    var relativeLuminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG contrast ratio against another colour (1…21).
    func contrastRatio(against other: TokenColor) -> Double {
        let hi = max(relativeLuminance, other.relativeLuminance)
        let lo = min(relativeLuminance, other.relativeLuminance)
        return (hi + 0.05) / (lo + 0.05)
    }
}

// MARK: - FillToken (bright accent — large-fill only)

/// The bright accent (`#1B2CFF`) and the other large-fill roles. Deliberately a
/// `ShapeStyle` and **not** a `TokenColor`: it exposes no `.color`, so the bright
/// accent has no path to text/icon foreground through the token palette. That is
/// P0-4 ("bright accent is large-fill only") enforced by the API shape, not a lint.
///
/// Use it for fills — `.background(theme.accentFill)`, `Capsule().fill(theme.accentFill)`.
/// The text-safe ultramarine for instrument strokes/dots is `accentInk` (a TokenColor),
/// per the capstone amendment: the no-bright-accent guard is a *text-role* constraint,
/// not a ban on non-text ultramarine.
struct FillToken: ShapeStyle, Equatable, Sendable {
    /// The underlying value — for tests and low-opacity fill derivations only.
    let token: TokenColor

    init(_ token: TokenColor) { self.token = token }

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        token.color
    }

    /// A low-opacity fill derived from this role (e.g. the capability band fill).
    func fill(opacity: Double) -> Color { token.withOpacity(opacity).color }
}

// MARK: - Appearance

/// The two concrete appearances. `dim` is "the negative of the page" — the same
/// roles, re-tabulated (DESIGN.md §Dim variant), not a separate design.
enum Appearance: String, CaseIterable, Sendable {
    case light, dim
}

// MARK: - Theme

/// The resolved colour roles for one appearance. Base roles are stored; the
/// data-viz family is *computed* from them, so "series-primary IS accent-ink",
/// "axis IS ink-muted" etc. (DESIGN.md §Data visualization) can never drift.
struct Theme: Equatable, Sendable {
    let appearance: Appearance

    // Surface / structure
    let paper: TokenColor
    let surface: TokenColor
    let well: TokenColor
    let hairline: TokenColor

    // Text / ink roles — the ONLY roles intended for foreground text & icons.
    // (No bright-accent member: that is the structural half of P0-4.)
    let ink: TokenColor
    let inkMuted: TokenColor
    let accentInk: TokenColor
    let onAccent: TokenColor
    let alert: TokenColor

    // Large-fill roles — `ShapeStyle`, no text path.
    let accentFill: FillToken
    let accentPress: FillToken
    let alertFill: FillToken

    // MARK: Data-viz (drawn instruments) — derived from the base roles.
    // Strokes/dots are accent-ink-the-value (text-safe); only the band is a fill.

    /// `series-primary: accent-ink line, 2pt`.
    var seriesPrimary: TokenColor { accentInk }
    /// `series-compare: ink at 30% opacity, 2pt`.
    var seriesCompare: TokenColor { ink.withOpacity(0.30) }
    /// `band: hairline edges` (the band fill is `bandFill`).
    var bandEdge: TokenColor { hairline }
    /// `point-measured: solid accent-ink dot`.
    var pointMeasured: TokenColor { accentInk }
    /// `point-estimated: hollow dot (ink stroke)` — low-confidence data looks less certain.
    var pointEstimatedStroke: TokenColor { ink }
    /// `axis: label type, ink-muted`.
    var axis: TokenColor { inkMuted }
    /// `band: accent at 8% fill` (light) / `#7B85FF at 12% fill` (dim). A fill value,
    /// not a text role: light draws the band from the bright accent, dim from the
    /// lifted accent-ink (DESIGN.md §data-viz / §data-viz-dim).
    var bandFill: TokenColor {
        switch appearance {
        case .light: accentFill.token.withOpacity(0.08)
        case .dim: accentInk.withOpacity(0.12)
        }
    }

    // MARK: Tables

    /// Light ("paper") — the default appearance.
    static let light = Theme(
        appearance: .light,
        paper: TokenColor(0xF6F2E8),
        surface: TokenColor(0xFFFFFF),
        well: TokenColor(0xEDE7D9),
        hairline: TokenColor(0xDCD5C4),
        ink: TokenColor(0x14151A),
        inkMuted: TokenColor(0x66645C),
        accentInk: TokenColor(0x1322CC),
        onAccent: TokenColor(0xFFFFFF),
        alert: TokenColor(0xC9241B),
        accentFill: FillToken(TokenColor(0x1B2CFF)),
        accentPress: FillToken(TokenColor(0x0E1AA3)),
        alertFill: FillToken(TokenColor(0xFF3B30))
    )

    /// Dim — the same roles, remapped. "The brand colour itself never shifts,
    /// only its small-scale cut": `accentFill` stays true ultramarine.
    static let dim = Theme(
        appearance: .dim,
        paper: TokenColor(0x14151A),
        surface: TokenColor(0x1C1E25),
        well: TokenColor(0x101116),
        hairline: TokenColor(0x2A2D36),
        ink: TokenColor(0xF6F2E8),
        inkMuted: TokenColor(0x9B9DA6),
        accentInk: TokenColor(0x7B85FF),
        onAccent: TokenColor(0xFFFFFF),
        alert: TokenColor(0xFF6B61),
        accentFill: FillToken(TokenColor(0x1B2CFF)),
        accentPress: FillToken(TokenColor(0x98A0FF)),
        alertFill: FillToken(TokenColor(0xFF3B30))
    )

    static func current(_ appearance: Appearance) -> Theme {
        appearance == .dim ? .dim : .light
    }
}

// MARK: - Environment injection

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .light
}

extension EnvironmentValues {
    /// The resolved design-system theme. Injected near the app root by
    /// `apexThemeRoot()`; re-inject across `fullScreenCover`/sheet boundaries that
    /// build their own environment.
    var apexTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Settings override

/// The user's appearance preference, persisted. `.system` follows the OS scheme
/// (DESIGN.md: "follow the system appearance by default; offer an in-app override").
enum AppearanceSetting: String, CaseIterable, Identifiable, Sendable {
    case system, light, dim

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dim: "Dim"
        }
    }

    /// The `@AppStorage` / `UserDefaults` key for the persisted preference.
    static let storageKey = "apex.appearanceSetting"

    /// Resolve to a concrete `Appearance`, given the current system colour scheme.
    func appearance(systemColorScheme: ColorScheme) -> Appearance {
        switch self {
        case .system: systemColorScheme == .dark ? .dim : .light
        case .light: .light
        case .dim: .dim
        }
    }
}

extension View {
    /// Resolve the design-system `Theme` from the persisted Settings override and
    /// inject it into the environment. Apply once near the app root. This is the
    /// new system's own light/dim switch — it does **not** touch the global
    /// `colorScheme`, so the legacy (un-migrated) screens are unaffected.
    func apexThemeRoot() -> some View { modifier(ApexThemeRoot()) }
}

private struct ApexThemeRoot: ViewModifier {
    @AppStorage(AppearanceSetting.storageKey) private var setting: AppearanceSetting = .system
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let appearance = setting.appearance(systemColorScheme: colorScheme)
        content.environment(\.apexTheme, Theme.current(appearance))
    }
}
