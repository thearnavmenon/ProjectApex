import SwiftUI

// MARK: - Apex Brutalist design tokens
//
// The production design-system identity for the workout screens. Ported from
// the approved "Brutalist Athletic" prototype direction: pure-black surfaces,
// a single volt-lime accent reserved for the live/primary action, sharp ~4pt
// corners, and tabular + condensed black numerals as the signature face.
//
// One identity, baked in. There is deliberately no `Direction` parameter here —
// production is Brutalist, full stop.

/// Caseless namespace for color / spacing / corner tokens and the numeral face.
enum Apex {

    // MARK: Surfaces
    /// Pure black backdrop (#000).
    static let bg = Color.black
    /// Card / raised surface fill.
    static let surface = Color(white: 0.05)
    /// Standard hairline stroke for card edges.
    static let hairline = Color.white.opacity(0.14)

    // MARK: Text ramp
    static let text = Color.white
    static let textDim = Color.white.opacity(0.50)
    static let textFaint = Color.white.opacity(0.32)

    // MARK: Accents
    /// Volt lime — used ONLY on the live / primary action.
    static let accent = Color(red: 0.80, green: 0.98, blue: 0.32)
    /// Amber — paused state only.
    static let amber = Color(red: 1.0, green: 0.66, blue: 0.20)
    /// Gold — personal-record (PR) highlight only.
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.36)
    /// Color shown on top of a filled accent surface (text/icon on volt lime).
    static let onAccent = Color.black

    // MARK: Geometry
    /// Sharp corner radius — the Brutalist signature.
    static let corner: CGFloat = 4
    /// Default content padding.
    static let pad: CGFloat = 22

    // MARK: Numerals
    /// The signature numeral face: black-weight, tabular (monospaced) digits.
    /// Apply `.fontWidth(.condensed)` alongside this for the full effect — the
    /// `ApexNumeral` view does that for you.
    ///
    /// Tabular digits are the structural fix for the "17.5 collapses / reflows"
    /// bug: every glyph is the same width, so a value never changes its mass in
    /// a fixed slot. Always render numerals through this (or `ApexNumeral`).
    static func numeral(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

// MARK: - Section micro-label

extension View {
    /// Small-caps descriptor label used above hero numerals and on chips:
    /// uppercase, tracked, condensed.
    func apexLabel(_ color: Color = Apex.textDim) -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.5)
            .fontWidth(.condensed)
            .foregroundStyle(color)
    }
}

// MARK: - Weight truncation fix

/// Split a kg value into its dominant integer part and a de-emphasised
/// fraction so "142.5" reads as a big "142" + small ".5", and "80" shows
/// no fraction at all — constant visual mass across magnitudes. This is the
/// weight-truncation fix: nothing reflows when the value changes (17.5 / 80 /
/// 142.5 all keep the same layout).
struct WeightParts {
    /// The whole-number part, e.g. "142".
    let whole: String
    /// The fractional part including its leading dot, e.g. ".5". `nil` when the
    /// value is a whole number.
    let frac: String?

    init(_ kg: Double) {
        let rounded = (kg * 10).rounded() / 10
        whole = String(Int(rounded))
        let f = rounded - Double(Int(rounded))
        frac = f == 0 ? nil : String(format: ".%d", Int((f * 10).rounded()))
    }
}
