// OnboardingView.swift
// ProjectApex — Onboarding Feature  (P4-T09)
//
// Full first-run onboarding sequence presented as a full-screen sheet over
// the main TabView. Dismissed only after all required steps are complete
// (or Step 4 gym scan is explicitly skipped with a warning).
//
// Steps:
//   1 — Display name entry         → stored in Keychain + users table
//   2 — Training profile           → training age, goal, days/week
//   3 — Notification permission    → for rest timer / session reminders
//   4 — Gym scanner                → ScannerView flow; skippable with warning
//   5 — Program generation         → loading screen (LLM call)
//   6 — Ready confirmation         → dismisses to Program tab
//
// First-run detection: KeychainService.retrieve(.userId) == nil
// On completion (#369 slice 3): the anonymous-auth `auth.uid()` is written to
// Keychain.userId (mirroring the auth subject, not a fresh UUID()); the
// public.users row is keyed to that same uid so slice 5's RLS policy matches.
// onboardingCompleted is stored in UserDefaults so subsequent launches skip
// this view immediately.

import SwiftUI
import UserNotifications

// MARK: - Training Profile Input Model

/// Collected during Step 2. Passed into ProgramGenerationService.
struct OnboardingProfile: Sendable {
    var displayName: String = ""
    var trainingAge: TrainingAge = .beginner
    var primaryGoal: TrainingGoal = .hypertrophy
    var daysPerWeek: Int = 4

    // FB-003: biometric fields
    /// User's bodyweight — optional, onboarding is not blocked if absent.
    var bodyweightKg: Double? = nil
    /// User's height in cm.
    var heightCm: Double? = nil
    /// User's age in years.
    var age: Int? = nil
    /// Whether bodyweight input is in kg (true) or lbs (false).
    var bodyweightInKg: Bool = true
}

enum TrainingAge: String, CaseIterable, Sendable {
    case beginner     = "Beginner (< 1 yr)"
    case intermediate = "Intermediate (1–3 yrs)"
    case advanced     = "Advanced (3+ yrs)"
}

enum TrainingGoal: String, CaseIterable, Sendable {
    case hypertrophy = "Hypertrophy (muscle size)"
    case strength    = "Strength (max weight)"
    case endurance   = "Muscular endurance"
    case general     = "General fitness"
}

// MARK: - OnboardingView

struct OnboardingView: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    // Called when onboarding fully completes so ContentView can switch to Program tab.
    var onCompleted: ((GymProfile?) -> Void)? = nil

    @State private var step: Int = 1
    @State private var profile = OnboardingProfile()
    /// Seeded from the UserDefaults cache (#318 U4) so a scan that completed
    /// before an app kill rehydrates instead of forcing a re-scan.
    @State private var gymProfile: GymProfile? = GymProfile.loadFromUserDefaults()
    @State private var scanSkipped: Bool = false
    @State private var notifGranted: Bool = false
    @State private var isGenerating: Bool = false
    @State private var generationError: String? = nil
    @State private var showSkipScanAlert: Bool = false

    // Step 4 inline scanner
    @State private var showingScannerSheet: Bool = false

    var body: some View {
        ZStack {
            // Apex background
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [Color(red: 0.23, green: 0.56, blue: 1.00).opacity(0.14), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.12),
                startRadius: 0, endRadius: 380
            ).ignoresSafeArea().blendMode(.plusLighter)

            VStack(spacing: 0) {
                // Progress indicator
                progressBar
                    .padding(.top, 20)
                    .padding(.horizontal, 32)

                // Step content
                Group {
                    switch step {
                    case 1: step1NameView
                    case 2: step2ProfileView
                    case 3: step3NotificationsView
                    case 4: step4ScannerView
                    case 5: step5GeneratingView
                    case 6: step6ReadyView
                    default: EmptyView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)  // Prevent accidental swipe-dismiss
        .sheet(isPresented: $showingScannerSheet) {
            NavigationStack {
                ScannerView { scannedProfile in
                    gymProfile = scannedProfile
                    scanSkipped = false
                    showingScannerSheet = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") {
                            showingScannerSheet = false
                            showSkipScanAlert = true
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .alert("Skip Gym Scan?", isPresented: $showSkipScanAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Skip", role: .destructive) {
                scanSkipped = true
                advance()
            }
        } message: {
            Text("Without scanning your gym, the AI coach won't know what equipment is available. You can complete this in Settings later.")
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Capsule()
                    .fill(i <= displayStep ? Color(red: 0.23, green: 0.56, blue: 1.00) : Color.white.opacity(0.15))
                    .frame(height: 3)
                    .animation(.spring(response: 0.35, dampingFraction: 0.82), value: displayStep)
            }
        }
    }

    /// Maps internal step (1–6) to a 1–5 progress indicator.
    /// Step 5 (generating) and 6 (ready) both show as fully filled.
    private var displayStep: Int {
        min(step, 5)
    }

    // MARK: - Step 1: Display Name

    private var step1NameView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Text("Welcome to\nProject Apex")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("Your AI-powered strength coach.\nLet's set you up in 5 steps.")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("What's your name?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                    TextField("", text: $profile.displayName, prompt: Text("e.g. Alex").foregroundStyle(.white.opacity(0.30)))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                                )
                        )
                        .autocorrectionDisabled()
                        .textContentType(.givenName)
                        .submitLabel(.done)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 32)

            Spacer()

            primaryButton(title: "Continue", enabled: !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 2 }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Step 2: Training Profile

    private var step2ProfileView: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 32) {
                    stepHeader(
                        icon: "figure.strengthtraining.traditional",
                        title: "Your Training Profile",
                        subtitle: "This helps the AI prescribe the right program intensity from day one."
                    )
                    .padding(.top, 24)

                    VStack(spacing: 20) {
                        profilePickerRow(
                            label: "Experience",
                            systemImage: "chart.bar.fill",
                            selection: $profile.trainingAge,
                            options: TrainingAge.allCases
                        ) { $0.rawValue }

                        profilePickerRow(
                            label: "Primary Goal",
                            systemImage: "target",
                            selection: $profile.primaryGoal,
                            options: TrainingGoal.allCases
                        ) { $0.rawValue }

                        // Days per week
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Days per Week", systemImage: "calendar")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.70))
                            HStack(spacing: 10) {
                                // #369 / O-F11: include 2 — the engine supports 2-day weeks
                                // (phase-advance handles daysPerWeek≥1; the macro-plan prompt
                                // takes any integer) and the onboarding spec lists 2/3/4/5+,
                                // but the picker previously started at 3, so 2-day-per-week
                                // users could not onboard honestly.
                                ForEach([2, 3, 4, 5, 6], id: \.self) { n in
                                    Button {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                                            profile.daysPerWeek = n
                                        }
                                    } label: {
                                        Text("\(n)")
                                            .font(.system(size: 18, weight: .bold, design: .rounded))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 14)
                                            .background(
                                                profile.daysPerWeek == n
                                                ? Color(red: 0.23, green: 0.56, blue: 1.00)
                                                : Color.white.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            )
                                            .foregroundStyle(.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // ── Biometric Fields (FB-003) ──────────────────────────

                        // Bodyweight — optional
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Bodyweight", systemImage: "scalemass")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.70))
                                Spacer()
                                // kg / lbs toggle
                                Picker("Unit", selection: $profile.bodyweightInKg) {
                                    Text("kg").tag(true)
                                    Text("lbs").tag(false)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 90)
                                .onChange(of: profile.bodyweightInKg) { _, useKg in
                                    // Convert stored kg value when user switches unit
                                    if let kg = profile.bodyweightKg {
                                        if !useKg {
                                            // Display value will be shown in lbs, storage stays kg — no conversion needed
                                            _ = kg
                                        }
                                    }
                                }
                            }
                            HStack(spacing: 8) {
                                TextField(
                                    profile.bodyweightInKg ? "e.g. 80" : "e.g. 176",
                                    text: Binding(
                                        get: {
                                            guard let kg = profile.bodyweightKg else { return "" }
                                            let displayValue = profile.bodyweightInKg ? kg : kg * 2.20462
                                            return displayValue.truncatingRemainder(dividingBy: 1) == 0
                                                ? String(format: "%.0f", displayValue)
                                                : String(format: "%.1f", displayValue)
                                        },
                                        set: { text in
                                            if text.isEmpty {
                                                profile.bodyweightKg = nil
                                            } else if let v = Double(text.replacingOccurrences(of: ",", with: ".")) {
                                                // Always store in kg
                                                profile.bodyweightKg = profile.bodyweightInKg ? v : v / 2.20462
                                            }
                                        }
                                    )
                                )
                                .keyboardType(.decimalPad)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.white.opacity(0.07))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                                        )
                                )
                                Text(profile.bodyweightInKg ? "kg" : "lbs")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(width: 32)
                            }
                            Text("Optional — helps the AI calibrate your starting weights")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.35))
                        }

                        // Height
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Height", systemImage: "ruler")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.70))
                            HStack(spacing: 8) {
                                TextField("e.g. 178", text: Binding(
                                    get: {
                                        guard let cm = profile.heightCm else { return "" }
                                        return cm.truncatingRemainder(dividingBy: 1) == 0
                                            ? String(format: "%.0f", cm)
                                            : String(format: "%.1f", cm)
                                    },
                                    set: { text in
                                        if text.isEmpty {
                                            profile.heightCm = nil
                                        } else if let v = Double(text.replacingOccurrences(of: ",", with: ".")) {
                                            profile.heightCm = v
                                        }
                                    }
                                ))
                                .keyboardType(.decimalPad)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.white.opacity(0.07))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                                        )
                                )
                                Text("cm")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(width: 32)
                            }
                        }

                        // Age
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Age", systemImage: "person.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.70))
                            HStack(spacing: 8) {
                                TextField("e.g. 28", text: Binding(
                                    get: { profile.age.map { String($0) } ?? "" },
                                    set: { text in
                                        if text.isEmpty {
                                            profile.age = nil
                                        } else if let v = Int(text) {
                                            profile.age = v
                                        }
                                    }
                                ))
                                .keyboardType(.numberPad)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.white.opacity(0.07))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                                        )
                                )
                                Text("yrs")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(width: 32)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)

                HStack(spacing: 12) {
                    backButton { withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 1 } }
                    primaryButton(title: "Continue", enabled: true) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 3 }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Step 3: Notifications

    private var step3NotificationsView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 32) {
                stepHeader(
                    icon: "bell.badge.fill",
                    title: "Stay On Track",
                    subtitle: "Allow notifications so the AI coach can alert you when your rest timer expires."
                )

                VStack(spacing: 14) {
                    notifFeatureRow(icon: "timer", label: "Rest timer alerts — never lose track of your rest")
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                primaryButton(title: "Allow Notifications", enabled: true) {
                    Task {
                        await requestNotificationPermission()
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 4 }
                    }
                }
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 4 }
                } label: {
                    Text("Not Now")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Step 4: Gym Scanner

    private var step4ScannerView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 32) {
                stepHeader(
                    icon: "camera.viewfinder",
                    title: "Scan Your Gym",
                    subtitle: "Walk around and photograph each piece of equipment. The AI coach uses this to guarantee every exercise fits what's available."
                )

                if let scannedProfile = gymProfile {
                    // Profile already captured — show summary card
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Gym scanned")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("\(scannedProfile.equipment.count) equipment items confirmed")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Button {
                            showingScannerSheet = true
                        } label: {
                            Text("Re-scan")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.60))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.10), in: Capsule())
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.green.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 4)
                } else {
                    // Scanner CTA
                    Button {
                        showingScannerSheet = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "camera.viewfinder")
                                .font(.title2)
                                .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Open Gym Scanner")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("Point your camera at each piece of equipment")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.50))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                primaryButton(
                    title: gymProfile != nil ? "Continue" : "Start Scanning",
                    enabled: true
                ) {
                    if gymProfile != nil {
                        advance()
                    } else {
                        showingScannerSheet = true
                    }
                }

                if gymProfile == nil {
                    Button {
                        showSkipScanAlert = true
                    } label: {
                        Text("Skip for now")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white.opacity(0.40))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Step 5: Program Generation

    private var step5GeneratingView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 36) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 2)
                        .frame(width: 88, height: 88)
                    if isGenerating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.5)
                    } else if generationError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 34))
                            .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
                    }
                }

                VStack(spacing: 10) {
                    Text(isGenerating ? "Building Your Program…" : (generationError != nil ? "Generation Failed" : "Program Ready"))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    if isGenerating {
                        Text("The AI coach is designing your 12-week periodized program.\nThis can take up to a couple of minutes.")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.white.opacity(0.50))
                            .multilineTextAlignment(.center)
                    } else if let err = generationError {
                        Text(err)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.orange.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            if generationError != nil {
                VStack(spacing: 12) {
                    primaryButton(title: "Try Again", enabled: true) {
                        Task { await runProgramGeneration() }
                    }
                    Button {
                        // Skip generation — user can regenerate from Settings
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 6 }
                    } label: {
                        Text("Continue without a program")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .task {
            if !isGenerating && generationError == nil {
                await runProgramGeneration()
            }
        }
    }

    // MARK: - Step 6: Ready

    private var step6ReadyView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
                        .symbolEffect(.bounce)

                    VStack(spacing: 10) {
                        Text("You're Ready to Train")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let readyMessage: String = {
                            if generationError != nil {
                                return "Program generation didn't finish. You can generate it from the Program tab — your answers are saved."
                            } else if scanSkipped {
                                return "Almost there — add your gym equipment to unlock your program."
                            } else {
                                return "Welcome, \(name.isEmpty ? "Athlete" : name). Your 12-week program is loaded. Head to the Program tab to review it, then start your first session."
                            }
                        }()
                        Text(readyMessage)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                }

                if scanSkipped {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Gym scan skipped — visit Settings → \"Complete your setup\" to scan your equipment.")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.orange.opacity(0.85))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.orange.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            primaryButton(title: "Start Training", enabled: true) {
                completeOnboarding()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Shared Sub-components

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func primaryButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    enabled
                    ? Color(red: 0.23, green: 0.56, blue: 1.00)
                    : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                Text("Back")
                    .font(.system(size: 16, weight: .regular))
            }
            .foregroundStyle(.white.opacity(0.50))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func notifFeatureRow(icon: String, label: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
                .frame(width: 24)
            Text(label)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
    }

    private func profilePickerRow<T: Hashable>(
        label: String,
        systemImage: String,
        selection: Binding<T>,
        options: [T],
        displayName: @escaping (T) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.70))
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { opt in
                    Text(displayName(opt)).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Actions

    private func advance() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
            step += 1
        }
    }

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notifGranted = granted
        } catch {
            notifGranted = false
        }
    }

    private func runProgramGeneration() async {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil

        // Persist user record (and userId in Keychain) before generation.
        await persistUserIfNeeded()

        // Persist daysPerWeek before the gymProfile guard so it is always
        // written regardless of whether the user skipped the gym scan.
        UserDefaults.standard.set(profile.daysPerWeek, forKey: UserProfileConstants.daysPerWeekKey)

        // Re-entry guard (#318 U4): if a program was already generated for this
        // user (e.g. the app was killed between generation and onboarding
        // completion), reuse the cached mesocycle instead of paying for a
        // second skeleton LLM call.
        if let cached = Mesocycle.loadFromUserDefaults(), cached.userId == deps.resolvedUserId {
            isGenerating = false
            withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 6 }
            return
        }

        guard let gymProf = gymProfile else {
            // No gym profile — can't generate a valid program. Advance directly to ready.
            isGenerating = false
            withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 6 }
            return
        }

        do {
            // #423 / #369: resolve the real auth uid BEFORE stamping the program's
            // owner. `resolvedOwnerUserId()` returns nil when auth never resolved or
            // resolved only to the placeholder — in that case we keep the local cache
            // but skip the server write (never stamp a row we can't own). When it
            // resolves we use the SAME uid for the mesocycle owner and the server
            // persist so they match.
            let owner = await deps.resolvedOwnerUserId()
            let userId = owner ?? deps.resolvedUserId
            print("[OnboardingView] runProgramGeneration — training_days_per_week: \(profile.daysPerWeek)")
            let skeleton = try await deps.macroPlanService.generateSkeleton(
                userId: userId,
                gymProfile: gymProf,
                experienceLevel: profile.trainingAge.rawValue,
                goals: [profile.primaryGoal.rawValue],
                bodyweightKg: profile.bodyweightKg,
                ageYears: profile.age,
                trainingAge: profile.trainingAge.rawValue,
                trainingDaysPerWeek: profile.daysPerWeek
            )
            let mesocycle = MacroPlanService.buildPendingMesocycle(from: skeleton, userId: userId)
            // Cache immediately so ProgramViewModel.loadProgram() finds it on the fast path.
            mesocycle.saveToUserDefaults()
            // #423: persist to the server `programs` table under the resolved owner.
            // Best-effort — failure leaves the local cache intact and does NOT block
            // onboarding (mirrors ProgramViewModel.persistProgram's local-first spirit).
            // Without this the program lived only in UserDefaults and every later
            // workout FK-failed on workout_sessions_program_id_fkey.
            await OnboardingProgramPersist.persistIfOwnerResolved(
                mesocycle,
                owner: owner,
                client: deps.supabaseClient
            )
            isGenerating = false
            withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 6 }
        } catch {
            isGenerating = false
            generationError = error.localizedDescription
        }
    }

    /// Writes the user record to Supabase and stores the userId in Keychain if not already done.
    /// Also persists biometric fields to UserDefaults so they are available to WorkoutSessionManager
    /// without a Supabase round-trip during active sessions (FB-003).
    private func persistUserIfNeeded() async {
        let keychain = deps.keychainService

        // Persist biometrics to UserDefaults for fast in-session access. These are
        // not identity-keyed, so they are written regardless of session state.
        UserDefaults.standard.set(profile.bodyweightKg, forKey: UserProfileConstants.bodyweightKgKey)
        UserDefaults.standard.set(profile.heightCm, forKey: UserProfileConstants.heightCmKey)
        UserDefaults.standard.set(profile.age, forKey: UserProfileConstants.ageKey)
        UserDefaults.standard.set(profile.trainingAge.rawValue, forKey: UserProfileConstants.trainingAgeKey)
        UserDefaults.standard.set(profile.primaryGoal.rawValue, forKey: UserProfileConstants.primaryGoalKey)

        // #369 slice 3: the `users` row's id MUST be the anonymous-auth
        // `auth.uid()` so slice 5's RLS policy (`id = auth.uid()`) will match.
        // The session is established at launch (slice 1); onboarding runs after,
        // so await the slice-1 readiness to make sure the uid has resolved before
        // we read it. If it still hasn't (sign-in failed/timed out), skip the
        // insert and the `.userId` mirror — do NOT write a placeholder-keyed row
        // that slice 5's RLS would orphan; the next onboarding run retries.
        _ = await deps.supabaseAuth.awaitFirstResolution()
        guard let userId = UserIdentityResolver.onboardingUserId(
            keychain: keychain,
            placeholder: AppDependencies.placeholderUserId
        ) else { return }
        // Mirror the auth uid into `.userId` (first-run signal + secondary read).
        try? keychain.store(userId.uuidString, for: .userId)

        // Best-effort upsert into users table — ON CONFLICT (id) DO UPDATE so the
        // row the handle_new_user trigger pre-provisioned (bare id) is overwritten
        // with the full profile. Failure is non-fatal for onboarding.
        let nameStr = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userRow = UserInsertRow(
            id: userId,
            displayName: nameStr.isEmpty ? nil : nameStr,
            bodyweightKg: profile.bodyweightKg,
            heightCm: profile.heightCm,
            age: profile.age,
            trainingAge: profile.trainingAge.rawValue
        )
        try? await deps.supabaseClient.upsert(userRow, table: "users")

        // #147: hydrate trainee_models.model_json.goal via the
        // update-trainee-goal Edge Function. Best-effort — failure leaves
        // the iOS side reading GoalState.placeholder (cold-start fallback
        // until the next onboarding retry or DeveloperSettingsView reset).
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let goalPayload = TraineeGoalUpsertPayload(
            userId: userId,
            goal: GoalUpsertBody(
                statement: profile.primaryGoal.rawValue,
                focusAreas: [],
                updatedAt: isoFormatter.string(from: Date())
            ),
            acknowledgeTriggeringSessionCount: nil,
            stretchEdits: nil,
            acknowledgeCalibrationReview: nil
        )
        if let encoded = try? JSONEncoder().encode(goalPayload) {
            _ = try? await deps.supabaseClient.invokeFunction(
                "update-trainee-goal",
                body: encoded
            )
        }
    }

    private func completeOnboarding() {
        // Mark scan-skipped flag so SettingsView shows the persistent prompt.
        UserDefaults.standard.set(scanSkipped, forKey: OnboardingConstants.scanSkippedKey)
        // Mark onboarding as completed so subsequent launches skip this view.
        UserDefaults.standard.set(true, forKey: OnboardingConstants.onboardingCompletedKey)
        onCompleted?(gymProfile)
    }
}

// MARK: - Onboarding Program Persist (#423)

/// Resolve-before-stamp persist for the onboarding-generated program.
///
/// The onboarding path builds the skeleton + mesocycle and caches it in
/// UserDefaults, but historically never wrote it to the server `programs` table
/// (the server-persist lived only in `ProgramViewModel`). A fresh user therefore
/// had a cached program but ZERO server programs, so every workout FK-failed on
/// `workout_sessions_program_id_fkey` and `set_logs` RLS-failed (#423).
///
/// This helper writes the program to the server **only under a resolved real
/// owner uid** (the #369 owner-stamping rule). A nil owner (auth unresolved /
/// offline) or the placeholder uid is never persisted — the local cache is the
/// fallback and the next onboarding run / `loadProgram` retries. Failure is
/// best-effort: it never throws into the onboarding flow.
enum OnboardingProgramPersist {
    /// - Returns: `true` iff the server write succeeded under a real resolved owner.
    @discardableResult
    static func persistIfOwnerResolved(
        _ mesocycle: Mesocycle,
        owner: UUID?,
        client: SupabaseClient
    ) async -> Bool {
        // resolve-before-stamp: never persist a row we can't own.
        guard let owner, owner != AppDependencies.placeholderUserId else { return false }
        do {
            try await client.deactivateAndInsertProgram(mesocycle, userId: owner)
            return true
        } catch {
            // Best-effort — local cache is preserved; do NOT crash onboarding.
            return false
        }
    }
}

// MARK: - Onboarding Constants

enum OnboardingConstants {
    static let onboardingCompletedKey = "com.projectapex.onboardingCompleted"
    static let scanSkippedKey         = "com.projectapex.gymScanSkipped"
}

// MARK: - UserProfile UserDefaults Keys (FB-003)

/// Shared keys for storing user biometrics in UserDefaults.
/// Used by OnboardingView (write) and AppDependencies/WorkoutSessionManager (read).
enum UserProfileConstants {
    static let bodyweightKgKey  = "com.projectapex.user.bodyweightKg"
    static let heightCmKey      = "com.projectapex.user.heightCm"
    static let ageKey           = "com.projectapex.user.age"
    /// Biological sex used by the AI coach to calibrate first-session pressing
    /// loads. Stored lowercase ("male"/"female"); absent = unset (#494 PR4).
    static let sexKey           = "com.projectapex.user.sex"
    static let trainingAgeKey   = "com.projectapex.user.trainingAge"
    /// Primary training goal selected during onboarding (TrainingGoal.rawValue).
    /// Read by GenerationUserProfile.assemble as the fallback goal source when
    /// the trainee-model digest goal is not hydrated (#318 U4).
    static let primaryGoalKey   = "com.projectapex.user.primaryGoal"
    /// Number of training days per week selected during onboarding. Default 4 if absent.
    static let daysPerWeekKey   = "com.projectapex.user.daysPerWeek"
    /// Incremented after each completed workout session. 0 = no sessions ever completed.
    /// Used to show the first-session calibration banner (FB-005).
    static let sessionCountKey  = "com.projectapex.user.sessionCount"
}

// MARK: - UserInsertRow (local Codable for users table)

/// Codable row for inserting/updating public.users with all profile fields.
private struct UserInsertRow: Codable, Sendable {
    let id: UUID
    let displayName: String?
    let bodyweightKg: Double?
    let heightCm: Double?
    let age: Int?
    let trainingAge: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName  = "display_name"
        case bodyweightKg = "bodyweight_kg"
        case heightCm     = "height_cm"
        case age
        case trainingAge  = "training_age"
    }

    /// Omit nil fields rather than encoding them as JSON `null`. With the upsert
    /// (`resolution=merge-duplicates`) a `null` would overwrite a previously-set
    /// column on a re-onboard; omitting absent fields makes the merge additive.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(bodyweightKg, forKey: .bodyweightKg)
        try c.encodeIfPresent(heightCm, forKey: .heightCm)
        try c.encodeIfPresent(age, forKey: .age)
        try c.encodeIfPresent(trainingAge, forKey: .trainingAge)
    }
}

// MARK: - TraineeGoalUpsertPayload (#147: onboarding goal write)

/// Request body for the `update-trainee-goal` Edge Function. Mirrors the
/// validator contract in `supabase/functions/update-trainee-goal/index.ts`:
/// top-level `user_id` (UUID string) and `goal` object carrying the
/// GoalState shape (statement + focusAreas + ISO-8601 updatedAt).
///
/// `internal` (not `private`) so the EF-contract parity test can encode it
/// directly and assert the wire shape the validator accepts (#154).
struct TraineeGoalUpsertPayload: Codable, Sendable {
    let userId: UUID
    let goal: GoalUpsertBody
    /// P5-D06 Slice B (#258): OPTIONAL top-level field. When non-nil, the EF
    /// idempotently appends this triggering-session count to
    /// `model_json.acknowledgedTriggeringSessionCounts`. Onboarding always
    /// passes `nil` — the synthesized `encodeIfPresent` then OMITS the key,
    /// keeping the onboarding wire shape exactly `{user_id, goal}`.
    let acknowledgeTriggeringSessionCount: Int?
    /// #269 S4: OPTIONAL. Athlete-raised stretch targets from the
    /// calibration-review screen. When non-nil the EF applies an upward-only
    /// clamp on `model_json.projections.patternProjections`. Synthesized
    /// `encodeIfPresent` OMITS the key when nil, so other call sites keep their
    /// exact wire shape.
    let stretchEdits: [StretchEditBody]?
    /// #269 S4: OPTIONAL. When true, the EF durably sets
    /// `model_json.calibrationReviewAcknowledged = true` so the pre-workout
    /// calibration banner does not reappear after a session sync. Omitted from
    /// the wire when nil.
    let acknowledgeCalibrationReview: Bool?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case goal
        case acknowledgeTriggeringSessionCount = "acknowledge_triggering_session_count"
        case stretchEdits = "stretch_edits"
        case acknowledgeCalibrationReview = "acknowledge_calibration_review"
    }
}

/// #269 S4: a single athlete-raised stretch target. Mirrors the EF's
/// `StretchEdit` shape (`pattern` rawValue + `stretch` kg). The default
/// member-name CodingKeys match the validator's expected camelCase-free
/// `{pattern, stretch}` wire shape.
struct StretchEditBody: Codable, Sendable {
    let pattern: String
    let stretch: Double
}

/// `internal` (not `private`) so the EF-contract parity test can assert the
/// camelCase wire shape (`statement`/`focusAreas`/`updatedAt`) the validator
/// requires — adding snake_case CodingKeys here would BREAK the EF (#154).
struct GoalUpsertBody: Codable, Sendable {
    let statement: String
    let focusAreas: [String]
    let updatedAt: String
}

// MARK: - Preview

#Preview {
    OnboardingView(onCompleted: { _ in })
        .environment(AppDependencies())
}
