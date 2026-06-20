// GoalReviewView.swift
// ProjectApex — Features/Workout
//
// P5-D06 Slice F2 (#258): the goal-review screen the heavy-reassessment
// banner's "Review goals" CTA presents. "Your training leveled up" — this
// screen lets the user revise their plain-language goal and focus areas in
// response, showing their current capability numbers as read-only context.
//
// On Save it (1) POSTs the revised goal to the `update-trainee-goal` Edge
// Function carrying the acknowledgment count (so the server appends it to
// model_json.acknowledgedTriggeringSessionCounts), and (2) calls the local
// banner-hide `acknowledgeReassessment` (Slice F1) so the banner disappears
// immediately — the EF returns no model, so the cache can't refresh from the
// round-trip and the local write is what hides the banner.
//
// STANDALONE / presentable: `triggeringSessionCount` defaults to nil so the
// screen previews and opens outside the heavy-reassessment flow. Slice E2
// wires the banner → this screen and passes the real count. This slice does
// NOT touch WorkoutView / PreWorkoutView wiring (E2 owns that).
//
// VISUAL: Brutalist Athletic (#473) — pure-black surfaces, an emphasized goal
// card, lime-on-selected focus chips, tabular ApexNumeral capability values,
// and a lime "Save goal" action. Behaviour/logic/state untouched.

import SwiftUI

struct GoalReviewView: View {

    /// E2 will pass the banner's triggering-session count; default nil keeps
    /// the screen previewable and presentable outside the reassessment flow.
    /// When nil, Save skips the local ack (there is no banner to hide) and the
    /// wire payload omits the acknowledgment key entirely.
    var triggeringSessionCount: Int? = nil

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    @State private var statement: String = ""
    @State private var selectedFocusAreas: Set<MuscleGroup> = []
    @State private var capabilities: [ExerciseProfile] = []
    /// Movement patterns currently re-anchoring after a long absence
    /// (PatternProfile.inTransitionMode), captured once at load. The transition
    /// flag is per-PATTERN; an exercise inherits it via ExerciseLibrary mapping.
    @State private var transitionPatterns: Set<MovementPattern> = []
    @State private var isSaving: Bool = false
    @State private var hasLoaded: Bool = false

    /// Cap the read-only capability list to the strongest few so the screen
    /// stays readable — the model can track dozens of exercises.
    private static let maxCapabilitiesShown = 8

    private var canSave: Bool {
        !isSaving &&
        !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Pure payload helper (the seam under TDD)

    /// Builds the update-trainee-goal payload from the edited goal fields (#258 F2).
    /// focusAreas are emitted as SORTED rawValue strings for deterministic JSONB
    /// (mirrors the Set-sort determinism convention in TraineeModel). The ack count
    /// is threaded straight through — nil when the screen is opened outside the
    /// heavy-reassessment flow, an Int when the banner triggered it.
    static func makeGoalPayload(
        userId: UUID,
        statement: String,
        focusAreas: Set<MuscleGroup>,
        triggeringSessionCount: Int?,
        now: Date
    ) -> TraineeGoalUpsertPayload {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return TraineeGoalUpsertPayload(
            userId: userId,
            goal: GoalUpsertBody(
                statement: statement,
                focusAreas: focusAreas.map(\.rawValue).sorted(),
                updatedAt: isoFormatter.string(from: now)
            ),
            acknowledgeTriggeringSessionCount: triggeringSessionCount,
            stretchEdits: nil,
            acknowledgeCalibrationReview: nil,
            confirmedLimitations: nil
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Apex.bg.ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        goalCard
                        focusAreasSection
                        capabilitiesSection
                        Color.clear.frame(height: 110)
                    }
                    .padding(.horizontal, Apex.pad)
                    .padding(.top, 16)
                }

                saveBar
            }
            .navigationTitle("Review your goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Apex.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Apex.textDim)
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                let model = await deps.traineeModelService.read()
                statement = model?.goal.statement ?? ""
                selectedFocusAreas = Set(model?.goal.focusAreas ?? [])
                capabilities = (model?.exercises.values.sorted { $0.e1rmCurrent > $1.e1rmCurrent } ?? [])
                // Capture which patterns are re-anchoring after a long absence so each
                // capability row can flag a provisional number. inTransitionMode defaults
                // its clock to now, the same "now" save() uses below.
                let patternProfiles = model.map { Array($0.patterns.values) } ?? []
                transitionPatterns = Set(
                    patternProfiles
                        .filter { $0.inTransitionMode() }
                        .map(\.pattern)
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Your goal

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ApexSectionLabel(text: "Your goal", color: Apex.accent)
            Text("Your training leveled up. Revise what you're working toward.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Apex.textDim)

            TextField(
                "What are you training for?",
                text: $statement,
                axis: .vertical
            )
            .lineLimit(3...6)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Apex.text)
            .tint(Apex.accent)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(Apex.hairline, lineWidth: 1)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard(emphasized: true)
    }

    // MARK: - Focus areas

    private var focusAreasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApexSectionLabel(text: "Focus areas", color: Apex.textFaint)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(MuscleGroup.allCases, id: \.self) { area in
                    focusChip(area)
                }
            }
        }
    }

    private func focusChip(_ area: MuscleGroup) -> some View {
        let isSelected = selectedFocusAreas.contains(area)
        return Button {
            if isSelected {
                selectedFocusAreas.remove(area)
            } else {
                selectedFocusAreas.insert(area)
            }
        } label: {
            Text(area.rawValue.capitalized)
                .font(.system(size: 14, weight: .bold))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .tracking(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                        .fill(isSelected ? Apex.accent : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                        .stroke(isSelected ? Color.clear : Apex.hairline, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Apex.onAccent : Apex.text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(area.rawValue.capitalized)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Where you are now (read-only)

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApexSectionLabel(text: "Where you are now", color: Apex.textFaint)
            Text("Current estimated 1RMs — informational, not editable.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Apex.textDim)

            if capabilities.isEmpty {
                Text("No capability estimates yet — log a few sessions and they'll appear here.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textFaint)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .apexCard()
            } else {
                VStack(spacing: 0) {
                    let shown = capabilities.prefix(Self.maxCapabilitiesShown)
                    ForEach(Array(shown.enumerated()), id: \.element.exerciseId) { index, profile in
                        capabilityRow(profile)
                        if index != shown.count - 1 {
                            Rectangle().fill(Apex.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .apexCard()
            }
        }
    }

    private func capabilityRow(_ profile: ExerciseProfile) -> some View {
        // The transition flag is per-PATTERN; map this exercise to its movement
        // pattern via the canonical ExerciseLibrary, then check the captured set.
        let pattern = ExerciseLibrary.lookup(profile.exerciseId)?.movementPattern
        let inTransition = pattern.map { transitionPatterns.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.exerciseId.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Apex.text)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ApexNumeral(text: "\(Int(profile.e1rmCurrent.rounded()))", size: 16, color: Apex.textDim)
                    ApexNumeral(text: " kg", size: 12, color: Apex.textFaint)
                }
            }
            // Re-anchoring after a long absence: the number is provisional, so caption
            // it rather than present the raw estimate without context.
            if inTransition {
                Text("Re-establishing after a break")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Apex.textDim)
            }
        }
        .padding(.vertical, 13)
    }

    // MARK: - Save bar

    private var saveBar: some View {
        Button {
            Task { await save() }
        } label: {
            ApexButton(title: isSaving ? "Saving…" : "Save goal", icon: isSaving ? nil : "checkmark")
                .opacity(canSave ? 1.0 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .animation(.easeInOut(duration: 0.18), value: canSave)
        .padding(.horizontal, Apex.pad)
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

        // Both writes are best-effort, mirroring onboarding's goal hydration.
        // #369 slice 6: send the owned server write only under a resolved real
        // owner (a placeholder would be rejected by the EF). The local banner-hide
        // below still runs regardless.
        if let userId = await deps.resolvedOwnerUserId() {
            let payload = Self.makeGoalPayload(
                userId: userId,
                statement: statement,
                focusAreas: selectedFocusAreas,
                triggeringSessionCount: triggeringSessionCount,
                now: Date()
            )
            if let encoded = try? JSONEncoder().encode(payload) {
                _ = try? await deps.supabaseClient.invokeFunction(
                    "update-trainee-goal",
                    body: encoded
                )
            }
        }

        // Local banner-hide (Slice F1): only when a banner triggered this
        // screen. The local ack is what hides the banner immediately.
        if let triggeringSessionCount {
            try? await deps.traineeModelService.acknowledgeReassessment(
                triggeringSessionCount: triggeringSessionCount
            )
        }

        dismiss()
    }
}

// MARK: - Preview

#Preview {
    GoalReviewView()
        .environment(AppDependencies())
}
