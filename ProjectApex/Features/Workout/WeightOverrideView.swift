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
                .padding(.horizontal, Apex.pad)
                .padding(.top, 24)
                .padding(.bottom, 20)

            if !useCustomInput {
                stepperSection
                    .padding(.horizontal, Apex.pad)
                    .padding(.bottom, 20)
            }

            customInputToggle
                .padding(.horizontal, Apex.pad)
                .padding(.bottom, 16)

            if useCustomInput {
                customInputSection
                    .padding(.horizontal, Apex.pad)
                    .padding(.bottom, 20)
            }

            Spacer(minLength: 8)

            confirmButton
                .padding(.horizontal, Apex.pad)
                .padding(.bottom, 32)
        }
        .background(Apex.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Adjust Weight")
                    .font(.system(size: 20, weight: .semibold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)
                ApexSectionLabel(text: "AI suggested \(weightString(currentWeight)) kg", color: Apex.textFaint)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .font(.system(size: 15, weight: .medium))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textDim)
        }
    }

    // MARK: - Stepper Section

    private var stepperSection: some View {
        VStack(spacing: 16) {
            // Large weight display — tabular numeral with de-emphasised fraction.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                let parts = WeightParts(displayWeight)
                ApexNumeral(text: parts.whole, size: 64)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: displayWeight)
                if let frac = parts.frac {
                    ApexNumeral(text: frac, size: 36, color: Apex.textDim)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: displayWeight)
                }
                Text("kg")
                    .font(.system(size: 22, weight: .semibold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textDim)
                    .baselineOffset(4)
                    .padding(.leading, 4)
            }

            // Stepper row
            HStack(spacing: 12) {
                stepperButton(
                    icon: "minus",
                    tint: Apex.text,
                    disabled: nearestIndex <= 0,
                    action: stepDown
                )
                stepperButton(
                    icon: "plus",
                    tint: Apex.accent,
                    disabled: nearestIndex >= increments.count - 1,
                    action: stepUp
                )
            }

            // Show nearest increment hint
            if let hint = incrementHint {
                ApexSectionLabel(text: hint, color: Apex.textFaint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepperButton(icon: String, tint: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(disabled ? Apex.textFaint : tint)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .apexCard()
        }
        .disabled(disabled)
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
                    .fontWidth(.condensed)
            }
            .foregroundStyle(Apex.textDim)
        }
    }

    // MARK: - Custom Input Section

    private var customInputSection: some View {
        HStack(spacing: 10) {
            TextField("e.g. 37.5", text: $customText)
                .keyboardType(.decimalPad)
                .font(Apex.numeral(28, weight: .bold))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .apexCard()
            Text("kg")
                .font(.system(size: 20, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textDim)
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
            ApexButton(title: "Use this weight", kind: canConfirm ? .filled : .ghost, icon: "checkmark")
                .opacity(canConfirm ? 1 : 0.4)
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
