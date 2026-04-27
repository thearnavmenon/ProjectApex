// Features/Workout/WeightCorrectionView.swift
// ProjectApex
//
// Sheet presented when user taps "My gym doesn't have this weight" on the
// prescription card. Offers two paths:
//
//   • "Missing permanently" — saves to GymFactStore so the AI never prescribes
//     this weight on this equipment type again.
//   • "Just for today" — session-only override, does NOT save to GymFactStore.
//     Use this when the weight is simply not right for this exercise today
//     (e.g. all 10kg dumbbells are in use) rather than genuinely absent from the gym.
//
// The two-path design prevents accidental permanent corrections that would block
// weights across all exercises on the same equipment type forever.

import SwiftUI

// MARK: - WeightCorrectionView

struct WeightCorrectionView: View {

    let prescribedWeight: Double
    let equipmentType: EquipmentType
    /// Called when the user confirms a PERMANENT correction ("my gym never has this").
    /// Saves to GymFactStore — AI will not prescribe this weight again on this equipment type.
    let onConfirmed: (Double) -> Void
    /// Called when the user wants a session-only override ("not available today").
    /// Does NOT save to GymFactStore — AI may prescribe this weight in future sessions.
    let onSessionOnly: (Double) -> Void

    @State private var selectedWeight: Double?
    @State private var customWeightText: String = ""
    @State private var savedPermanently: Bool = false
    @State private var savedSessionOnly: Bool = false
    @Environment(\.dismiss) private var dismiss

    // Show 2 below and 2 above the prescribed weight from standard defaults
    private var nearestWeights: [Double] {
        let defaults = DefaultWeightIncrements.defaults(for: equipmentType)
        let below = defaults.filter { $0 < prescribedWeight }.suffix(2)
        let above = defaults.filter { $0 > prescribedWeight }.prefix(2)
        return Array(below) + Array(above)
    }

    // The confirmed weight: custom text input takes priority over button selection
    private var confirmedWeight: Double? {
        if !customWeightText.isEmpty {
            return Double(customWeightText)
        }
        return selectedWeight
    }

    private var anySaved: Bool { savedPermanently || savedSessionOnly }

    private var confirmationMessage: String {
        guard let confirmed = confirmedWeight else { return "" }
        let confirmedStr = formatWeight(confirmed)
        let prescribedStr = formatWeight(prescribedWeight)
        if savedPermanently {
            return "Got it — we'll never suggest \(prescribedStr) again on \(equipmentType.displayName).\nUsing \(confirmedStr) instead."
        } else {
            return "Using \(confirmedStr) for this session only.\n\(prescribedStr) is still in the AI's toolkit."
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Main content
                VStack(alignment: .leading, spacing: 24) {

                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This weight isn't available")
                            .font(.title2.bold())
                        Text("Pick the nearest weight your gym has, then choose how to handle it.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Quick-select buttons for nearest standard weights
                    if !nearestWeights.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 12
                        ) {
                            ForEach(nearestWeights, id: \.self) { weight in
                                Button {
                                    selectedWeight = weight
                                    customWeightText = ""
                                } label: {
                                    VStack(spacing: 4) {
                                        Text("\(weight.formatted())kg")
                                            .font(.headline)
                                        Text(weight < prescribedWeight
                                             ? "Lighter" : "Heavier")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(
                                        selectedWeight == weight
                                            ? Color.accentColor
                                            : Color(.secondarySystemFill)
                                    )
                                    .foregroundStyle(selectedWeight == weight ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }

                    // Divider with label
                    HStack {
                        Rectangle().fill(.separator).frame(height: 1)
                        Text("or enter exact weight")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Rectangle().fill(.separator).frame(height: 1)
                    }

                    // Custom weight input for non-standard increments
                    HStack {
                        TextField("e.g. 17.5", text: $customWeightText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customWeightText) { _, _ in
                                selectedWeight = nil
                            }
                        Text("kg")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Two-path action buttons
                    VStack(spacing: 10) {
                        // Session-only path (primary — easier to tap, lower consequence)
                        Button {
                            guard let weight = confirmedWeight else { return }
                            onSessionOnly(weight)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                                savedSessionOnly = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_400_000_000)
                                dismiss()
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text("Just for today")
                                    .font(.headline)
                                Text("Skip this weight this session only")
                                    .font(.caption)
                                    .opacity(0.75)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(confirmedWeight == nil)

                        // Permanent path (secondary — requires deliberate choice)
                        Button {
                            guard let weight = confirmedWeight else { return }
                            onConfirmed(weight)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                                savedPermanently = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_600_000_000)
                                dismiss()
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text("Missing permanently — lock it out")
                                    .font(.subheadline.weight(.semibold))
                                Text("AI will never prescribe \(formatWeight(prescribedWeight)) on this equipment again")
                                    .font(.caption)
                                    .opacity(0.70)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.secondary)
                        .disabled(confirmedWeight == nil)
                    }
                }
                .padding(24)
                .opacity(anySaved ? 0.0 : 1.0)
                .animation(.easeOut(duration: 0.20), value: anySaved)

                // Confirmation overlay — fades in after save
                if anySaved {
                    VStack(spacing: 20) {
                        Image(systemName: savedPermanently ? "lock.fill" : "checkmark.circle.fill")
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(savedPermanently ? .orange : .green)
                        Text(confirmationMessage)
                            .font(.system(size: 16, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.primary)
                    }
                    .padding(32)
                    .transition(.opacity.combined(with: .scale(scale: 0.90)))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .opacity(anySaved ? 0 : 1)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fkg", kg)
            : String(format: "%.1fkg", kg)
    }
}

// MARK: - Preview

#Preview {
    WeightCorrectionView(
        prescribedWeight: 42.5,
        equipmentType: .dumbbellSet,
        onConfirmed: { weight in
            print("Permanent correction: \(weight)kg")
        },
        onSessionOnly: { weight in
            print("Session-only override: \(weight)kg")
        }
    )
}
