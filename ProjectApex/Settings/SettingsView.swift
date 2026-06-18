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

    /// Injected app dependencies — used to fetch calibration projections on
    /// demand for the "Review targets" sheet. Flows in from the app-root
    /// `.environment(deps)`; sheets inherit it, so no ContentView change needed.
    @Environment(AppDependencies.self) private var deps

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
    /// Biological sex stored lowercase ("male"/"female") in `UserProfileConstants.sexKey`.
    /// nil = unset; existing users keep their current (sex-agnostic) coach behaviour (#494 PR4).
    @State private var sex: String? = nil
    @State private var trainingAge: TrainingAge = .beginner

    // #494 PR3: Program controls.
    /// Training days per week — backed by `UserProfileConstants.daysPerWeekKey`.
    /// Applied on the user's NEXT regenerate (program generation reads this key);
    /// changing it here does NOT auto-regenerate. Clamped 2–6, default 4.
    @State private var daysPerWeek: Int = 4
    @State private var showGoalReview = false
    @State private var showCalibrationReview = false
    /// Projections fetched on demand when "Review targets" is tapped.
    @State private var calibrationProjections: [PatternProjection] = []

    // #494 PR5: release-safe full reset.
    /// Controls the destructive "Reset all data" confirmation alert.
    @State private var showResetAllConfirmation = false

    private static let daysPerWeekRange = 2...6

    /// Destructive-action red. The production design system has no danger token
    /// (lime stays reserved for additive/commit actions), so this destructive row
    /// defines its own red locally rather than adding to the shared DesignSystem.
    private let dangerRed = Color(red: 0.92, green: 0.30, blue: 0.30)

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
            dataSection
            aboutSection
        }
        .listStyle(.plain)
        .listSectionSpacing(20)
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
        .sheet(isPresented: $showGoalReview) {
            // Standalone use (no banner): GoalReviewView reads `deps` from the
            // environment, inherited through the sheet.
            GoalReviewView(triggeringSessionCount: nil)
                .presentationDetents([.large])
                .presentationCornerRadius(24)
        }
        .sheet(isPresented: $showCalibrationReview) {
            // Renders the current per-pattern targets fetched on demand. Empty
            // when no projections exist yet — the screen shows its own empty state.
            CalibrationReviewView(projections: calibrationProjections, recalibratedPatterns: [])
                .presentationDetents([.large])
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
        // #494 PR5: release-safe full reset confirmation.
        .alert("Reset all data?", isPresented: $showResetAllConfirmation) {
            Button("Reset", role: .destructive) {
                Task {
                    await performFullDataReset(deps: deps)
                    onResetAll?()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This erases your profile, program, and history on this device. This can't be undone.")
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
            .settingsCardRow(.single)
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
                    .settingsCardRow(equipmentItems.first?.id == item.id ? .first : .middle)
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
                .settingsCardRow(.middle)

                // Re-scan — neutral / off-accent (opens a destructive confirm).
                Button {
                    showingRescanAlert = true
                } label: {
                    actionRowLabel(icon: "camera.viewfinder", title: "Re-scan Gym", tint: Apex.text)
                }
                .settingsCardRow(.last)
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
                .settingsCardRow(.single)
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
            biometricRow(icon: "scalemass", title: "Bodyweight", pos: .first,
                         text: $bodyweightText, unit: "kg", keyboard: .decimalPad) { v in
                let kg = Double(v.replacingOccurrences(of: ",", with: "."))
                UserDefaults.standard.set(kg, forKey: UserProfileConstants.bodyweightKgKey)
            }

            // Height
            biometricRow(icon: "ruler", title: "Height", pos: .middle,
                         text: $heightText, unit: "cm", keyboard: .decimalPad) { v in
                let cm = Double(v.replacingOccurrences(of: ",", with: "."))
                UserDefaults.standard.set(cm, forKey: UserProfileConstants.heightCmKey)
            }

            // Age
            biometricRow(icon: "person.fill", title: "Age", pos: .middle,
                         text: $ageText, unit: "yrs", keyboard: .numberPad) { v in
                let age = Int(v)
                UserDefaults.standard.set(age, forKey: UserProfileConstants.ageKey)
            }

            // Sex — stored lowercase ("male"/"female"); nil = unset (#494 PR4).
            HStack(spacing: 13) {
                boxedIcon("figure.stand")
                Picker("Sex", selection: $sex) {
                    Text("Male").tag(String?.some("male"))
                    Text("Female").tag(String?.some("female"))
                }
                .font(.system(size: 16, weight: .medium))
                .tint(Apex.textDim)
            }
            .onChange(of: sex) { _, v in
                UserDefaults.standard.set(v, forKey: UserProfileConstants.sexKey)
            }
            .settingsCardRow(.middle)

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
            .settingsCardRow(.last)
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
        pos: SettingsCardPos,
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
        .settingsCardRow(pos)
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
        sex = defaults.string(forKey: UserProfileConstants.sexKey)
        if let ta = defaults.string(forKey: UserProfileConstants.trainingAgeKey),
           let match = TrainingAge.allCases.first(where: { $0.rawValue == ta }) {
            trainingAge = match
        }

        // #494 PR3: default 4 when absent or non-positive (integer(forKey:)
        // returns 0 for a missing key), then clamp into the valid 2–6 range.
        let stored = defaults.integer(forKey: UserProfileConstants.daysPerWeekKey)
        daysPerWeek = (stored <= 0 ? 4 : stored)
            .clamped(to: Self.daysPerWeekRange)
    }

    /// Program management section — only shown when a gym profile exists.
    private var programSection: some View {
        Section {
            // Training days — adjusts the next regenerate (does not auto-regen).
            HStack(spacing: 13) {
                boxedIcon("calendar")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Training days")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Apex.text)
                    Text("per week")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Apex.textFaint)
                }
                Spacer()
                DaysStepper(value: $daysPerWeek, range: Self.daysPerWeekRange)
                    .onChange(of: daysPerWeek) { _, v in
                        UserDefaults.standard.set(v, forKey: UserProfileConstants.daysPerWeekKey)
                    }
            }
            .settingsCardRow(.first)

            // Goal & focus — presents the goal-review screen.
            Button {
                showGoalReview = true
            } label: {
                navRowLabel(icon: "flag.fill", title: "Goal & focus")
            }
            .settingsCardRow(.middle)

            // Review targets — fetches current projections, then presents them.
            Button {
                Task { await presentCalibrationReview() }
            } label: {
                navRowLabel(icon: "scope", title: "Review targets")
            }
            .settingsCardRow(.middle)

            // Regenerate Program.
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
            .settingsCardRow(.last)
        } header: {
            ApexSectionLabel(text: "Program")
        } footer: {
            footerText("Changing your training days or goal updates your next regenerate.")
        }
    }

    /// Fetches the current per-pattern projections from the cached trainee model
    /// and presents the calibration-review screen. The projections live on the
    /// model regardless of banner-ack state, so this surfaces current targets at
    /// any time (unlike the digest's `calibrationReviewSignal`, which is gated on
    /// a pending review). Sorted by pattern for deterministic ordering, matching
    /// the signal-derivation convention. Presents even when empty — the screen
    /// renders its own "no targets yet" state.
    @MainActor
    private func presentCalibrationReview() async {
        let digest = await deps.traineeModelService.digest()
        calibrationProjections = (digest?.projections?.patternProjections ?? [])
            .sorted { $0.pattern.rawValue < $1.pattern.rawValue }
        showCalibrationReview = true
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
            .settingsCardRow(.single)
        } header: {
            ApexSectionLabel(text: "Developer")
        }
        #endif
    }

    /// Release-safe "Reset all data" — destructive, red, gated behind a confirm.
    /// Wipes on-device data + the anonymous Supabase session via the shared
    /// `performFullDataReset` (same code path as the developer reset).
    private var dataSection: some View {
        Section {
            Button(role: .destructive) {
                showResetAllConfirmation = true
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(dangerRed)
                        .frame(width: 30)
                    Text("Reset all data")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(dangerRed)
                }
            }
            .settingsCardRow(.single)
        } header: {
            ApexSectionLabel(text: "Data")
        } footer: {
            footerText("Erases your profile, program, and history on this device. Can't be undone.")
        }
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
            .settingsCardRow(.single)
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

    /// Neutral navigation row that opens a sheet: leading boxed icon + title +
    /// trailing chevron. No accent — the chevron signals "drills in".
    private func navRowLabel(icon: String, title: String) -> some View {
        HStack(spacing: 13) {
            boxedIcon(icon)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Apex.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Apex.textFaint)
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

// MARK: - Training-days stepper
//
// A `−  N  +` pill bound to an Int, clamped to a range. Ported from the
// prototype's `StepperPill`, baked to the Brutalist identity (lime − / + as
// the interactive controls, tabular numeral in a fixed-width slot so the
// digit never reflows). Kept local to Settings — not a shared design-system atom.
private struct DaysStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            btn("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - 1)
            }
            Rectangle().fill(Apex.hairline).frame(width: 1, height: 22)
            ApexNumeral(text: "\(value)", size: 18, weight: .bold, color: Apex.text)
                .frame(width: 40)
            Rectangle().fill(Apex.hairline).frame(width: 1, height: 22)
            btn("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + 1)
            }
        }
        .background(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
            .stroke(Apex.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
    }

    private func btn(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(enabled ? Apex.accent : Apex.textFaint)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private extension Comparable {
    /// Clamps a value into a closed range.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Sharp-corner grouped-card rows
//
// A `List` gives swipe-to-delete, but `.insetGrouped` forces ~10pt rounded
// corners. To match the rest of the Brutalist app (sharp ~4pt corners) we use
// `.plain` and draw each row's grouped-card background ourselves — sharp corners
// on the first/last row of a section, with an internal hairline between rows.
private enum SettingsCardPos {
    case single, first, middle, last
    var radii: RectangleCornerRadii {
        let r = Apex.corner
        switch self {
        case .single: return .init(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r)
        case .first:  return .init(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r)
        case .middle: return .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 0, topTrailing: 0)
        case .last:   return .init(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)
        }
    }
    var hairline: Bool { self == .first || self == .middle }
}

private extension View {
    /// Inset + hidden-separator + sharp grouped-card background for one List row.
    func settingsCardRow(_ pos: SettingsCardPos) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 13, leading: Apex.pad + 14, bottom: 13, trailing: Apex.pad + 14))
            .listRowSeparator(.hidden)
            .listRowBackground(
                UnevenRoundedRectangle(cornerRadii: pos.radii, style: .continuous)
                    .fill(Apex.surface)
                    .overlay(alignment: .bottom) {
                        if pos.hairline {
                            Rectangle().fill(Apex.hairline).frame(height: 1).padding(.leading, 14)
                        }
                    }
                    .padding(.horizontal, Apex.pad)
            )
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
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}

#Preview("No profile") {
    NavigationStack {
        SettingsView()
    }
    .environment(AppDependencies())
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
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}
