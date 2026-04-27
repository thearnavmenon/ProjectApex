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

    // MARK: - Body

    var body: some View {
        ZStack {
            apexBackground

            VStack(spacing: 0) {
                // Top bar with end-early menu (P3-T09)
                HStack {
                    Spacer()
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
                            .foregroundStyle(.white.opacity(0.38))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer(minLength: 12)

                // REST label
                Text("REST")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                    .tracking(2.5)
                    .textCase(.uppercase)

                Spacer(minLength: 20)

                // Circular progress ring
                timerRing

                Spacer(minLength: 28)

                // AI status row
                aiStatusRow

                Spacer(minLength: 32)

                // Next exercise preview card
                nextExerciseCard

                Spacer()

                // Skip rest button
                skipButton
                    .padding(.bottom, 48)
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
            // Track ring
            Circle()
                .stroke(streak.tintColor.opacity(0.12), lineWidth: 3)
                .frame(width: 220, height: 220)

            // Progress ring — draws from full (1.0) down to 0
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(
                    AngularGradient(
                        colors: [
                            streak.tintColor.opacity(0.45),
                            streak.tintColor
                        ],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 220, height: 220)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1.0), value: ringProgress)

            // Countdown number
            VStack(spacing: 4) {
                Text(countdownDisplay)
                    .font(.system(size: 80, weight: .ultraLight, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.3), value: viewModel.restSecondsRemaining)

                Text("seconds")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
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
                            .fill(streak.tintColor.opacity(0.75))
                            .frame(width: 5, height: 5)
                            .modifier(LiquidWaveMiniModifier(index: i))
                    }
                }
                Text("Coach preparing next set…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
            } else if viewModel.isAIOffline {
                Image(systemName: "brain.head.profile.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0))
                Text(viewModel.fallbackDescription ?? "Coach offline — using plan defaults")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                // Prescription ready
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(streak.tintColor)
                Text("Prescription ready")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(streak.tintColor.opacity(0.80))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: Capsule())
    }

    // MARK: - Next Exercise Card

    private var nextExerciseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEXT UP")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.30))
                .tracking(1.5)

            HStack(alignment: .top, spacing: 14) {
                // Muscle colour dot
                Circle()
                    .fill(muscleColor(for: nextExercise.primaryMuscle))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(nextExercise.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Set \(setNumber) · \(nextExercise.repRange.min)–\(nextExercise.repRange.max) reps · RIR \(nextExercise.rirTarget)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()

                // AI prescription preview (weight + reps) if ready
                if let p = viewModel.currentPrescription {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(weightString(p.weightKg))
                                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                            Text("kg")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .baselineOffset(2)
                        }
                        Text("\(p.reps) reps")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.70),
                               value: viewModel.currentPrescription != nil)
                }
            }
        }
        .padding(20)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Skip Button

    private var skipButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            viewModel.skipRest()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("NEXT SET")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.0)
            }
            .foregroundStyle(.white.opacity(0.28))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.white.opacity(0.04), in: Capsule())
        }
    }

    // MARK: - Background

    private var apexBackground: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [streak.tintColor.opacity(0.12), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
        }
    }

    // MARK: - Computed Helpers

    /// 0.0 → 1.0, where 1.0 = full rest remaining, 0.0 = timer done.
    private var ringProgress: Double {
        guard totalRestDuration > 0 else { return 0 }
        return Double(viewModel.restSecondsRemaining) / Double(totalRestDuration)
    }

    private var countdownDisplay: String {
        "\(viewModel.restSecondsRemaining)"
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
        confidence: 0.91
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
