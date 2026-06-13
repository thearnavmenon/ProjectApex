// LensView.swift
// ProjectApex — DesignSystem/Instruments
//
// The Lens: a 6-blade camera-iris readiness gauge (#346 / ADR-0026 Phase 3 UI).
// DORMANT: reusable component, built behind the new 3-tab shell flag.
// Source spec: docs/design/splash-today.md §The Lens, ui-overhaul-spec.md §6.
//
// State-word lexicon (≤5 words, sized to "Calibrating" — the longest):
//   Optimal · Good · Reduced · Poor  (resolved, focused iris)
//   Calibrating                       (unknown / stale / day-one, unfocused + "—")
//   Updating                          (computing, slow oscillation)
//
// Colour law: DesignSystem ink/accent tokens ONLY. ReadinessScore.tintColor is
// the legacy multi-hue palette; it is ignored here (ONE-accent rule).
//
// Motion: gauge-focus = Motion.gaugeFocus (spring 0.5 / 0.7, tiny overshoot).
// Reduce Motion fallback: crossfade (Motion.reduceMotionCrossfade).
// The bare LensView has NO entrance / idle animation — it snapshots assembled
// at frame 1. The computing oscillation is gated by an injected flag so tests
// capture a deterministic frame.

import SwiftUI

// MARK: - LensState

/// The three display states of the Lens gauge.
enum LensState {
    /// Data resolved. Shows the iris focused + a numeric score + a state word.
    case resolved(ReadinessScore)
    /// Data unknown / calibrating / stale. Shows the iris unfocused + "—" + "Calibrating".
    case unknown
    /// Background computation in progress. Shows slow iris blade oscillation + "Updating".
    case computing
}

extension LensState: Equatable {
    static func == (lhs: LensState, rhs: LensState) -> Bool {
        switch (lhs, rhs) {
        case (.resolved(let a), .resolved(let b)): return a.score == b.score
        case (.unknown, .unknown): return true
        case (.computing, .computing): return true
        default: return false
        }
    }
}

extension LensState {
    /// The numeric string rendered beside the gauge.
    var displayNumber: String {
        switch self {
        case .resolved(let r): return "\(r.score)"
        case .unknown, .computing: return "—"
        }
    }

    /// The state word. Lexicon ≤5 words; sized to "Calibrating" (the longest).
    var stateWord: String {
        switch self {
        case .resolved(let r):
            switch r.label {
            case .optimal: return "Optimal"
            case .good:    return "Good"
            case .reduced: return "Reduced"
            case .poor:    return "Poor"
            }
        case .unknown:   return "Calibrating"
        case .computing: return "Updating"
        }
    }

    /// Iris aperture fraction: 0 (fully closed) → 1 (fully open).
    var aperture: Double {
        switch self {
        case .resolved(let r): return Double(r.score) / 100.0
        case .unknown:         return 0.25
        case .computing:       return 0.5
        }
    }

    /// Whether the iris blades are in the focused (sharp-edge) position.
    var isFocused: Bool {
        if case .resolved = self { return true }
        return false
    }
}

// MARK: - IrisBlade

/// A single camera-iris blade: a rotated rounded rectangle that pivots around
/// the iris centre. Six blades placed 60° apart make the aperture.
private struct IrisBlade: Shape {
    var angle: Double       // degrees, animated
    var aperture: Double    // 0…1, animated via blade length

    var animatableData: AnimatablePair<Double, Double> {
        get { .init(angle, aperture) }
        set { angle = newValue.first; aperture = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let bladeWidth  = r * 0.55
        // Blade length shrinks as aperture opens (the hole gets bigger).
        let bladeLength = r * (0.9 - aperture * 0.5)
        let pivot = CGPoint(x: rect.midX, y: rect.midY)

        // Build the blade centred on the pivot, then rotate and offset to the rim.
        var p = Path()
        let cornerRadius: CGFloat = bladeWidth * 0.25
        let bladeBounds = CGRect(
            x: -bladeWidth / 2,
            y: -bladeLength,
            width: bladeWidth,
            height: bladeLength
        )
        p.addRoundedRect(in: bladeBounds,
                         cornerSize: CGSize(width: cornerRadius, height: cornerRadius))

        let rad = angle * .pi / 180
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: pivot.x, y: pivot.y)
        t = t.rotated(by: rad)
        t = t.translatedBy(x: 0, y: -r * 0.38) // offset to the rim edge
        return p.applying(t)
    }
}

// MARK: - IrisView

/// Six blades composited with EvenOdd fill to punch the aperture hole.
struct IrisView: View {
    let state: LensState
    /// When true, allows the computing oscillation animation. Set to false
    /// in tests (and in the bare component) so snapshots capture frame 1.
    var allowsOscillation: Bool = false

    @Environment(\.apexTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rotation offset for the computing oscillation (animated separately).
    @State private var oscillationOffset: Double = 0

    private static let bladeCount = 6

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                irisBlades(size: size)
                // Aperture-hole punch: solid circle matching paper, blended over blades.
                Circle()
                    .fill(theme.paper.color)
                    .frame(width: size * apertureHoleSize, height: size * apertureHoleSize)
                    // Focus ring: accentInk when resolved, hairline when not.
                    .overlay(
                        Circle()
                            .stroke(state.isFocused ? theme.accentInk.color : theme.hairline.color,
                                    lineWidth: state.isFocused ? 2 : 1)
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            guard allowsOscillation, case .computing = state, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                oscillationOffset = 18
            }
        }
    }

    private var apertureHoleSize: Double {
        // Hole diameter as a fraction of the iris diameter.
        let base = 0.22 + state.aperture * 0.38
        return base
    }

    private func irisBlades(size: CGFloat) -> some View {
        let baseRotation = oscillationOffset
        return ZStack {
            ForEach(0..<Self.bladeCount, id: \.self) { i in
                let angle = Double(i) * (360.0 / Double(Self.bladeCount)) + baseRotation
                IrisBlade(angle: angle, aperture: state.aperture)
                    .fill(theme.ink.color.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        // Animation applied structurally (ADR-0025 frame-1 == end-state discipline):
        // the blades animate when state changes but start settled.
        .animation(
            reduceMotion ? Motion.reduceMotionCrossfade : Motion.gaugeFocus,
            value: state
        )
    }
}

// MARK: - LensView (compact)

/// The compact Lens: iris + number + state word, always both present.
/// Size is intrinsic — caller constrains via `.frame`.
struct LensView: View {
    let state: LensState
    /// Allow computing oscillation (set to false in tests).
    var allowsOscillation: Bool = false

    @Environment(\.apexTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: LensState, allowsOscillation: Bool = false) {
        self.state = state
        self.allowsOscillation = allowsOscillation
    }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            IrisView(state: state, allowsOscillation: allowsOscillation)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                // Number — tabular, bold. "—" when not resolved.
                Text(state.displayNumber)
                    .apexFont(.display)
                    .foregroundStyle(theme.ink.color)
                    .monospacedDigit()
                    .animation(reduceMotion ? Motion.reduceMotionCrossfade : Motion.gaugeFocus,
                               value: state.displayNumber)

                // State word — sized to "Calibrating" (the longest) so layout never reflows.
                ZStack(alignment: .leading) {
                    // Invisible sizing ghost = longest possible word.
                    Text("Calibrating")
                        .apexFont(.label)
                        .hidden()
                    Text(state.stateWord)
                        .apexFont(.label)
                        .foregroundStyle(theme.inkMuted.color)
                        .animation(
                            reduceMotion ? Motion.reduceMotionCrossfade : Motion.gaugeFocus,
                            value: state.stateWord
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isStaticText)
    }

    private var accessibilityLabel: String {
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

// MARK: - LensSheet

/// The disclosure sheet: stays small, no deep-view creep.
/// Iris large + number + state word → why grounded in training-load numbers
/// → two-tier "How to read this" / "How it's calculated".
struct LensSheet: View {
    let state: LensState
    /// 1–2 representative training-load numbers for the "why" section.
    /// e.g. ["Acute load: 1,240", "Chronic load: 980"]
    let trainingLoadLines: [String]

    @Environment(\.apexTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    heroSection
                    Divider()
                        .background(theme.hairline.color)
                    whySection
                    Divider()
                        .background(theme.hairline.color)
                    howToReadSection
                    howItsCalculatedSection
                }
                .padding(Spacing.lg)
            }
            .background(theme.paper.color)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .apexFont(.label)
                        .foregroundStyle(theme.accentInk.color)
                }
            }
        }
    }

    // MARK: Sections

    private var heroSection: some View {
        HStack(spacing: Spacing.md) {
            IrisView(state: state)
                .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(state.displayNumber)
                    .apexFont(.heroNum)
                    .foregroundStyle(theme.ink.color)
                    .monospacedDigit()
                // Sized to longest word as in compact view.
                ZStack(alignment: .leading) {
                    Text("Calibrating").apexFont(.title).hidden()
                    Text(state.stateWord)
                        .apexFont(.title)
                        .foregroundStyle(theme.inkMuted.color)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private var heroAccessibilityLabel: String {
        switch state {
        case .resolved(let r): return "Readiness \(r.score), \(state.stateWord)"
        case .unknown:         return "Readiness unknown, Calibrating"
        case .computing:       return "Readiness updating"
        }
    }

    private var whySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Based on your training load — no sleep or HRV data")
                .apexFont(.body)
                .foregroundStyle(theme.inkMuted.color)
            ForEach(trainingLoadLines, id: \.self) { line in
                Text(line)
                    .apexFont(.body)
                    .foregroundStyle(theme.ink.color)
            }
        }
    }

    private var howToReadSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                bulletRow("80–100",  detail: "Optimal — go hard today.")
                bulletRow("60–79",   detail: "Good — train as planned.")
                bulletRow("40–59",   detail: "Reduced — consider scaling volume.")
                bulletRow("0–39",    detail: "Poor — rest or light movement only.")
                bulletRow("—",       detail: "Calibrating — not enough data yet; give it a few sessions.")
            }
            .padding(.top, Spacing.xs)
        } label: {
            Text("How to read this")
                .apexFont(.label)
                .foregroundStyle(theme.ink.color)
        }
        .tint(theme.inkMuted.color)
    }

    private var howItsCalculatedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Readiness is a 0–100 score derived from your recent training load — how hard and how much you have trained in the last 7 days compared to your rolling 28-day average. Higher chronic base with lower recent spike = higher readiness. The model updates after each session.")
                    .apexFont(.body)
                    .foregroundStyle(theme.inkMuted.color)
            }
            .padding(.top, Spacing.xs)
        } label: {
            Text("How it's calculated")
                .apexFont(.label)
                .foregroundStyle(theme.ink.color)
        }
        .tint(theme.inkMuted.color)
    }

    private func bulletRow(_ label: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .apexFont(.label)
                .foregroundStyle(theme.accentInk.color)
                .frame(width: 48, alignment: .trailing)
                .monospacedDigit()
            Text(detail)
                .apexFont(.body)
                .foregroundStyle(theme.inkMuted.color)
        }
    }
}
