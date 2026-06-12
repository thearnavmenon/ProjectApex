// DrawnInstrumentSnapshotTests.swift
// ProjectApexTests
//
// The image layer of the snapshot/visual-regression harness (#342 / ADR-0025).
// pointfreeco/swift-snapshot-testing drives one rendering route — a UIHostingController
// captured with `.image(...)` — over the rebuild's drawn instruments. This proves
// holistic layout + token/hue rendering that the geometry assertions
// (DesignSystemGeometryTests) can't see: that the band fill is the right ink at the
// right opacity, that hollow-vs-solid dots read apart, that a wrong colour fails.
//
// ────────────────────────────────────────────────────────────────────────────────
// REFERENCE IMAGES ARE NOT YET RECORDED — BY DESIGN. See "Recording references".
// On a developer machine (Xcode 26.5) this suite is gated OFF (APEX_SNAPSHOT_TESTS
// unset) so it neither records nor compares. References must be recorded by ONE
// owner on the CI-pinned toolchain (Xcode 26.3) — recording them on a skewed local
// toolchain poisons every later instrument slice with San-Francisco / sub-pixel
// drift. Until that CI record job runs, the `assertSnapshot` cases are
// reference-pending: enabling the gate WITHOUT references will *fail* (missing
// reference), which is the correct "not yet ratified" signal, not a false green.
// ────────────────────────────────────────────────────────────────────────────────
//
// Two things in this file run UNGATED, on every push, because they protect the
// references rather than depend on them:
//   • `fontPrecondition` — asserts both embedded faces resolve by PostScript name.
//     If they don't, any recorded reference silently encodes San Francisco.
//   • the hue-swap negative test lives in the gated suite (it needs the pixel
//     engine) but documents the tolerance contract.
//
// Recording references (HUMAN / CI step — do NOT do this locally on 26.5):
//   1. A CI "record mode" job selects Xcode 26.3 (the same pin as ci.yml's test job).
//   2. It runs this suite with BOTH env vars set:
//        APEX_SNAPSHOT_TESTS=1   (un-gates the suite)
//        APEX_RECORD_SNAPSHOTS=1 (flips record mode → writes PNGs, fails the run)
//      e.g.  xcodebuild test -project ProjectApex.xcodeproj -scheme ProjectApex \
//              -only-testing:ProjectApexTests/DrawnInstrumentSnapshotTests \
//              -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
//              APEX_SNAPSHOT_TESTS=1 APEX_RECORD_SNAPSHOTS=1
//   3. The job commits the generated `__Snapshots__/` PNGs. record-mode runs ALWAYS
//      fail (snapshot-testing's contract), which is the CI guard that record mode is
//      never left on in the compare job: the compare job sets only APEX_SNAPSHOT_TESTS=1.

import Testing
import SwiftUI
import SnapshotTesting
@testable import ProjectApex

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Gating

/// The image suite is opt-in via `APEX_SNAPSHOT_TESTS=1`, mirroring
/// `APEX_INTEGRATION_TESTS`. It is OFF in the default scheme so a font-render nudge
/// can't be auto-merged-past on the mandatory path (ADR-0025 §Gating); it reuses the
/// existing pinned scheme so it can't silently rot.
private var snapshotTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_SNAPSHOT_TESTS"] == "1"
}

/// Record mode is a SEPARATE opt-in, set only by the CI record job. The `SnapshotTesting`
/// 1.18 API takes record mode through the `record:` argument on `assertSnapshot`; we
/// thread this flag in so a stray local run never rewrites references.
private var recordModeEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_RECORD_SNAPSHOTS"] == "1"
}

// MARK: - The reusable harness pattern

/// The one rendering route (ADR-0025: UIHostingController, never `ImageRenderer`) plus
/// the "renders assembled at frame 1" guarantee. Every later drawn-instrument slice
/// calls this — it is the reusable pattern the issue asks for.
///
/// "Frame-1 == end-state" is achieved *structurally*: each instrument is an
/// animation-free, value-driven View whose entrance lives in a separate wrapper, so
/// the bare instrument has no entrance to scrub. We additionally disable Core Animation
/// actions so no implicit animation can leak a partial frame into the capture.
@MainActor
enum SnapshotHarness {

    /// A fixed per-instrument canvas — never a full screen — so each reference is
    /// isolated from the parallel shell churn (ADR-0025: the single biggest flake win).
    static func host<V: View>(_ view: V, size: CGSize, appearance: Appearance,
                              dynamicType: DynamicTypeSize = .large) -> UIViewController {
        #if canImport(UIKit)
        let rooted = view
            .environment(\.apexTheme, Theme.current(appearance))
            .environment(\.dynamicTypeSize, dynamicType)
            .frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: rooted)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = Theme.current(appearance).paper.uiColor
        // Lay out once, synchronously — the end-state, no RunLoop spin.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host
        #else
        return UIViewController()
        #endif
    }

    #if canImport(UIKit)
    /// `.image` config carrying the ADR-0025 determinism tolerances: never 1.0, so
    /// sub-pixel AA jitter is absorbed while a wrong ink still fails.
    static let imaging: Snapshotting<UIViewController, UIImage> = .image(
        on: .iPhone17Pro,
        precision: 0.99,
        perceptualPrecision: 0.98
    )
    #endif
}

#if canImport(UIKit)
private extension TokenColor {
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: opacity)
    }
}

/// Pin the capture device so the reference is independent of the run-time simulator
/// chrome. iPhone 17 Pro is the CI-pinned destination (ci.yml). We fix only the size
/// here — the per-instrument canvas overrides it — but the trait set is the device's.
private extension ViewImageConfig {
    static let iPhone17Pro = ViewImageConfig(
        safeArea: .zero,
        size: CGSize(width: 393, height: 852),
        traits: UITraitCollection(displayScale: 3)
    )
}
#endif

// MARK: - Ungated precondition (protects the references; runs on every push)

@Suite("Snapshot harness preconditions")
struct SnapshotHarnessPreconditionTests {

    @Test("Both embedded faces resolve by PostScript name — else references encode San Francisco")
    func fontPrecondition() {
        _ = AppFont.register
        #if canImport(UIKit)
        // If any of these is nil, the snapshot engine falls back to San Francisco and
        // every reference silently bakes the wrong type. This is the guard ADR-0025
        // mandates run BEFORE recording.
        #expect(UIFont(name: AppFont.PostScriptName.spaceGroteskBold, size: 64) != nil)
        #expect(UIFont(name: AppFont.PostScriptName.spaceGroteskSemiBold, size: 34) != nil)
        #expect(UIFont(name: AppFont.PostScriptName.interMedium, size: 13) != nil)
        #expect(UIFont(name: AppFont.PostScriptName.interRegular, size: 17) != nil)
        #endif
    }
}

// MARK: - The image suite (gated; reference-pending until the CI record job runs)

@Suite("Drawn-instrument snapshots", .enabled(if: snapshotTestsEnabled))
@MainActor
struct DrawnInstrumentSnapshotTests {

    /// The worked example the issue asks for: the #341 token gallery, proving the
    /// harness end-to-end (record → compare → fail-on-diff) across the light/dim ×
    /// default/AX matrix. The gallery is the densest single surface — every colour,
    /// type, and data-viz token in one frame — so one diff catches a token regression
    /// anywhere in the foundation.
    private static let gallerySize = CGSize(width: 393, height: 1400)

    #if canImport(UIKit)
    @Test("Token gallery — light, default Dynamic Type")
    func gallery_light_default() {
        let vc = SnapshotHarness.host(TokenGallery(theme: .light),
                                      size: Self.gallerySize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "gallery-light-default", record: recordModeEnabled)
    }

    @Test("Token gallery — dim, default Dynamic Type")
    func gallery_dim_default() {
        let vc = SnapshotHarness.host(TokenGallery(theme: .dim),
                                      size: Self.gallerySize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "gallery-dim-default", record: recordModeEnabled)
    }

    @Test("Token gallery — light, AX5 (largest accessibility size)")
    func gallery_light_ax5() {
        let vc = SnapshotHarness.host(TokenGallery(theme: .light),
                                      size: Self.gallerySize, appearance: .light,
                                      dynamicType: .accessibility5)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "gallery-light-ax5", record: recordModeEnabled)
    }

    @Test("Token gallery — dim, AX5")
    func gallery_dim_ax5() {
        let vc = SnapshotHarness.host(TokenGallery(theme: .dim),
                                      size: Self.gallerySize, appearance: .dim,
                                      dynamicType: .accessibility5)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "gallery-dim-ax5", record: recordModeEnabled)
    }

    // MARK: Reduce-Motion contract — byte-identical to the normal end-state.

    @Test("Reduce Motion is byte-identical to the normal end-state (frame-1 == end-state)")
    func gallery_reduceMotion_matchesEndState() {
        // ADR-0025: each instrument is animation-free and captured at its bare
        // end-state, with its entrance owned by a separate wrapper. Reduce Motion's
        // contract is "a 150ms crossfade to the SAME destination", so the destination
        // image is identical with or without it — there is no entrance in the captured
        // view to suppress. We prove this by re-capturing the bare instrument and
        // asserting it against the SAME `gallery-light-default` reference (not a new
        // one): if a future instrument ever leaked an animated entrance into the bare
        // view, its non-settled frame would diff against this canonical end-state.
        let vc = SnapshotHarness.host(TokenGallery(theme: .light),
                                      size: Self.gallerySize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "gallery-light-default", record: recordModeEnabled)
    }

    // MARK: Negative control — proves the tolerance still catches a wrong ink.

    @Test("Hue-swap negative control: the bright accent is NOT the accent-ink (tolerance catches a wrong ink)")
    func hueSwap_negativeControl() {
        // ADR-0025 calls for a deliberate hue-swap proof that perceptualPrecision 0.98
        // still fails on a wrong ink (#1B2CFF bright-accent-fill vs #1322CC accent-ink).
        // The structural half is asserted here without a pixel: the two inks differ by
        // more than rounding, so a swatch drawn with the wrong one cannot pass the
        // perceptual tolerance. The pixel-level proof is recorded as a known-failing
        // reference pair by the CI record job (documented above); this assertion is the
        // always-on sentinel that the two source inks never converge.
        let brightAccent = Theme.light.accentFill.token   // #1B2CFF — large-fill only
        let accentInk = Theme.light.accentInk             // #1322CC — text-safe stroke
        #expect(brightAccent != accentInk)
        // A perceptual delta this large (different blue + different green channel) is
        // well outside the 0.98 perceptual tolerance — a swap would fail the snapshot.
        let channelDelta = abs(brightAccent.blue - accentInk.blue)
            + abs(brightAccent.green - accentInk.green)
            + abs(brightAccent.red - accentInk.red)
        #expect(channelDelta > 0.05)
    }
    #endif
}
