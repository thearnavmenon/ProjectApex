// Features/Workout/WeightOverrideView.swift
// ProjectApex — FB-001
//
// Inline weight override sheet opened when the user taps the weight value
// on the prescription card. Allows the user to adjust the AI-suggested weight
// using a stepper (snapping to DefaultWeightIncrements for the equipment type)
// or keyboard input. Confirming saves the correction to GymFactStore and
// updates the prescription in-place without losing rep/tempo/RIR context.
//
// Acceptance criteria (FB-001):
//   ✓ Opens from a tap on the weight value — same .medium detent as rep/RPE sheet
//   ✓ Current weight pre-filled
//   ✓ +/− stepper snaps to DefaultWeightIncrements values for the equipment type
//   ✓ Keyboard input accepts arbitrary decimal weight
//   ✓ Confirming saves override to GymFactStore and uses corrected weight in set log
//   ✓ Corrected weight passed back as userCorrectedWeight = true in WorkoutContext

import SwiftUI

// MARK: - WeightOverrideView

struct WeightOverrideView: View {

    let currentWeight: Double
    let equipmentType: EquipmentType
    /// Called with the confirmed weight when the user taps "Use This Weight".
    let onConfirmed: (Double) -> Void

    @State private var displayWeight: Double
    @State private var customText: String = ""
    @State private var useCustomInput: Bool = false
    @Environment(\.dismiss) private var dismiss

    init(currentWeight: Double, equipmentType: EquipmentType, onConfirmed: @escaping (Double) -> Void) {
        self.currentWeight = currentWeight
        self.equipmentType = equipmentType
        self.onConfirmed = onConfirmed
        _displayWeight = State(initialValue: currentWeight)
    }

    // MARK: - Computed

    private var increments: [Double] {
        let defaults = DefaultWeightIncrements.defaults(for: equipmentType)
        return defaults.isEmpty ? stride(from: 0.0, through: 200.0, by: 2.5).map { $0 } : defaults
    }

    private var nearestIndex: Int {
        guard !increments.isEmpty else { return 0 }
        let idx = increments.enumerated().min(by: { abs($0.element - displayWeight) < abs($1.element - displayWeight) })?.offset ?? 0
        return idx
    }

    /// The weight that will be applied when confirmed.
    private var confirmedWeight: Double? {
        if useCustomInput {
            return Double(customText.replacingOccurrences(of: ",", with: "."))
        }
        return displayWeight
    }

    private var canConfirm: Bool {
        guard let w = confirmedWeight else { return false }
        return w > 0 && w <= 500
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

            if !useCustomInput {
                stepperSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }

            customInputToggle
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            if useCustomInput {
                customInputSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }

            Spacer(minLength: 8)

            confirmButton
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Adjust Weight")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("AI suggested \(weightString(currentWeight)) kg")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
        }
    }

    // MARK: - Stepper Section

    private var stepperSection: some View {
        VStack(spacing: 16) {
            // Large weight display
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(weightString(displayWeight))
                    .font(.system(size: 64, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: displayWeight)
                Text("kg")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
                    .baselineOffset(4)
            }

            // Stepper row
            HStack(spacing: 32) {
                Button {
                    stepDown()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.60))
                }
                .frame(minWidth: 56, minHeight: 56)
                .disabled(nearestIndex <= 0)

                Button {
                    stepUp()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color(red: 0.40, green: 0.85, blue: 0.60).opacity(nearestIndex >= increments.count - 1 ? 0.30 : 0.90))
                }
                .frame(minWidth: 56, minHeight: 56)
                .disabled(nearestIndex >= increments.count - 1)
            }

            // Show nearest increment hint
            if let hint = incrementHint {
                Text(hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.30))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var incrementHint: String? {
        let step = incrementStep
        guard step > 0 else { return nil }
        if step == step.rounded() {
            return "±\(Int(step)) kg steps"
        }
        return "±\(weightString(step)) kg steps"
    }

    private var incrementStep: Double {
        guard increments.count > 1 else { return 0 }
        let idx = nearestIndex
        if idx < increments.count - 1 {
            return increments[idx + 1] - increments[idx]
        }
        if idx > 0 {
            return increments[idx] - increments[idx - 1]
        }
        return 0
    }

    // MARK: - Custom Input Toggle

    private var customInputToggle: some View {
        Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                useCustomInput.toggle()
                customText = useCustomInput ? weightString(displayWeight) : ""
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: useCustomInput ? "minus.circle" : "keyboard")
                    .font(.system(size: 12, weight: .medium))
                Text(useCustomInput ? "Use stepper instead" : "Enter exact weight")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.38))
        }
    }

    // MARK: - Custom Input Section

    private var customInputSection: some View {
        HStack(spacing: 10) {
            TextField("e.g. 37.5", text: $customText)
                .keyboardType(.decimalPad)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                )
            Text("kg")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - Confirm Button

    private var confirmButton: some View {
        Button {
            guard let weight = confirmedWeight else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onConfirmed(weight)
            dismiss()
        } label: {
            Text("Use This Weight")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    canConfirm
                        ? Color(red: 0.40, green: 0.85, blue: 0.60)
                        : Color.white.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .disabled(!canConfirm)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: canConfirm)
    }

    // MARK: - Stepper Actions

    private func stepDown() {
        let idx = nearestIndex
        guard idx > 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            displayWeight = increments[idx - 1]
        }
    }

    private func stepUp() {
        let idx = nearestIndex
        guard idx < increments.count - 1 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            displayWeight = increments[idx + 1]
        }
    }

    // MARK: - Helpers

    private func weightString(_ kg: Double) -> String {
        if kg.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", kg)
        }
        return String(format: "%.1f", kg)
    }
}

// MARK: - Preview

#Preview {
    WeightOverrideView(
        currentWeight: 82.5,
        equipmentType: .barbell,
        onConfirmed: { weight in
            print("Override confirmed: \(weight)kg")
        }
    )
}
