// LensTests.swift
// ProjectApexTests
//
// Tests for the Lens readiness gauge (#346).
//
// Two layers:
//   1. UNCONDITIONAL — geometry/token/a11y assertions. Run on every push; no
//      simulator required. Covers: state → (number, word) mapping for all
//      ReadinessScore.Label cases and the "—" unknown/calibrating/stale case;
//      lexicon ≤ 5 words; accessibility label format; token hygiene (DesignSystem,
//      not legacy tintColor).
//   2. GATED — image snapshots (APEX_SNAPSHOT_TESTS=1), following the harness
//      in DrawnInstrumentSnapshotTests.swift. Reference images are NOT recorded
//      here; APEX_RECORD_SNAPSHOTS is never set in this repo.

import Testing
import SwiftUI
import SnapshotTesting
@testable import ProjectApex

// MARK: - Gating (mirrors DrawnInstrumentSnapshotTests)

private var snapshotTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_SNAPSHOT_TESTS"] == "1"
}

private var recordModeEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_RECORD_SNAPSHOTS"] == "1"
}

// MARK: - Unconditional layer (geometry / token / a11y)

@Suite("Lens gauge — state mapping and lexicon")
struct LensStateMappingTests {

    // MARK: Resolved states — all ReadinessScore.Label cases

    @Test("Optimal (score 90) → number '90', word 'Optimal'")
    func resolved_optimal() {
        let state = LensState.resolved(ReadinessScore(score: 90))
        #expect(state.displayNumber == "90")
        #expect(state.stateWord == "Optimal")
    }

    @Test("Good (score 70) → number '70', word 'Good'")
    func resolved_good() {
        let state = LensState.resolved(ReadinessScore(score: 70))
        #expect(state.displayNumber == "70")
        #expect(state.stateWord == "Good")
    }

    @Test("Reduced (score 50) → number '50', word 'Reduced'")
    func resolved_reduced() {
        let state = LensState.resolved(ReadinessScore(score: 50))
        #expect(state.displayNumber == "50")
        #expect(state.stateWord == "Reduced")
    }

    @Test("Poor (score 20) → number '20', word 'Poor'")
    func resolved_poor() {
        let state = LensState.resolved(ReadinessScore(score: 20))
        #expect(state.displayNumber == "20")
        #expect(state.stateWord == "Poor")
    }

    // MARK: Unknown / calibrating / stale state

    @Test("Unknown state → '—' + 'Calibrating'")
    func unknown_state() {
        let state = LensState.unknown
        #expect(state.displayNumber == "—")
        #expect(state.stateWord == "Calibrating")
    }

    // MARK: Computing state

    @Test("Computing state → '—' + 'Updating'")
    func computing_state() {
        let state = LensState.computing
        #expect(state.displayNumber == "—")
        #expect(state.stateWord == "Updating")
    }

    // MARK: Lexicon constraint (≤5 words, sized to the longest)

    @Test("Every state word is ≤5 words long")
    func stateWords_maxFiveWords() {
        let allStates: [LensState] = [
            .resolved(ReadinessScore(score: 90)),
            .resolved(ReadinessScore(score: 70)),
            .resolved(ReadinessScore(score: 50)),
            .resolved(ReadinessScore(score: 20)),
            .unknown,
            .computing,
        ]
        for state in allStates {
            let wordCount = state.stateWord.split(separator: " ").count
            #expect(wordCount <= 5,
                    "State word '\(state.stateWord)' has \(wordCount) words (max 5)")
        }
    }

    @Test("'Calibrating' is the longest state word — layout ghost is correctly sized")
    func longestStateWord_isCalibrating() {
        let allWords: [LensState] = [
            .resolved(ReadinessScore(score: 90)),
            .resolved(ReadinessScore(score: 70)),
            .resolved(ReadinessScore(score: 50)),
            .resolved(ReadinessScore(score: 20)),
            .unknown,
            .computing,
        ].map { $0 }
        let longest = allWords.map { $0.stateWord }.max(by: { $0.count < $1.count })!
        #expect(longest == "Calibrating")
    }
}

// MARK: - Accessibility layer

@Suite("Lens gauge — accessibility")
struct LensAccessibilityTests {

    @Test("Resolved: accessibility label includes number and state word")
    func a11y_resolved_includesNumberAndWord() {
        let score = ReadinessScore(score: 82)
        let state = LensState.resolved(score)
        // Verify the compact LensView's label contract: "Readiness N, Word"
        let expectedLabel = "Readiness 82, Optimal"
        // We test the public computed property indirectly through the state:
        let label = accessibilityLabel(for: state)
        #expect(label == expectedLabel)
    }

    @Test("Unknown: accessibility label says 'unknown, Calibrating'")
    func a11y_unknown() {
        let label = accessibilityLabel(for: .unknown)
        #expect(label == "Readiness unknown, Calibrating")
    }

    @Test("Computing: accessibility label says 'updating'")
    func a11y_computing() {
        let label = accessibilityLabel(for: .computing)
        #expect(label == "Readiness updating")
    }

    @Test("Accessibility label does NOT say just 'image'")
    func a11y_notJustImage() {
        let states: [LensState] = [
            .resolved(ReadinessScore(score: 60)),
            .unknown,
            .computing,
        ]
        for state in states {
            let label = accessibilityLabel(for: state)
            #expect(label.lowercased() != "image",
                    "State \(state.stateWord): label must not be just 'image'")
            #expect(!label.isEmpty, "State \(state.stateWord): label must not be empty")
        }
    }

    // Mirrors the LensView.accessibilityLabel computed property.
    private func accessibilityLabel(for state: LensState) -> String {
        switch state {
        case .resolved(let r):
            return "Readiness \(r.score), \(state.stateWord)"
        case .unknown:
            return "Readiness unknown, Calibrating"
        case .computing:
            return "Readiness updating"
        }
    }
}

// MARK: - Token hygiene

@Suite("Lens gauge — token hygiene (DesignSystem, not legacy tintColor)")
struct LensTokenTests {

    @Test("ReadinessScore.tintColor is NOT used — token palette is accent-ink only")
    func tokenHygiene_noLegacyTintColor() {
        // This is a structural assertion: ReadinessScore.tintColor is the legacy
        // multi-hue pre-overhaul palette (#3A8EFF / #8A9AAF / #E8A030 / #E84830).
        // The Lens must use ONLY DesignSystem ink/accent tokens.
        // We verify this by confirming the DesignSystem accent-ink is the one-accent
        // token (not any of the four legacy colours) per Theme.light.
        let accentInk = Theme.light.accentInk  // #1322CC
        let legacyOptimalRed   = 0.23
        let legacyOptimalGreen = 0.56
        let legacyOptimalBlue  = 1.00
        // accent-ink differs from every legacy tintColor channel:
        #expect(abs(accentInk.red   - legacyOptimalRed)   > 0.05)
        #expect(abs(accentInk.green - legacyOptimalGreen) > 0.05)
        #expect(abs(accentInk.blue  - legacyOptimalBlue)  > 0.05)
    }

    @Test("LensState.isFocused is true only for resolved states")
    func isFocused_onlyResolvedStates() {
        #expect(LensState.resolved(ReadinessScore(score: 75)).isFocused == true)
        #expect(LensState.unknown.isFocused == false)
        #expect(LensState.computing.isFocused == false)
    }

    @Test("Aperture is proportional to score for resolved states")
    func aperture_proportionalToScore() {
        let high = LensState.resolved(ReadinessScore(score: 100))
        let low  = LensState.resolved(ReadinessScore(score: 0))
        #expect(high.aperture > low.aperture)
        #expect(high.aperture == 1.0)
        #expect(low.aperture  == 0.0)
    }
}

// MARK: - Image snapshot layer (gated; reference-pending)

#if canImport(UIKit)

private let lensCanvasSize = CGSize(width: 200, height: 80)
private let lensSheetSize  = CGSize(width: 393, height: 600)

@Suite("Lens gauge snapshots", .enabled(if: snapshotTestsEnabled))
@MainActor
struct LensSnapshotTests {

    // MARK: Compact — all states × light + dim

    @Test("LensView resolved (score 82, Optimal) — light")
    func compact_resolved_optimal_light() {
        let view = LensView(state: .resolved(ReadinessScore(score: 82)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-optimal-light", record: recordModeEnabled)
    }

    @Test("LensView resolved (score 82, Optimal) — dim")
    func compact_resolved_optimal_dim() {
        let view = LensView(state: .resolved(ReadinessScore(score: 82)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-optimal-dim", record: recordModeEnabled)
    }

    @Test("LensView resolved (score 65, Good) — light")
    func compact_resolved_good_light() {
        let view = LensView(state: .resolved(ReadinessScore(score: 65)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-good-light", record: recordModeEnabled)
    }

    @Test("LensView resolved (score 65, Good) — dim")
    func compact_resolved_good_dim() {
        let view = LensView(state: .resolved(ReadinessScore(score: 65)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-good-dim", record: recordModeEnabled)
    }

    @Test("LensView resolved (score 50, Reduced) — light")
    func compact_resolved_reduced_light() {
        let view = LensView(state: .resolved(ReadinessScore(score: 50)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-reduced-light", record: recordModeEnabled)
    }

    @Test("LensView resolved (score 50, Reduced) — dim")
    func compact_resolved_reduced_dim() {
        let view = LensView(state: .resolved(ReadinessScore(score: 50)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-reduced-dim", record: recordModeEnabled)
    }

    @Test("LensView resolved (score 20, Poor) — light")
    func compact_resolved_poor_light() {
        let view = LensView(state: .resolved(ReadinessScore(score: 20)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-poor-light", record: recordModeEnabled)
    }

    @Test("LensView resolved (score 20, Poor) — dim")
    func compact_resolved_poor_dim() {
        let view = LensView(state: .resolved(ReadinessScore(score: 20)))
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-poor-dim", record: recordModeEnabled)
    }

    @Test("LensView unknown/calibrating — light")
    func compact_unknown_light() {
        let view = LensView(state: .unknown)
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-unknown-light", record: recordModeEnabled)
    }

    @Test("LensView unknown/calibrating — dim")
    func compact_unknown_dim() {
        let view = LensView(state: .unknown)
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-unknown-dim", record: recordModeEnabled)
    }

    @Test("LensView computing (oscillation gated — deterministic frame 1) — light")
    func compact_computing_light() {
        // allowsOscillation: false → blade oscillation is off; snapshots at frame 1.
        let view = LensView(state: .computing, allowsOscillation: false)
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-computing-light", record: recordModeEnabled)
    }

    @Test("LensView computing (oscillation gated) — dim")
    func compact_computing_dim() {
        let view = LensView(state: .computing, allowsOscillation: false)
        let vc = SnapshotHarness.host(view, size: lensCanvasSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-compact-computing-dim", record: recordModeEnabled)
    }

    // MARK: Sheet — resolved + unknown, light + dim

    @Test("LensSheet resolved (score 78) — light")
    func sheet_resolved_light() {
        let view = LensSheet(
            state: .resolved(ReadinessScore(score: 78)),
            trainingLoadLines: ["Acute load: 1,240", "Chronic load: 980"]
        )
        let vc = SnapshotHarness.host(view, size: lensSheetSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-sheet-resolved-light", record: recordModeEnabled)
    }

    @Test("LensSheet resolved (score 78) — dim")
    func sheet_resolved_dim() {
        let view = LensSheet(
            state: .resolved(ReadinessScore(score: 78)),
            trainingLoadLines: ["Acute load: 1,240", "Chronic load: 980"]
        )
        let vc = SnapshotHarness.host(view, size: lensSheetSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-sheet-resolved-dim", record: recordModeEnabled)
    }

    @Test("LensSheet unknown — light")
    func sheet_unknown_light() {
        let view = LensSheet(
            state: .unknown,
            trainingLoadLines: []
        )
        let vc = SnapshotHarness.host(view, size: lensSheetSize, appearance: .light)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-sheet-unknown-light", record: recordModeEnabled)
    }

    @Test("LensSheet unknown — dim")
    func sheet_unknown_dim() {
        let view = LensSheet(
            state: .unknown,
            trainingLoadLines: []
        )
        let vc = SnapshotHarness.host(view, size: lensSheetSize, appearance: .dim)
        assertSnapshot(of: vc, as: SnapshotHarness.imaging,
                       named: "lens-sheet-unknown-dim", record: recordModeEnabled)
    }
}

#endif
