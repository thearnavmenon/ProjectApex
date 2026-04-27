// DeveloperSettingsView.swift
// ProjectApex — Settings Feature
//
// A developer-facing screen for manually entering API keys that are then
// stored securely in the Keychain via KeychainService.
//
// Navigation:
//   ContentView (Settings tab) → SettingsView → "Developer" row →
//   NavigationLink → DeveloperSettingsView
//
// Design decisions:
//   • SecureField for masked input; a show/hide toggle lets the developer
//     verify what they pasted without exposing plain text by default.
//   • Per-field status indicator (green checkmark / red exclamation) reads
//     directly from Keychain on appear and after every save so it always
//     reflects the persisted state, not just the current text field content.
//   • Basic format validation before save: Anthropic keys start with
//     "sk-ant-", OpenAI keys start with "sk-". Supabase anon keys are JWTs
//     starting with "eyJ" — validated accordingly.
//   • Save stores each *non-empty* field; empty fields are left unchanged
//     so the developer can update one key at a time.

import SwiftUI

// MARK: - DeveloperSettingsView

#if DEBUG
struct DeveloperSettingsView: View {

    // MARK: - Dependencies (optional — injected when available)

    /// The active workout view model, used to display the current fallback reason.
    /// Nil when no workout session is active.
    var workoutViewModel: WorkoutViewModel?

    /// Called after "Reset All App Data" completes so ContentView can return to onboarding.
    var onResetAll: (() -> Void)?

    // MARK: - Environment

    @Environment(AppDependencies.self) private var deps

    // MARK: - State

    @State private var anthropicKey: String    = ""
    @State private var openAIKey: String       = ""
    @State private var supabaseKey: String     = ""
    @State private var supabaseServiceKey: String = ""

    /// Tracks which fields are revealing plain text.
    @State private var showAnthropic: Bool     = false
    @State private var showOpenAI: Bool        = false
    @State private var showSupabase: Bool      = false
    @State private var showServiceKey: Bool    = false

    /// Keychain presence status loaded on appear / after save.
    @State private var anthropicStored: Bool      = false
    @State private var openAIStored: Bool         = false
    @State private var supabaseStored: Bool       = false
    @State private var supabaseServiceStored: Bool = false

    /// Banner shown after a save attempt.
    @State private var bannerMessage: String?
    @State private var bannerIsError: Bool  = false

    // MARK: - Reset confirmation alerts

    /// Controls the "Reset All App Data" confirmation alert.
    @State private var showResetAllConfirmation: Bool = false
    /// Controls the "Reset Onboarding Only" confirmation alert.
    @State private var showResetOnboardingConfirmation: Bool = false
    /// Controls the "Clear RAG Memory" confirmation alert.
    @State private var showClearMemoryConfirmation: Bool = false

    /// Gym weight correction facts loaded from GymFactStore for display and deletion.
    @State private var gymFacts: [GymFactStore.WeightFact] = []

    // MARK: - Start Any Day mode

    /// When true, all generated programme days are immediately startable regardless
    /// of their scheduled date. Does not affect the programme sequence — off-schedule
    /// sessions are logged as standalone workouts. DEBUG builds only.
    @State private var startAnyDayMode: Bool = UserDefaults.standard.bool(forKey: "dev_start_any_day_mode")

    // MARK: - Session count override

    @State private var sessionCount: Int = UserDefaults.standard.integer(forKey: UserProfileConstants.sessionCountKey)

    private let keychain = KeychainService.shared

    // MARK: - Body

    var body: some View {
        Form {
            keychainStatusSection
            aiCoachDiagnosticsSection
            gymWeightCorrectionsSection
            anthropicSection
            openAISection
            supabaseSection
            supabaseServiceSection
            saveSection
            developerToolsSection
        }
        .navigationTitle("Developer Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshStoredStatus()
            Task { gymFacts = await deps.gymFactStore.facts }
        }
        // Banner overlay at the bottom of the screen.
        .overlay(alignment: .bottom) {
            if let message = bannerMessage {
                bannerView(message: message, isError: bannerIsError)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: bannerMessage)
        // Reset All confirmation
        .alert("Reset All App Data?", isPresented: $showResetAllConfirmation) {
            Button("Reset Everything", role: .destructive) {
                Task { await performResetAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all local data and return to onboarding. This cannot be undone.")
        }
        // Reset Onboarding Only confirmation
        .alert("Reset Onboarding?", isPresented: $showResetOnboardingConfirmation) {
            Button("Reset Onboarding", role: .destructive) {
                performResetOnboarding()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears only the onboarding completion flag. Your GymProfile and program will remain intact.")
        }
        // Clear RAG Memory confirmation
        .alert("Clear RAG Memory?", isPresented: $showClearMemoryConfirmation) {
            Button("Clear Memory", role: .destructive) {
                Task { await performClearRAGMemory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all AI memory embeddings for this user from Supabase. Useful for testing cold-start AI behaviour.")
        }
    }

    // MARK: - Sections

    /// AI Coach diagnostics — shows fallback reason when coach is offline (P3-T07 AC).
    private var aiCoachDiagnosticsSection: some View {
        Section("AI Coach Diagnostics") {
            if let vm = workoutViewModel, vm.isAIOffline {
                HStack {
                    Image(systemName: "brain.head.profile.slash")
                        .foregroundStyle(.orange)
                    Text("Coach Offline")
                        .foregroundStyle(.orange)
                }
                if let devDesc = vm.developerFallbackDescription {
                    HStack {
                        Text("Reason")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(devDesc)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(2)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.green)
                    Text("Coach Online")
                        .foregroundStyle(.green)
                }
                Text("No fallback active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Quick-glance summary of which keys are present in the Keychain.
    private var keychainStatusSection: some View {
        Section("Keychain Status") {
            statusRow(label: "Anthropic API Key",      isPresent: anthropicStored)
            statusRow(label: "OpenAI API Key",         isPresent: openAIStored)
            statusRow(label: "Supabase Anon Key",      isPresent: supabaseStored)
            statusRow(label: "Supabase Service Key",   isPresent: supabaseServiceStored)
        }
    }

    /// Lists all recorded GymFactStore weight corrections. Each row can be deleted
    /// to fix incorrectly captured corrections (e.g. 35kg blocked on all cable machines
    /// due to a correction made on a different exercise).
    private var gymWeightCorrectionsSection: some View {
        Section {
            if gymFacts.isEmpty {
                Text("No weight corrections recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(gymFacts) { fact in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.equipmentType.displayName)
                                .font(.subheadline.weight(.medium))
                            Text("\(formatFactWeight(fact.unavailableWeight)) → \(formatFactWeight(fact.availableWeight))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                await deps.gymFactStore.removeFact(
                                    for: fact.equipmentType,
                                    unavailableWeight: fact.unavailableWeight
                                )
                                gymFacts = await deps.gymFactStore.facts
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            Text("Gym Weight Corrections")
        } footer: {
            Text("Weight corrections are equipment-wide, not exercise-specific. Delete an incorrect correction to restore the blocked weight for all exercises on that equipment type.")
                .font(.caption)
        }
    }

    private func formatFactWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fkg", kg)
            : String(format: "%.1fkg", kg)
    }

    private var anthropicSection: some View {
        Section {
            apiKeyField(
                label: "Anthropic API Key",
                hint: "sk-ant-...",
                text: $anthropicKey,
                showPlainText: $showAnthropic
            )
            formatHint("Must begin with \"sk-ant-\"")
        } header: {
            Text("Anthropic")
        } footer: {
            Text("Used by AnthropicProvider for set-prescription inference.")
                .font(.caption)
        }
    }

    private var openAISection: some View {
        Section {
            apiKeyField(
                label: "OpenAI API Key",
                hint: "sk-...",
                text: $openAIKey,
                showPlainText: $showOpenAI
            )
            formatHint("Must begin with \"sk-\"")
        } header: {
            Text("OpenAI (Fallback)")
        } footer: {
            Text("Used by OpenAIProvider as fallback when Anthropic is unavailable.")
                .font(.caption)
        }
    }

    private var supabaseSection: some View {
        Section {
            apiKeyField(
                label: "Supabase Anon Key",
                hint: "eyJ...",
                text: $supabaseKey,
                showPlainText: $showSupabase
            )
            formatHint("JWT — begins with \"eyJ\"")
        } header: {
            Text("Supabase")
        } footer: {
            Text("Anonymous key for database reads and RAG memory retrieval.")
                .font(.caption)
        }
    }

    private var supabaseServiceSection: some View {
        Section {
            apiKeyField(
                label: "Supabase Service Key",
                hint: "eyJ...",
                text: $supabaseServiceKey,
                showPlainText: $showServiceKey
            )
            formatHint("JWT — begins with \"eyJ\". Bypasses RLS for MVP writes.")
        } header: {
            Text("Supabase Service Role (MVP)")
        } footer: {
            Text("Required until Supabase Auth is wired. Allows the app to write embeddings and session data. Keep secret — never share publicly.")
                .font(.caption)
        }
    }

    private var saveSection: some View {
        Section {
            Button(action: saveKeys) {
                Label("Save to Keychain", systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        } footer: {
            Text("Only non-empty fields are saved. Existing keys are not overwritten by blank input.")
                .font(.caption)
        }
    }

    /// Developer Tools — reset actions for iterating on onboarding and AI flows.
    private var developerToolsSection: some View {
        Section {
            // Start Any Day mode — unlocks all generated days for immediate training.
            Toggle(isOn: $startAnyDayMode) {
                Label("Start Any Day Mode", systemImage: "calendar.badge.checkmark")
            }
            .onChange(of: startAnyDayMode) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "dev_start_any_day_mode")
            }

            // Offline fallback session count — only used if Supabase is unreachable at session start.
            // The live count is fetched from workout_sessions on every session start.
            Stepper(value: $sessionCount, in: 0...999) {
                HStack {
                    Label("Offline Session Count", systemImage: "number.circle")
                    Spacer()
                    Text("\(sessionCount)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(sessionCount == 0 ? .orange : .secondary)
                }
            }
            .onChange(of: sessionCount) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: UserProfileConstants.sessionCountKey)
            }

            // Wipes all persisted state: UserDefaults, Keychain, GymFactStore, returns to onboarding.
            Button(role: .destructive) {
                showResetAllConfirmation = true
            } label: {
                Label("Reset All App Data", systemImage: "trash.fill")
            }

            // Clears only the onboarding completion flag — leaves GymProfile and program intact.
            Button(role: .destructive) {
                showResetOnboardingConfirmation = true
            } label: {
                Label("Reset Onboarding Only", systemImage: "arrow.counterclockwise")
            }

            // Removes all memory_embeddings rows for this user — tests cold-start AI coaching.
            Button(role: .destructive) {
                showClearMemoryConfirmation = true
            } label: {
                Label("Clear RAG Memory", systemImage: "brain.filled.head.profile")
            }
        } header: {
            Text("Developer Tools")
        } footer: {
            Text("Start Any Day Mode unlocks all generated days for immediate training without affecting programme sequence. Offline Session Count is a fallback used only when Supabase is unreachable — the live count is always fetched from the database at session start. Other reset actions are irreversible. For development use only.")
                .font(.caption)
        }
    }

    // MARK: - Reusable Components

    /// A masked / unmasked text field row with a toggle eye button.
    @ViewBuilder
    private func apiKeyField(
        label: String,
        hint: String,
        text: Binding<String>,
        showPlainText: Binding<Bool>
    ) -> some View {
        HStack {
            Group {
                if showPlainText.wrappedValue {
                    TextField(hint, text: text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField(hint, text: text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .font(.system(.body, design: .monospaced))

            Button {
                showPlainText.wrappedValue.toggle()
            } label: {
                Image(systemName: showPlainText.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showPlainText.wrappedValue ? "Hide key" : "Show key")
        }
    }

    /// A single row showing the key name and a presence indicator.
    private func statusRow(label: String, isPresent: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            if isPresent {
                Label("Stored", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(label) is stored in Keychain")
            } else {
                Label("Missing", systemImage: "exclamationmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(label) is not stored in Keychain")
            }
        }
    }

    /// Subtle caption-style format requirement hint.
    private func formatHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Temporary banner that auto-dismisses after 3 seconds.
    private func bannerView(message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
            Text(message)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(isError ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
        )
        .foregroundStyle(.white)
    }

    // MARK: - Actions

    /// Validates and saves non-empty fields to the Keychain.
    private func saveKeys() {
        var savedCount  = 0
        var errors: [String] = []

        // Anthropic key
        if !anthropicKey.isEmpty {
            if !anthropicKey.hasPrefix("sk-ant-") {
                errors.append("Anthropic key must start with \"sk-ant-\"")
            } else {
                do {
                    try keychain.store(anthropicKey, for: .anthropicAPIKey)
                    savedCount += 1
                } catch {
                    errors.append("Anthropic: \(error.localizedDescription)")
                }
            }
        }

        // OpenAI key
        if !openAIKey.isEmpty {
            if !openAIKey.hasPrefix("sk-") {
                errors.append("OpenAI key must start with \"sk-\"")
            } else {
                do {
                    try keychain.store(openAIKey, for: .openAIAPIKey)
                    savedCount += 1
                } catch {
                    errors.append("OpenAI: \(error.localizedDescription)")
                }
            }
        }

        // Supabase anon key (JWT)
        if !supabaseKey.isEmpty {
            if !supabaseKey.hasPrefix("eyJ") {
                errors.append("Supabase key must start with \"eyJ\" (JWT)")
            } else {
                do {
                    try keychain.store(supabaseKey, for: .supabaseAnonKey)
                    savedCount += 1
                } catch {
                    errors.append("Supabase: \(error.localizedDescription)")
                }
            }
        }

        // Supabase service role key (JWT)
        if !supabaseServiceKey.isEmpty {
            if !supabaseServiceKey.hasPrefix("eyJ") {
                errors.append("Supabase service key must start with \"eyJ\" (JWT)")
            } else {
                do {
                    try keychain.store(supabaseServiceKey, for: .supabaseServiceKey)
                    savedCount += 1
                    // Apply immediately to the live SupabaseClient so current session benefits.
                    let key = supabaseServiceKey
                    Task { await deps.supabaseClient.set(serviceKey: key) }
                } catch {
                    errors.append("Supabase Service: \(error.localizedDescription)")
                }
            }
        }

        // Refresh stored-status indicators.
        refreshStoredStatus()
        // Clear text fields so the saved values are no longer visible.
        anthropicKey      = ""
        openAIKey         = ""
        supabaseKey       = ""
        supabaseServiceKey = ""

        // Show banner.
        if errors.isEmpty {
            if savedCount == 0 {
                showBanner("No keys entered — nothing saved.", isError: false)
            } else {
                showBanner("\(savedCount) key\(savedCount == 1 ? "" : "s") saved to Keychain.", isError: false)
            }
        } else {
            showBanner(errors.joined(separator: "\n"), isError: true)
        }
    }

    /// Reads each key's presence from the Keychain and updates the status flags.
    private func refreshStoredStatus() {
        anthropicStored      = (try? keychain.retrieve(.anthropicAPIKey))    != nil
        openAIStored         = (try? keychain.retrieve(.openAIAPIKey))       != nil
        supabaseStored       = (try? keychain.retrieve(.supabaseAnonKey))    != nil
        supabaseServiceStored = (try? keychain.retrieve(.supabaseServiceKey)) != nil
    }

    /// Displays the banner for 3 seconds then hides it.
    private func showBanner(_ message: String, isError: Bool) {
        bannerMessage = message
        bannerIsError = isError
        Task {
            try? await Task.sleep(for: .seconds(3))
            bannerMessage = nil
        }
    }

    // MARK: - Reset Actions

    /// Wipes all persisted app state except API keys in the Keychain, then returns to onboarding.
    ///
    /// Clears in order:
    ///   1. All UserDefaults for this app's bundle domain (onboarding flags, scan-skipped flag, etc.)
    ///   2. GymFactStore weight-correction facts (UserDefaults-backed)
    ///   3. The userId Keychain entry so onboarding generates a fresh identity
    ///   (API keys — anthropicAPIKey, openAIAPIKey, supabaseAnonKey — are intentionally preserved)
    @MainActor
    private func performResetAll() async {
        // 1. Wipe all UserDefaults for this bundle (onboarding flags, scan-skipped, gym facts, etc.)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // 2. Clear GymFactStore weight corrections (belt-and-suspenders after UserDefaults wipe)
        await deps.gymFactStore.clearAll()

        // 3. Remove the persisted userId so onboarding creates a fresh identity
        try? keychain.delete(.userId)

        // Navigate to onboarding without a relaunch
        onResetAll?()
        showBanner("All app data cleared.", isError: false)
    }

    /// Clears onboarding flags and the cached program so re-running onboarding
    /// generates a fresh program rather than loading the old one.
    ///
    /// Clears:
    ///   - onboardingCompletedKey (UserDefaults)
    ///   - scanSkippedKey (UserDefaults)
    ///   - daysPerWeekKey (UserDefaults) — forces re-read from new onboarding selection
    ///   - activeProgram cache (UserDefaults) — old program must not shadow new one
    private func performResetOnboarding() {
        UserDefaults.standard.removeObject(forKey: OnboardingConstants.onboardingCompletedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingConstants.scanSkippedKey)
        UserDefaults.standard.removeObject(forKey: UserProfileConstants.daysPerWeekKey)
        Mesocycle.clearUserDefaults()

        onResetAll?()
        showBanner("Onboarding flags cleared.", isError: false)
    }

    /// Deletes all memory_embeddings rows for this user from Supabase.
    ///
    /// Clears:
    ///   - All rows in `memory_embeddings` where user_id matches the resolved userId
    @MainActor
    private func performClearRAGMemory() async {
        let userId = deps.resolvedUserId.uuidString
        do {
            try await deps.memoryService.deleteAllEmbeddings(userId: userId)
            showBanner("RAG memory cleared.", isError: false)
        } catch {
            showBanner("Failed: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DeveloperSettingsView()
    }
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}
#endif
