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
// On completion: UUID written to Keychain.userId; onboardingCompleted stored
// in UserDefaults so subsequent launches skip this view immediately.

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
    @State private var gymProfile: GymProfile? = nil
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
                                ForEach([3, 4, 5, 6], id: \.self) { n in
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
                    subtitle: "Allow notifications so the AI coach can alert you when your rest timer expires and remind you of upcoming sessions."
                )

                VStack(spacing: 14) {
                    notifFeatureRow(icon: "timer", label: "Rest timer alerts — never lose track of your rest")
                    notifFeatureRow(icon: "calendar.badge.clock", label: "Session reminders — train on schedule")
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
                        Text("The AI coach is designing your 12-week periodized program.\nThis usually takes under a minute.")
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
                        Text("Welcome, \(name.isEmpty ? "Athlete" : name). Your 12-week program is loaded. Head to the Program tab to review it, then start your first session.")
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

        guard let gymProf = gymProfile else {
            // No gym profile — can't generate a valid program. Advance directly to ready.
            isGenerating = false
            withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) { step = 6 }
            return
        }

        do {
            let userId = deps.resolvedUserId.uuidString
            let userProfile = UserProfile(
                userId: userId,
                experienceLevel: profile.trainingAge.rawValue,
                goals: [profile.primaryGoal.rawValue],
                bodyweightKg: profile.bodyweightKg,
                ageYears: profile.age
            )
            print("[OnboardingView] runProgramGeneration — training_days_per_week: \(profile.daysPerWeek)")
            let mesocycle = try await deps.programGenerationService.generate(
                userProfile: userProfile,
                gymProfile: gymProf,
                trainingDaysPerWeek: profile.daysPerWeek
            )
            // Cache immediately so ProgramViewModel.loadProgram() finds it on the fast path.
            mesocycle.saveToUserDefaults()
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
        // If userId is already stored, nothing to do for the Keychain+Supabase write —
        // but still persist any updated biometrics to UserDefaults.
        let isNewUser: Bool
        if let existing = try? keychain.retrieve(.userId), !existing.isEmpty {
            isNewUser = false
        } else {
            isNewUser = true
        }

        let userId: UUID
        if isNewUser {
            userId = UUID()
            try? keychain.store(userId.uuidString, for: .userId)
        } else {
            userId = deps.resolvedUserId
        }

        // Persist biometrics to UserDefaults for fast in-session access.
        UserDefaults.standard.set(profile.bodyweightKg, forKey: UserProfileConstants.bodyweightKgKey)
        UserDefaults.standard.set(profile.heightCm, forKey: UserProfileConstants.heightCmKey)
        UserDefaults.standard.set(profile.age, forKey: UserProfileConstants.ageKey)
        UserDefaults.standard.set(profile.trainingAge.rawValue, forKey: UserProfileConstants.trainingAgeKey)

        // Best-effort upsert into users table — failure is non-fatal for onboarding.
        let nameStr = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userRow = UserInsertRow(
            id: userId,
            displayName: nameStr.isEmpty ? nil : nameStr,
            bodyweightKg: profile.bodyweightKg,
            heightCm: profile.heightCm,
            age: profile.age,
            trainingAge: profile.trainingAge.rawValue
        )
        try? await deps.supabaseClient.insert(userRow, table: "users")
    }

    private func completeOnboarding() {
        // Mark scan-skipped flag so SettingsView shows the persistent prompt.
        UserDefaults.standard.set(scanSkipped, forKey: OnboardingConstants.scanSkippedKey)
        // Mark onboarding as completed so subsequent launches skip this view.
        UserDefaults.standard.set(true, forKey: OnboardingConstants.onboardingCompletedKey)
        onCompleted?(gymProfile)
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
    static let trainingAgeKey   = "com.projectapex.user.trainingAge"
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
}

// MARK: - Preview

#Preview {
    OnboardingView(onCompleted: { _ in })
        .environment(AppDependencies())
}
