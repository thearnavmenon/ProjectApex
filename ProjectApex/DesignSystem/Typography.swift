// Typography.swift
// ProjectApex — DesignSystem
//
// The type layer of the Phase 3 UI overhaul (DESIGN.md §Typography): two embedded
// families — Space Grotesk (display 600 / hero-num 700) and Inter (ui 500 / body
// 400) — exposed as typed tokens at the locked scale. Body & UI track Dynamic
// Type through the AX sizes; hero-num & display cap at 1.3× (past that, layout
// sheds decoration — numbers never ellipsize). Hero-num bakes in tabular figures.
//
// Fonts are registered at runtime with Core Text (ADR-0024) rather than the
// Info.plist `UIAppFonts` key, so embedding touches no `project.pbxproj` build
// setting.

import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Font registration

enum AppFont {
    /// PostScript names of the embedded faces (verified from the .ttf name tables).
    enum PostScriptName {
        static let spaceGroteskSemiBold = "SpaceGrotesk-SemiBold"  // display 600
        static let spaceGroteskBold = "SpaceGrotesk-Bold"          // hero-num 700
        static let interMedium = "Inter-Medium"                    // ui 500
        static let interRegular = "Inter-Regular"                  // body 400
    }

    private static let fileNames = [
        "SpaceGrotesk-SemiBold",
        "SpaceGrotesk-Bold",
        "Inter-Medium",
        "Inter-Regular",
    ]

    /// Register the embedded fonts with Core Text for this process. Evaluated once
    /// (a `static let`), so it is idempotent and safe to touch from app launch,
    /// SwiftUI previews, and the hosted test target.
    static let register: Void = {
        for name in fileNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf")
            else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

// MARK: - FontToken

/// One entry in the type scale. Descriptor fields are introspectable by tests;
/// `font` / the `apexFont(_:)` modifier apply Dynamic Type, the 1.3× cap on
/// hero/display, tabular figures, and tracking.
struct FontToken: Equatable, Sendable {

    /// The four embedded cuts mapped to DESIGN.md's `type` families.
    enum Face: Equatable, Sendable {
        case spaceGroteskSemiBold   // display 600
        case spaceGroteskBold       // hero-num 700
        case interMedium            // ui 500
        case interRegular           // body 400

        var postScriptName: String {
            switch self {
            case .spaceGroteskSemiBold: AppFont.PostScriptName.spaceGroteskSemiBold
            case .spaceGroteskBold: AppFont.PostScriptName.spaceGroteskBold
            case .interMedium: AppFont.PostScriptName.interMedium
            case .interRegular: AppFont.PostScriptName.interRegular
            }
        }
    }

    let face: Face
    /// Base point size before Dynamic Type (DESIGN.md §type-scale).
    let size: CGFloat
    /// The text style this token scales relative to, for Dynamic Type.
    let relativeTo: Font.TextStyle
    /// Tabular (`tnum`) figures — on for hero-num so digits never jitter.
    let tabular: Bool
    /// Dynamic Type ceiling. `nil` tracks every size (body/ui/label); `1.3` caps
    /// hero-num/display (DESIGN.md: past 1.3× layout sheds decoration).
    let maxScale: CGFloat?
    /// Tracking as a fraction of an em (DESIGN.md gives display -0.02em).
    let trackingEm: CGFloat

    // The five DESIGN.md scale anchors.
    static let heroNum = FontToken(face: .spaceGroteskBold, size: 64, relativeTo: .largeTitle, tabular: true, maxScale: 1.3, trackingEm: 0)
    static let display = FontToken(face: .spaceGroteskSemiBold, size: 34, relativeTo: .largeTitle, tabular: false, maxScale: 1.3, trackingEm: -0.02)
    static let title = FontToken(face: .interMedium, size: 22, relativeTo: .title2, tabular: false, maxScale: nil, trackingEm: 0)
    static let body = FontToken(face: .interRegular, size: 17, relativeTo: .body, tabular: false, maxScale: nil, trackingEm: 0)
    static let label = FontToken(face: .interMedium, size: 13, relativeTo: .caption, tabular: false, maxScale: nil, trackingEm: 0)

    /// The base (un-capped) SwiftUI font: custom face, scaled relative to its text
    /// style for Dynamic Type, tabular applied when requested. The capped tokens
    /// (hero/display) get their cap through `apexFont(_:)`; this property is their
    /// un-capped fallback.
    var font: Font {
        _ = AppFont.register
        var f = Font.custom(face.postScriptName, size: size, relativeTo: relativeTo)
        if tabular { f = f.monospacedDigit() }
        return f
    }
}

// MARK: - Dynamic Type resolution

enum Typography {
    /// The Dynamic-Type-scaled point size for a token, capped at `maxScale` when
    /// set. UIFontMetrics is the source of truth for the scale curve; runs in the
    /// hosted test target.
    static func resolvedSize(_ token: FontToken, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        #if canImport(UIKit)
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle(token.relativeTo))
        let trait = UITraitCollection(preferredContentSizeCategory: uiContentSizeCategory(dynamicTypeSize))
        let scaled = metrics.scaledValue(for: token.size, compatibleWith: trait)
        if let maxScale = token.maxScale {
            return min(scaled, token.size * maxScale)
        }
        return scaled
        #else
        if let maxScale = token.maxScale {
            return token.size * maxScale
        }
        return token.size
        #endif
    }

    #if canImport(UIKit)
    private static func uiContentSizeCategory(_ s: DynamicTypeSize) -> UIContentSizeCategory {
        switch s {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    private static func uiTextStyle(_ s: Font.TextStyle) -> UIFont.TextStyle {
        switch s {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
    #endif
}

// MARK: - apexFont modifier

extension View {
    /// Apply a design-system type token: the custom face, Dynamic Type (capped at
    /// 1.3× for hero/display), tabular figures on hero-num, and DESIGN.md tracking.
    ///
    /// Numbers must never be truncated — do not add `.lineLimit`/truncation to a
    /// number run rendered with `.heroNum`.
    func apexFont(_ token: FontToken) -> some View {
        modifier(ApexFontModifier(token: token))
    }
}

private struct ApexFontModifier: ViewModifier {
    let token: FontToken
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        _ = AppFont.register
        let font: Font
        if token.maxScale != nil {
            // Capped: resolve a concrete size, then use a non-scaling custom font.
            let size = Typography.resolvedSize(token, dynamicTypeSize: dynamicTypeSize)
            var f = Font.custom(token.face.postScriptName, fixedSize: size)
            if token.tabular { f = f.monospacedDigit() }
            font = f
        } else {
            // Uncapped: track Dynamic Type natively via `relativeTo`.
            font = token.font
        }
        return content
            .font(font)
            .tracking(token.size * token.trackingEm)
    }
}
