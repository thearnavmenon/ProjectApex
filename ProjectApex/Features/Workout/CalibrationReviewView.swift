// CalibrationReviewView.swift
// ProjectApex — Features/Workout
//
// #269 S2: the read-only calibration-review display the pre-workout
// calibration banner's "Review targets" CTA presents. "Your starting targets
// are ready" — this screen shows the per-pattern floor/stretch projections set
// at calibration review, plus each pattern's progress state. Nothing is
// editable here.
//
// On "Got it" it calls the local `acknowledgeCalibrationReview()` (mirrors the
// heavy-reassessment local ack) so the banner disappears immediately, then
// dismisses.

import SwiftUI

struct CalibrationReviewView: View {

    /// Per-pattern floor/stretch projections to display. Passed in from the
    /// calibration-review signal (already sorted by pattern.rawValue).
    let projections: [PatternProjection]

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    @State private var isAcknowledging: Bool = false

    private static let accentPurple = Color(red: 0.58, green: 0.45, blue: 0.95)
    private static let darkChrome = Color(red: 0.04, green: 0.04, blue: 0.06)

    init(projections: [PatternProjection]) {
        self.projections = projections
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Self.darkChrome.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        introCard
                        projectionsCard
                        gotItButton
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Your Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Self.darkChrome, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("WHAT THIS MEANS")
            Text("Your starting targets are ready. Floor is the level we'll keep you at; stretch is the next milestone to aim for.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
        }
        .calibrationCardChrome()
    }

    // MARK: - Projections (read-only)

    private var projectionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("STARTING TARGETS")

            if projections.isEmpty {
                Text("No targets yet — log a few sessions and they'll appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(projections.enumerated()), id: \.element.pattern) { index, projection in
                        projectionRow(projection)
                        if index != projections.count - 1 {
                            Divider().background(Color.white.opacity(0.06))
                        }
                    }
                }
            }
        }
        .calibrationCardChrome()
    }

    private func projectionRow(_ projection: PatternProjection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(projection.pattern.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(Self.progressLabel(projection.progress))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.accentPurple)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Self.accentPurple.opacity(0.14), in: Capsule())
            }
            HStack(spacing: 16) {
                Text("Floor: \(Self.formatWeight(projection.floor)) kg")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                Text("Stretch: \(Self.formatWeight(projection.stretch)) kg")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Got it

    private var gotItButton: some View {
        Button {
            Task { await acknowledge() }
        } label: {
            Text(isAcknowledging ? "Saving\u{2026}" : "Got it")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Self.accentPurple.opacity(isAcknowledging ? 0.40 : 0.85),
                           in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.20), lineWidth: 0.5)
                )
        }
        .disabled(isAcknowledging)
        .padding(.top, 8)
    }

    // MARK: - Acknowledge

    @MainActor
    private func acknowledge() async {
        isAcknowledging = true
        defer { isAcknowledging = false }
        try? await deps.traineeModelService.acknowledgeCalibrationReview()
        dismiss()
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.40))
            .kerning(0.8)
    }

    // MARK: - Display helpers

    /// Maps a ProjectionProgress to its human-facing label.
    private static func progressLabel(_ progress: ProjectionProgress) -> String {
        switch progress {
        case .behind:   return "Behind"
        case .onTrack:  return "On track"
        case .ahead:    return "Ahead"
        case .achieved: return "Achieved"
        }
    }

    /// Renders a weight, dropping a trailing ".0" so whole kilos read cleanly.
    private static func formatWeight(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

// MARK: - Card chrome

private extension View {
    /// The translucent rounded-card surface used across the dark-chrome feature
    /// screens (matches GoalReviewView's `cardChrome`). Named distinctly to avoid
    /// clashing with that file's private extension.
    func calibrationCardChrome() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Preview

#Preview {
    CalibrationReviewView(projections: [
        PatternProjection(pattern: .squat, floor: 100, stretch: 107.5, progress: .onTrack),
        PatternProjection(pattern: .horizontalPush, floor: 80, stretch: 85, progress: .behind),
        PatternProjection(pattern: .hipHinge, floor: 140, stretch: 150, progress: .ahead),
    ])
    .environment(AppDependencies())
}
