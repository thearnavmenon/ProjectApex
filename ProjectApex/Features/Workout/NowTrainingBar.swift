// Features/Workout/NowTrainingBar.swift
// ProjectApex — #462
//
// A floating "Now Training" pill pinned above the tab bar, replacing the old
// colour-coded tab badge (iOS strips a Text badge's foregroundStyle and renders its
// own red dot, so live vs paused was indistinguishable). The pill carries the
// distinction in THREE redundant channels so it survives colourblindness and Reduce
// Motion: motion (a pulsing dot when live), colour (lime vs amber), and text+icon
// ("Training" + circle vs "Workout paused" + pause glyph).
//
// State is a pure function of the ActiveSessionCoordinator's isLive / pausedSessionExists
// (BarState.resolve), so it is unit-testable without rendering. Tapping the pill switches
// to the Workout tab; it does NOT itself resume (the #461 paused screen owns resume).

import SwiftUI

struct NowTrainingBar: View {

    enum BarState: Equatable {
        case live
        case paused
        case idle

        /// Live wins over a (stale) paused sentinel — mirrors the coordinator's
        /// live-over-paused precedence (ActiveSessionCoordinator).
        static func resolve(isLive: Bool, pausedExists: Bool) -> BarState {
            if isLive { return .live }
            if pausedExists { return .paused }
            return .idle
        }
    }

    let state: BarState
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .live, .paused:
            pill
        }
    }

    /// Live uses the volt-lime accent; paused uses amber. (Brutalist design system.)
    private var accent: Color {
        state == .live ? Apex.accent : Apex.amber
    }

    /// Canonical pill copy. Static so it is unit-testable without rendering
    /// (mirrors `BarState.resolve`). #468 — one vocabulary: the paused state reads
    /// "Workout paused" everywhere; the chevron already signals tappable, so the
    /// word "Resume" is reserved for the surface that actually resumes.
    static func label(for state: BarState) -> String {
        state == .live ? "Training" : "Workout paused"
    }
    private var label: String { Self.label(for: state) }

    private var pill: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                indicator
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Apex.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Apex.textDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                // A raised dark surface (not the tab bar's chrome) so the pill reads as
                // a distinct floating element rather than part of the tab bar.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Apex.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accent.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.40), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(state == .live ? "Workout in progress" : "Workout paused")
        .accessibilityHint("Opens your workout")
    }

    @ViewBuilder
    private var indicator: some View {
        // A halo ring around the state glyph (matches the prototype LivePill).
        ZStack {
            Circle()
                .fill(accent.opacity(0.25))
                .frame(width: 22, height: 22)
            switch state {
            case .live:
                // Motion is the PRIMARY live signal; suppressed under Reduce Motion, where
                // colour + the filled dot + "Training" still carry the state. The dot is an
                // SF Symbol (not a plain Circle) so `.symbolEffect(.pulse)` actually animates.
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Apex.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Apex.amber)
            case .idle:
                EmptyView()
            }
        }
    }
}

#Preview {
    ZStack {
        Apex.bg.ignoresSafeArea()
        VStack(spacing: 24) {
            NowTrainingBar(state: .live, onTap: {})
            NowTrainingBar(state: .paused, onTap: {})
        }
    }
    .preferredColorScheme(.dark)
}
