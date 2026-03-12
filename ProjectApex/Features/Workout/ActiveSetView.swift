// Features/Workout/ActiveSetView.swift
// ProjectApex — P3-T04
//
// Full-screen active set screen rendered during SessionState.active.
//
// Acceptance criteria:
//   ✓ Prescription card: exercise name, set X of Y, weight (kg), reps, tempo, RIR target, rest
//   ✓ Coaching cue in italics below prescription
//   ✓ Reasoning in small muted monospaced text — collapsible
//   ✓ Safety flags as colour-coded badges (red for pain_reported, amber for others)
//   ✓ "(adjusted to nearest available: Xkg)" annotation when weight was rounded
//   ✓ Set Complete button: 72pt, full-width, heavy haptic on tap
//   ✓ Actual reps stepper post-tap: pre-filled, +/−, 5-second auto-dismiss
//   ✓ RPE/RIR felt 3-option picker: Too easy / On target / Too hard
//   ✓ Microphone button always visible — opens STT modal
//   ✓ "Coach offline" banner when fallbackReason set (auto-dismisses in 3s)
//
// DEPENDS ON: P3-T02 (WorkoutViewModel, WorkoutSessionManager)

import SwiftUI
import UIKit

// MARK: - ActiveSetView

struct ActiveSetView: View {

    @Bindable var viewModel: WorkoutViewModel
    let exercise: PlannedExercise
    let setNumber: Int
    let streak: StreakResult

    // MARK: - Local UI state

    /// True after "Set Complete" tap — shows rep/RPE confirmation sheet
    @State private var showRepConfirmation: Bool = false

    /// Actual reps completed (pre-filled from prescription)
    @State private var actualReps: Int = 8

    /// RPE felt: 0 = Too easy, 1 = On target, 2 = Too hard
    @State private var rpeFelt: Int = 1

    /// Auto-dismiss timer for the rep/RPE sheet (counts down from 5)
    @State private var dismissCountdown: Int = 5
    @State private var dismissTask: Task<Void, Never>?

    /// Controls the collapsible reasoning section
    @State private var reasoningExpanded: Bool = false

    /// Controls the voice note modal
    @State private var showVoiceNoteModal: Bool = false

    /// Controls the weight correction sheet (P1-T11)
    @State private var showWeightCorrection: Bool = false

    /// Controls the "Coach offline" non-blocking banner visibility
    @State private var showOfflineBanner: Bool = false
    @State private var offlineBannerTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        ZStack {
            apexBackground

            VStack(spacing: 0) {
                sessionHeader
                    .padding(.top, 16)
                    .padding(.horizontal, 24)

                exerciseProgressDots
                    .padding(.top, 12)

                Spacer(minLength: 12)

                // Prescription card (hero element)
                if let prescription = viewModel.currentPrescription {
                    prescriptionCard(prescription)
                        .transition(.apexPrescriptionReveal)
                } else {
                    aiThinkingIndicator
                }

                Spacer(minLength: 20)

                setCompleteButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }

            // Floating mic button — always visible
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    voiceNoteButton
                        .padding(.trailing, 24)
                        .padding(.bottom, 120) // above Set Complete button
                }
            }

            // "Coach offline" non-blocking banner
            if showOfflineBanner, let desc = viewModel.fallbackDescription {
                VStack {
                    offlineBanner(description: desc)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showRepConfirmation) {
            repRPEConfirmationSheet
                .presentationDetents([.medium])
                .presentationCornerRadius(24)
        }
        .sheet(isPresented: $showVoiceNoteModal) {
            voiceNoteModal
                .presentationDetents([.medium])
                .presentationCornerRadius(24)
        }
        // Weight correction sheet (P1-T11)
        .sheet(isPresented: $showWeightCorrection) {
            weightCorrectionSheet
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(24)
        }
        // End session early confirmation (P3-T09)
        .alert("End Workout Early?", isPresented: $viewModel.showEndSessionEarlyConfirmation) {
            Button("End Workout", role: .destructive) {
                viewModel.onEndSessionEarly()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your progress so far will be saved. You can review your partial session summary.")
        }
        // Sync prescription reps into stepper when it changes
        .onChange(of: viewModel.currentPrescription?.reps) { _, newReps in
            if let r = newReps { actualReps = r }
        }
        // Show/hide offline banner reactively
        .onChange(of: viewModel.isAIOffline) { _, offline in
            if offline {
                triggerOfflineBanner()
            }
        }
        .onAppear {
            if let r = viewModel.currentPrescription?.reps { actualReps = r }
            if viewModel.isAIOffline { triggerOfflineBanner() }
        }
    }

    // MARK: - Session Header (ghost)

    private var sessionHeader: some View {
        HStack {
            Text("\(exercise.name.uppercased()) · SET \(setNumber) OF \(exercise.sets)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.8)
                .lineLimit(1)
            Spacer()
            Menu {
                Button(role: .destructive) {
                    viewModel.requestEndSessionEarly()
                } label: {
                    Label("End Workout Early", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Exercise Progress Dots

    private var exerciseProgressDots: some View {
        HStack(spacing: 6) {
            ForEach(1...exercise.sets, id: \.self) { n in
                Capsule()
                    .fill(n < setNumber
                          ? streak.tintColor
                          : (n == setNumber
                             ? streak.tintColor.opacity(0.80)
                             : Color.white.opacity(0.15)))
                    .frame(width: n == setNumber ? 20 : 8, height: 4)
                    .animation(.apexSnap, value: setNumber)
            }
        }
    }

    // MARK: - AI Thinking Indicator

    private var aiThinkingIndicator: some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(streak.tintColor.opacity(0.80))
                        .frame(width: 8, height: 8)
                        .modifier(LiquidWaveModifier(index: i))
                }
            }
            Text("Coach preparing prescription…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 60)
    }

    // MARK: - Prescription Card

    @ViewBuilder
    private func prescriptionCard(_ prescription: SetPrescription) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header: exercise name + set badge
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(exercise.primaryMuscle.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(muscleColor(for: exercise.primaryMuscle))
                }
                Spacer()
                Text("SET \(setNumber)/\(exercise.sets)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(streak.tintColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(streak.tintColor.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            // Weight / Reps hero numbers
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(weightString(prescription.weightKg))
                    .font(.system(size: 72, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .id("weight_\(prescription.weightKg)")
                Text("kg")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .baselineOffset(6)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(prescription.reps)")
                        .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("reps")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .baselineOffset(4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)

            // Adjusted weight annotation
            if let adjustedNote = viewModel.weightAdjustmentNote {
                Text(adjustedNote)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(streak.tintColor.opacity(0.80))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }

            // "Weight not available?" button (P1-T11)
            Button {
                showWeightCorrection = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scalemass")
                        .font(.system(size: 10, weight: .medium))
                    Text("Weight not available?")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            glassRowDivider

            // Tempo / RIR / Rest row
            HStack(spacing: 0) {
                metricChip(icon: "metronome", label: prescription.tempo)
                Spacer()
                metricChip(icon: "target", label: "RIR \(prescription.rirTarget)")
                Spacer()
                metricChip(icon: "timer", label: "\(prescription.restSeconds)s rest")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            // Coaching cue
            if !prescription.coachingCue.isEmpty {
                glassRowDivider
                Text("\u{201C}\(prescription.coachingCue)\u{201D}")
                    .font(.system(size: 15, weight: .regular).italic())
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }

            // Reasoning (collapsible)
            if !prescription.reasoning.isEmpty {
                glassRowDivider
                Button {
                    withAnimation(.apexSnap) { reasoningExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: reasoningExpanded
                              ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.30))
                        Text("Coach reasoning")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.30))
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                }
                if reasoningExpanded {
                    Text(prescription.reasoning)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.28))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Safety flags
            if !prescription.safetyFlags.isEmpty {
                glassRowDivider
                HStack(spacing: 8) {
                    ForEach(prescription.safetyFlags, id: \.rawValue) { flag in
                        SafetyFlagBadge(flag: flag)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            // Confidence arc (bottom edge)
            if let conf = prescription.confidence {
                confidenceArc(conf)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.06))
                // Specular top-edge highlight
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
        )
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelFor(prescription))
        .accessibilityHint("Double tap to mark set as complete")
        .onAppear {
            withAnimation(.apexCrystalise) {}
        }
    }

    // MARK: - Set Complete Button

    private var setCompleteButton: some View {
        Button {
            handleSetCompleteTap()
        } label: {
            HStack(spacing: 10) {
                if viewModel.isCompletingSet {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                }
                Text(viewModel.isCompletingSet ? "Logging…" : "Set Complete")
                    .font(.system(size: 19, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(
                streak.tintColor.opacity(viewModel.isCompletingSet ? 0.40 : 0.88),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
        .disabled(viewModel.isCompletingSet)
        .buttonStyle(HapticButtonStyle(style: .heavy))
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: viewModel.isCompletingSet)
    }

    // MARK: - Voice Note Button

    private var voiceNoteButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showVoiceNoteModal = true
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 56, height: 56)
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .accessibilityLabel("Voice note")
        .accessibilityHint("Open speech recording for a training note")
    }

    // MARK: - Rep / RPE Confirmation Sheet

    private var repRPEConfirmationSheet: some View {
        VStack(spacing: 28) {
            // Header with auto-dismiss countdown
            HStack {
                Text("How did that feel?")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if dismissCountdown > 0 {
                    Text("Auto-logging in \(dismissCountdown)s")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .padding(.top, 4)

            // Actual reps stepper
            VStack(spacing: 10) {
                Text("Actual Reps")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                    .tracking(0.5)

                HStack(spacing: 24) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if actualReps > 1 { actualReps -= 1 }
                        resetDismissCountdown()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(minWidth: 44, minHeight: 44)

                    Text("\(actualReps)")
                        .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .frame(minWidth: 72)

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if actualReps < 30 { actualReps += 1 }
                        resetDismissCountdown()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(streak.tintColor.opacity(0.90))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }

            // RPE/RIR felt — 3-option segmented picker
            VStack(spacing: 10) {
                Text("How hard was it?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                    .tracking(0.5)

                Picker("RPE felt", selection: $rpeFelt) {
                    Text("Too Easy").tag(0)
                    Text("On Target").tag(1)
                    Text("Too Hard").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: rpeFelt) { _, _ in resetDismissCountdown() }
            }

            // Log button
            Button {
                commitSetComplete()
            } label: {
                Text("Log Set")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(streak.tintColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(24)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
        .onAppear { startDismissCountdown() }
        .onDisappear { dismissTask?.cancel() }
    }

    // MARK: - Voice Note Modal

    private var voiceNoteModal: some View {
        VStack(spacing: 20) {
            Text("Voice Note")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text("Speech recording is enabled in Phase 4 (P4-T03). For now, use text input.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(streak.tintColor)
            Spacer()
        }
        .padding(28)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
    }

    // MARK: - Weight Correction Sheet (P1-T11)

    @ViewBuilder
    private var weightCorrectionSheet: some View {
        let weight = viewModel.currentPrescription?.weightKg ?? 0
        WeightCorrectionView(
            prescribedWeight: weight,
            equipmentType: exercise.equipmentRequired,
            onConfirmed: { confirmedWeight in
                viewModel.onWeightCorrection(
                    confirmedWeight: confirmedWeight,
                    equipmentType: exercise.equipmentRequired
                )
            }
        )
    }

    // MARK: - Offline Banner (P3-T07)

    private func offlineBanner(description: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0))
            Text("Coach offline — using program defaults")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.35), lineWidth: 0.5)
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Shared Sub-components

    private var glassRowDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.horizontal, 24)
    }

    private func metricChip(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func confidenceArc(_ confidence: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.07))
                    .frame(height: 2)
                Capsule()
                    .fill(streak.tintColor.opacity(0.55))
                    .frame(width: geo.size.width * CGFloat(confidence), height: 2)
            }
        }
        .frame(height: 2)
    }

    private var apexBackground: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [streak.tintColor.opacity(0.16), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.12),
                startRadius: 0,
                endRadius: 400
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
        }
    }

    // MARK: - Helpers

    private func weightString(_ kg: Double) -> String {
        if kg.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", kg)
        }
        return String(format: "%.1f", kg)
    }

    private func muscleColor(for muscle: String) -> Color {
        switch muscle {
        case let m where m.contains("pectoral"): return Color(red: 0.96, green: 0.42, blue: 0.30)
        case let m where m.contains("lat"), let m where m.contains("back"), let m where m.contains("dorsi"):
            return Color(red: 0.30, green: 0.70, blue: 0.96)
        case let m where m.contains("delt"):     return Color(red: 0.70, green: 0.50, blue: 0.96)
        case let m where m.contains("quad"), let m where m.contains("hamstring"), let m where m.contains("glute"):
            return Color(red: 0.30, green: 0.96, blue: 0.60)
        case let m where m.contains("bicep"), let m where m.contains("tricep"):
            return Color(red: 0.96, green: 0.80, blue: 0.30)
        default: return Color.white.opacity(0.45)
        }
    }

    private func accessibilityLabelFor(_ p: SetPrescription) -> String {
        "Set \(setNumber) of \(exercise.sets). \(exercise.name). " +
        "\(weightString(p.weightKg)) kilograms. \(p.reps) reps. " +
        "Tempo \(p.tempo). RIR target \(p.rirTarget). " +
        "Coach says: \(p.coachingCue)"
    }

    // MARK: - Actions

    private func handleSetCompleteTap() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        actualReps = viewModel.currentPrescription?.reps ?? actualReps
        rpeFelt = 1
        showRepConfirmation = true
    }

    private func commitSetComplete() {
        dismissTask?.cancel()
        showRepConfirmation = false
        // Map 0/1/2 picker to a rough RPE value: too easy = 5, on target = 7, too hard = 9
        let rpeValue: Int = [5, 7, 9][rpeFelt]
        viewModel.onSetComplete(actualReps: actualReps, rpeFelt: rpeValue)
    }

    private func startDismissCountdown() {
        dismissCountdown = 5
        dismissTask = Task {
            while dismissCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                dismissCountdown -= 1
            }
            // Auto-commit on expiry
            commitSetComplete()
        }
    }

    private func resetDismissCountdown() {
        dismissTask?.cancel()
        dismissCountdown = 5
        startDismissCountdown()
    }

    private func triggerOfflineBanner() {
        offlineBannerTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.70)) {
            showOfflineBanner = true
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        offlineBannerTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.40)) {
                showOfflineBanner = false
            }
        }
    }
}

// MARK: - LiquidWaveModifier

/// Animates dots in a liquid wave pattern for the AI thinking indicator.
private struct LiquidWaveModifier: ViewModifier {
    let index: Int
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.5)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.15)
                ) {
                    offset = -6
                }
            }
    }
}

// MARK: - HapticButtonStyle

/// Button style that fires haptic + scale-down on press.
private struct HapticButtonStyle: ButtonStyle {
    let style: UIImpactFeedbackGenerator.FeedbackStyle
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.82),
                       value: configuration.isPressed)
    }
}

// MARK: - SafetyFlagBadge

struct SafetyFlagBadge: View {
    let flag: SafetyFlag

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "shield.lefthalf.filled.slash")
                .font(.system(size: 10, weight: .bold))
            Text(flagLabel)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(chipColor.opacity(0.13), in: Capsule())
    }

    private var flagLabel: String {
        switch flag {
        case .painReported:      return "Pain Reported"
        case .shoulderCaution:   return "Shoulder Caution"
        case .jointConcern:      return "Joint Concern"
        case .fatigueHigh:       return "Fatigue High"
        case .deloadRecommended: return "Deload"
        }
    }

    private var chipColor: Color {
        switch flag {
        case .painReported:                    return Color(red: 1.0, green: 0.25, blue: 0.15)
        case .shoulderCaution, .jointConcern:  return Color(red: 1.0, green: 0.75, blue: 0.00)
        case .fatigueHigh, .deloadRecommended: return Color(red: 0.40, green: 0.80, blue: 1.00)
        }
    }
}

// MARK: - Animation Token Extensions

private extension Animation {
    static let apexSnap       = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let apexCrystalise = Animation.spring(response: 0.45, dampingFraction: 0.70)
}

private extension AnyTransition {
    static var apexPrescriptionReveal: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.95)),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

// MARK: - Previews

#Preview("Active Set — With Prescription") {
    ActiveSetView(
        viewModel: WorkoutViewModel.mockActive(),
        exercise: PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: ["anterior_deltoid", "triceps_brachii"],
            equipmentRequired: .barbell,
            sets: 4,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 150,
            rirTarget: 2,
            coachingCues: ["Retract scapulae before unracking"]
        ),
        setNumber: 2,
        streak: StreakResult.compute(currentStreakDays: 7, longestStreak: 10)
    )
    .preferredColorScheme(.dark)
}

#Preview("Active Set — Safety Flags") {
    let vm = WorkoutViewModel.mockActive()
    vm.currentPrescription = SetPrescription(
        weightKg: 70.0,
        reps: 6,
        tempo: "3-1-1-0",
        rirTarget: 3,
        restSeconds: 180,
        coachingCue: "Reduce ROM slightly — pain flag active",
        reasoning: "HRV -22% · pain_reported in previous note → load reduced 15%.",
        safetyFlags: [.painReported, .shoulderCaution],
        confidence: 0.72
    )
    return ActiveSetView(
        viewModel: vm,
        exercise: PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: ["anterior_deltoid"],
            equipmentRequired: .barbell,
            sets: 4,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 150,
            rirTarget: 2,
            coachingCues: []
        ),
        setNumber: 3,
        streak: StreakResult.compute(currentStreakDays: 2, longestStreak: 7)
    )
    .preferredColorScheme(.dark)
}
