// AppDependencies.swift
// ProjectApex — App Layer
//
// Central DI container. Instantiated once at app launch and injected into the
// SwiftUI environment via `.environment(deps)`. All services are created in
// dependency order so each service can receive the services it needs.
//
// Init order:
//   KeychainService → SupabaseClient → HealthKitService
//     → MemoryService → SpeechService → AIInferenceService
//
// After a successful gym scan, call `reinitialiseAIInference(with:)` so that
// the EquipmentRounder inside AIInferenceService reflects the new GymProfile
// without requiring a full app restart.

import SwiftUI

@Observable
@MainActor
final class AppDependencies {

    // MARK: Services

    let keychainService: KeychainService
    let supabaseClient: SupabaseClient
    let healthKitService: HealthKitService
    let memoryService: MemoryService
    let speechService: SpeechService
    /// Mutable so it can be replaced when a new GymProfile is confirmed.
    private(set) var aiInferenceService: AIInferenceService

    // MARK: Private: Stored Anthropic key for re-init

    private let anthropicKey: String

    // MARK: Init

    init() {
        // 1. Keychain — source of all API keys
        let keychain = KeychainService.shared
        self.keychainService = keychain

        // 2. Supabase — needs its anon key from Keychain; URL comes from Config
        let supabaseAnonKey = (try? keychain.retrieve(.supabaseAnonKey)) ?? ""
        self.supabaseClient = SupabaseClient(supabaseURL: Config.supabaseURL, anonKey: supabaseAnonKey)

        // 3. HealthKit — no dependencies
        self.healthKitService = HealthKitService()

        // 4. Memory — needs Supabase + OpenAI embedding key
        let openAIKey = (try? keychain.retrieve(.openAIAPIKey)) ?? ""
        self.memoryService = MemoryService(supabase: supabaseClient, embeddingAPIKey: openAIKey)

        // 5. Speech — no dependencies
        self.speechService = SpeechService()

        // 6. AI Inference — needs Anthropic key + GymProfile
        let anthropicKey = (try? keychain.retrieve(.anthropicAPIKey)) ?? ""
        self.anthropicKey = anthropicKey
        let gymProfile = GymProfile.loadFromUserDefaults() ?? GymProfile.mockProfile()
        self.aiInferenceService = AIInferenceService(
            provider: AnthropicProvider(apiKey: anthropicKey),
            gymProfile: gymProfile
        )
    }

    // MARK: - Profile-driven re-initialisation

    /// Replaces the current `AIInferenceService` with a fresh instance built
    /// from `newProfile`. Call this immediately after a new GymProfile has been
    /// confirmed and saved so the EquipmentRounder inside the service uses the
    /// latest equipment data without requiring an app restart.
    ///
    /// - Parameter newProfile: The newly confirmed and saved `GymProfile`.
    func reinitialiseAIInference(with newProfile: GymProfile) {
        aiInferenceService = AIInferenceService(
            provider: AnthropicProvider(apiKey: anthropicKey),
            gymProfile: newProfile
        )
    }
}
