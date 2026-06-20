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
            acknowledgeCalibrationReview: true,
            confirmedLimitations: nil
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Apex.bg.ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        introBlock
                        projectionsSection
                        Color.clear.frame(height: 110)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                VStack {
                    Spacer()
                    saveBar
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Apex.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("YOUR TARGETS")
                        .font(.system(size: 12, weight: .semibold))
                        .fontWidth(.condensed)
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .foregroundStyle(Apex.textDim)
                }
            }
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

    private var introBlock: some View {
        Text(isRecalibration
            ? "You've consistently climbed past some of your targets — so we've raised them. Floor is the level we'll keep you at; stretch is your next milestone. Nudge it up if you want a bigger goal."
            : "Where you are now, and where we're headed. Floor is the level we'll keep you at; stretch is the next milestone to aim for — nudge it up if you want a bigger goal.")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Apex.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
    }

    // MARK: - Projections (stretch editable)

    @ViewBuilder
    private var projectionsSection: some View {
        if projections.isEmpty {
            Text("No targets yet — log a few sessions and they'll appear here.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Apex.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .apexCard()
        } else {
            ForEach(projections, id: \.pattern) { projection in
                projectionRow(projection)
            }
        }
    }

    private func projectionRow(_ projection: PatternProjection) -> some View {
        let current = editedStretch[projection.pattern] ?? projection.stretch
        // Lowering is clamped at the original stretch — never below it.
        let canLower = current - Self.stretchStep >= projection.stretch
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(projection.pattern.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)
                // #305: a freshly re-calibrated pattern shows a "Levelled up"
                // badge rather than its (just-reset) progress label, so hitting
                // the old target reads as a win, not a demotion to "On track".
                if recalibratedPatterns.contains(projection.pattern) {
                    levelledUpChip
                }
                Spacer()
                if !recalibratedPatterns.contains(projection.pattern) {
                    Text(Self.progressLabel(projection.progress))
                        .font(.system(size: 11, weight: .semibold))
                        .fontWidth(.condensed)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Apex.textDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .overlay(Capsule().stroke(Apex.hairline, lineWidth: 0.5))
                }
            }

            HStack(spacing: 12) {
                valueBox(label: "Floor", value: projection.floor, editable: false)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Apex.textFaint)
                valueBox(label: "Stretch", value: current, editable: true)
            }

            // Upward-only stretch controls. Lowering is clamped at the original
            // stretch; raising is unbounded.
            HStack(spacing: 10) {
                stretchStepButton(label: "\u{2212}2.5 kg", enabled: canLower) {
                    editedStretch[projection.pattern] = max(projection.stretch, current - Self.stretchStep)
                }
                stretchStepButton(label: "+2.5 kg", enabled: true) {
                    editedStretch[projection.pattern] = current + Self.stretchStep
                }
            }
        }
        .padding(16)
        .apexCard()
    }

    /// "Levelled up" lime chip — filled accent, black label, with an up-right
    /// arrow. Marks a pattern whose floor just ratcheted up (#305).
    private var levelledUpChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .black))
            Text("Levelled up")
                .font(.system(size: 10, weight: .black))
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .foregroundStyle(Apex.onAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Apex.accent))
    }

    /// A floor / stretch value box. The editable (stretch) box carries an
    /// accent outline + pencil glyph; the read-only (floor) box is plain.
    private func valueBox(label: String, value: Double, editable: Bool) -> some View {
        let parts = WeightParts(value)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ApexSectionLabel(text: label, color: editable ? Apex.accent : Apex.textFaint)
                if editable {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Apex.accent)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                ApexNumeral(text: parts.whole, size: 26, weight: .bold, color: Apex.text)
                if let frac = parts.frac {
                    ApexNumeral(text: frac, size: 18, weight: .bold, color: Apex.textDim)
                }
                Text("kg")
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
                    .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                        .stroke(editable ? Apex.accent.opacity(0.4) : Apex.hairline, lineWidth: 1)
                )
        )
    }

    private func stretchStepButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .fontWidth(.condensed)
                .foregroundStyle(enabled ? Apex.accent : Apex.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                        .fill(enabled ? Apex.accent.opacity(0.14) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                        .stroke(enabled ? Apex.accent.opacity(0.4) : Apex.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Save targets

    private var saveBar: some View {
        Button {
            Task { await save() }
        } label: {
            ApexButton(
                title: isSaving ? "Saving\u{2026}" : "Save targets",
                icon: isSaving ? nil : "checkmark"
            )
            .opacity(isSaving ? 0.45 : 1.0)
        }
        .disabled(isSaving)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .background(
            LinearGradient(
                colors: [Apex.bg.opacity(0), Apex.bg],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
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

        // #369 slice 6: send the owned server write only under a resolved real
        // owner; the placeholder would be rejected by the EF's ownership check.
        // The local cache update + ack below still run regardless.
        if let userId = await deps.resolvedOwnerUserId() {
            let payload = Self.makeCalibrationStretchPayload(
                userId: userId,
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
