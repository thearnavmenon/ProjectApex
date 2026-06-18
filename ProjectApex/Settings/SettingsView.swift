// SettingsView.swift
// ProjectApex — Settings Feature
//
// Top-level Settings screen accessible from the main tab bar.
// Surfaces:
//   • Profile section → bodyweight, height, age, training age (FB-003)
//   • Equipment section → edit/delete items, add new, re-scan gym
//   • Program section → "Regenerate Program" (P2-T08)
//   • Developer row → DeveloperSettingsView (API key management)
//
// Visual identity: Brutalist Athletic (#494). Pure-black surfaces, condensed
// tabular numerals, volt-lime accent reserved for additive/commit actions only.
// The screen stays a `List` so swipe-to-delete on equipment keeps working.

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

    /// Shared ProgramViewModel — forwarded to DeveloperSettingsView for force-sync.
    var programViewModel: ProgramViewModel? = nil

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
        List {
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Apex.bg.ignoresSafeArea())
        .tint(Apex.accent)
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
        .toolbarBackground(Apex.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Apex.amber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Complete your setup")
                            .font(.system(size: 16, weight: .bold))
                            .fontWidth(.condensed)
                            .foregroundStyle(Apex.text)
                        Text("Scan your gym so the AI coach can tailor your program to available equipment.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Apex.textDim)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(rowBackground)
            .listRowSeparatorTint(Apex.hairline)
        } header: {
            ApexSectionLabel(text: "Action Required", color: Apex.amber)
        }
    }

    // MARK: - Equipment Section

    /// Full equipment list with add/delete/re-scan controls.
    @ViewBuilder
    private var equipmentSection: some View {
        if hasExistingProfile {
            Section {
                ForEach($equipmentItems) { $item in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 13) {
                            boxedIcon(item.equipmentType.category.systemImage)
                            Text(item.equipmentType.displayName)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Apex.text)
                            Spacer()
                            if !item.detectedByVision {
                                Text("Manual")
                                    .font(.system(size: 11, weight: .semibold))
                                    .textCase(.uppercase)
                                    .tracking(0.8)
                                    .foregroundStyle(Apex.textFaint)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().stroke(Apex.hairline, lineWidth: 1))
                            }
                        }
                        // Loadable / Bodyweight mode control for pull-up bars, dip stations, etc.
                        if item.equipmentType.isNaturallyBodyweightOnly {
                            BodyweightModeControl(bodyweightOnly: $item.bodyweightOnly)
                                .padding(.leading, 43)
                                .onChange(of: item.bodyweightOnly) { _, _ in
                                    commitEquipmentChanges()
                                }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(rowBackground)
                    .listRowSeparatorTint(Apex.hairline)
                }
                .onDelete { indexSet in
                    deleteEquipment(at: indexSet)
                }

                // Add Equipment — lime accent (additive action).
                Button {
                    showingBulkPicker = true
                } label: {
                    actionRowLabel(icon: "plus.circle", title: "Add Equipment", tint: Apex.accent)
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(Apex.hairline)

                // Re-scan — neutral / off-accent (opens a destructive confirm).
                Button {
                    showingRescanAlert = true
                } label: {
                    actionRowLabel(icon: "camera.viewfinder", title: "Re-scan Gym", tint: Apex.text)
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(Apex.hairline)
            } header: {
                ApexSectionLabel(text: "Equipment · \(equipmentItems.count)")
            } footer: {
                footerText("Swipe left on any item to remove it. Changes are saved immediately.")
            }
        } else {
            Section {
                Button {
                    onScanFirst?()
                } label: {
                    actionRowLabel(icon: "camera.viewfinder", title: "Scan Your Gym", tint: Apex.text)
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(Apex.hairline)
            } header: {
                ApexSectionLabel(text: "Equipment")
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
            biometricRow(icon: "scalemass", title: "Bodyweight",
                         text: $bodyweightText, unit: "kg", keyboard: .decimalPad) { v in
                let kg = Double(v.replacingOccurrences(of: ",", with: "."))
                UserDefaults.standard.set(kg, forKey: UserProfileConstants.bodyweightKgKey)
            }

            // Height
            biometricRow(icon: "ruler", title: "Height",
                         text: $heightText, unit: "cm", keyboard: .decimalPad) { v in
                let cm = Double(v.replacingOccurrences(of: ",", with: "."))
                UserDefaults.standard.set(cm, forKey: UserProfileConstants.heightCmKey)
            }

            // Age
            biometricRow(icon: "person.fill", title: "Age",
                         text: $ageText, unit: "yrs", keyboard: .numberPad) { v in
                let age = Int(v)
                UserDefaults.standard.set(age, forKey: UserProfileConstants.ageKey)
            }

            // Training age
            HStack(spacing: 13) {
                boxedIcon("chart.bar.fill")
                Picker("Experience", selection: $trainingAge) {
                    ForEach(TrainingAge.allCases, id: \.self) { age in
                        Text(age.rawValue).tag(age)
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .tint(Apex.textDim)
            }
            .onChange(of: trainingAge) { _, v in
                UserDefaults.standard.set(v.rawValue, forKey: UserProfileConstants.trainingAgeKey)
            }
            .listRowBackground(rowBackground)
            .listRowSeparatorTint(Apex.hairline)
        } header: {
            ApexSectionLabel(text: "Training Profile")
        } footer: {
            footerText("Used by the AI coach to calibrate weight prescriptions for your first session and beyond.")
        }
    }

    /// A single editable biometric row: leading icon + title, big condensed
    /// right-aligned tabular numeral input, dim unit suffix.
    private func biometricRow(
        icon: String,
        title: String,
        text: Binding<String>,
        unit: String,
        keyboard: UIKeyboardType,
        onChange: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 13) {
            boxedIcon(icon)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Apex.text)
            Spacer()
            TextField("", text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(Apex.numeral(24, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .frame(width: 84)
                .onChange(of: text.wrappedValue) { _, v in onChange(v) }
            Text(unit)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Apex.textFaint)
        }
        .listRowBackground(rowBackground)
        .listRowSeparatorTint(Apex.hairline)
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
        Section {
            Button {
                showingRegenerateSheet = true
            } label: {
                actionRowLabel(
                    icon: "arrow.clockwise.circle",
                    title: "Regenerate Program",
                    tint: isRegenerating ? Apex.textDim : Apex.text
                )
            }
            .disabled(isRegenerating)
            .listRowBackground(rowBackground)
            .listRowSeparatorTint(Apex.hairline)
        } header: {
            ApexSectionLabel(text: "Program")
        }
    }

    // MARK: - Regenerate Confirmation Sheet

    /// Bottom sheet confirming regeneration. Makes clear that history is preserved
    /// and notes if the equipment list has changed since the last generation.
    private var regenerateConfirmationSheet: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Apex.textFaint)
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Apex.accent)
                    Text("Regenerate Program?")
                        .font(.system(size: 24, weight: .black))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                }

                VStack(alignment: .leading, spacing: 14) {
                    // Always-present preservation guarantee
                    guaranteeRow(
                        icon: "checkmark.seal.fill",
                        iconTint: Apex.accent,
                        text: "Your completed workouts will be preserved. Your programme will continue from your next scheduled session.",
                        textColor: Apex.text
                    )

                    guaranteeRow(
                        icon: "brain.head.profile",
                        iconTint: Apex.textDim,
                        text: "Your workout history, lift progression, and AI memory are never deleted.",
                        textColor: Apex.textDim
                    )

                    // Conditional: only shown when equipment was edited
                    if equipmentChangedSinceLastRegenerate {
                        guaranteeRow(
                            icon: "dumbbell.fill",
                            iconTint: Apex.amber,
                            text: "Your programme will be updated to reflect your current equipment list.",
                            textColor: Apex.amber
                        )
                    }
                }
                .padding(.vertical, 2)

                Rectangle()
                    .fill(Apex.hairline)
                    .frame(height: 1)

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        showingRegenerateSheet = false
                        equipmentChangedSinceLastRegenerate = false
                        onRegenerateProgram?()
                    } label: {
                        ApexButton(title: "Regenerate", icon: "arrow.clockwise")
                    }

                    Button {
                        showingRegenerateSheet = false
                    } label: {
                        ApexButton(title: "Cancel", kind: .ghost, tint: Apex.textDim)
                    }
                }
            }
            .padding(.horizontal, Apex.pad)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Apex.bg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    /// One preservation/guarantee line in the regenerate sheet.
    private func guaranteeRow(icon: String, iconTint: Color, text: String, textColor: Color) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var developerSection: some View {
        #if DEBUG
        Section {
            NavigationLink(destination: DeveloperSettingsView(onResetAll: onResetAll, programViewModel: programViewModel)) {
                actionRowLabel(icon: "key.fill", title: "Developer Settings", tint: Apex.text)
            }
            .listRowBackground(rowBackground)
            .listRowSeparatorTint(Apex.hairline)
        } header: {
            ApexSectionLabel(text: "Developer")
        }
        #endif
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Apex.text)
                Spacer()
                Text(appVersion)
                    .font(Apex.numeral(15, weight: .bold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textDim)
            }
            .listRowBackground(rowBackground)
            .listRowSeparatorTint(Apex.hairline)
        } header: {
            ApexSectionLabel(text: "About")
        }
    }

    // MARK: - Generating Overlay

    private var generatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Apex.accent)
                    .scaleEffect(1.4)

                Text("Regenerating Program…")
                    .font(.system(size: 18, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)

                Text("The AI coach is building your new 12-week program.\nThis may take up to a minute.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Apex.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(32)
            .apexCard()
        }
    }

    // MARK: - Row Atoms

    /// The card-style fill behind each list row.
    private var rowBackground: some View {
        Apex.surface
    }

    /// Attribute-row leading icon in a sharp-cornered chip — echoes the 4pt signature.
    private func boxedIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Apex.textDim)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(Apex.hairline, lineWidth: 1))
    }

    /// Standard tappable action row: plain icon + title, tinted together.
    private func actionRowLabel(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    /// Section footer styling — faint condensed caption.
    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Apex.textFaint)
    }

    // MARK: - Helpers

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - Bodyweight mode control
//
// Two-cell segmented control replacing the old amber "Bodyweight Only" toggle.
// BODYWEIGHT selected == `bodyweightOnly == true`. Ported from the prototype's
// `SegmentedTwo`, baked to the Brutalist identity (no Direction parameter).
// Kept local to Settings — it is not a shared design-system atom.
private struct BodyweightModeControl: View {
    @Binding var bodyweightOnly: Bool

    var body: some View {
        HStack(spacing: 0) {
            cell("Loadable", selected: !bodyweightOnly) { bodyweightOnly = false }
            Rectangle().fill(Apex.hairline).frame(width: 1)
            cell("Bodyweight", selected: bodyweightOnly) { bodyweightOnly = true }
        }
        .background(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .stroke(Apex.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
    }

    private func cell(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.9)
                .fontWidth(.condensed)
                .foregroundStyle(selected ? Apex.onAccent : Apex.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Apex.accent : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
