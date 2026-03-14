// SettingsView.swift
// ProjectApex — Settings Feature
//
// Top-level Settings screen accessible from the main tab bar.
// Surfaces:
//   • Profile section → bodyweight, height, age, training age (FB-003)
//   • Gym section → "Scan Your Gym" (first-time) or "Re-scan Gym" (P1-T06)
//   • Program section → "Regenerate Program" (P2-T08)
//   • Developer row → DeveloperSettingsView (API key management)

import SwiftUI

struct SettingsView: View {

    /// Set to true when the user has an existing GymProfile. Controls
    /// whether "Re-scan Gym" vs "Scan Your Gym" is shown.
    var hasExistingProfile: Bool = false

    /// Called when the user confirms they want to start a fresh re-scan.
    var onRescan: (() -> Void)? = nil

    /// Called when the user taps "Scan Your Gym" (no profile yet).
    var onScanFirst: (() -> Void)? = nil

    /// The confirmed profile, used to show the equipment count chip
    /// and to enable the regenerate action.
    var confirmedProfile: GymProfile? = nil

    /// Called when the user confirms "Regenerate Program".
    /// Passes the current GymProfile so the caller can trigger generation.
    var onRegenerateProgram: (() -> Void)? = nil

    /// True while program generation is in-flight — drives the progress HUD.
    var isRegenerating: Bool = false

    /// If non-nil, an error alert is shown with this message.
    var regenerateErrorMessage: String? = nil

    @State private var showingRescanAlert = false
    @State private var showingRegenerateAlert = false

    // FB-003: Editable biometric fields — backed directly by UserDefaults.
    @State private var bodyweightText: String = ""
    @State private var heightText: String = ""
    @State private var ageText: String = ""
    @State private var trainingAge: TrainingAge = .beginner

    /// True when the user skipped the gym scan during onboarding — drives the setup prompt.
    private var gymScanSkipped: Bool {
        UserDefaults.standard.bool(forKey: OnboardingConstants.scanSkippedKey)
    }

    var body: some View {
        Form {
            // Persistent "Complete your setup" prompt — visible only if gym scan was skipped.
            if gymScanSkipped && !hasExistingProfile {
                setupPromptSection
            }
            profileSection
            gymSection
            if confirmedProfile != nil {
                programSection
            }
            developerSection
            aboutSection
        }
        .onAppear { loadBiometricsFromDefaults() }
        .navigationTitle("Settings")
        .overlay {
            if isRegenerating {
                generatingOverlay
            }
        }
        .alert("Re-scan Gym?", isPresented: $showingRescanAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Re-scan", role: .destructive) {
                onRescan?()
            }
        } message: {
            Text("This will replace your current equipment profile. Are you sure?")
        }
        .alert("Regenerate Program?", isPresented: $showingRegenerateAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Regenerate", role: .destructive) {
                onRegenerateProgram?()
            }
        } message: {
            Text("This will replace your current 12-week program. All future sessions will be reset. Are you sure?")
        }
        .alert(
            "Generation Failed",
            isPresented: Binding(
                get: { regenerateErrorMessage != nil },
                set: { _ in }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(regenerateErrorMessage ?? "")
        }
    }

    // MARK: - Sections

    /// Persistent setup prompt shown when the gym scan was skipped during onboarding.
    private var setupPromptSection: some View {
        Section {
            Button {
                onScanFirst?()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Complete your setup")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Scan your gym so the AI coach can tailor your program to available equipment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Action Required")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Profile Section (FB-003)

    /// Editable user biometric fields — updated in real time to UserDefaults.
    private var profileSection: some View {
        Section {
            // Bodyweight
            HStack {
                Label("Bodyweight", systemImage: "scalemass")
                Spacer()
                TextField("e.g. 80", text: $bodyweightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .onChange(of: bodyweightText) { _, v in
                        let kg = Double(v.replacingOccurrences(of: ",", with: "."))
                        UserDefaults.standard.set(kg, forKey: UserProfileConstants.bodyweightKgKey)
                    }
                Text("kg").foregroundStyle(.secondary)
            }

            // Height
            HStack {
                Label("Height", systemImage: "ruler")
                Spacer()
                TextField("e.g. 178", text: $heightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .onChange(of: heightText) { _, v in
                        let cm = Double(v.replacingOccurrences(of: ",", with: "."))
                        UserDefaults.standard.set(cm, forKey: UserProfileConstants.heightCmKey)
                    }
                Text("cm").foregroundStyle(.secondary)
            }

            // Age
            HStack {
                Label("Age", systemImage: "person.fill")
                Spacer()
                TextField("e.g. 28", text: $ageText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .onChange(of: ageText) { _, v in
                        let age = Int(v)
                        UserDefaults.standard.set(age, forKey: UserProfileConstants.ageKey)
                    }
                Text("yrs").foregroundStyle(.secondary)
            }

            // Training age
            Picker("Experience", selection: $trainingAge) {
                ForEach(TrainingAge.allCases, id: \.self) { age in
                    Text(age.rawValue).tag(age)
                }
            }
            .onChange(of: trainingAge) { _, v in
                UserDefaults.standard.set(v.rawValue, forKey: UserProfileConstants.trainingAgeKey)
            }
        } header: {
            Text("Training Profile")
        } footer: {
            Text("Used by the AI coach to calibrate weight prescriptions for your first session and beyond.")
        }
    }

    private func loadBiometricsFromDefaults() {
        let defaults = UserDefaults.standard
        if let bw = defaults.object(forKey: UserProfileConstants.bodyweightKgKey) as? Double {
            bodyweightText = bw.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", bw)
                : String(format: "%.1f", bw)
        }
        if let h = defaults.object(forKey: UserProfileConstants.heightCmKey) as? Double {
            heightText = h.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", h)
                : String(format: "%.1f", h)
        }
        if let a = defaults.object(forKey: UserProfileConstants.ageKey) as? Int {
            ageText = String(a)
        }
        if let ta = defaults.string(forKey: UserProfileConstants.trainingAgeKey),
           let match = TrainingAge.allCases.first(where: { $0.rawValue == ta }) {
            trainingAge = match
        }
    }

    /// Gym management section — always visible; content adapts to profile state.
    private var gymSection: some View {
        Section("Gym") {
            if hasExistingProfile {
                // Profile summary row
                if let profile = confirmedProfile {
                    HStack {
                        Label("Equipment", systemImage: "dumbbell.fill")
                        Spacer()
                        Text("\(profile.equipment.count) items")
                            .foregroundStyle(.secondary)
                    }
                }
                // Re-scan
                Button {
                    showingRescanAlert = true
                } label: {
                    Label("Re-scan Gym", systemImage: "camera.viewfinder")
                        .foregroundStyle(.primary)
                }
            } else {
                // First-time scan CTA
                Button {
                    onScanFirst?()
                } label: {
                    Label("Scan Your Gym", systemImage: "camera.viewfinder")
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    /// Program management section — only shown when a gym profile exists.
    private var programSection: some View {
        Section("Program") {
            Button {
                showingRegenerateAlert = true
            } label: {
                Label("Regenerate Program", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(isRegenerating ? .secondary : .primary)
            }
            .disabled(isRegenerating)
        }
    }

    private var developerSection: some View {
        Section("Developer") {
            NavigationLink(destination: DeveloperSettingsView()) {
                Label("Developer Settings", systemImage: "key.fill")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Generating Overlay

    private var generatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)

                Text("Regenerating Program…")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                Text("The AI coach is building your new 12-week program.\nThis may take up to a minute.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.70))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#Preview("With profile") {
    NavigationStack {
        SettingsView(hasExistingProfile: true, onRescan: { })
    }
    .preferredColorScheme(.dark)
}

#Preview("No profile") {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Regenerating") {
    NavigationStack {
        SettingsView(
            hasExistingProfile: true,
            confirmedProfile: GymProfile.mockProfile(),
            isRegenerating: true
        )
    }
    .preferredColorScheme(.dark)
}
