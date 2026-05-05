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
//     → WorkoutSessionManager

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
    /// Computes gym streak score for AI intensity modulation (P4-E1).
    let gymStreakService: GymStreakService
    private(set) var aiInferenceService: AIInferenceService
    /// Generates 12-week periodized programs on demand using claude-opus-4.
    private(set) var programGenerationService: ProgramGenerationService
    /// FB-008: Generates 12-week macro skeleton (phase structure, no exercises).
    private(set) var macroPlanService: MacroPlanService
    /// FB-008: Generates individual session content on-demand before each workout.
    private(set) var sessionPlanService: SessionPlanService
    /// P3-T10: Multi-turn exercise swap chat service.
    let exerciseSwapService: ExerciseSwapService
    /// Local write-ahead queue for reliable Supabase writes during workouts.
    let writeAheadQueue: WriteAheadQueue
    /// Orchestrates the full set-by-set AI coaching loop during active workout sessions.
    let workoutSessionManager: WorkoutSessionManager

    // MARK: - Auth (MVP)

    /// Fixed placeholder user ID used throughout the MVP until real auth is wired.
    /// Matches the hardcoded UUID used in WorkoutSessionManager for session creation.
    static let placeholderUserId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Returns the user UUID stored in Keychain if available, falling back to
    /// the MVP placeholder. Use this for all Supabase writes and AI calls so
    /// that real user IDs flow through automatically once onboarding has run.
    var resolvedUserId: UUID {
        if let stored = try? keychainService.retrieve(.userId),
           !stored.isEmpty,
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        return Self.placeholderUserId
    }

    // MARK: Private: Stored Anthropic key for re-init

    private let anthropicKey: String

    // MARK: Init

    init() {
        // 1. Keychain — source of all API keys
        let keychain = KeychainService.shared
        self.keychainService = keychain

        // 2. Supabase — needs its anon key from Keychain; URL comes from Config
        let supabaseAnonKey = (try? keychain.retrieve(.supabaseAnonKey)) ?? ""
        let supabaseServiceKey = (try? keychain.retrieve(.supabaseServiceKey)) ?? ""
        let client = SupabaseClient(supabaseURL: Config.supabaseURL, anonKey: supabaseAnonKey)
        if !supabaseServiceKey.isEmpty {
            Task { await client.set(serviceKey: supabaseServiceKey) }
        }
        self.supabaseClient = client

        // 3. HealthKit — no dependencies
        self.healthKitService = HealthKitService()

        // 4. Memory — needs Supabase + OpenAI embedding key + Anthropic key for Haiku tag classification
        let openAIKey = (try? keychain.retrieve(.openAIAPIKey)) ?? ""
        // Read Anthropic key early so MemoryService can use Haiku for tag classification.
        let anthropicKey = (try? keychain.retrieve(.anthropicAPIKey)) ?? ""
        self.memoryService = MemoryService(
            supabase: supabaseClient,
            embeddingAPIKey: openAIKey,
            anthropicAPIKey: anthropicKey.isEmpty ? nil : anthropicKey
        )

        // 5. Speech — uses OpenAI Whisper API as low-confidence fallback
        self.speechService = SpeechService(
            whisperAPIKey: openAIKey.isEmpty ? nil : openAIKey
        )

        // 6. GymFactStore — persists user weight corrections
        self.gymFactStore = GymFactStore()

        // 6b. GymStreakService — training consistency for AI intensity modulation (P4-E1)
        self.gymStreakService = GymStreakService(supabase: supabaseClient)

        // 7. AI Inference — needs Anthropic key (sonnet model, 8-second timeout)
        self.anthropicKey = anthropicKey
        let inferenceService = AIInferenceService(
            provider: AnthropicProvider(apiKey: anthropicKey)
        )
        self.aiInferenceService = inferenceService

        // 8. Program Generation — uses opus model; no timeout (user waits explicitly)
        // enableCaching: false — one-shot call, never repeats the same prompt, no cache benefit.
        self.programGenerationService = ProgramGenerationService(
            provider: AnthropicProvider.forProgramGeneration(apiKey: anthropicKey)
        )

        // 8b. MacroPlanService — Sonnet skeleton generation (one-shot at programme start)
        // enableCaching: false — same reason as ProgramGenerationService above.
        self.macroPlanService = MacroPlanService(
            provider: AnthropicProvider.forProgramGeneration(apiKey: anthropicKey)
        )

        // 8c. SessionPlanService — Sonnet per-session generation (called on "Start Workout")
        self.sessionPlanService = SessionPlanService(
            provider: AnthropicProvider(apiKey: anthropicKey, maxTokens: 8000, requestTimeout: 120),
            memoryService: memoryService,
            supabaseClient: supabaseClient
        )

        // 8d. ExerciseSwapService — mid-session exercise swap chat (P3-T10)
        self.exerciseSwapService = ExerciseSwapService(
            provider: AnthropicProvider(apiKey: anthropicKey, maxTokens: 1024, requestTimeout: 15)
        )

        // 9. WriteAheadQueue — reliable Supabase write queue (P3-T06)
        let waq = WriteAheadQueue(supabase: supabaseClient)
        self.writeAheadQueue = waq

        // 10. WorkoutSessionManager — needs AI inference, HealthKit, Memory, Supabase, GymFactStore, WAQ, streak
        self.workoutSessionManager = WorkoutSessionManager(
            aiInference: inferenceService,
            healthKit: healthKitService,
            memoryService: memoryService,
            supabase: supabaseClient,
            gymFactStore: gymFactStore,
            writeAheadQueue: waq,
            gymStreakService: gymStreakService
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
        macroPlanService = MacroPlanService(
            provider: AnthropicProvider.forProgramGeneration(apiKey: anthropicKey)
        )
        sessionPlanService = SessionPlanService(
            provider: AnthropicProvider(apiKey: anthropicKey, maxTokens: 8000, requestTimeout: 120),
            memoryService: memoryService,
            supabaseClient: supabaseClient
        )
    }
}
