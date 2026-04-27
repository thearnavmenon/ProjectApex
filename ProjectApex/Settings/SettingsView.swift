// SettingsView.swift
// ProjectApex — Settings Feature
//
// Top-level Settings screen accessible from the main tab bar.
// Surfaces:
//   • Profile section → bodyweight, height, age, training age (FB-003)
//   • Equipment section → edit/delete items, add new, re-scan gym
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
    var onRegenerateProgram: (() -> Void)? = nil

    /// Called when the user modifies their equipment list.
    /// The updated GymProfile is passed so ContentView can persist it.
    var onEquipmentChanged: ((GymProfile) -> Void)? = nil

    /// True while program generation is in-flight — drives the progress HUD.
    var isRegenerating: Bool = false

    /// If non-nil, an error alert is shown with this message.
    var regenerateErrorMessage: String? = nil

    /// Called after a developer reset so ContentView can return to onboarding.
    var onResetAll: (() -> Void)? = nil

    // MARK: - Local mutable equipment list

    /// Working copy of the equipment list. Seeded from confirmedProfile on appear.
    @State private var equipmentItems: [EquipmentItem] = []

    @State private var showingRescanAlert = false
    @State private var showingRegenerateSheet = false
    @State private var showingBulkPicker = false
    @State private var equipmentChangedSinceLastRegenerate = false

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
            equipmentSection
            if confirmedProfile != nil {
                programSection
            }
            developerSection
            aboutSection
        }
        .onAppear {
            loadBiometricsFromDefaults()
            if let profile = confirmedProfile {
                equipmentItems = profile.equipment
            }
        }
        .onChange(of: confirmedProfile) { _, newProfile in
            // Sync if the profile is replaced externally (e.g. after re-scan).
            if let profile = newProfile {
                equipmentItems = profile.equipment
            }
        }
        .navigationTitle("Settings")
        .overlay {
            if isRegenerating {
                generatingOverlay
            }
        }
        .sheet(isPresented: $showingBulkPicker) {
            BulkEquipmentPickerSheet(
                alreadyAdded: Set(equipmentItems.map { $0.equipmentType }),
                onConfirm: { newItems in
                    equipmentItems.append(contentsOf: newItems)
                    showingBulkPicker = false
                    commitEquipmentChanges()
                    equipmentChangedSinceLastRegenerate = true
                },
                onCancel: {
                    showingBulkPicker = false
                }
            )
        }
        .sheet(isPresented: $showingRegenerateSheet) {
            regenerateConfirmationSheet
        }
        .alert("Re-scan Gym?", isPresented: $showingRescanAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Re-scan", role: .destructive) {
                onRescan?()
            }
        } message: {
            Text("This will replace your current equipment profile. Are you sure?")
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

    // MARK: - Equipment Section

    /// Full equipment list with add/delete/re-scan controls.
    @ViewBuilder
    private var equipmentSection: some View {
        if hasExistingProfile {
            Section {
                ForEach($equipmentItems) { $item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: item.equipmentType.category.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(item.equipmentType.displayName)
                            Spacer()
                            if !item.detectedByVision {
                                Text("Manual")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        // Bodyweight-only toggle for pull-up bars, dip stations, etc.
                        if item.equipmentType.isNaturallyBodyweightOnly {
                            Toggle(isOn: $item.bodyweightOnly) {
                                Text("Bodyweight Only")
                                    .font(.caption)
                                    .foregroundStyle(item.bodyweightOnly ? .orange : .secondary)
                            }
                            .tint(.orange)
                            .onChange(of: item.bodyweightOnly) { _, _ in
                                commitEquipmentChanges()
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    deleteEquipment(at: indexSet)
                }

                // Add Equipment
                Button {
                    showingBulkPicker = true
                } label: {
                    Label("Add Equipment", systemImage: "plus.circle")
                        .foregroundStyle(.blue)
                }

                // Re-scan
                Button {
                    showingRescanAlert = true
                } label: {
                    Label("Re-scan Gym", systemImage: "camera.viewfinder")
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("Equipment")
            } footer: {
                Text("Swipe left on any item to remove it. Changes are saved immediately.")
            }
        } else {
            Section("Equipment") {
                Button {
                    onScanFirst?()
                } label: {
                    Label("Scan Your Gym", systemImage: "camera.viewfinder")
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - Equipment Helpers

    private func deleteEquipment(at indexSet: IndexSet) {
        let removedTypes = indexSet.map { equipmentItems[$0].equipmentType }

        // Check if any removed equipment appears in the current programme
        let programEquipment = currentProgramEquipmentTypes()
        let affectsProgram = removedTypes.contains { programEquipment.contains($0) }

        equipmentItems.remove(atOffsets: indexSet)
        commitEquipmentChanges()
        equipmentChangedSinceLastRegenerate = true

        if affectsProgram {
            // Non-blocking informational message surfaced via the footer is sufficient;
            // the note is static in the footer. Deletes are already committed.
            // Additional per-deletion alert could be added here if needed.
            _ = affectsProgram // suppress unused warning
        }
    }

    /// Commits the current equipmentItems back to the confirmedProfile and notifies the parent.
    private func commitEquipmentChanges() {
        guard var updated = confirmedProfile else { return }
        updated.equipment = equipmentItems
        updated.lastUpdatedAt = Date()
        onEquipmentChanged?(updated)
    }

    /// Returns the set of EquipmentTypes currently referenced in the user's programme.
    private func currentProgramEquipmentTypes() -> Set<EquipmentType> {
        guard let data = UserDefaults.standard.data(forKey: "com.projectapex.activeProgram"),
              let mesocycle = try? JSONDecoder.workoutProgram.decode(Mesocycle.self, from: data)
        else { return [] }
        let types = mesocycle.weeks.flatMap { $0.trainingDays }
            .flatMap { $0.exercises }
            .map { $0.equipmentRequired }
        return Set(types)
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

    /// Program management section — only shown when a gym profile exists.
    private var programSection: some View {
        Section("Program") {
            Button {
                showingRegenerateSheet = true
            } label: {
                Label("Regenerate Program", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(isRegenerating ? .secondary : .primary)
            }
            .disabled(isRegenerating)
        }
    }

    // MARK: - Regenerate Confirmation Sheet

    /// Bottom sheet confirming regeneration. Makes clear that history is preserved
    /// and notes if the equipment list has changed since the last generation.
    private var regenerateConfirmationSheet: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("Regenerate Program?")
                        .font(.title3.bold())
                }

                VStack(alignment: .leading, spacing: 10) {
                    // Always-present preservation guarantee
                    Label {
                        Text("Your completed workouts will be preserved. Your programme will continue from your next scheduled session.")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }

                    Label {
                        Text("Your workout history, lift progression, and AI memory are never deleted.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.secondary)
                    }

                    // Conditional: only shown when equipment was edited
                    if equipmentChangedSinceLastRegenerate {
                        Label {
                            Text("Your programme will be updated to reflect your current equipment list.")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        } icon: {
                            Image(systemName: "dumbbell.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 4)

                Divider()

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        showingRegenerateSheet = false
                        equipmentChangedSinceLastRegenerate = false
                        onRegenerateProgram?()
                    } label: {
                        Text("Regenerate")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cancel", role: .cancel) {
                        showingRegenerateSheet = false
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private var developerSection: some View {
        Section("Developer") {
            #if DEBUG
            NavigationLink(destination: DeveloperSettingsView(onResetAll: onResetAll)) {
                Label("Developer Settings", systemImage: "key.fill")
            }
            #endif
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
        SettingsView(
            hasExistingProfile: true,
            onRescan: { },
            confirmedProfile: GymProfile.mockProfile(),
            onEquipmentChanged: { _ in }
        )
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
