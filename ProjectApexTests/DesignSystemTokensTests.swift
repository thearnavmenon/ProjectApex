// DesignSystemTokensTests.swift
// ProjectApexTests
//
// Executable fixtures for the Phase 3 design-system foundation (#341 / ADR-0024).
// Pure-Swift tokens make DESIGN.md's rules checkable: a wrong ink, a dim role that
// forgot to remap, an accent that drifts below AA, or a bright accent wired as text
// all fail here.
//
// Covers:
//   • Colour token resolution + DESIGN.md hex fixtures
//   • Dim remap distinctness (same role → distinct value)
//   • AA contrast (accent-ink ≥4.5:1 on paper; ink/ink-muted floors)
//   • P0-4: bright accent never wired as a text/icon/hairline role
//   • Data-viz token resolution + distinctness + dim remap
//   • Typography: scale, family mapping, tabular, the 1.3× cap, font registration
//   • The Settings appearance override resolution

import Testing
import SwiftUI
@testable import ProjectApex

@Suite("DesignSystem tokens")
struct DesignSystemTokensTests {

    private let bothThemes: [Theme] = [.light, .dim]

    // MARK: - Colour resolution

    @Test("Every colour role resolves to in-gamut sRGB components")
    func everyTokenResolves() {
        for theme in bothThemes {
            let textRoles = [theme.paper, theme.surface, theme.well, theme.hairline,
                             theme.ink, theme.inkMuted, theme.accentInk, theme.onAccent, theme.alert]
            for c in textRoles {
                #expect((0...1).contains(c.red))
                #expect((0...1).contains(c.green))
                #expect((0...1).contains(c.blue))
                #expect((0...1).contains(c.opacity))
            }
            for f in [theme.accentFill, theme.accentPress, theme.alertFill] {
                #expect((0...1).contains(f.token.red))
                #expect((0...1).contains(f.token.green))
                #expect((0...1).contains(f.token.blue))
            }
        }
    }

    @Test("Hex values match DESIGN.md exactly")
    func hexFixtures() {
        #expect(Theme.light.paper == TokenColor(0xF6F2E8))
        #expect(Theme.light.surface == TokenColor(0xFFFFFF))
        #expect(Theme.light.ink == TokenColor(0x14151A))
        #expect(Theme.light.inkMuted == TokenColor(0x66645C))
        #expect(Theme.light.accentInk == TokenColor(0x1322CC))
        #expect(Theme.light.accentFill.token == TokenColor(0x1B2CFF))
        #expect(Theme.light.alert == TokenColor(0xC9241B))

        #expect(Theme.dim.paper == TokenColor(0x14151A))
        #expect(Theme.dim.ink == TokenColor(0xF6F2E8))
        #expect(Theme.dim.accentInk == TokenColor(0x7B85FF))
        // The brand colour itself never shifts — only its small-scale cut.
        #expect(Theme.dim.accentFill.token == TokenColor(0x1B2CFF))
    }

    // MARK: - Dim remap distinctness

    @Test("Dim remaps the small-scale roles to distinct values")
    func dimRemapDistinct() {
        #expect(Theme.light.paper != Theme.dim.paper)
        #expect(Theme.light.surface != Theme.dim.surface)
        #expect(Theme.light.well != Theme.dim.well)
        #expect(Theme.light.hairline != Theme.dim.hairline)
        #expect(Theme.light.ink != Theme.dim.ink)
        #expect(Theme.light.inkMuted != Theme.dim.inkMuted)
        #expect(Theme.light.accentInk != Theme.dim.accentInk)
        #expect(Theme.light.accentPress.token != Theme.dim.accentPress.token)
        #expect(Theme.light.alert != Theme.dim.alert)
        // The brand fill is intentionally invariant across appearances.
        #expect(Theme.light.accentFill.token == Theme.dim.accentFill.token)
    }

    // MARK: - Contrast (AA)

    @Test("accent-ink meets AA (≥4.5:1) on paper, both appearances")
    func accentInkAA() {
        #expect(Theme.light.accentInk.contrastRatio(against: Theme.light.paper) >= 4.5)
        #expect(Theme.dim.accentInk.contrastRatio(against: Theme.dim.paper) >= 4.5)
    }

    @Test("ink and ink-muted clear their contrast floors on paper")
    func inkContrast() {
        #expect(Theme.light.ink.contrastRatio(against: Theme.light.paper) >= 7)        // ~15:1
        #expect(Theme.light.inkMuted.contrastRatio(against: Theme.light.paper) >= 4.5)
        #expect(Theme.dim.ink.contrastRatio(against: Theme.dim.paper) >= 7)
        #expect(Theme.dim.inkMuted.contrastRatio(against: Theme.dim.paper) >= 4.5)
    }

    // MARK: - P0-4: bright accent is large-fill only

    @Test("Bright accent is never wired as a text / icon / hairline role")
    func brightAccentNeverText() {
        for theme in bothThemes {
            let brightAccent = theme.accentFill.token
            let textIconHairlineRoles = [theme.ink, theme.inkMuted, theme.accentInk,
                                         theme.onAccent, theme.alert, theme.hairline]
            for role in textIconHairlineRoles {
                #expect(role != brightAccent)
            }
        }
    }

    // MARK: - Data-viz tokens

    @Test("Data-viz tokens resolve, alias the right base roles, and stay distinct")
    func dataVizTokens() {
        let t = Theme.light
        // Aliases per DESIGN.md §Data visualization.
        #expect(t.seriesPrimary == t.accentInk)
        #expect(t.axis == t.inkMuted)
        #expect(t.bandEdge == t.hairline)
        #expect(t.pointMeasured == t.accentInk)
        #expect(t.pointEstimatedStroke == t.ink)
        // Measured (solid accent-ink) vs estimated (ink stroke) must read differently.
        #expect(t.pointMeasured != t.pointEstimatedStroke)
        // Compare series is ink at reduced opacity — distinct from the primary.
        #expect(t.seriesCompare != t.seriesPrimary)
        #expect(t.seriesCompare.opacity < 1.0)
        // Band is a low-opacity fill.
        #expect(t.bandFill.opacity < 0.2)
        // Dim remaps the small-scale cut.
        #expect(Theme.light.seriesPrimary != Theme.dim.seriesPrimary)
        #expect(Theme.light.bandFill != Theme.dim.bandFill)
    }

    // MARK: - Typography

    @Test("Type tokens carry the DESIGN.md scale and family mapping")
    func typeScale() {
        #expect(FontToken.heroNum.size == 64)
        #expect(FontToken.display.size == 34)
        #expect(FontToken.title.size == 22)
        #expect(FontToken.body.size == 17)
        #expect(FontToken.label.size == 13)

        #expect(FontToken.heroNum.face == .spaceGroteskBold)
        #expect(FontToken.display.face == .spaceGroteskSemiBold)
        #expect(FontToken.title.face == .interMedium)
        #expect(FontToken.body.face == .interRegular)
        #expect(FontToken.label.face == .interMedium)
    }

    @Test("hero-num bakes tabular figures; body does not")
    func tabularFigures() {
        #expect(FontToken.heroNum.tabular == true)
        #expect(FontToken.body.tabular == false)
    }

    @Test("hero-num & display cap at 1.3×; body / ui / label track Dynamic Type uncapped")
    func dynamicTypeCaps() {
        #expect(FontToken.heroNum.maxScale == 1.3)
        #expect(FontToken.display.maxScale == 1.3)
        #expect(FontToken.body.maxScale == nil)
        #expect(FontToken.title.maxScale == nil)
        #expect(FontToken.label.maxScale == nil)

        // The cap holds: at the largest AX size hero-num is exactly its 1.3× ceiling.
        let cappedHero = Typography.resolvedSize(.heroNum, dynamicTypeSize: .accessibility5)
        #expect(cappedHero == FontToken.heroNum.size * FontToken.heroNum.maxScale!)

        // Body scales unbounded — strictly larger than its base at the biggest AX size…
        let bigBody = Typography.resolvedSize(.body, dynamicTypeSize: .accessibility5)
        #expect(bigBody > FontToken.body.size)
        // …and ≈ its base at the default content size.
        let defaultBody = Typography.resolvedSize(.body, dynamicTypeSize: .large)
        #expect(abs(defaultBody - FontToken.body.size) < 0.5)
    }

    @Test("Embedded fonts register and resolve by PostScript name")
    func fontsRegister() {
        _ = AppFont.register
        #if canImport(UIKit)
        #expect(UIFont(name: AppFont.PostScriptName.spaceGroteskBold, size: 64) != nil)
        #expect(UIFont(name: AppFont.PostScriptName.spaceGroteskSemiBold, size: 34) != nil)
        #expect(UIFont(name: AppFont.PostScriptName.interRegular, size: 17) != nil)
        #expect(UIFont(name: AppFont.PostScriptName.interMedium, size: 13) != nil)
        #endif
    }

    // MARK: - Settings appearance override

    @Test("Appearance override resolves to the correct concrete appearance")
    func appearanceOverride() {
        #expect(AppearanceSetting.system.appearance(systemColorScheme: .dark) == .dim)
        #expect(AppearanceSetting.system.appearance(systemColorScheme: .light) == .light)
        #expect(AppearanceSetting.light.appearance(systemColorScheme: .dark) == .light)
        #expect(AppearanceSetting.dim.appearance(systemColorScheme: .light) == .dim)
    }
}
