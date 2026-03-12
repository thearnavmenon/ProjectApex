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

struct DeveloperSettingsView: View {

    // MARK: - Dependencies (optional — injected when available)

    /// The active workout view model, used to display the current fallback reason.
    /// Nil when no workout session is active.
    var workoutViewModel: WorkoutViewModel?

    // MARK: - State

    @State private var anthropicKey: String = ""
    @State private var openAIKey: String    = ""
    @State private var supabaseKey: String  = ""

    /// Tracks which fields are revealing plain text.
    @State private var showAnthropic: Bool  = false
    @State private var showOpenAI: Bool     = false
    @State private var showSupabase: Bool   = false

    /// Keychain presence status loaded on appear / after save.
    @State private var anthropicStored: Bool = false
    @State private var openAIStored: Bool    = false
    @State private var supabaseStored: Bool  = false

    /// Banner shown after a save attempt.
    @State private var bannerMessage: String?
    @State private var bannerIsError: Bool  = false

    private let keychain = KeychainService.shared

    // MARK: - Body

    var body: some View {
        Form {
            keychainStatusSection
            aiCoachDiagnosticsSection
            anthropicSection
            openAISection
            supabaseSection
            saveSection
        }
        .navigationTitle("Developer Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshStoredStatus() }
        // Banner overlay at the bottom of the screen.
        .overlay(alignment: .bottom) {
            if let message = bannerMessage {
                bannerView(message: message, isError: bannerIsError)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: bannerMessage)
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
            statusRow(label: "Anthropic API Key", isPresent: anthropicStored)
            statusRow(label: "OpenAI API Key",    isPresent: openAIStored)
            statusRow(label: "Supabase Anon Key", isPresent: supabaseStored)
        }
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

        // Refresh stored-status indicators.
        refreshStoredStatus()
        // Clear text fields so the saved values are no longer visible.
        anthropicKey = ""
        openAIKey    = ""
        supabaseKey  = ""

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
        anthropicStored = (try? keychain.retrieve(.anthropicAPIKey)) != nil
        openAIStored    = (try? keychain.retrieve(.openAIAPIKey))    != nil
        supabaseStored  = (try? keychain.retrieve(.supabaseAnonKey)) != nil
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
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DeveloperSettingsView()
    }
    .preferredColorScheme(.dark)
}
