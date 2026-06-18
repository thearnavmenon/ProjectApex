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
                Apex.bg.ignoresSafeArea()

                // Main content
                VStack(alignment: .leading, spacing: 24) {

                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This weight isn't available")
                            .font(.system(size: 24, weight: .bold))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.text)
                        Text("Pick the nearest weight your gym has, then choose how to handle it.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Apex.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Prescribed-weight badge
                    HStack(spacing: 8) {
                        ApexSectionLabel(text: "Prescribed", color: Apex.textFaint)
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            let parts = WeightParts(prescribedWeight)
                            ApexNumeral(text: parts.whole, size: 22, weight: .bold)
                            if let frac = parts.frac {
                                ApexNumeral(text: frac, size: 16, weight: .bold, color: Apex.textDim)
                            }
                            Text("kg")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Apex.textFaint)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .apexCard()

                    // Quick-select chips for nearest standard weights
                    if !nearestWeights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ApexSectionLabel(text: "Nearby on your equipment", color: Apex.textFaint)
                            LazyVGrid(
                                columns: [GridItem(.flexible()), GridItem(.flexible())],
                                spacing: 10
                            ) {
                                ForEach(nearestWeights, id: \.self) { weight in
                                    Button {
                                        selectedWeight = weight
                                        customWeightText = ""
                                    } label: {
                                        nearbyChip(weight)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Divider with label
                    HStack {
                        Rectangle().fill(Apex.hairline).frame(height: 1)
                        Text("or enter exact weight")
                            .apexLabel(Apex.textFaint)
                            .fixedSize()
                        Rectangle().fill(Apex.hairline).frame(height: 1)
                    }

                    // Custom weight input for non-standard increments
                    HStack(spacing: 10) {
                        TextField("e.g. 17.5", text: $customWeightText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Apex.text)
                            .tint(Apex.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .apexCard()
                            .onChange(of: customWeightText) { _, _ in
                                selectedWeight = nil
                            }
                        Text("kg")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Apex.textFaint)
                    }

                    Spacer()

                    // Two-path action buttons. Session-only is the prominent,
                    // low-consequence default; the permanent path is the recessive,
                    // amber-flagged action because it edits the gym profile forever
                    // (the two-path design deliberately guards against accidental
                    // permanent corrections — see this file's header).
                    VStack(spacing: 16) {
                        // Session-only path — PRIMARY (filled lime, safe default)
                        VStack(spacing: 5) {
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
                                ApexButton(title: "Just for today", icon: "clock.arrow.circlepath")
                                    .opacity(confirmedWeight == nil ? 0.4 : 1.0)
                            }
                            .buttonStyle(.plain)
                            .disabled(confirmedWeight == nil)

                            Text("Skip it this session only — the coach keeps \(formatWeight(prescribedWeight)) in its toolkit.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Apex.textFaint)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Permanent path — SECONDARY (recessive amber ghost)
                        VStack(spacing: 5) {
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
                                ApexButton(title: "Missing permanently", kind: .ghost, icon: "xmark.bin", tint: Apex.amber)
                                    .opacity(confirmedWeight == nil ? 0.4 : 1.0)
                            }
                            .buttonStyle(.plain)
                            .disabled(confirmedWeight == nil)

                            Text("Updates your gym profile so the coach never prescribes \(formatWeight(prescribedWeight)) on \(equipmentType.displayName) again.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Apex.textFaint)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                            .foregroundStyle(savedPermanently ? Apex.amber : Apex.accent)
                        Text(confirmationMessage)
                            .font(.system(size: 16, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Apex.text)
                    }
                    .padding(32)
                    .transition(.opacity.combined(with: .scale(scale: 0.90)))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Apex.textDim)
                        .opacity(anySaved ? 0 : 1)
                }
            }
            .toolbarBackground(Apex.bg, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Nearby chip

    /// A nearby available weight rendered as a tappable `apexCard` chip. Selected
    /// state shifts the card stroke to the accent (`emphasized`) so the picked
    /// weight stands out, mirroring the prescription card's live treatment.
    @ViewBuilder
    private func nearbyChip(_ weight: Double) -> some View {
        let isSelected = selectedWeight == weight
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                let parts = WeightParts(weight)
                ApexNumeral(text: parts.whole, size: 20, weight: .bold)
                if let frac = parts.frac {
                    ApexNumeral(text: frac, size: 14, weight: .bold, color: Apex.textDim)
                }
                Text("kg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Apex.textFaint)
            }
            Text(weight < prescribedWeight ? "Lighter" : "Heavier")
                .apexLabel(isSelected ? Apex.accent : Apex.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .apexCard(emphasized: isSelected)
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
