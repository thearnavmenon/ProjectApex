import SwiftUI

// MARK: - Apex Brutalist shared atoms
//
// The reusable building blocks every workout screen draws from, with the
// Brutalist identity baked in (no `Direction` parameter). Ported from the
// approved prototype's `.brutalist` branches.

// MARK: - Numeral

/// A tabular + condensed black-weight numeral — the signature face. Render all
/// hero numbers (weights, reps, timers) through this so they never reflow.
struct ApexNumeral: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .black
    var color: Color = Apex.text

    var body: some View {
        Text(text)
            .font(Apex.numeral(size, weight: weight))
            .fontWidth(.condensed)
            .foregroundStyle(color)
    }
}

// MARK: - Section label

/// Section micro-label: uppercase, tracked, condensed.
struct ApexSectionLabel: View {
    let text: String
    var color: Color = Apex.textDim

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.5)
            .fontWidth(.condensed)
            .foregroundStyle(color)
    }
}

// MARK: - Card background

/// Card container: dark fill, sharp corner, hairline stroke. When `emphasized`,
/// the stroke shifts to the accent so the live/primary card stands out.
struct ApexCardModifier: ViewModifier {
    var emphasized: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .fill(Apex.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(emphasized ? Apex.accent.opacity(0.55) : Apex.hairline,
                            lineWidth: emphasized ? 1.5 : 1)
            }
    }
}

extension View {
    /// Apply the Brutalist card background (dark fill + hairline + sharp corner).
    func apexCard(emphasized: Bool = false) -> some View {
        modifier(ApexCardModifier(emphasized: emphasized))
    }
}

// MARK: - Buttons

/// Primary / ghost action button. Filled defaults to the volt-lime accent with
/// black label — reserve the filled accent for the live/primary action. Ghost
/// is an outlined variant for secondary actions.
struct ApexButton: View {
    enum Kind { case filled, ghost }

    let title: String
    var kind: Kind = .filled
    var icon: String? = nil
    /// Override the accent tint (e.g. `Apex.amber` for a paused action). When
    /// `nil`, the volt-lime accent is used.
    var tint: Color? = nil

    var body: some View {
        let c = tint ?? Apex.accent
        HStack(spacing: 9) {
            if let icon {
                Image(systemName: icon).font(.system(size: 16, weight: .bold))
            }
            Text(title)
                .textCase(.uppercase)
                .tracking(1.1)
                .fontWidth(.condensed)
        }
        .font(.system(size: 17, weight: .bold, design: .default))
        .foregroundStyle(kind == .filled ? Apex.onAccent : c)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 17)
        .background {
            if kind == .filled {
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous).fill(c)
            } else {
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(c.opacity(0.55), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Tag chip

/// A muscle / tag chip: dotted accent + uppercase condensed label in a capsule.
struct ApexTagChip: View {
    let text: String
    /// Override the dot/fill tint; defaults to the volt-lime accent.
    var tint: Color? = nil

    var body: some View {
        let c = tint ?? Apex.accent
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Apex.text.opacity(0.9))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(c.opacity(0.14)))
        .overlay(Capsule().stroke(c.opacity(0.28), lineWidth: 0.5))
    }
}

// MARK: - Metric pill

/// Small metric pill (tempo / RIR / rest): a tabular value over a faint label,
/// on a card background.
struct ApexMetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .default).monospacedDigit())
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
            ApexSectionLabel(text: label, color: Apex.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .apexCard()
    }
}

// MARK: - Progress ring

/// Progress ring used by the timer + readiness gauges. Defaults to the
/// volt-lime accent on a faint track.
struct ApexRing: View {
    var progress: Double
    var lineWidth: CGFloat = 10
    var color: Color = Apex.accent
    var track: Color = Color.white.opacity(0.08)
    var useGradient: Bool = false

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(
                    useGradient
                        ? AnyShapeStyle(AngularGradient(
                            gradient: Gradient(colors: [color.opacity(0.55), color]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)))
                        : AnyShapeStyle(color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Apex Brutalist atoms") {
    ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            ApexSectionLabel(text: "Working weight")

            // Hero numeral with the WeightParts truncation fix.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                let parts = WeightParts(142.5)
                ApexNumeral(text: parts.whole, size: 72)
                if let frac = parts.frac {
                    ApexNumeral(text: frac, size: 40, color: Apex.textDim)
                }
                ApexNumeral(text: " kg", size: 28, color: Apex.textFaint)
            }

            HStack(spacing: 8) {
                ApexTagChip(text: "Chest")
                ApexTagChip(text: "PR", tint: Apex.gold)
                ApexTagChip(text: "Paused", tint: Apex.amber)
            }

            HStack(spacing: 8) {
                ApexMetricPill(label: "Tempo", value: "3-1-1")
                ApexMetricPill(label: "RIR", value: "2")
                ApexMetricPill(label: "Rest", value: "2:30")
            }

            ApexRing(progress: 0.62)
                .frame(width: 80, height: 80)

            VStack(spacing: 12) {
                ApexButton(title: "Start set", icon: "play.fill")
                ApexButton(title: "Skip", kind: .ghost)
            }
        }
        .padding(Apex.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Apex.bg)
    .preferredColorScheme(.dark)
}
#endif
