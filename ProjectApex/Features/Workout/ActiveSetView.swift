// Features/Workout/ActiveSetView.swift
// ProjectApex — P3-T04 / P4-T06
//
// Full-screen active set screen rendered during SessionState.active.
//
// Acceptance criteria (P3-T04):
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
// Acceptance criteria (P4-T06):
//   ✓ Mic button labelled "Coach, note this" always visible
//   ✓ Permission denied → "Enable Microphone" text link replaces mic button
//   ✓ Tap opens modal: large mic animation, live transcript text updates in real time
//   ✓ Auto-stop after 4s silence; tap again to stop early
//   ✓ Transcript appended to WorkoutContext.qualitativeNotesToday (via WorkoutViewModel)
//   ✓ MemoryService.embed() called non-blocking after transcript confirmed
//   ✓ Transcript shown in PostWorkoutSummaryView via session notes
//
// DEPENDS ON: P3-T02 (WorkoutViewModel, WorkoutSessionManager), P4-T03 (SpeechService)

import SwiftUI
import UIKit

// MARK: - ActiveSetView

struct ActiveSetView: View {

    @Bindable var viewModel: WorkoutViewModel
    let exercise: PlannedExercise
    let setNumber: Int
    let streak: StreakResult
    /// Injected SpeechService for live voice notes (P4-T06).
    let speechService: SpeechService
    /// Injected ExerciseSwapService for mid-session swap chat (P3-T10).
    let exerciseSwapService: ExerciseSwapService

    // MARK: - Local UI state

    /// ViewModel driving the exercise swap chat sheet (P3-T10).
    @State private var swapViewModel: ExerciseSwapViewModel?

    /// True after "Set Complete" tap — shows rep/RPE confirmation sheet
    @State private var showRepConfirmation: Bool = false

    /// Reps / RPE / intent state for the active rep-confirmation sheet.
    /// Initialised on sheet appearance from the live prescription. Slice 6
    /// (#10) replaced the previous individual @State fields and the
    /// 5-second auto-dismiss timer with this unit-testable struct so the
    /// "Save disabled until explicit intent tap" AC is observable.
    @State private var formState: SetCompletionFormState = SetCompletionFormState(actualReps: 8)

    /// Controls the collapsible reasoning section
    @State private var reasoningExpanded: Bool = false

    /// Controls the voice note modal
    @State private var showVoiceNoteModal: Bool = false

    /// Controls the weight correction sheet (P1-T11 — "Weight not available")
    @State private var showWeightCorrection: Bool = false

    /// Controls the inline weight override sheet (FB-001 — tapping the weight value)
    @State private var showWeightOverride: Bool = false

    // MARK: - Voice note state (P4-T06)

    /// Whether microphone permission has been denied.
    @State private var micPermissionDenied: Bool = false
    /// Whether SpeechService is currently listening.
    @State private var isRecording: Bool = false
    /// Live partial transcript shown inside the modal.
    @State private var liveTranscript: String = ""
    /// Task managing the recording stream lifecycle.
    @State private var recordingTask: Task<Void, Never>?

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
        // Inline weight override sheet — tapping the weight value (FB-001)
        .sheet(isPresented: $showWeightOverride) {
            weightOverrideSheet
                .presentationDetents([.medium])
                .presentationCornerRadius(24)
        }
        // Weight correction sheet (P1-T11 — "Weight not available")
        .sheet(isPresented: $showWeightCorrection) {
            weightCorrectionSheet
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(24)
        }
        // Exercise swap chat sheet (P3-T10)
        .sheet(isPresented: $viewModel.showExerciseSwapSheet, onDismiss: {
            swapViewModel = nil
        }) {
            if let vm = swapViewModel {
                ExerciseSwapView(viewModel: vm)
            }
        }
        .onChange(of: viewModel.showExerciseSwapSheet) { _, isShowing in
            guard isShowing else { return }
            let vm = ExerciseSwapViewModel(service: exerciseSwapService)
            vm.onConfirmSwap = { suggestion, reason in
                viewModel.onExerciseSwapConfirmed(suggestion: suggestion, reason: reason)
            }
            vm.onDismiss = {
                viewModel.showExerciseSwapSheet = false
            }
            swapViewModel = vm
            Task {
                if let context = await viewModel.buildSwapContext() {
                    await vm.startConversation(context: context)
                }
            }
        }
        // End session early confirmation (P3-T09)
        // Two variants: zero-sets → discard; with-sets → partial save.
        .alert("No Sets Logged", isPresented: Binding(
            get: { viewModel.showEndSessionEarlyConfirmation && !viewModel.hasLoggedAnySets },
            set: { if !$0 { viewModel.showEndSessionEarlyConfirmation = false } }
        )) {
            Button("Exit Without Saving", role: .destructive) {
                viewModel.showEndSessionEarlyConfirmation = false
                viewModel.resetSession()
            }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("No sets logged — this session will not be saved. Exit anyway?")
        }
        .alert("End Workout Early?", isPresented: Binding(
            get: { viewModel.showEndSessionEarlyConfirmation && viewModel.hasLoggedAnySets },
            set: { if !$0 { viewModel.showEndSessionEarlyConfirmation = false } }
        )) {
            Button("End Workout", role: .destructive) {
                viewModel.onEndSessionEarly()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your progress so far will be saved. You can review your partial session summary.")
        }
    }

    // MARK: - Session Header (ghost)

    private var sessionHeader: some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(exercise.name.uppercased()) · SET \(setNumber) OF \(exercise.sets)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .tracking(0.8)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button {
                        viewModel.requestExerciseSwap()
                    } label: {
                        Label("Swap Exercise", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        viewModel.onPauseSession()
                    } label: {
                        Label("Pause Session", systemImage: "pause.circle")
                    }
                    Button(role: .destructive) {
                        viewModel.requestEndSessionEarly()
                    } label: {
                        Label("End Workout Early", systemImage: "xmark.circle")
                    }
                    .disabled(!viewModel.hasLoggedAnySets)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            if !viewModel.hasLoggedAnySets {
                Text("Complete at least one set to end the session")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
                if prescription.weightKg == 0 {
                    // Bodyweight exercise — show non-interactive "BW" label
                    Text("BW")
                        .font(.system(size: 72, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .accessibilityLabel("Bodyweight exercise")
                } else {
                    // Tappable weight value — opens inline override sheet (FB-001)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showWeightOverride = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(weightString(prescription.weightKg))
                                .font(.system(size: 72, weight: .black, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                                .id("weight_\(prescription.weightKg)")
                                .underline(true, color: .white.opacity(0.28))
                            Text("kg")
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .baselineOffset(6)
                            Image(systemName: "pencil")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                                .baselineOffset(8)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Adjust weight: \(weightString(prescription.weightKg)) kilograms")
                    .accessibilityHint("Double tap to change the weight")
                }

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

            // "Adjusted" badge — shown after user overrides weight (FB-001)
            if prescription.userCorrectedWeight == true {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Adjusted")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundStyle(Color(red: 0.40, green: 0.85, blue: 0.60))
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }

            // "Using last session weights" badge — AI was unavailable, user chose manual fallback
            if prescription.isManualFallback == true {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Using last session weights")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundStyle(Color(red: 1.0, green: 0.65, blue: 0.0))
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }

            // Adjusted weight annotation (equipment snap note from AI)
            if let adjustedNote = viewModel.weightAdjustmentNote {
                Text(adjustedNote)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(streak.tintColor.opacity(0.80))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }

            // "My gym doesn't have this weight" button — hidden for bodyweight exercises
            if prescription.weightKg != 0 {
                Button {
                    showWeightCorrection = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "scalemass")
                            .font(.system(size: 10, weight: .medium))
                        Text("My gym doesn't have this weight")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, viewModel.gymWeightHintText != nil ? 4 : 8)

                // Available weight range hint — shown when GymFactStore has corrections for this equipment
                if let hint = viewModel.gymWeightHintText {
                    Text(hint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
            }

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
            // Load gym weight hint on first appearance
            viewModel.refreshGymWeightHint(
                equipmentType: exercise.equipmentRequired,
                near: prescription.weightKg
            )
        }
        .onChange(of: prescription.weightKg) { _, newWeight in
            // Refresh hint when weight changes (e.g. after a correction)
            viewModel.refreshGymWeightHint(equipmentType: exercise.equipmentRequired, near: newWeight)
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

    // MARK: - Voice Note Button (P4-T06)

    @ViewBuilder
    private var voiceNoteButton: some View {
        if micPermissionDenied {
            // Permission denied state: text link to open Settings
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Enable Microphone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
            }
            .accessibilityLabel("Enable Microphone")
            .accessibilityHint("Opens Settings to grant microphone permission")
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showVoiceNoteModal = true
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.08))
                            .frame(width: 56, height: 56)
                            .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text("Coach, note this")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.40))
                        .tracking(0.3)
                }
            }
            .accessibilityLabel("Coach, note this")
            .accessibilityHint("Open speech recording for a training note")
        }
    }

    // MARK: - Rep / RPE / Intent Confirmation Sheet (Slice 6 / #10)

    private var repRPEConfirmationSheet: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header — no auto-dismiss countdown per Slice 6 AC.
                HStack {
                    Text("How did that feel?")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
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
                            if formState.actualReps > 1 { formState.actualReps -= 1 }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(minWidth: 44, minHeight: 44)

                        Text("\(formState.actualReps)")
                            .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .frame(minWidth: 72)

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if formState.actualReps < 30 { formState.actualReps += 1 }
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

                    Picker("RPE felt", selection: $formState.rpeFelt) {
                        Text("Too Easy").tag(0)
                        Text("On Target").tag(1)
                        Text("Too Hard").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                // Intent picker (Slice 6 / #10) — required, no silent default.
                intentPickerSection

                // Log button — disabled until intent is explicitly selected.
                Button {
                    commitSetComplete()
                } label: {
                    Text("Log Set")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            (formState.canSubmit
                                ? streak.tintColor
                                : Color.white.opacity(0.10)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .disabled(!formState.canSubmit)
                .accessibilityHint(formState.canSubmit
                                   ? "Log this set"
                                   : "Pick an intent to enable logging")
                .animation(.easeInOut(duration: 0.18), value: formState.canSubmit)
            }
            .padding(24)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
        .onAppear {
            // Initialise form state from the live prescription. Intent
            // pre-fills from prescription.intent when present (AI-prescribed
            // sets) and stays nil for freestyle. `intentTouched` starts
            // false in both cases — Slice 6 AC: even a matching prefill
            // requires explicit interaction.
            formState = SetCompletionFormState(
                actualReps: viewModel.currentPrescription?.reps ?? formState.actualReps,
                prescribedIntent: viewModel.currentPrescription?.intent
            )
        }
    }

    // MARK: - Intent Picker (Slice 6 / #10)

    @ViewBuilder
    private var intentPickerSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("What kind of set?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                    .tracking(0.5)
                if formState.hasUnconfirmedAIPrefill {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(streak.tintColor.opacity(0.90))
                    Text("Coach suggested — tap to confirm")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(streak.tintColor.opacity(0.90))
                }
                Spacer()
            }

            // Two rows: 3 + 2 chips. Centred. Wrapping is deterministic and
            // works across iPhone widths (5 chips × ~80pt > 375pt).
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([SetIntent.warmup, .top, .backoff], id: \.self) { intent in
                        intentChip(intent)
                    }
                }
                HStack(spacing: 8) {
                    ForEach([SetIntent.technique, .amrap], id: \.self) { intent in
                        intentChip(intent)
                    }
                }
            }
        }
    }

    /// Three visual states drive chip rendering, derived from `formState`:
    ///   - **Confirmed**         (`intentTouched && intent == case`): solid
    ///                            tint background, white bold text — the
    ///                            user's explicit choice.
    ///   - **AI-suggested-pending** (`hasUnconfirmedAIPrefill && intent == case`):
    ///                            tint outline + low-opacity tint fill +
    ///                            sparkles icon. Visually distinct from
    ///                            "confirmed" so the user knows a tap is
    ///                            still required (Slice 6 AC).
    ///   - **Unselected**         (everything else): white-on-glass-low.
    @ViewBuilder
    private func intentChip(_ intent: SetIntent) -> some View {
        let isConfirmed = formState.intentTouched && formState.intent == intent
        let isAISuggested = formState.hasUnconfirmedAIPrefill && formState.intent == intent

        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            formState.recordIntentTap(intent)
        } label: {
            HStack(spacing: 4) {
                if isAISuggested {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(intentLabel(intent))
                    .font(.system(size: 13, weight: isConfirmed ? .bold : .semibold))
                    .tracking(0.3)
            }
            .foregroundStyle(
                isConfirmed
                    ? Color.white
                    : (isAISuggested
                        ? streak.tintColor
                        : Color.white.opacity(0.65))
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            isConfirmed
                                ? streak.tintColor
                                : (isAISuggested
                                    ? streak.tintColor.opacity(0.14)
                                    : Color.white.opacity(0.06))
                        )
                    Capsule()
                        .stroke(
                            isConfirmed
                                ? streak.tintColor
                                : (isAISuggested
                                    ? streak.tintColor.opacity(0.55)
                                    : Color.white.opacity(0.18)),
                            lineWidth: isAISuggested ? 1.0 : 0.5
                        )
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(intentLabel(intent))
        .accessibilityValue(isConfirmed
                            ? "selected"
                            : (isAISuggested ? "AI suggested, awaiting confirmation" : ""))
        .accessibilityAddTraits(isConfirmed ? .isSelected : [])
        .animation(.easeInOut(duration: 0.18), value: formState.intent)
        .animation(.easeInOut(duration: 0.18), value: formState.intentTouched)
    }

    private func intentLabel(_ intent: SetIntent) -> String {
        switch intent {
        case .warmup:    return "Warmup"
        case .top:       return "Top"
        case .backoff:   return "Backoff"
        case .technique: return "Technique"
        case .amrap:     return "AMRAP"
        }
    }

    // MARK: - Voice Note Modal (P4-T06)

    private var voiceNoteModal: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Voice Note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if isRecording {
                    // Recording indicator dot
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isRecording)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)

            // Mic animation (liquid wave dots)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(isRecording ? Color.red.opacity(0.85) : streak.tintColor.opacity(0.60))
                        .frame(width: 12, height: 12)
                        .modifier(LiquidWaveModifier(index: i))
                }
            }
            .padding(.vertical, 24)

            // Live transcript text
            ScrollView {
                Text(liveTranscript.isEmpty
                     ? (isRecording ? "Listening…" : "Tap the button below to start recording")
                     : liveTranscript)
                    .font(.system(size: 17, weight: liveTranscript.isEmpty ? .regular : .medium))
                    .foregroundStyle(liveTranscript.isEmpty ? .white.opacity(0.35) : .white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .animation(.easeInOut(duration: 0.2), value: liveTranscript)
            }
            .frame(minHeight: 80, maxHeight: 140)

            Spacer(minLength: 20)

            // Record / Stop button
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Text(isRecording ? "Stop Recording" : "Start Recording")
                        .font(.system(size: 17, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    isRecording
                        ? Color.red.opacity(0.80)
                        : streak.tintColor.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isRecording)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
        .onAppear {
            // Request permission and auto-start recording
            Task { await requestPermissionAndRecord() }
        }
        .onDisappear {
            // If dismissed while recording, stop cleanly
            recordingTask?.cancel()
            recordingTask = nil
            isRecording = false
        }
    }

    // MARK: - Voice Note Actions (P4-T06)

    private func requestPermissionAndRecord() async {
        let status = await speechService.requestSpeechPermissions()
        switch status {
        case .authorized:
            micPermissionDenied = false
            startRecording()
        case .denied, .notDetermined:
            micPermissionDenied = true
            showVoiceNoteModal = false
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        liveTranscript = ""
        isRecording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        recordingTask = Task {
            do {
                let stream = try await speechService.startListening()
                for await partial in stream {
                    if Task.isCancelled { break }
                    liveTranscript = partial
                }
                // Stream finished (silence or stop) — finalise
                await finaliseTranscript()
            } catch {
                isRecording = false
            }
        }
    }

    private func stopRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        Task { await finaliseTranscript() }
    }

    private func finaliseTranscript() async {
        isRecording = false
        // Attempt to get final transcript from stopListening()
        let finalText: String
        do {
            finalText = try await speechService.stopListening()
        } catch {
            // Already stopped (e.g. silence auto-stop fired) — use what we have
            finalText = liveTranscript
        }

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showVoiceNoteModal = false
            return
        }

        liveTranscript = trimmed
        // Brief pause so user can read the final transcript
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Submit to session manager (writes session_notes + appends qualitative context)
        viewModel.onAddVoiceNote(transcript: trimmed, exerciseId: exercise.exerciseId)

        showVoiceNoteModal = false
        liveTranscript = ""
    }

    // MARK: - Weight Override Sheet (FB-001 — tapping the weight value)
    // Session-only: adjusts the weight for this set without writing to GymFactStore.
    // Use "My gym doesn't have this weight" for a permanent equipment inventory correction.

    @ViewBuilder
    private var weightOverrideSheet: some View {
        let weight = viewModel.currentPrescription?.weightKg ?? 0
        WeightOverrideView(
            currentWeight: weight,
            equipmentType: exercise.equipmentRequired,
            onConfirmed: { confirmedWeight in
                viewModel.onWeightOverrideSessionOnly(
                    confirmedWeight: confirmedWeight,
                    equipmentType: exercise.equipmentRequired
                )
            }
        )
    }

    // MARK: - Weight Correction Sheet (P1-T11 — "Weight not available")

    @ViewBuilder
    private var weightCorrectionSheet: some View {
        let weight = viewModel.currentPrescription?.weightKg ?? 0
        WeightCorrectionView(
            prescribedWeight: weight,
            equipmentType: exercise.equipmentRequired,
            onConfirmed: { confirmedWeight in
                // Permanent path — saves to GymFactStore
                viewModel.onWeightCorrection(
                    unavailableWeight: weight,
                    confirmedWeight: confirmedWeight,
                    equipmentType: exercise.equipmentRequired
                )
            },
            onSessionOnly: { confirmedWeight in
                // Session-only path — does NOT save to GymFactStore
                viewModel.onWeightOverrideSessionOnly(
                    confirmedWeight: confirmedWeight,
                    equipmentType: exercise.equipmentRequired
                )
            }
        )
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
        // Sheet's onAppear seeds the formState from the prescription —
        // resetting here would race with that. The sheet is single-shot
        // per Set Complete tap.
        showRepConfirmation = true
    }

    private func commitSetComplete() {
        // Slice 6 AC: this path is only reachable when formState.canSubmit
        // is true (button is disabled otherwise). Defensive guard left in
        // case the path is invoked programmatically in the future.
        guard formState.canSubmit, let chosenIntent = formState.intent else { return }
        showRepConfirmation = false
        // Map 0/1/2 picker to a rough RPE value: too easy = 5, on target = 7, too hard = 9
        let rpeValue: Int = [5, 7, 9][formState.rpeFelt]
        viewModel.onSetComplete(
            actualReps: formState.actualReps,
            rpeFelt: rpeValue,
            intent: chosenIntent
        )
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
        streak: StreakResult.compute(currentStreakDays: 7, longestStreak: 10),
        speechService: SpeechService(),
        exerciseSwapService: ExerciseSwapService(provider: AnthropicProvider(apiKey: ""))
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
        confidence: 0.72,
        intent: .top
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
        streak: StreakResult.compute(currentStreakDays: 2, longestStreak: 7),
        speechService: SpeechService(),
        exerciseSwapService: ExerciseSwapService(provider: AnthropicProvider(apiKey: ""))
    )
    .preferredColorScheme(.dark)
}
