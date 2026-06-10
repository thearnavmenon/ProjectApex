// CalibrationReviewView.swift
// ProjectApex — Features/Workout
//
// #269 S2 / S4: the calibration-review screen the pre-workout calibration
// banner's "Review targets" CTA presents. "Your starting targets are ready" —
// this screen shows the per-pattern floor/stretch projections set at
// calibration review, plus each pattern's progress state.
//
// S4 makes the STRETCH target editable (upward-only). The floor stays
// read-only (it is the immovable level we keep the athlete at). On "Save
// targets" the screen:
//   1. POSTs the raised stretches + acknowledge_calibration_review:true to the
//      `update-trainee-goal` Edge Function (best-effort, mirrors GoalReviewView).
//   2. applies the same upward-only clamp to the local cache and records the
//      local calibration-review ack, so the banner disappears immediately (the
//      EF returns no model, so the cache can't refresh from the round-trip).
//   3. dismisses.
//
// Even with zero edits, Save still acknowledges the review so "review and
// accept as-is" hides the banner durably.

import SwiftUI

struct CalibrationReviewView: View {

    /// Per-pattern floor/stretch projections to display. Passed in from the
    /// calibration-review signal (already sorted by pattern.rawValue).
    let projections: [PatternProjection]
    /// #305 (ADR-0023): patterns that just re-calibrated (capability outgrew
    /// the band). Empty ⇒ first-ever calibration. Drives the celebratory intro
    /// copy + the per-row "Levelled up" badge.
    let recalibratedPatterns: Set<MovementPattern>

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    @State private var isSaving: Bool = false
    /// Live, athlete-editable stretch targets keyed by pattern, seeded from the
    /// injected projections on appear. Upward-only — never drops below the
    /// original stretch.
    @State private var editedStretch: [MovementPattern: Double] = [:]

    /// Increment used by the +/- stretch controls.
    private static let stretchStep: Double = 2.5

    private static let accentPurple = Color(red: 0.58, green: 0.45, blue: 0.95)
    private static let darkChrome = Color(red: 0.04, green: 0.04, blue: 0.06)

    init(projections: [PatternProjection], recalibratedPatterns: Set<MovementPattern> = []) {
        self.projections = projections
        self.recalibratedPatterns = recalibratedPatterns
    }

    /// True iff this presentation is a re-calibration (vs the first calibration).
    private var isRecalibration: Bool { !recalibratedPatterns.isEmpty }

    // MARK: - Pure payload helper (the seam under TDD)

    /// Builds the `update-trainee-goal` payload for a calibration-review Save
    /// (#269 S4). `stretchEdits` includes ONLY patterns whose `editedStretch`
    /// is strictly greater than the original stretch (an unchanged or — never
    /// reachable from the UI — lowered value is omitted; the server applies its
    /// own upward-only clamp regardless). `acknowledgeCalibrationReview` is
    /// ALWAYS true so "review and accept as-is" still hides the banner durably.
    /// Mirrors GoalReviewView.makeGoalPayload's style.
    static func makeCalibrationStretchPayload(
        userId: UUID,
        goal: GoalUpsertBody,
        editedStretch: [MovementPattern: Double],
        original: [PatternProjection],
        now: Date
    ) -> TraineeGoalUpsertPayload {
        let originalStretch = Dictionary(
            original.map { ($0.pattern, $0.stretch) },
            uniquingKeysWith: { first, _ in first }
        )
        let raised: [StretchEditBody] = original.compactMap { projection in
            guard let edited = editedStretch[projection.pattern] else { return nil }
            let base = originalStretch[projection.pattern] ?? projection.stretch
            guard edited > base else { return nil }
            return StretchEditBody(pattern: projection.pattern.rawValue, stretch: edited)
        }
        return TraineeGoalUpsertPayload(
            userId: userId,
            goal: goal,
            acknowledgeTriggeringSessionCount: nil,
            stretchEdits: raised.isEmpty ? nil : raised,
            acknowledgeCalibrationReview: true
        )
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
                        saveButton
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
        .onAppear {
            // Seed the editable stretch state from the injected projections once.
            if editedStretch.isEmpty {
                editedStretch = Dictionary(
                    projections.map { ($0.pattern, $0.stretch) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }
    }

    // MARK: - Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("WHAT THIS MEANS")
            Text(isRecalibration
                ? "You've consistently climbed past some of your targets — so we've raised them. Floor is the level we'll keep you at; stretch is your next milestone. Nudge it up if you want a bigger goal."
                : "Your starting targets are ready. Floor is the level we'll keep you at; stretch is the next milestone to aim for — nudge it up if you want a bigger goal.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
        }
        .calibrationCardChrome()
    }

    // MARK: - Projections (stretch editable)

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
        let current = editedStretch[projection.pattern] ?? projection.stretch
        // Lowering is clamped at the original stretch — never below it.
        let canLower = current - Self.stretchStep >= projection.stretch
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(projection.pattern.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                // #305: a freshly re-calibrated pattern shows a "Levelled up"
                // badge rather than its (just-reset) progress label, so hitting
                // the old target reads as a win, not a demotion to "On track".
                if recalibratedPatterns.contains(projection.pattern) {
                    Text("Levelled up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.accentPurple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Self.accentPurple.opacity(0.14), in: Capsule())
                } else {
                    Text(Self.progressLabel(projection.progress))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.accentPurple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Self.accentPurple.opacity(0.14), in: Capsule())
                }
            }
            Text("Floor: \(Self.formatWeight(projection.floor)) kg")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 12) {
                Text("Stretch: \(Self.formatWeight(current)) kg")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                stretchStepButton(label: "\u{2212}2.5 kg", enabled: canLower) {
                    editedStretch[projection.pattern] = max(projection.stretch, current - Self.stretchStep)
                }
                stretchStepButton(label: "+2.5 kg", enabled: true) {
                    editedStretch[projection.pattern] = current + Self.stretchStep
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func stretchStepButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(enabled ? Self.accentPurple : .white.opacity(0.25))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    (enabled ? Self.accentPurple.opacity(0.14) : Color.white.opacity(0.04)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Save targets

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Text(isSaving ? "Saving\u{2026}" : "Save targets")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Self.accentPurple.opacity(isSaving ? 0.40 : 0.85),
                           in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.20), lineWidth: 0.5)
                )
        }
        .disabled(isSaving)
        .padding(.top, 8)
    }

    // MARK: - Save

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }

        // The current goal carried through unchanged (this screen doesn't edit
        // it). Read it from the cached model; fall back to the placeholder shape
        // if the cache is cold.
        let model = await deps.traineeModelService.read()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let goalState = model?.goal ?? GoalState.placeholder
        let goalBody = GoalUpsertBody(
            statement: goalState.statement,
            focusAreas: goalState.focusAreas.map(\.rawValue).sorted(),
            updatedAt: isoFormatter.string(from: goalState.updatedAt)
        )

        let payload = Self.makeCalibrationStretchPayload(
            userId: deps.resolvedUserId,
            goal: goalBody,
            editedStretch: editedStretch,
            original: projections,
            now: Date()
        )

        // Best-effort server write, mirroring GoalReviewView.save().
        if let encoded = try? JSONEncoder().encode(payload) {
            _ = try? await deps.supabaseClient.invokeFunction(
                "update-trainee-goal",
                body: encoded
            )
        }

        // Local cache update + ack so the banner hides immediately. Apply only
        // the raised stretches (the service mirrors the upward-only clamp).
        let raisedEdits: [MovementPattern: Double] = projections.reduce(into: [:]) { acc, projection in
            if let edited = editedStretch[projection.pattern], edited > projection.stretch {
                acc[projection.pattern] = edited
            }
        }
        try? await deps.traineeModelService.applyStretchEdits(raisedEdits)
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
