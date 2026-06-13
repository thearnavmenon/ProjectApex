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
//     → WriteAheadQueue → TraineeModelLocalStore → TraineeModelUpdateJob
//     → WorkoutSessionManager

import SwiftUI

@Observable
@MainActor
final class AppDependencies {

    // MARK: Services

    let keychainService: KeychainService
    let supabaseClient: SupabaseClient
    /// GoTrue anonymous-auth session owner (#369 slice 1). Additive: sets the
    /// client's JWT; does not repoint resolvedUserId or enable RLS this slice.
    let supabaseAuth: SupabaseAuth
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
    /// Local SwiftData cache for the trainee model snapshot (Phase 1 / Slice 8).
    let traineeModelLocalStore: TraineeModelLocalStore
    /// WAQ adapter: routes trainee_model_updates items to the Edge Function (Phase 1 / Slice 11).
    let traineeModelUpdateJob: TraineeModelUpdateJob
    /// Producer side: enqueues a trainee_model_updates item per completed session (#135).
    let traineeModelService: TraineeModelService
    /// Pending late-arrival notifications surfaced on the post-session summary (Phase 2 / Slice A3, ADR-0008).
    let lateArrivalNotificationQueue: LateArrivalNotificationQueue
    /// Orchestrates the full set-by-set AI coaching loop during active workout sessions.
    let workoutSessionManager: WorkoutSessionManager
    /// Single polling source for "is a session live" + summary. Views read from
    /// this instead of running their own .task loops against the manager actor.
    let liveSessionWatcher: LiveSessionWatcher

    // MARK: - Auth (MVP)

    /// Fixed placeholder user ID used throughout the MVP until real auth is wired.
    /// Matches the hardcoded UUID used in WorkoutSessionManager for session creation.
    static let placeholderUserId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The app's user identity for all Supabase writes and AI calls. As of #369
    /// slice 3 this is the anonymous-auth `auth.uid()` slice 1 persists to
    /// `.supabaseAuthUserId`, read synchronously so this stays a sync property.
    ///
    /// First-launch race: on a fresh install the async anon sign-in may not have
    /// completed the first time this is read, so the resolver falls back to the
    /// `.userId` onboarding mirror and finally the placeholder. That fallback is
    /// safe THIS slice only because RLS is still off (placeholder-keyed reads
    /// work); it goes vestigial once RLS lands (slice 5) + slice 1's readiness
    /// gate guarantees a session before any RLS-gated read. See `UserIdentityResolver`.
    var resolvedUserId: UUID {
        UserIdentityResolver.resolve(keychain: keychainService, placeholder: Self.placeholderUserId)
    }

    /// Awaits the first GoTrue session resolution, then returns the real auth uid
    /// IFF it is not the placeholder. Returns `nil` when auth never resolved
    /// (sign-in failed/timed out) or resolved only to the placeholder — callers
    /// MUST treat nil as "abort this owner-stamped write" and never fall back to
    /// the placeholder, mirroring the guard in `OnboardingView.persistUserIfNeeded`
    /// (`UserIdentityResolver.onboardingUserId`). This is the resolve-before-stamp
    /// surface owned writes adopt — workout-start as of this slice; later slices
    /// migrate the remaining sync `resolvedUserId` sites onto it. Do not define a
    /// second copy.
    ///
    /// Safe from any async context: `awaitFirstResolution` is internally bounded
    /// (signInTimeout ceiling) and never hangs. On a restored session it returns in
    /// microseconds; only a true fresh launch pays the sign-in latency.
    func resolvedOwnerUserId() async -> UUID? {
        _ = await supabaseAuth.awaitFirstResolution()
        return UserIdentityResolver.onboardingUserId(
            keychain: keychainService,
            placeholder: Self.placeholderUserId
        )
    }

    // MARK: Private: Stored Anthropic key for re-init

    private let anthropicKey: String

    /// True when an Anthropic key was resolvable at launch (Keychain or bundled
    /// build-time key). False on a fresh install with no key baked in — drives the
    /// honest "this build needs setup" launch gate (#329 / O-F1) instead of letting
    /// onboarding start and die mid-gym-scan with a raw HTTP error.
    let hasResolvableAIKey: Bool

    /// True when a Supabase anon key was resolvable at launch (Keychain or bundled
    /// build-time key). False on a fresh install with no key baked in (#369 slice 2).
    let hasResolvableSupabaseKey: Bool

    // MARK: Init

    init() {
        // 0. One-shot cleanup: remove the legacy StagnationService +
        // VolumeValidationService + PatternPhaseService UserDefaults keys.
        // The services + keys were deleted in B1 (#86), B2 (#87), and B3 (#88);
        // this prevents stale data from persisting on installs that upgraded
        // across the cutovers. Cheap idempotent ops — removeObject is a no-op
        // when the key is absent.
        UserDefaults.standard.removeObject(forKey: "apex.stagnation_signals")
        UserDefaults.standard.removeObject(forKey: "apex.volume_deficits")
        UserDefaults.standard.removeObject(forKey: "apex.pattern_phase_states")

        // 1. Keychain — source of all API keys
        let keychain = KeychainService.shared
        self.keychainService = keychain

        // 2. Supabase — needs its anon key; URL comes from Config.
        // Precedence (#369 slice 2): existing Keychain value → bundled build-time key
        // (seeded into the Keychain) → nil. A fresh install with a bundled key behaves
        // exactly like a dev install that entered the key via Developer Settings.
        let resolvedSupabaseAnonKey = SupabaseAnonKeyResolver.resolve(
            retrieve: { try? keychain.retrieve(.supabaseAnonKey) },
            store: { try? keychain.store($0, for: .supabaseAnonKey) },
            bundled: { BundledAPIKey.supabaseAnon() }
        )
        self.hasResolvableSupabaseKey = resolvedSupabaseAnonKey != nil
        let supabaseAnonKey = resolvedSupabaseAnonKey ?? ""
        let client = SupabaseClient(supabaseURL: Config.supabaseURL, anonKey: supabaseAnonKey)
        self.supabaseClient = client

        // 2b. Supabase Auth (GoTrue) — #369 slice 1. Additive only: establishes
        // an anonymous session and sets the client's JWT. resolvedUserId is NOT
        // repointed and RLS is still off, so behavior is unchanged this slice.
        // A stored session restores instantly; a fresh launch signs in anonymously
        // in the background and falls back to the anon key on failure/timeout.
        // GoTrue gets its OWN ephemeral URLSession rather than URLSession.shared.
        // The shared session, once the PostgREST path teaches it the host advertises
        // HTTP/3, attempts QUIC for sign-in; on some networks that handshake stalls
        // and the launch sign-in times out with no session (→ placeholder uid →
        // RLS 403 on every owned write). A fresh ephemeral session carries no cached
        // Alt-Svc, so its first request negotiates HTTP/2 over TCP — which the server
        // serves fine. waitsForConnectivity rides out a brief connectivity drop.
        let authSessionConfig = URLSessionConfiguration.ephemeral
        authSessionConfig.waitsForConnectivity = true
        authSessionConfig.timeoutIntervalForRequest = 15
        let auth = SupabaseAuth(
            supabaseURL: Config.supabaseURL,
            anonKey: supabaseAnonKey,
            urlSession: URLSession(configuration: authSessionConfig)
        )
        self.supabaseAuth = auth
        // Wire the refresh/401-retry hooks so authed requests stay valid.
        Task {
            await client.setRefreshHooks(
                refreshIfNeeded: { await auth.validAccessToken() },
                forceRefresh: { await auth.forceRefreshAccessToken() }
            )
            // Resolve the first session (restore-or-sign-in), then set the JWT.
            // Bounded internally so this can never hang. nil → stays on anon key.
            if let session = await auth.awaitFirstResolution() {
                await client.setAuthToken(session.accessToken)
            }
        }

        // 3. HealthKit — no dependencies
        self.healthKitService = HealthKitService()

        // 4. Memory — needs Supabase + OpenAI embedding key + Anthropic key for Haiku tag classification
        let openAIKey = (try? keychain.retrieve(.openAIAPIKey)) ?? ""
        // Read Anthropic key early so MemoryService can use Haiku for tag classification.
        // Precedence (#329): existing Keychain value → bundled build-time key (seeded
        // into the Keychain) → nil. Resolving here, before any service is built, means
        // a fresh install with a bundled key behaves exactly like a dev install.
        let resolvedAnthropicKey = AnthropicKeyResolver.resolve(
            retrieve: { try? keychain.retrieve(.anthropicAPIKey) },
            store: { try? keychain.store($0, for: .anthropicAPIKey) },
            bundled: { BundledAPIKey.anthropic() }
        )
        self.hasResolvableAIKey = resolvedAnthropicKey != nil
        let anthropicKey = resolvedAnthropicKey ?? ""
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

        // 9. WriteAheadQueue — reliable Supabase write queue (P3-T06)
        // Hoisted above SessionPlanService so the trainee-model stack below
        // can be injected into SessionPlanService (B1 / #86).
        let waq = WriteAheadQueue(supabase: supabaseClient)
        self.writeAheadQueue = waq

        // 10. TraineeModelLocalStore + TraineeModelUpdateJob (Phase 1 / Slices 8 + 11)
        // makeShared() can fail only if SwiftData can't create the container — treat as fatal.
        let tmStore = (try? TraineeModelLocalStore.makeShared()) ?? (try! TraineeModelLocalStore.makeInMemory())
        self.traineeModelLocalStore = tmStore
        let lateArrivalQueue = LateArrivalNotificationQueue.makeShared()
        self.lateArrivalNotificationQueue = lateArrivalQueue
        let tmJob = TraineeModelUpdateJob(
            supabase: supabaseClient,
            store: tmStore,
            notificationQueue: lateArrivalQueue
        )
        self.traineeModelUpdateJob = tmJob
        // Register the handler with the WAQ. Done via Task so the async WAQ actor hop
        // doesn't block the synchronous init. The Task is scheduled immediately and
        // completes before any user interaction can trigger a WAQ flush.
        Task { await tmJob.register(with: waq) }

        // 10b. TraineeModelService — producer side. Enqueues one trainee_model_updates
        // item per completed session; the handler registered above dispatches them.
        let tmService = TraineeModelService(store: tmStore, writeAheadQueue: waq)
        self.traineeModelService = tmService

        // 8c. SessionPlanService — Sonnet per-session generation (called on "Start Workout")
        self.sessionPlanService = SessionPlanService(
            provider: AnthropicProvider(apiKey: anthropicKey, maxTokens: 8000, requestTimeout: 120),
            memoryService: memoryService,
            supabaseClient: supabaseClient,
            traineeModelService: tmService
        )

        // 8d. ExerciseSwapService — mid-session exercise swap chat (P3-T10)
        self.exerciseSwapService = ExerciseSwapService(
            provider: AnthropicProvider(apiKey: anthropicKey, maxTokens: 1024, requestTimeout: 15)
        )

        // 11. WorkoutSessionManager — needs AI inference, HealthKit, Memory, Supabase, GymFactStore, WAQ, streak, trainee model
        let manager = WorkoutSessionManager(
            aiInference: inferenceService,
            healthKit: healthKitService,
            memoryService: memoryService,
            supabase: supabaseClient,
            gymFactStore: gymFactStore,
            writeAheadQueue: waq,
            gymStreakService: gymStreakService,
            traineeModelService: tmService
        )
        self.workoutSessionManager = manager

        // 12. LiveSessionWatcher — single polling source for live-session UI signals
        // (tab badge, calendar day highlight, set summary). Starts polling on init.
        self.liveSessionWatcher = LiveSessionWatcher(manager: manager)
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
            supabaseClient: supabaseClient,
            traineeModelService: traineeModelService
        )
    }

    // MARK: - Lifecycle

    nonisolated deinit {}
}
