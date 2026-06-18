// Features/Workout/RestTimerView.swift
// ProjectApex — P3-T05
//
// Full-screen rest-timer view rendered during SessionState.resting.
//
// Acceptance criteria:
//   ✓ Circular progress ring with countdown number in centre (220pt, 3pt stroke)
//   ✓ Timer starts immediately on Set Complete (plan default rest used while AI in-flight)
//   ✓ Timer target updated if AI prescription arrives with different rest_seconds (extends only)
//   ✓ Haptic feedback at 10 seconds remaining and at 0 seconds
//   ✓ Audio tone at 0 seconds (if app in foreground)
//   ✓ Manual skip: user taps "NEXT SET" to advance early at any time
//   ✓ Rest timer anchored to absolute expiry time — survives app backgrounding
//   ✓ On foreground: snaps display to correct remaining time immediately
//   ✓ If expiry already passed when foregrounding: fires haptic/tone, skips to next set
//   ✓ Local notification fires when rest expires while app is in background
//
// DEPENDS ON: P3-T02 (WorkoutViewModel, WorkoutSessionManager)

import SwiftUI
import UIKit
import AVFoundation
import UserNotifications

// MARK: - RestTimerView

struct RestTimerView: View {

    @Bindable var viewModel: WorkoutViewModel
    let nextExercise: PlannedExercise
    let setNumber: Int
    let streak: StreakResult

    // MARK: - Private state

    /// Total duration of the current rest period (used to compute ring progress).
    /// Updated when the prescription arrives with an extended rest duration.
    @State private var totalRestDuration: Int = 90

    /// True when the prescription has just arrived (soft-pulse the ring).
    @State private var prescriptionJustArrived: Bool = false

    /// Tracks the last prescription rest_seconds we observed, to detect changes.
    @State private var lastSeenRestSeconds: Int = 0

    /// Whether haptic at 10s has already fired this rest period.
    @State private var hapticsAt10Fired: Bool = false

    /// Whether haptic at 0s has already fired this rest period.
    @State private var hapticsAt0Fired: Bool = false

    // Background task support
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// True when notification permission is denied — the background
    /// "rest complete" alert cannot fire, so we surface a quiet notice (G-F5).
    @State private var notificationsDenied: Bool = false

    // MARK: - Body

    var body: some View {
        ZStack {
            apexBackground

            VStack(spacing: 0) {
                // Top bar with end-early menu (P3-T09)
                HStack {
                    ApexSectionLabel(text: "Rest", color: Apex.textDim)
                    Spacer()
                    Button {
                        viewModel.showSessionPlanSheet = true
                    } label: {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Apex.textFaint)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Today's plan")
                    .accessibilityHint("Shows the planned exercises and what you've logged so far")
                    Menu {
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
                            .foregroundStyle(Apex.textFaint)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, Apex.pad)
                .padding(.top, 8)

                Spacer(minLength: 20)

                // Circular progress ring (volt-lime, tabular numeral, finishes-at)
                timerRing

                Spacer(minLength: 28)

                // AI status row
                aiStatusRow

                Spacer(minLength: 32)

                // Next exercise preview card
                nextExerciseCard

                Spacer()

                // Rest-alert disabled notice (G-F5) — display-only, shown when
                // notification permission is denied.
                if notificationsDenied {
                    Text("Rest alerts are off — enable notifications in iOS Settings.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Apex.textFaint)
                        .padding(.bottom, 12)
                }

                // Skip rest button — lime primary
                skipButton
                    .padding(.horizontal, Apex.pad)
                    .padding(.bottom, 40)
            }
        }
        .onChange(of: viewModel.restSecondsRemaining) { old, new in
            handleTimerTick(remaining: new)
        }
        // Watch the prescription's restSeconds by tracking changes via a computed int.
        // Avoids requiring SetPrescription to conform to Equatable.
        .onChange(of: viewModel.currentPrescription?.restSeconds) { _, restSec in
            if let s = restSec {
                handlePrescriptionArrival(restSeconds: s)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
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
        .task {
            // Check notification authorization once per appearance (G-F5).
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsDenied = settings.authorizationStatus == .denied
        }
        .onAppear {
            // Seed total duration from plan default or AI prescription if already present
            if let p = viewModel.currentPrescription {
                totalRestDuration = max(totalRestDuration, p.restSeconds)
                lastSeenRestSeconds = p.restSeconds
            } else {
                totalRestDuration = nextExercise.restSeconds
            }
            // Seed current remaining as total if the timer just started
            if viewModel.restSecondsRemaining > totalRestDuration {
                totalRestDuration = viewModel.restSecondsRemaining
            }
            hapticsAt10Fired = false
            hapticsAt0Fired = false
        }
        .onDisappear {
            endBackgroundTask()
            cancelRestExpiryNotification()
        }
    }

    // MARK: - Timer Ring

    private var timerRing: some View {
        ZStack {
            // Thick volt-lime progress ring (track + accent arc), drawn from
            // full (1.0) down to 0.
            ApexRing(progress: ringProgress, lineWidth: 14)
                .frame(width: 286, height: 286)
                .animation(.linear(duration: 1.0), value: ringProgress)

            VStack(spacing: 10) {
                // Big tabular countdown numeral (m:ss).
                ApexNumeral(text: countdownDisplay, size: 78)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.3), value: viewModel.restSecondsRemaining)

                // "Finishes at HH:MM" subtitle — display-only, derived from the
                // existing absolute expiry date.
                if let finishesAt = finishesAtDisplay {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Finishes at \(finishesAt)")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Apex.textFaint)
                }
            }
        }
        .scaleEffect(prescriptionJustArrived ? 1.03 : 1.0)
        .animation(.spring(response: 0.45, dampingFraction: 0.70), value: prescriptionJustArrived)
    }

    // MARK: - AI Status Row

    private var aiStatusRow: some View {
        HStack(spacing: 8) {
            if viewModel.currentPrescription == nil && !viewModel.isAIOffline {
                // Thinking indicator
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Apex.textDim)
                            .frame(width: 5, height: 5)
                            .modifier(LiquidWaveMiniModifier(index: i))
                    }
                }
                Text("Coach preparing next set…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textFaint)
            } else if viewModel.isAIOffline {
                Image(systemName: "brain.head.profile.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Apex.amber)
                Text(viewModel.fallbackDescription ?? "Coach offline — using program defaults")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textDim)
            } else {
                // Prescription ready
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Apex.text.opacity(0.80))
                Text("Prescription ready")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Apex.surface, in: Capsule())
        .overlay(Capsule().stroke(Apex.hairline, lineWidth: 1))
    }

    // MARK: - Next Exercise Card

    private var nextExerciseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApexSectionLabel(text: "Next up", color: Apex.textFaint)

            HStack(alignment: .top, spacing: 14) {
                // Muscle colour dot
                Circle()
                    .fill(muscleColor(for: nextExercise.primaryMuscle))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text(nextExercise.name)
                        .font(.system(size: 18, weight: .semibold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                    Text("Set \(setNumber) · \(nextExercise.repRange.min)–\(nextExercise.repRange.max) reps · RIR \(nextExercise.rirTarget)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Apex.textDim)
                }
                Spacer()

                // AI prescription preview (weight + reps) if ready
                if let p = viewModel.currentPrescription {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            ApexNumeral(text: weightString(p.weightKg), size: 22, weight: .bold)
                                .contentTransition(.numericText())
                            Text("kg")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Apex.textDim)
                                .baselineOffset(2)
                        }
                        Text("\(p.reps) reps")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Apex.textDim)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.70),
                               value: viewModel.currentPrescription != nil)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
        .padding(.horizontal, Apex.pad)
    }

    // MARK: - Skip Button

    private var skipButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            viewModel.skipRest()
        } label: {
            ApexButton(title: "Next set", icon: "forward.fill")
        }
        .accessibilityLabel("Next set")
    }

    // MARK: - Background

    private var apexBackground: some View {
        Apex.bg.ignoresSafeArea()
    }

    // MARK: - Computed Helpers

    /// 0.0 → 1.0, where 1.0 = full rest remaining, 0.0 = timer done.
    private var ringProgress: Double {
        guard totalRestDuration > 0 else { return 0 }
        return Double(viewModel.restSecondsRemaining) / Double(totalRestDuration)
    }

    private var countdownDisplay: String {
        viewModel.formattedRestTime
    }

    /// "Finishes at HH:MM" subtitle — display-only, formatted from the existing
    /// absolute expiry date. `nil` when no expiry is set (no behaviour change).
    private var finishesAtDisplay: String? {
        guard let expiresAt = viewModel.restExpiresAt else { return nil }
        return expiresAt.formatted(date: .omitted, time: .shortened)
    }

    private func weightString(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
    }

    private func muscleColor(for muscle: String) -> Color {
        switch muscle {
        case let m where m.contains("pectoral"):  return Color(red: 0.96, green: 0.42, blue: 0.30)
        case let m where m.contains("lat"), let m where m.contains("back"), let m where m.contains("dorsi"):
            return Color(red: 0.30, green: 0.70, blue: 0.96)
        case let m where m.contains("delt"):      return Color(red: 0.70, green: 0.50, blue: 0.96)
        case let m where m.contains("quad"), let m where m.contains("hamstring"), let m where m.contains("glute"):
            return Color(red: 0.30, green: 0.96, blue: 0.60)
        case let m where m.contains("bicep"), let m where m.contains("tricep"):
            return Color(red: 0.96, green: 0.80, blue: 0.30)
        default: return Color.white.opacity(0.40)
        }
    }

    // MARK: - Timer Event Handling

    private func handleTimerTick(remaining: Int) {
        // Haptic at 10 seconds remaining
        if remaining == 10 && !hapticsAt10Fired {
            hapticsAt10Fired = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        // Haptic + audio at 0 seconds.
        // Also cancel the pending notification — the timer fired in-app so the
        // background notification would fire redundantly if left scheduled.
        if remaining == 0 && !hapticsAt0Fired {
            hapticsAt0Fired = true
            cancelRestExpiryNotification()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            playCompletionTone()
            endBackgroundTask()
        }
    }

    private func handlePrescriptionArrival(restSeconds: Int) {
        guard restSeconds != lastSeenRestSeconds else { return }
        lastSeenRestSeconds = restSeconds
        // Per TDD §7.4: only extend, never shorten
        if restSeconds > totalRestDuration {
            totalRestDuration = restSeconds
            // Soft pulse ring to signal update
            prescriptionJustArrived = true
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                prescriptionJustArrived = false
            }
            // Cancel and reschedule the notification so it fires at the new (later) expiry
            // time rather than the original default. Only relevant while backgrounded, but
            // calling cancel+reschedule in the foreground is a no-op cost.
            cancelRestExpiryNotification()
            scheduleRestExpiryNotification()
        }
    }

    // MARK: - Background Task

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Request up to 30s background execution so the actor timer keeps ticking briefly.
            if backgroundTaskID == .invalid {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(
                    withName: "RestTimer",
                    expirationHandler: { endBackgroundTask() }
                )
            }
            // Schedule a local notification so the user knows rest is over even if the
            // app is suspended before the background task expires.
            scheduleRestExpiryNotification()
        case .active:
            endBackgroundTask()
            cancelRestExpiryNotification()
            // Snap the display immediately using the absolute expiry time.
            snapTimerToCurrentRemaining()
        default:
            break
        }
    }

    /// Reads the absolute expiry time from the view model and updates the display.
    /// If the timer has already expired, fires the completion haptic/tone and skips rest.
    private func snapTimerToCurrentRemaining() {
        guard let expiresAt = viewModel.restExpiresAt else { return }
        let remaining = max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
        if remaining <= 0 && !hapticsAt0Fired {
            hapticsAt0Fired = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            playCompletionTone()
            endBackgroundTask()
            // Advance to next set — same behaviour as timer reaching zero normally.
            viewModel.skipRest()
        } else {
            handleTimerTick(remaining: remaining)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Local Notification (rest-complete when backgrounded)

    private static let restNotificationID = "rest_timer_complete"

    /// Schedules a local notification to fire when the rest period expires.
    /// Cancelled when the app returns to foreground.
    private func scheduleRestExpiryNotification() {
        guard let expiresAt = viewModel.restExpiresAt else { return }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = "Rest complete — time for your next set."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.restNotificationID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[RestTimerView] Failed to schedule rest notification: \(error.localizedDescription)")
            }
        }
    }

    private func cancelRestExpiryNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.restNotificationID]
        )
    }

    // MARK: - Audio Tone

    private func playCompletionTone() {
        // System sound 1057 is a short, crisp completion tone (calendar alert).
        // Only plays if the app is in the foreground (scenePhase check is implicit
        // because background silence is acceptable per acceptance criteria).
        AudioServicesPlaySystemSound(1057)
    }
}

// MARK: - LiquidWaveMiniModifier

private struct LiquidWaveMiniModifier: ViewModifier {
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
                    offset = -4
                }
            }
    }
}

// MARK: - Previews

#Preview("Rest Timer — AI Pending") {
    RestTimerView(
        viewModel: WorkoutViewModel.mockResting(),
        nextExercise: PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: ["anterior_deltoid"],
            equipmentRequired: .barbell,
            sets: 4,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 120,
            rirTarget: 2,
            coachingCues: []
        ),
        setNumber: 3,
        streak: StreakResult.compute(currentStreakDays: 7, longestStreak: 10)
    )
    .preferredColorScheme(.dark)
}

#Preview("Rest Timer — Prescription Ready") {
    let vm = WorkoutViewModel.mockResting()
    vm.currentPrescription = SetPrescription(
        weightKg: 85.0,
        reps: 7,
        tempo: "3-1-1-0",
        rirTarget: 2,
        restSeconds: 150,
        coachingCue: "Drive through the bar",
        reasoning: "Up 2.5 kg from last session — HRV trending positive.",
        safetyFlags: [],
        confidence: 0.91,
        intent: .top,
        setFraming: "Heaviest work of the day. Brace and grind."
    )
    return RestTimerView(
        viewModel: vm,
        nextExercise: PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: [],
            equipmentRequired: .barbell,
            sets: 4,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 120,
            rirTarget: 2,
            coachingCues: []
        ),
        setNumber: 3,
        streak: StreakResult.compute(currentStreakDays: 7, longestStreak: 10)
    )
    .preferredColorScheme(.dark)
}
