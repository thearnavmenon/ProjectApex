// Features/Workout/PreWorkoutView.swift
// ProjectApex — P3-T03 / P4-E1
//
// Pre-workout screen shown before a session starts. Restyled to the Brutalist
// Athletic identity (#473): pure-black surface, restrained streak ring + count,
// a today's-plan day card listing exercises, and one volt-lime primary action.
//
// Acceptance criteria:
//   ✓ StreakResult ring with consecutive-day count (Brutalist single-accent: lime ring/count)
//   ✓ Today's training day: label, exercise count, estimated duration
//   ✓ "Start Workout" → WorkoutSessionManager.startSession() via ViewModel
//   ✓ Preflight state: "Preparing your session…" with spinner
//   ✓ Dismissable banners (welcome-back / heavy-reassessment / calibration) preserved

import SwiftUI

// MARK: - PreWorkoutView

struct PreWorkoutView: View {

    @Environment(AppDependencies.self) private var deps

    /// The WorkoutViewModel owned by the parent WorkoutView.
    @Bindable var viewModel: WorkoutViewModel

    /// The training day the user is about to do.
    let trainingDay: TrainingDay

    /// The mesocycle this day belongs to.
    let programId: UUID

    /// Streak result from GymStreakService (fetched by WorkoutView).
    let streak: StreakResult

    /// 1-based week number within the mesocycle, written to workout_sessions.week_number.
    var weekNumber: Int = 1
    /// 0-based exercise index to start from (0 = first exercise, N = continue from exercise N+1).
    var startingExerciseIndex: Int = 0
    /// True when the user has never completed a session before (FB-005).
    /// Shows the first-session calibration banner.
    var isFirstSession: Bool = false
    /// Number of completed training days in the current mesocycle (for Day X of Y display).
    var completedDayCount: Int = 0
    /// Total training days in the current mesocycle (for Day X of Y display).
    var totalDayCount: Int = 0
    /// Days since the user's last completed session — nil means first-ever session.
    /// Drives the welcome-back banner when the gap is ≥ 14 days (2.4A).
    var daysSinceLastSession: Int? = nil
    /// Raw `session_date` string ("yyyy-MM-dd") of that last completed session —
    /// the stable key for the welcome-back banner's dismissal fingerprint (J-F7).
    var lastSessionDateKey: String? = nil
    /// Heavy-reassessment signal (#258). When present (and not locally dismissed),
    /// shows the level-up banner naming recently-advanced patterns. Nil → no banner.
    var heavyReassessmentSignal: HeavyReassessmentSignal? = nil
    /// Called when the user taps "Review goals" on the heavy-reassessment banner.
    /// Injected; a later slice (#258 E2) wires it to the goal-review screen. Default no-op.
    var onReviewGoals: () -> Void = {}
    /// Calibration-review signal (#269). When present (and not locally dismissed),
    /// shows the one-time targets banner. Takes precedence over the heavy-
    /// reassessment banner when both are present. Nil → no calibration banner.
    var calibrationReviewSignal: CalibrationReviewSignal? = nil
    /// Called when the user taps "Review targets" on the calibration banner (#269).
    /// Wired to the read-only calibration screen. Default no-op.
    var onReviewCalibration: () -> Void = {}
    /// Watermark pair backing the calibration banner's dismissal fingerprint
    /// (J-F7): `ProjectionState.calibrationReviewFiredAt` and
    /// `ProjectionState.lastRecalibratedAtSessionCount`. Re-calibration moves
    /// the watermark, which re-arms a dismissed banner (#305 semantics).
    var calibrationWatermarkFiredAt: Date? = nil
    var calibrationWatermarkRecalibratedAtSessionCount: Int? = nil
    /// Called when the user taps "Skip this session". Defers this day without recording
    /// any session data — the next pending non-skipped day becomes the active session.
    var onSkipSession: (() -> Void)? = nil
    /// Called when the user taps the back button or swipes from the left edge.
    var onBack: (() -> Void)? = nil
    /// Called when the user taps the × close button on the Tab 1 entry path (idle only).
    var onCloseToTab0: (() -> Void)? = nil
    /// True while a pending day's session is being generated in place. Shows a spinner
    /// on the "Generate Session" CTA and disables it.
    var isGeneratingSession: Bool = false
    /// Called when the user taps "Generate Session" on a pending day. Non-nil only when
    /// a gym profile is confirmed; nil renders the CTA disabled with a "set up your gym"
    /// hint instead of routing to a no-op.
    var onGenerateSession: (() -> Void)? = nil

    // MARK: - Private state
    @State private var showSkipConfirmation: Bool = false
    /// Durable, event-fingerprinted dismissal store for the three dismissable
    /// banners (J-F7 / #318). Replaces the transient per-banner Bool flags —
    /// a dismissal now survives view rebuilds and is keyed to the event it
    /// dismissed, re-arming only when the underlying event genuinely changes.
    private let bannerDismissals = BannerDismissals()
    /// Banners dismissed during this view's lifetime. The durable store is the
    /// source of truth across rebuilds; this set exists only so an X-tap
    /// triggers an immediate SwiftUI re-render.
    @State private var locallyDismissedBanners: Set<BannerDismissals.Banner> = []
    /// Set true once the user taps "Generate Session". Combined with the day still being
    /// pending and generation no longer in progress, this surfaces the inline failure
    /// line — generateDaySession restores .loaded silently on error (amendment 2.2).
    @State private var generationAttempted: Bool = false

    // MARK: - Body

    var body: some View {
        ZStack {
            // Pure-black Brutalist backdrop.
            Apex.bg.ignoresSafeArea()

            if viewModel.isPreflight {
                preflightView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        programProgressSection
                        if isFirstSession {
                            firstSessionBanner
                        }
                        // Precedence (#269): the calibration banner takes priority; the
                        // heavy-reassessment banner shows only when the calibration banner
                        // is not currently shown.
                        if let calibration = calibrationReviewSignal,
                           showsBanner(.calibrationReview, fingerprint: calibrationFingerprint) {
                            calibrationReviewBanner(calibration)
                        } else if let signal = heavyReassessmentSignal,
                                  showsBanner(.heavyReassessment, fingerprint: heavyReassessmentFingerprint(signal)) {
                            heavyReassessmentBanner(signal)
                        }
                        if let days = daysSinceLastSession, days >= 14,
                           showsBanner(.welcomeBack, fingerprint: welcomeBackFingerprint) {
                            welcomeBackBanner(days: days)
                        }
                        sessionInfoCard
                        startButton
                        if onSkipSession != nil {
                            skipButton
                        }
                    }
                    .padding(.horizontal, Apex.pad)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                }
            }
        }
        .gesture(
            DragGesture().onEnded { value in
                guard !viewModel.isPreflight else { return }
                if value.translation.width > 80 {
                    if onBack != nil { onBack?() }
                    else { onCloseToTab0?() }
                }
            }
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !viewModel.isPreflight {
                    if onBack != nil {
                        Button(action: { onBack?() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Apex.text.opacity(0.80))
                        }
                    } else if onCloseToTab0 != nil {
                        Button(action: { onCloseToTab0?() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Apex.text.opacity(0.80))
                        }
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Text("TODAY'S SESSION")
                    .font(.system(size: 12, weight: .semibold))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .foregroundStyle(Apex.textDim)
            }
        }
    }

    // MARK: - Preflight

    private var preflightView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Apex.accent)
                .scaleEffect(1.4)
            Text("Preparing your session\u{2026}")
                .font(.system(size: 15, weight: .medium))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(Apex.textDim)
            Spacer()
        }
    }

    // MARK: - Programme Progress Section (streak ring + Day X of Y)

    private var programProgressSection: some View {
        let progress: CGFloat = totalDayCount > 0 ? CGFloat(completedDayCount) / CGFloat(totalDayCount) : 0

        return VStack(spacing: 18) {
            // Progress ring with Day X of Y inside — Brutalist single-accent: lime.
            ZStack {
                ApexRing(
                    progress: Double(progress),
                    lineWidth: 9,
                    color: Apex.accent,
                    track: Apex.accent.opacity(0.12),
                    useGradient: true
                )
                .frame(width: 156, height: 156)
                .animation(.easeOut(duration: 0.8), value: completedDayCount)

                // Day count inside ring — hidden until totalDayCount is known
                if totalDayCount > 0 {
                    VStack(spacing: 2) {
                        ApexSectionLabel(text: "Day")
                        ApexNumeral(text: "\(completedDayCount + 1)", size: 48)
                        Text("of \(totalDayCount)")
                            .font(.system(size: 13, weight: .semibold))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.accent)
                            .tracking(0.5)
                    }
                }
            }
            .padding(.top, 8)

            // Subtitle label
            ApexSectionLabel(text: progressSubtitle, color: Apex.textFaint)
        }
    }

    private var progressSubtitle: String {
        guard totalDayCount > 0 else { return "Programme in progress" }
        let percent = Int(round(Double(completedDayCount) / Double(totalDayCount) * 100))
        return "\(percent)% of programme complete"
    }

    // MARK: - Session Info Card (today's plan)

    private var sessionInfoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(trainingDay.dayLabel.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 22, weight: .heavy))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                    ApexSectionLabel(text: "Week \(weekLabel)", color: Apex.textFaint)
                }
                Spacer()
                // Exercise count chip — only meaningful once the session is generated.
                if !isPending {
                    ApexTagChip(text: "\(trainingDay.exercises.count) exercises")
                }
            }
            .padding(18)

            Rectangle()
                .fill(Apex.hairline)
                .frame(height: 1)

            if isPending {
                // Not-yet-generated day: no exercises exist, so don't render a 0-count
                // preview or a "~0 min" estimate — say so plainly.
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Apex.textFaint)
                    Text("Session not generated yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Apex.textFaint)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            } else {
                // Exercise list preview (first 3 + overflow)
                VStack(spacing: 0) {
                    let preview = Array(trainingDay.exercises.prefix(3))
                    ForEach(Array(preview.enumerated()), id: \.offset) { index, exercise in
                        ExerciseRowPreview(index: index, exercise: exercise)
                        if index < preview.count - 1 {
                            Rectangle()
                                .fill(Apex.hairline.opacity(0.6))
                                .frame(height: 1)
                                .padding(.leading, 18)
                        }
                    }
                    if trainingDay.exercises.count > 3 {
                        Text("+ \(trainingDay.exercises.count - 3) more exercises")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Apex.textFaint)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 14)
                    }
                }

                // Duration estimate
                Rectangle()
                    .fill(Apex.hairline)
                    .frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(Apex.textFaint)
                    Text("~\(estimatedDurationMinutes) min estimated")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Apex.textFaint)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .apexCard()
    }

    // MARK: - First Session Banner (FB-005)

    private var firstSessionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Apex.gold)
            VStack(alignment: .leading, spacing: 4) {
                ApexSectionLabel(text: "First session", color: Apex.gold)
                Text("We'll calibrate your starting weights today.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Apex.textDim)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - Banner dismissal semantics (J-F7 / #318)

    /// True when the banner should render: not dismissed during this view's
    /// lifetime (the set drives the immediate re-render on X-tap) and the
    /// current event fingerprint differs from the durably dismissed one (the
    /// store drives persistence across view rebuilds).
    private func showsBanner(_ banner: BannerDismissals.Banner, fingerprint: String) -> Bool {
        !locallyDismissedBanners.contains(banner)
            && bannerDismissals.shouldShow(banner, fingerprint: fingerprint)
    }

    /// Writes the current event fingerprint durably. No server-side ack —
    /// sheet-save remains the only durable-ack path.
    private func dismissBanner(_ banner: BannerDismissals.Banner, fingerprint: String) {
        bannerDismissals.dismiss(banner, fingerprint: fingerprint)
        locallyDismissedBanners.insert(banner)
    }

    private var welcomeBackFingerprint: String {
        BannerDismissals.welcomeBackFingerprint(lastSessionDateKey: lastSessionDateKey ?? "")
    }

    private func heavyReassessmentFingerprint(_ signal: HeavyReassessmentSignal) -> String {
        BannerDismissals.heavyReassessmentFingerprint(triggeringSessionCount: signal.triggeringSessionCount)
    }

    private var calibrationFingerprint: String {
        BannerDismissals.calibrationFingerprint(
            calibrationReviewFiredAt: calibrationWatermarkFiredAt,
            lastRecalibratedAtSessionCount: calibrationWatermarkRecalibratedAtSessionCount
        )
    }

    /// Dismiss "×" control shared by the dismissable banners.
    private func bannerDismissButton(_ banner: BannerDismissals.Banner, fingerprint: String) -> some View {
        Button {
            dismissBanner(banner, fingerprint: fingerprint)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Apex.textFaint)
                .padding(6)
        }
    }

    // MARK: - Welcome Back Banner (2.4A)

    /// Pure message-selection for the welcome-back banner, extracted for unit testing.
    /// A pending day's session hasn't been generated yet, so it genuinely will account
    /// for the break; an already-generated session was planned before the break, so the
    /// copy must not claim any break-aware adjustment.
    static func welcomeBackMessage(days: Int, status: TrainingDayStatus) -> String {
        switch status {
        case .pending:
            return days >= 28
                ? "Welcome back — it's been \(days) days. Today is a recovery session with reduced volume to get you back on track."
                : "Welcome back — it's been \(days) days. Today's session will account for the break."
        default:
            return "Welcome back — it's been \(days) days. This session was planned before your break — take it easy out there."
        }
    }

    private func welcomeBackBanner(days: Int) -> some View {
        let isReturnSession = days >= 28
        let message = Self.welcomeBackMessage(days: days, status: trainingDay.status)
        return HStack(spacing: 12) {
            Image(systemName: isReturnSession ? "arrow.counterclockwise.circle.fill" : "hand.wave.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Apex.amber)
            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Apex.text.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            bannerDismissButton(.welcomeBack, fingerprint: welcomeBackFingerprint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - Heavy Reassessment Banner (#258)

    private func heavyReassessmentBanner(_ signal: HeavyReassessmentSignal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Apex.text.opacity(0.85))
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ApexSectionLabel(text: HeavyReassessmentBannerCopy.title)
                    Text(HeavyReassessmentBannerCopy.body(for: signal))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Apex.text.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    onReviewGoals()
                } label: {
                    Text("Review goals")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Apex.text)
                }
            }
            Spacer(minLength: 0)
            bannerDismissButton(.heavyReassessment, fingerprint: heavyReassessmentFingerprint(signal))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - Calibration Review Banner (#269)

    private func calibrationReviewBanner(_ signal: CalibrationReviewSignal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "target")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Apex.text.opacity(0.85))
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ApexSectionLabel(text: CalibrationReviewBannerCopy.title(isRecalibration: signal.isRecalibration))
                    Text(CalibrationReviewBannerCopy.body(for: signal))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Apex.text.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    onReviewCalibration()
                } label: {
                    Text("Review targets")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Apex.text)
                }
            }
            Spacer(minLength: 0)
            bannerDismissButton(.calibrationReview, fingerprint: calibrationFingerprint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - Start Button

    /// A not-yet-generated day shows a "Generate Session" CTA instead of "Start Workout":
    /// the session has to be created before it can be started.
    private var isPending: Bool { trainingDay.status == .pending }

    @ViewBuilder
    private var startButton: some View {
        if isPending {
            pendingButtonGroup
        } else {
            startWorkoutButton
        }
    }

    /// CTA group shown when the day's session has not been generated yet.
    @ViewBuilder
    private var pendingButtonGroup: some View {
        VStack(spacing: 12) {
            if onGenerateSession != nil {
                generateSessionButton
                // Inline failure: generateDaySession restores .loaded silently on error,
                // leaving the day pending. Surface that honestly rather than failing mute.
                if generationAttempted && !isGeneratingSession {
                    Text("Couldn't generate the session. Check your connection and try again.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.45))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // No confirmed gym profile — generation can't run. Disabled CTA + hint,
                // not a no-op route.
                noGymProfileButton
                Text("Set up your gym in Settings first")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    private var generateSessionButton: some View {
        Button {
            generationAttempted = true
            onGenerateSession?()
        } label: {
            ApexButton(
                title: isGeneratingSession ? "Generating\u{2026}" : "Generate Session",
                icon: isGeneratingSession ? nil : "wand.and.stars"
            )
            .opacity(isGeneratingSession ? 0.45 : 1.0)
            .overlay {
                if isGeneratingSession {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Apex.onAccent)
                        .scaleEffect(0.85)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isGeneratingSession)
        }
        .disabled(isGeneratingSession)
    }

    private var noGymProfileButton: some View {
        HStack(spacing: 9) {
            Image(systemName: "wand.and.stars").font(.system(size: 16, weight: .bold))
            Text("Generate Session")
                .textCase(.uppercase)
                .tracking(1.1)
                .fontWidth(.condensed)
        }
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(Apex.textDim)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 17)
        .background {
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .fill(Apex.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(Apex.hairline, lineWidth: 1)
        }
    }

    private var startWorkoutButton: some View {
        VStack(spacing: 12) {
            startWorkoutButtonCore
            // Inline failure: the auth gate aborts (no placeholder row) when owner
            // auth never resolves. Surface that honestly rather than failing mute (#399).
            if let startError = viewModel.startError, !viewModel.isStartingSession {
                Text(startError)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }

    private var startWorkoutButtonCore: some View {
        Button {
            viewModel.startSession(trainingDay: trainingDay, programId: programId, resolveOwner: { await deps.resolvedOwnerUserId() }, weekNumber: weekNumber, startingExerciseIndex: startingExerciseIndex)
        } label: {
            ApexButton(
                title: viewModel.isStartingSession ? "Loading\u{2026}" : "Start Workout",
                icon: viewModel.isStartingSession ? nil : "play.fill"
            )
            .opacity(viewModel.isStartingSession ? 0.45 : 1.0)
            .overlay {
                if viewModel.isStartingSession {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Apex.onAccent)
                        .scaleEffect(0.85)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: viewModel.isStartingSession)
        }
        .disabled(viewModel.isStartingSession)
    }

    // MARK: - Skip Button

    private var skipButton: some View {
        Button {
            showSkipConfirmation = true
        } label: {
            Text("Skip this session")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Apex.textFaint)
        }
        .disabled(viewModel.isStartingSession)
        .alert("Skip this session?", isPresented: $showSkipConfirmation) {
            Button("Skip Session", role: .destructive) {
                onSkipSession?()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This session won't be logged and the programme will advance to the next session.")
        }
    }

    // MARK: - Computed helpers

    private var weekLabel: String {
        return "\(weekNumber)"
    }

    private var estimatedDurationMinutes: Int {
        // Rough estimate: 4 sets × 45s work + rest_seconds per exercise
        trainingDay.exercises.reduce(0) { total, exercise in
            let workTime = exercise.sets * 45
            let restTime = exercise.sets * exercise.restSeconds
            return total + (workTime + restTime) / 60
        }
    }
}

// MARK: - ExerciseRowPreview

private struct ExerciseRowPreview: View {
    let index: Int
    let exercise: PlannedExercise

    var body: some View {
        HStack(spacing: 12) {
            // Numbered slot — Brutalist tabular index.
            Text(String(format: "%02d", index + 1))
                .font(Apex.numeral(13, weight: .bold))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textFaint)

            // Muscle-group dot — accent.
            Circle()
                .fill(Apex.accent.opacity(0.8))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Apex.text)
                Text("\(exercise.sets) × \(exercise.repRange.min)–\(exercise.repRange.max)")
                    .font(.system(size: 12, weight: .medium))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
            }

            Spacer()

            Text(exercise.equipmentRequired.displayName)
                .font(.system(size: 11, weight: .medium))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Apex.textFaint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

// MARK: - Preview

#Preview("Pre-Workout — On Fire") {
    let day = Mesocycle.mockMesocycle().weeks[0].trainingDays[0]
    NavigationStack {
        PreWorkoutView(
            viewModel: WorkoutViewModel.mockPreflight(),
            trainingDay: day,
            programId: UUID(),
            streak: StreakResult.compute(currentStreakDays: 12, longestStreak: 14)
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Pre-Workout — Cold") {
    let day = Mesocycle.mockMesocycle().weeks[0].trainingDays[0]
    NavigationStack {
        PreWorkoutView(
            viewModel: WorkoutViewModel.mockPreflight(),
            trainingDay: day,
            programId: UUID(),
            streak: .neutral
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Pre-Workout — First Session") {
    let day = Mesocycle.mockMesocycle().weeks[0].trainingDays[0]
    NavigationStack {
        PreWorkoutView(
            viewModel: WorkoutViewModel.mockPreflight(),
            trainingDay: day,
            programId: UUID(),
            streak: .neutral,
            isFirstSession: true
        )
    }
    .preferredColorScheme(.dark)
}
