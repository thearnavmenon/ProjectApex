// Features/Workout/NowTrainingBar.swift
// ProjectApex — #462
//
// A floating "Now Training" pill pinned above the tab bar, replacing the old
// colour-coded tab badge (iOS strips a Text badge's foregroundStyle and renders its
// own red dot, so live vs paused was indistinguishable). The pill carries the
// distinction in THREE redundant channels so it survives colourblindness and Reduce
// Motion: motion (a pulsing dot when live), colour (blue vs amber), and text+icon
// ("Training" + circle vs "Paused — tap to resume" + pause glyph).
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

    private static let liveAccent = Color(red: 0.25, green: 0.72, blue: 1.0)
    private static let pausedAccent = Color(red: 1.0, green: 0.65, blue: 0.0)

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .live, .paused:
            pill
        }
    }

    private var accent: Color {
        state == .live ? Self.liveAccent : Self.pausedAccent
    }

    private var label: String {
        state == .live ? "Training" : "Paused — tap to resume"
    }

    private var pill: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                indicator
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                // A raised dark fill (not the tab bar's chrome) so the pill reads as a
                // distinct floating element rather than part of the tab bar.
                Color(red: 0.13, green: 0.13, blue: 0.16),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(accent.opacity(0.45), lineWidth: 1)
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
        switch state {
        case .live:
            // Motion is the PRIMARY live signal; suppressed under Reduce Motion, where
            // colour + the filled dot + "Training" still carry the state.
            Image(systemName: "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Self.liveAccent)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Self.pausedAccent)
        case .idle:
            EmptyView()
        }
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
        VStack(spacing: 24) {
            NowTrainingBar(state: .live, onTap: {})
            NowTrainingBar(state: .paused, onTap: {})
        }
    }
    .preferredColorScheme(.dark)
}
