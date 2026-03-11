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
    let aiInferenceService: AIInferenceService

    // MARK: Init

    init() {
        // 1. Keychain — source of all API keys
        let keychain = KeychainService.shared
        self.keychainService = keychain

        // 2. Supabase — needs its anon key from Keychain
        let supabaseAnonKey = (try? keychain.retrieve(.supabaseAnonKey)) ?? ""
        self.supabaseClient = SupabaseClient(anonKey: supabaseAnonKey)

        // 3. HealthKit — no dependencies
        self.healthKitService = HealthKitService()

        // 4. Memory — needs Supabase + OpenAI embedding key
        let openAIKey = (try? keychain.retrieve(.openAIAPIKey)) ?? ""
        self.memoryService = MemoryService(supabase: supabaseClient, embeddingAPIKey: openAIKey)

        // 5. Speech — no dependencies
        self.speechService = SpeechService()

        // 6. AI Inference — needs Anthropic key + GymProfile
        let anthropicKey = (try? keychain.retrieve(.anthropicAPIKey)) ?? ""
        let gymProfile = GymProfile.loadFromUserDefaults() ?? GymProfile.mockProfile()
        self.aiInferenceService = AIInferenceService(
            provider: AnthropicProvider(apiKey: anthropicKey),
            gymProfile: gymProfile
        )
    }
}
