// Features/Workout/WeightCorrectionView.swift
// ProjectApex
//
// Sheet presented when user taps "Weight not available" on the prescription
// card during an active set. Lets the user select or type the nearest
// available weight, which is then recorded permanently in GymFactStore and
// used to re-prescribe the current set via the AI.

import SwiftUI

// MARK: - WeightCorrectionView

struct WeightCorrectionView: View {

    let prescribedWeight: Double
    let equipmentType: EquipmentType
    let onConfirmed: (Double) -> Void  // Returns the confirmed available weight

    @State private var selectedWeight: Double?
    @State private var customWeightText: String = ""
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("No \(prescribedWeight.formatted())kg available")
                        .font(.title2.bold())
                    Text("Select the nearest weight you can use:")
                        .foregroundStyle(.secondary)
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

                // Confirm button
                Button {
                    guard let weight = confirmedWeight else { return }
                    onConfirmed(weight)
                    dismiss()
                } label: {
                    Text("Update My Prescription")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(confirmedWeight == nil)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    WeightCorrectionView(
        prescribedWeight: 16.0,
        equipmentType: .dumbbellSet,
        onConfirmed: { weight in
            print("Confirmed: \(weight)kg")
        }
    )
}
