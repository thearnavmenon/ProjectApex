// AppDependencies.swift
// ProjectApex — App Layer
//
// Central DI container. Instantiated once at app launch and injected into the
// SwiftUI environment via `.environment(deps)`. All services are created in
// dependency order so each service can receive the services it needs.
//
// Init order:
//   KeychainService → SupabaseClient → HealthKitService
//     → MemoryService → SpeechService → GymFactStore
//     → AIInferenceService → ProgramGenerationService

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
    let gymFactStore: GymFactStore
    private(set) var aiInferenceService: AIInferenceService
    /// Generates 12-week periodized programs on demand using claude-opus-4.
    private(set) var programGenerationService: ProgramGenerationService

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

        // 6. GymFactStore — persists user weight corrections
        self.gymFactStore = GymFactStore()

        // 7. AI Inference — needs Anthropic key (sonnet model, 8-second timeout)
        let anthropicKey = (try? keychain.retrieve(.anthropicAPIKey)) ?? ""
        self.anthropicKey = anthropicKey
        self.aiInferenceService = AIInferenceService(
            provider: AnthropicProvider(apiKey: anthropicKey)
        )

        // 8. Program Generation — uses opus model; no timeout (user waits explicitly)
        self.programGenerationService = ProgramGenerationService(
            provider: AnthropicProvider.forProgramGeneration(apiKey: anthropicKey)
        )
    }

    // MARK: - Re-initialisation

    /// Replaces AI services with fresh instances using the current Anthropic key.
    /// Call this if the API key changes (e.g. after re-login via Developer Settings).
    func reinitialiseAIInference() {
        aiInferenceService = AIInferenceService(
            provider: AnthropicProvider(apiKey: anthropicKey)
        )
        programGenerationService = ProgramGenerationService(
            provider: AnthropicProvider.forProgramGeneration(apiKey: anthropicKey)
        )
    }
}
