import SwiftUI
import UIKit

/// The brief "exercise complete" moment shown after the last set of an
/// exercise — a volt-lime stamp that slams in, the exercise name in condensed
/// black, and a faint "next up" line so the pause reads as forward motion.
/// Replaces the old grey-checkmark placeholder. The session manager holds this
/// state for ~1.2s while the next exercise's AI prescription loads, then the
/// state machine advances to the rest timer; this view owns only the visuals.
struct ExerciseCompleteView: View {
    let exerciseName: String
    /// Prescribed set count for the just-finished exercise (0 hides the line).
    let setCount: Int
    /// Name of the next exercise, if any — drives the "Next ·" continuity line.
    let nextExerciseName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stamped = false

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [Apex.accent.opacity(0.18), .clear],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0, endRadius: 360
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)

            VStack(spacing: 28) {
                stamp
                caption
            }
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if reduceMotion {
                stamped = true
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                    stamped = true
                }
            }
        }
    }

    // The hero: a sharp-cornered volt-lime badge with a black checkmark that
    // slams in (scale + spring overshoot).
    private var stamp: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .fill(Apex.accent)
                .frame(width: 132, height: 132)
            Image(systemName: "checkmark")
                .font(.system(size: 62, weight: .black))
                .foregroundStyle(Apex.onAccent)
        }
        .scaleEffect(stamped || reduceMotion ? 1.0 : 0.5)
        .opacity(stamped ? 1.0 : 0.0)
    }

    private var caption: some View {
        VStack(spacing: 12) {
            ApexSectionLabel(text: "Exercise complete", color: Apex.accent)
            Text(exerciseName)
                .font(.system(size: 32, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .multilineTextAlignment(.center)
            subline
        }
        .padding(.horizontal, Apex.pad)
        .opacity(stamped ? 1.0 : 0.0)
        .offset(y: stamped || reduceMotion ? 0 : 10)
    }

    @ViewBuilder private var subline: some View {
        HStack(spacing: 8) {
            if setCount > 0 {
                ApexSectionLabel(text: "\(setCount) sets", color: Apex.textFaint)
            }
            if setCount > 0, nextExerciseName != nil {
                Circle().fill(Apex.textFaint).frame(width: 3, height: 3)
            }
            if let next = nextExerciseName {
                ApexSectionLabel(text: "Next · \(next)", color: Apex.textDim)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
