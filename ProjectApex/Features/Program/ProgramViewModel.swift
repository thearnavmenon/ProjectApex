// ProgramViewModel.swift
// ProjectApex — Features/Program
//
// Observable view model bridging programme services to ProgramOverviewView.
// Manages loading, empty, generating, and loaded states.
//
// FB-008: Extended to support the two-service architecture:
//   • MacroPlanService — one-shot skeleton generation (phase structure, week intent)
//   • SessionPlanService — on-demand session generation before each workout
//
// The view model exposes:
//   • `viewState` for top-level program loading/generation state
//   • `generateDaySession(day:week:)` for on-demand session generation
//   • `currentMesocycle` so views can observe in-place day mutations

import SwiftUI
import OSLog

private let programPersistLogger = Logger(subsystem: "com.projectapex", category: "ProgramPersist")

// MARK: - SessionMetaRow

/// Lightweight Decodable used to fetch workout_sessions metadata without the
/// broken nested set_logs join that the full WorkoutSession model requires.
private struct SessionMetaRow: Decodable {
    let id: UUID
    let dayType: String
    let sessionDate: String

    enum CodingKeys: String, CodingKey {
        case id
        case dayType     = "day_type"
        case sessionDate = "session_date"
    }
}

// MARK: - GenerationUserProfile (#318 U4)

/// Profile payload assembled from the user's persisted onboarding answers for
/// program/session generation. Extracted as a pure value + static assembler so
/// the assembly rules are unit-testable and shared by the generation
/// paths (generateMacroSkeleton, generateDaySession).
struct GenerationUserProfile: Equatable {
    let bodyweightKg: Double?
    let ageYears: Int?
    let trainingAge: String?
    let experienceLevel: String
    let goals: [String]

    /// Assembles the profile from the persisted onboarding answers.
    ///
    /// Goal source is hybrid (#318 U4): the live trainee-model digest goal
    /// statement wins when hydrated (so a renegotiated goal, ADR-0022, is not
    /// shadowed by a stale onboarding answer), then the onboarding answer
    /// persisted under `UserProfileConstants.primaryGoalKey`, then the legacy
    /// "hypertrophy" default. `GoalState.placeholder` has an empty statement
    /// (#146), so empty/whitespace detection covers the un-hydrated case.
    static func assemble(
        defaults: UserDefaults = .standard,
        digestGoalStatement: String?
    ) -> GenerationUserProfile {
        let bwKg: Double? = defaults.double(forKey: UserProfileConstants.bodyweightKgKey) > 0
            ? defaults.double(forKey: UserProfileConstants.bodyweightKgKey) : nil
        let ageYears: Int? = defaults.integer(forKey: UserProfileConstants.ageKey) > 0
            ? defaults.integer(forKey: UserProfileConstants.ageKey) : nil
        let trainingAge: String? = defaults.string(forKey: UserProfileConstants.trainingAgeKey)

        let goal: String
        let digestGoal = (digestGoalStatement ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let storedGoal = (defaults.string(forKey: UserProfileConstants.primaryGoalKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !digestGoal.isEmpty {
            goal = digestGoal
        } else if !storedGoal.isEmpty {
            goal = storedGoal
        } else {
            goal = "hypertrophy"
        }

        return GenerationUserProfile(
            bodyweightKg: bwKg,
            ageYears: ageYears,
            trainingAge: trainingAge,
            experienceLevel: trainingAge ?? "intermediate",
            goals: [goal]
        )
    }
}

// MARK: - ProgramViewState

enum ProgramViewState: Equatable {
    case loading
    case empty
    case loaded(Mesocycle)
    case generating
    case generatingSession(dayId: UUID)   // FB-008: generating a single day's session
    case error(String)

    static func == (lhs: ProgramViewState, rhs: ProgramViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.empty, .empty), (.generating, .generating): return true
        case (.loaded(let a), .loaded(let b)):       return a.id == b.id
        case (.error(let a), .error(let b)):         return a == b
        case (.generatingSession(let a), .generatingSession(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - ProgramViewModel

@Observable
@MainActor
final class ProgramViewModel {

    // MARK: Published State

    var viewState: ProgramViewState = .loading
    var selectedDay: TrainingDay?
    var selectedWeek: TrainingWeek?
    /// Exposed so views can observe in-place mutations (e.g. day status changes).
    /// Internal (not private) so test targets can inject a mesocycle directly
    /// without going through the UserDefaults fast-path in loadProgram().
    var currentMesocycle: Mesocycle?

    /// #439 (Q3 = refuse-and-prompt): set true when `regenerateProgram` was asked to
    /// run while a live/paused session sentinel (`PausedSessionState`) still exists.
    /// Regenerating then would mint a fresh mesocycle with new day UUIDs and orphan
    /// the sentinel — its `trainingDayId` would point at a deleted TrainingDay
    /// ("Session Not Found" / "Session Mismatch", STATE-5/STATE-6). The guard
    /// REFUSES (no mutation, no new UUIDs) and sets this flag so the UI can prompt
    /// the user to finish or abandon the paused session first. Cleared on the next
    /// regenerate attempt that is allowed to proceed.
    var regenerationBlockedBySession: Bool = false

    // MARK: Sync-error state (#188)
    /// Non-nil when a background Supabase persist failed. The view renders a
    /// non-blocking banner so the user is aware the sync failed. Local-first
    /// design: local state remains valid; sync is the failure, not the local write.
    var persistError: String?
    /// Retry action captured at the time of failure. Invoking it re-runs the
    /// deactivate → insert flow. Set to nil on banner dismissal.
    var persistRetryAction: (@MainActor @Sendable () async -> Void)?

    // MARK: Private

    private let supabaseClient: SupabaseClient
    private let macroPlanService: MacroPlanService
    private let sessionPlanService: SessionPlanService
    private let traineeModelService: TraineeModelService?

    /// User ID sourced from AppDependencies.resolvedUserId at construction time.
    /// Best-effort id for NON-owned-write uses only (generation LLM payloads +
    /// history-read filters). The single owned write re-resolves the owner async at
    /// write time via `resolveOwner` (#409) so a `programs` row is never stamped
    /// under the pre-auth placeholder uid.
    private let userId: UUID

    /// Async owner re-resolution for the single owned write (`persistProgram`).
    /// Returns nil / the placeholder when auth has not resolved; the owned write
    /// aborts in that case rather than stamping a uid the user can't own (#409,
    /// mirrors `AppDependencies.resolvedOwnerUserId()`).
    private let resolveOwner: () async -> UUID?

    /// Per-pattern phase state for the PATTERN PROGRESS section in ProgramOverviewView
    /// — sourced from TraineeModelDigest.perPatternSummary (B3 / #88). Empty until
    /// the local trainee-model cache hydrates.
    var patternPhaseSummaries: [PatternSummary] = []

    // MARK: Init

    init(
        supabaseClient: SupabaseClient,
        macroPlanService: MacroPlanService,
        sessionPlanService: SessionPlanService,
        userId: UUID,
        resolveOwner: @escaping () async -> UUID?,
        traineeModelService: TraineeModelService? = nil
    ) {
        self.supabaseClient = supabaseClient
        self.macroPlanService = macroPlanService
        self.sessionPlanService = sessionPlanService
        self.traineeModelService = traineeModelService
        self.userId = userId
        self.resolveOwner = resolveOwner
    }

    nonisolated deinit {}

    // MARK: - Load

    /// Loads the active program: tries UserDefaults cache first, then Supabase.
    func loadProgram() async {
        viewState = .loading

        // Refresh per-pattern phase summaries from the trainee model digest (B3 / #88).
        patternPhaseSummaries = await traineeModelService?.digest()?.perPatternSummary ?? []

        // 1. Fast path: UserDefaults cache
        if let cached = Mesocycle.loadFromUserDefaults() {
            currentMesocycle = cached
            viewState = .loaded(cached)
            // #425: resolve-before-stamp backfill safety-net. #424 persists the
            // onboarding program ONLY when the owner resolves at onboard time; when
            // auth is unresolved then (offline / a QUIC sign-in stall like #392/#394)
            // the program lives only in UserDefaults and the server `programs` table
            // stays empty, so every later workout FK-fails on
            // `workout_sessions_program_id_fkey`. Re-attempt the server write here,
            // off the fast path, once a real session resolves. Best-effort and
            // non-blocking: the cached program is already displayed above; this never
            // throws out of loadProgram and never slows the UI.
            //
            // #444 (Q5): the same background pass also RECONCILES per-day statuses
            // against the server (the durable record) when a server program exists,
            // so a fresh install whose cache says pending shows completed/skipped
            // days correctly. Backfill (server empty) and reconcile (server present)
            // are the two mutually-exclusive outcomes of the one server fetch.
            Task { await self.backfillOrReconcileCachedProgram(cached) }
            return
        }

        // 2. Network fetch
        // Read semantics unchanged for PR-A.
        do {
            if let row = try await supabaseClient.fetchActiveProgram(userId: userId) {
                let mesocycle = row.toMesocycle()
                mesocycle.saveToUserDefaults()
                currentMesocycle = mesocycle
                viewState = .loaded(mesocycle)
            } else {
                viewState = .empty
            }
        } catch {
            // If fetch fails but no cache → show empty so user can generate
            viewState = .empty
        }
    }

    /// #425 safety-net: re-persist a locally-cached program to the server once a
    /// real owner resolves, but ONLY when the server genuinely has no active program.
    ///
    /// Best-effort and non-blocking — fired from `loadProgram`'s cache-hit fast path
    /// on a detached Task so the cached program displays immediately. Never throws,
    /// never touches `viewState`; UserDefaults remains the source of truth.
    ///
    /// Critically distinguishes "server says empty" from "couldn't reach server":
    /// only a fetch that SUCCEEDS and returns no active program triggers the
    /// backfill. A fetch that throws (offline / transient) bails — a later load
    /// retries — so a transient error is never mistaken for "empty" (which would
    /// spuriously re-insert and could shadow a real server program).
    ///
    /// Reuses `OnboardingProgramPersist.persistIfOwnerResolved` so the
    /// placeholder-guard + resolve-before-stamp + best-effort-catch live in exactly
    /// one place (the same path #424 added).
    ///
    /// #444 (Q5): when the fetch instead finds an active server program, this
    /// RECONCILES per-day statuses onto the displayed cache rather than backfilling
    /// — see `reconcileServerStatuses`.
    private func backfillOrReconcileCachedProgram(_ cached: Mesocycle) async {
        // Resolve the real owner. nil / placeholder → do nothing; the next resolved
        // load catches it. persistIfOwnerResolved also guards the placeholder, but we
        // bail early to avoid the server fetch when there's no owner to stamp under.
        guard let owner = await resolveOwner(), owner != AppDependencies.placeholderUserId else {
            return
        }

        // A thrown error means we couldn't reach the server — bail, do NOT conclude
        // "empty" (that would spuriously re-insert) and do NOT reconcile against a
        // record we never read.
        let serverActiveProgram: ProgramRow?
        do {
            serverActiveProgram = try await supabaseClient.fetchActiveProgram(userId: owner)
        } catch {
            programPersistLogger.notice("backfill/reconcile: server fetch failed; bailing — a later load retries")
            return
        }

        guard let serverProgram = serverActiveProgram else {
            // Server is genuinely empty under a real owner → backfill the cached
            // program via the shared resolve-before-stamp helper (#424). Idempotent.
            let didPersist = await OnboardingProgramPersist.persistIfOwnerResolved(
                cached,
                owner: owner,
                client: supabaseClient
            )
            if didPersist {
                programPersistLogger.notice("backfill: re-persisted local-only program to server under resolved owner")
            }
            return
        }

        // Server HAS an active program → reconcile its per-day statuses onto the
        // displayed cache (#444, Q5).
        reconcileServerStatuses(from: serverProgram.toMesocycle(), into: cached)
    }

    /// #444 (Q5): merge the server's per-day `TrainingDayStatus` onto the cached
    /// mesocycle, preferring the MORE-ADVANCED status per day so neither a stale
    /// server nor a stale cache regresses real progress (terminal `.completed` /
    /// `.skipped` and `.paused` beat `.pending` / `.generated`).
    ///
    /// Only the SAME mesocycle is reconciled: the server program must share the
    /// cache's mesocycle id (the same client-generated program persisted via the
    /// shared path), and days are matched by their stable `TrainingDay.id`. If the
    /// server is a different program entirely, the cache is left untouched — that
    /// is a #423/#425 backfill/regeneration concern, not a per-day status merge.
    ///
    /// Best-effort and non-fatal: a no-op when nothing is more advanced. Updates
    /// the in-memory state, view state, and UserDefaults so the reconciled
    /// progress survives the next launch.
    private func reconcileServerStatuses(from server: Mesocycle, into cached: Mesocycle) {
        guard server.id == cached.id else { return }

        // Build a day-id → server status lookup.
        var serverStatusByDay: [UUID: TrainingDayStatus] = [:]
        for week in server.weeks {
            for day in week.trainingDays {
                serverStatusByDay[day.id] = day.status
            }
        }

        var merged = cached
        var changed = false
        for wIdx in merged.weeks.indices {
            for dIdx in merged.weeks[wIdx].trainingDays.indices {
                let day = merged.weeks[wIdx].trainingDays[dIdx]
                guard let serverStatus = serverStatusByDay[day.id] else { continue }
                if Self.statusRank(serverStatus) > Self.statusRank(day.status) {
                    merged.weeks[wIdx].trainingDays[dIdx].status = serverStatus
                    changed = true
                }
            }
        }

        guard changed else { return }
        merged.saveToUserDefaults()
        currentMesocycle = merged
        viewState = .loaded(merged)
        programPersistLogger.notice("reconcile: honored more-advanced server statuses on \(merged.id.uuidString, privacy: .public)")
    }

    /// Advancement rank for `TrainingDayStatus` (higher = more advanced). Terminal
    /// statuses outrank in-flight ones; `.completed` and `.skipped` tie (both
    /// terminal). Used by `reconcileServerStatuses` to pick the winner per day.
    private static func statusRank(_ status: TrainingDayStatus) -> Int {
        switch status {
        case .pending:   return 0
        case .generated: return 1
        case .paused:    return 2
        case .completed: return 3
        case .skipped:   return 3
        }
    }

    /// #444 (Q5): re-persist the updated mesocycle to the server after a
    /// `markDay*` status change so the durable server record matches local
    /// progress (a reinstall / cache-clear otherwise reverts completed days to
    /// pending and feeds wrong-day routing).
    ///
    /// Owner-gated (resolve-before-stamp; never under the placeholder/unresolved
    /// owner — the #369 pattern) and best-effort: the in-memory + UserDefaults
    /// update by the caller is already the local source of truth, so a failed
    /// server write is non-fatal and arms no banner. Reuses the shared
    /// `OnboardingProgramPersist.persistIfOwnerResolved` helper (idempotent
    /// upsert on the client-generated program id) — the same path #424/#425 use.
    private func persistDayStatusUpdate(_ mesocycle: Mesocycle) async {
        let owner = await resolveOwner()
        let didPersist = await OnboardingProgramPersist.persistIfOwnerResolved(
            mesocycle,
            owner: owner,
            client: supabaseClient
        )
        if !didPersist {
            programPersistLogger.notice("markDay: status persist skipped (owner unresolved/placeholder) or failed; local cache intact")
        }
    }

    // MARK: - Regenerate

    /// Replaces the existing program with a freshly generated one, preserving all
    /// completed days exactly as they are. The new skeleton takes over from the
    /// first incomplete day forward — nothing already done is touched.
    ///
    /// Algorithm:
    ///   1. Snapshot all completed days from the old mesocycle (ordered by week/day index).
    ///   2. Clear the local cache so the new program is not shadowed by the old one.
    ///   3. Generate a new program via the shared path.
    ///   4. Graft the completed days back into the new mesocycle at the same flat index
    ///      positions, overwriting whatever the new generation put there.
    ///   5. Mark grafted days as `.completed` so they are read-only in the new program.
    ///   6. Persist the merged mesocycle.
    ///
    /// Called from Settings → "Regenerate Program".
    func regenerateProgram(gymProfile: GymProfile) async {
        // #439 (Q3 = refuse-and-prompt): a live/paused session sentinel pins the
        // current mesocycle's day UUIDs. Regenerating would mint a fresh mesocycle
        // with new UUIDs and orphan the sentinel (its trainingDayId would point at a
        // deleted TrainingDay — "Session Not Found" / "Session Mismatch",
        // STATE-5/STATE-6). REFUSE: do not snapshot, clear the cache, or generate.
        // Surface the refusal so the call site can prompt the user to finish or
        // abandon the paused session first.
        guard PausedSessionState.load() == nil else {
            regenerationBlockedBySession = true
            return
        }
        regenerationBlockedBySession = false

        // 1. Snapshot completed days (flat ordered list) before clearing cache.
        let completedDaySnapshots = snapshotCompletedDays()

        // 2. Clear the local cache so generation is not shadowed by old data.
        Mesocycle.clearUserDefaults()

        // 3. Generate a new skeleton via FB-008 path (skip Supabase — we persist after grafting).
        await generateMacroSkeleton(gymProfile: gymProfile, persistToSupabase: false)

        // 4. Graft completed days back if we have any and generation succeeded.
        guard !completedDaySnapshots.isEmpty,
              var mesocycle = currentMesocycle else { return }

        let graftCount = completedDaySnapshots.count
        var flatIndex = 0
        outer: for wIdx in mesocycle.weeks.indices {
            for dIdx in mesocycle.weeks[wIdx].trainingDays.indices {
                if flatIndex < graftCount {
                    // Overwrite with the completed snapshot; keep its .completed status.
                    mesocycle.weeks[wIdx].trainingDays[dIdx] = completedDaySnapshots[flatIndex]
                    flatIndex += 1
                } else {
                    break outer
                }
            }
        }

        // 5. Persist the merged result.
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)

        // Persist to Supabase in the background. Failure surfaces via persistError
        // banner (#188) — local-first design; local state is already updated above.
        Task { await self.persistProgram(mesocycle, context: "regenerateProgram") }
    }

    /// Returns a flat list of all terminal TrainingDays (`.completed` or `.skipped`) in the
    /// current mesocycle, ordered by week then day index.
    /// Used by `regenerateProgram` to graft resolved days into the new programme so training
    /// history is not lost across regenerations.
    private func snapshotCompletedDays() -> [TrainingDay] {
        guard let mesocycle = currentMesocycle else { return [] }
        return mesocycle.weeks.flatMap { week in
            week.trainingDays.filter(\.isTerminal)
        }
    }

    // MARK: - Sync helper (#188)

    /// Deactivates existing programs and inserts a new row server-side.
    /// On failure, surfaces the error via `persistError` + `persistRetryAction`
    /// rather than swallowing it. Local state is unaffected (local-first design).
    ///
    /// - Parameters:
    ///   - mesocycle: The mesocycle to persist.
    ///   - context: A short label for the logger (e.g. "regenerateProgram").
    ///
    /// Internal (not private) so test targets can drive the owned write directly —
    /// same convention as `currentMesocycle` above. The public generate paths fire
    /// this on a detached Task that a unit test cannot deterministically await.
    func persistProgram(_ mesocycle: Mesocycle, context: String) async {
        // Re-resolve the owner at write time (#409). On a fresh launch the captured
        // `userId` can still be the pre-auth placeholder; stamping the `programs` row
        // under it produced the #369 owner-mismatch. resolveOwner mirrors
        // AppDependencies.resolvedOwnerUserId(): nil / placeholder means auth has not
        // resolved, so abort silently — the local cache is already saved by callers,
        // and #425 is the dedicated resolve-before-stamp backfill safety-net. This is
        // NOT the persistError "sync failed, tap to retry" state (retrying would just
        // re-abort), so clear both and log a notice instead of arming a banner.
        guard let owner = await resolveOwner(), owner != AppDependencies.placeholderUserId else {
            persistError = nil
            persistRetryAction = nil
            programPersistLogger.notice("persistProgram: owner unresolved/placeholder; skipping server stamp (local cache intact)")
            return
        }

        let capturedClient = supabaseClient
        let capturedMesocycle = mesocycle
        do {
            // Atomic server-side deactivate-old + upsert-new in one transaction
            // (#189): replaces the non-transactional PATCH-then-POST whose partial
            // failure could leave the user with zero active programs. Idempotent
            // on retry (upsert on the client-generated program id).
            try await capturedClient.deactivateAndInsertProgram(capturedMesocycle, userId: owner)
            // Success: clear any prior sync error.
            persistError = nil
            persistRetryAction = nil
        } catch {
            programPersistLogger.error(
                """
                program insert failed (\(context)): \
                \(error.localizedDescription, privacy: .public) — \
                user_id=\(owner.uuidString, privacy: .public), \
                program_id=\(capturedMesocycle.id.uuidString, privacy: .public). \
                Local cache preserved; row will not exist server-side until a successful retry.
                """
            )
            persistError = "Couldn't sync your program. Tap to retry."
            // Retry re-invokes persistProgram, which RE-RESOLVES the owner on each
            // attempt (#409) — so a retry never replays a captured/placeholder uid.
            persistRetryAction = { [weak self] in
                await self?.persistProgram(capturedMesocycle, context: context)
            }
        }
    }

    /// Dismisses the sync-error banner without retrying.
    func dismissPersistError() {
        persistError = nil
        persistRetryAction = nil
    }

    // MARK: - FB-008: Generate Macro Skeleton

    /// Generates a 12-week skeleton (phase structure + week intents, no exercises).
    /// The resulting Mesocycle has all TrainingDays as `.pending` stubs.
    ///
    /// - Parameter persistToSupabase: When false, skips the Supabase write so the
    ///   caller (e.g. regenerateProgram) can write after applying its own post-processing.
    func generateMacroSkeleton(gymProfile: GymProfile, persistToSupabase: Bool = true) async {
        guard await !macroPlanService.isGenerating else { return }
        viewState = .generating

        // Read onboarding profile from UserDefaults if available (#318 U4).
        let profile = GenerationUserProfile.assemble(
            digestGoalStatement: await traineeModelService?.digest()?.goal.statement
        )
        let daysPerWeek: Int = {
            let v = UserDefaults.standard.integer(forKey: UserProfileConstants.daysPerWeekKey)
            return v > 0 ? v : 4
        }()

        // Carry the user's established day-label convention into generation so a
        // regen reuses it instead of inventing a fresh one that detaches lift
        // history (#172/#141). Empty for a first program — the LLM derives labels.
        let historicalDayLabels = await fetchHistoricalDayLabels()

        print("[ProgramViewModel] generateMacroSkeleton — training_days_per_week: \(daysPerWeek), historical_day_labels: \(historicalDayLabels)")

        do {
            let skeleton = try await macroPlanService.generateSkeleton(
                userId: userId,
                gymProfile: gymProfile,
                experienceLevel: profile.experienceLevel,
                goals: profile.goals,
                bodyweightKg: profile.bodyweightKg,
                ageYears: profile.ageYears,
                trainingAge: profile.trainingAge,
                trainingDaysPerWeek: daysPerWeek,
                historicalDayLabels: historicalDayLabels
            )

            // Build pending mesocycle from skeleton
            let mesocycle = MacroPlanService.buildPendingMesocycle(from: skeleton, userId: userId)

            if persistToSupabase {
                // Persist to Supabase in the background. Failure surfaces via
                // persistError banner (#188) — local-first design.
                Task { await self.persistProgram(mesocycle, context: "generateMacroSkeleton") }
            }
            mesocycle.saveToUserDefaults()
            currentMesocycle = mesocycle
            viewState = .loaded(mesocycle)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    /// Fetches the user's established day-label convention from past sessions so a
    /// regenerated program reuses it instead of inventing a fresh convention (#172).
    /// Returns the distinct `day_type` values from the user's recent sessions,
    /// most-recent-first, or `[]` for a user with no history (first program).
    /// Best-effort: a fetch failure just falls back to LLM-derived labels.
    private func fetchHistoricalDayLabels() async -> [String] {
        do {
            let sessions = try await supabaseClient.fetch(
                SessionMetaRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id", op: .eq,  value: userId.uuidString),
                    Filter(column: "status",  op: .neq, value: "abandoned")
                ],
                order: "session_date.desc",
                limit: 30
            )
            // Distinct labels, preserving most-recent-first order.
            var seen = Set<String>()
            var labels: [String] = []
            for session in sessions where !session.dayType.isEmpty {
                if seen.insert(session.dayType).inserted { labels.append(session.dayType) }
            }
            return labels
        } catch {
            return []
        }
    }

    // MARK: - FB-008: Generate Day Session

    /// Called when the user taps "Start Workout" on a `.pending` day.
    /// Shows a loading state, calls SessionPlanService, and mutates the day in-place.
    ///
    /// - Parameters:
    ///   - day: The pending TrainingDay stub.
    ///   - week: The containing TrainingWeek.
    ///   - gymProfile: User's gym equipment profile.
    /// - Returns: The generated (populated) TrainingDay, or nil on failure.
    @discardableResult
    func generateDaySession(
        day: TrainingDay,
        week: TrainingWeek,
        gymProfile: GymProfile
    ) async -> TrainingDay? {
        guard day.status == .pending else { return day }

        viewState = .generatingSession(dayId: day.id)

        // #564: the user profile that fed the from-scratch session LLM is no
        // longer needed — the deterministic autoregulator instantiates from the
        // frozen committed slot + the digest below.

        // ── Step 1: Fetch recent session metadata (last 7 days) for fatigue signals ──
        // Uses a lightweight SessionMetaRow instead of the full WorkoutSession, avoiding
        // the broken nested set_logs join that was causing recentSetLogs to always be [].
        var recentSetLogs: [SetLog] = []
        var weekSessionCount: Int = 0
        // recentSessions hoisted to outer scope so TemporalContext assembly can read it.
        var recentSessions: [SessionMetaRow] = []
        do {
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            recentSessions = try await supabaseClient.fetch(
                SessionMetaRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",      op: .eq,  value: userId.uuidString),
                    Filter(column: "session_date", op: .gte, value: ISO8601DateFormatter().string(from: sevenDaysAgo)),
                    Filter(column: "completed",    op: .is,  value: "true")
                ],
                order: "session_date.desc"
            )
            weekSessionCount = recentSessions.count
            if recentSessions.isEmpty {
                recentSetLogs = []
            } else {
                let ids = recentSessions.map(\.id.uuidString)
                let inValue = "(\(ids.joined(separator: ",")))"
                recentSetLogs = try await supabaseClient.fetch(
                    SetLog.self,
                    table: "set_logs",
                    filters: [Filter(column: "session_id", op: .in, value: inValue)]
                )
            }
        } catch {
            recentSetLogs = []
            weekSessionCount = 0
        }

        // ── Step 2: Per-exercise deep history (no date cap) ──
        // Fetch the last 10 sessions of this day type across all time and pull their set_logs.
        // No completed/status filter — sessions where the WAQ completion PATCH didn't arrive
        // (app killed post-last-set, network failure) are stored with completed=false but still
        // contain valid training data. Excluding them caused older sessions to be invisible,
        // making the AI treat exercises with weeks of history as first-time lifts.
        //
        // The previousExerciseIds block is used only to decide whether Supabase has any data
        // at all for this day type. We check EITHER the in-memory mesocycle (has completed days
        // with exercises) OR fall through to Supabase regardless when in doubt.
        var deepLiftHistory: [SetLog] = []
        do {
            // Consider a previous instance to exist if the mesocycle has ANY generated/completed
            // day with this label, even if exercises weren't persisted locally — Supabase is the
            // source of truth for lift history.
            let hasLocalHistory: Bool = {
                guard let mesocycle = currentMesocycle else { return false }
                return mesocycle.weeks
                    .flatMap(\.trainingDays)
                    .contains { $0.dayLabel == day.dayLabel && ($0.status == .completed || $0.status == .generated) }
            }()

            if !hasLocalHistory {
                // Genuinely first time this day label has been seen — use 7-day window
                deepLiftHistory = recentSetLogs
            } else {
                // Fetch the last 10 sessions of this day type (no date constraint, no status filter)
                let deepSessions = try await supabaseClient.fetch(
                    SessionMetaRow.self,
                    table: "workout_sessions",
                    filters: [
                        Filter(column: "user_id",  op: .eq,  value: userId.uuidString),
                        Filter(column: "day_type", op: .eq,  value: day.dayLabel),
                        Filter(column: "status",   op: .neq, value: "abandoned")
                    ],
                    order: "session_date.desc",
                    limit: 10
                )
                if deepSessions.isEmpty {
                    deepLiftHistory = recentSetLogs
                } else {
                    let deepIds = deepSessions.map(\.id.uuidString)
                    let deepInValue = "(\(deepIds.joined(separator: ",")))"
                    deepLiftHistory = try await supabaseClient.fetch(
                        SetLog.self,
                        table: "set_logs",
                        filters: [Filter(column: "session_id", op: .in, value: deepInValue)]
                    )
                }
            }
        } catch {
            deepLiftHistory = recentSetLogs
        }

        // Per-exercise session count — visible in console to verify lookback depth
        let exerciseSessionCounts = Dictionary(grouping: deepLiftHistory) { $0.exerciseId }
            .mapValues { logs in Set(logs.map { $0.sessionId }).count }
        print("[ProgramViewModel] deepLiftHistory: \(deepLiftHistory.count) set_log(s) across \(exerciseSessionCounts.count) exercise(s):")
        for (exerciseId, count) in exerciseSessionCounts.sorted(by: { $0.key < $1.key }) {
            print("[ProgramViewModel]   • \(exerciseId): \(count) session(s)")
        }

        // ── Step 3: Assemble TemporalContext — gap-awareness + per-pattern phase for the LLM ──
        // daysSinceLastSession: from the most recent session in the 7-day window (any type),
        // or fall back to the most recent date in deepLiftHistory.
        let temporalContext: TemporalContext = {
            let calendar = Calendar.current
            let now = Date()

            // daysSinceLastSession — prefer 7-day window first (ordered desc)
            var daysSinceLastSession: Int? = nil
            if let mostRecentSession = recentSessions.first {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                if let sessionDate = dateFormatter.date(from: mostRecentSession.sessionDate) {
                    daysSinceLastSession = calendar.dateComponents([.day], from: sessionDate, to: now).day
                }
            } else if let mostRecentLog = deepLiftHistory.max(by: { $0.loggedAt < $1.loggedAt }) {
                daysSinceLastSession = calendar.dateComponents([.day], from: mostRecentLog.loggedAt, to: now).day
            }

            // daysSinceLastTrainedByPattern — aggregate deepLiftHistory by movement pattern
            var patternMostRecent: [String: Date] = [:]
            for log in deepLiftHistory {
                guard let pattern = ExerciseLibrary.lookup(log.exerciseId)?.movementPattern.rawValue
                else { continue }
                if let existing = patternMostRecent[pattern] {
                    if log.loggedAt > existing { patternMostRecent[pattern] = log.loggedAt }
                } else {
                    patternMostRecent[pattern] = log.loggedAt
                }
            }
            var daysSinceByPattern: [String: Int] = [:]
            for (pattern, date) in patternMostRecent {
                if let days = calendar.dateComponents([.day], from: date, to: now).day {
                    daysSinceByPattern[pattern] = days
                }
            }

            // skippedSessionCountLast30Days — from local mesocycle cache
            let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            let skippedCount = currentMesocycle?.weeks
                .flatMap(\.trainingDays)
                .filter { $0.status == .skipped && ($0.skippedAt ?? .distantPast) >= thirtyDaysAgo }
                .count ?? 0

            return TemporalContext(
                daysSinceLastSession: daysSinceLastSession,
                daysSinceLastTrainedByPattern: daysSinceByPattern,
                skippedSessionCountLast30Days: skippedCount,
                // #561: no global calendar phase/week — the per-pattern engine is the sole clock.
                requiresReturnPhaseOverride: (daysSinceLastSession ?? 0) >= 28
            )
        }()

        // #564 (ADR-0030): deterministic instantiation — pull the frozen committed
        // slot (its exercises were committed by the block-commit call, #563) and
        // apply digest deltas as arithmetic. No LLM / no network call (replaces the
        // from-scratch SessionPlanService.generateSession on the live start path —
        // the root of the "Coach is offline" mid-flow stalls, #555/#556). The
        // trend is sourced from the digest hybrid verdict, not a local Epley dup.
        let digest = await traineeModelService?.digest()
        let generatedDay = SessionAutoregulator.instantiate(
            day: day,
            digest: digest,
            requiresReturnOverride: temporalContext.requiresReturnPhaseOverride
        )

        // Mutate mesocycle in-place.
        if var mesocycle = currentMesocycle {
            if let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == week.id }),
               let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == day.id }) {
                mesocycle.weeks[wIdx].trainingDays[dIdx] = generatedDay
                mesocycle.saveToUserDefaults()
                currentMesocycle = mesocycle
                viewState = .loaded(mesocycle)
            }
        }
        return generatedDay
    }

    // MARK: - FB-010: Mark Day Completed (manual log & live session)

    /// Marks a training day as `.completed` in the local mesocycle cache.
    /// Triggers an immediate view state update so the calendar and progress bar re-render.
    func markDayCompleted(dayId: UUID, weekId: UUID) {
        guard var mesocycle = currentMesocycle else {
            print("[ProgramViewModel] markDayCompleted — no currentMesocycle, ignoring dayId: \(dayId)")
            return
        }
        guard let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == weekId }),
              let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == dayId })
        else {
            print("[ProgramViewModel] markDayCompleted — day not found: dayId=\(dayId) weekId=\(weekId)")
            return
        }
        mesocycle.weeks[wIdx].trainingDays[dIdx].status = .completed
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)
        print("[ProgramViewModel] markDayCompleted ✓ — dayId: \(dayId), week \(mesocycle.weeks[wIdx].weekNumber)")
        // #444 (Q5): persist the updated per-day status to the server so a
        // reinstall / cache-clear can't revert it to pending. Owner-gated +
        // best-effort; UserDefaults above remains the local source of truth.
        let updated = mesocycle
        Task { await self.persistDayStatusUpdate(updated) }
    }

    // MARK: - Pause support

    /// Marks a training day as `.paused` in the local mesocycle cache.
    /// Called by ProgramDayDetailView when WorkoutView fires `onSessionPaused`.
    func markDayPaused(dayId: UUID, weekId: UUID) {
        guard var mesocycle = currentMesocycle else { return }
        guard let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == weekId }),
              let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == dayId })
        else { return }
        mesocycle.weeks[wIdx].trainingDays[dIdx].status = .paused
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)
        print("[ProgramViewModel] markDayPaused ✓ — dayId: \(dayId), week \(mesocycle.weeks[wIdx].weekNumber)")
        // #444 (Q5): persist the updated per-day status to the server. Owner-gated
        // + best-effort; UserDefaults above remains the local source of truth.
        let updated = mesocycle
        Task { await self.persistDayStatusUpdate(updated) }
    }

    // MARK: - Mark Day Skipped (Phase-1-Skip)

    /// Marks a training day as `.skipped` in the local mesocycle cache.
    ///
    /// This is the persistent skip — it advances programme position (Day X of Y) and
    /// permanently records the skip. The day's exercises are preserved so the user can
    /// view what was planned. Called from PreWorkoutView and ProgramDayDetailView.
    ///
    /// Programme progression rule: `programme_day_index` advances by +1 on every
    /// transition to `.completed` OR `.skipped`. Calendar logic never advances it.
    func markDaySkipped(dayId: UUID, weekId: UUID) {
        guard var mesocycle = currentMesocycle else {
            print("[ProgramViewModel] markDaySkipped — no currentMesocycle, ignoring dayId: \(dayId)")
            return
        }
        guard let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == weekId }),
              let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == dayId })
        else {
            print("[ProgramViewModel] markDaySkipped — day not found: dayId=\(dayId) weekId=\(weekId)")
            return
        }
        mesocycle.weeks[wIdx].trainingDays[dIdx].status = .skipped
        mesocycle.weeks[wIdx].trainingDays[dIdx].skippedAt = Date()
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)
        print("[ProgramViewModel] markDaySkipped ✓ — dayId: \(dayId), week \(mesocycle.weeks[wIdx].weekNumber)")
        // #444 (Q5): persist the updated per-day status to the server. Owner-gated
        // + best-effort; UserDefaults above remains the local source of truth.
        let updated = mesocycle
        Task { await self.persistDayStatusUpdate(updated) }
    }

    // MARK: - Regenerate session (#318 U4 / J-F10)

    /// Resets a `.generated` day back to `.pending` so its session can be
    /// regenerated via the normal on-demand path. The day id is PRESERVED so
    /// sentinel matching and history queries still hold.
    ///
    /// Refuses (no-op) unless the day is eligible:
    ///   • status must be `.generated` — completed/paused/skipped/pending days
    ///     are historical, live, or already pending;
    ///   • no matching paused-session sentinel — `PausedSessionState` is written
    ///     at session start and updated every set, so a matching sentinel means
    ///     a live or paused session (with logged sets) exists for this day.
    func resetDayToPending(dayId: UUID, weekId: UUID) {
        guard var mesocycle = currentMesocycle else { return }
        guard let wIdx = mesocycle.weeks.firstIndex(where: { $0.id == weekId }),
              let dIdx = mesocycle.weeks[wIdx].trainingDays.firstIndex(where: { $0.id == dayId })
        else { return }
        guard mesocycle.weeks[wIdx].trainingDays[dIdx].status == .generated else {
            print("[ProgramViewModel] resetDayToPending — refused, status is \(mesocycle.weeks[wIdx].trainingDays[dIdx].status), dayId: \(dayId)")
            return
        }
        if PausedSessionState.load()?.trainingDayId == dayId {
            print("[ProgramViewModel] resetDayToPending — refused, session sentinel matches dayId: \(dayId)")
            return
        }
        mesocycle.weeks[wIdx].trainingDays[dIdx].status = .pending
        mesocycle.weeks[wIdx].trainingDays[dIdx].exercises = []
        mesocycle.saveToUserDefaults()
        currentMesocycle = mesocycle
        viewState = .loaded(mesocycle)
        print("[ProgramViewModel] resetDayToPending ✓ — dayId: \(dayId), week \(mesocycle.weeks[wIdx].weekNumber)")
    }

    // MARK: - Computed helpers

    /// Current week index (0-based) based on training-time progression.
    ///
    /// Returns the index of the week that contains the next incomplete (non-completed,
    /// non-skipped) training day. This decouples programme position from calendar dates:
    /// the "current week" advances when the user completes or skips sessions, not when
    /// the calendar ticks over.
    ///
    /// If all days are done, returns the last week index.
    func currentWeekIndex(in mesocycle: Mesocycle) -> Int {
        for (wIdx, week) in mesocycle.weeks.enumerated() {
            for day in week.trainingDays {
                if !day.isTerminal {
                    return wIdx
                }
            }
        }
        // All days completed or skipped — return last week
        return max(0, mesocycle.weeks.count - 1)
    }

    /// Day IDs skipped this session (in-memory only; resets on app relaunch).
    /// When the user taps "Skip session" on the pre-workout screen, the day is added here
    /// so nextIncompleteDay() moves past it to the next pending day.
    private(set) var skippedDayIds: Set<UUID> = []

    /// Defers a training day for the current session by adding its ID to the skip set.
    /// Does not affect programme progress or session records — the day remains pending
    /// and will surface again on next launch (or after all other pending days complete).
    func skipDay(_ dayId: UUID) {
        skippedDayIds.insert(dayId)
    }

    /// Returns the first TrainingDay across all weeks where status is neither `.completed`
    /// nor `.skipped` (persistent), and the day has not been deferred this session (soft skip).
    /// Returns nil when every day is completed or skipped. Searches weeks in order, days within each week in order.
    /// If all remaining days have been soft-skipped this session, clears the defer set and starts over.
    func nextIncompleteDay(in mesocycle: Mesocycle) -> (day: TrainingDay, week: TrainingWeek)? {
        for week in mesocycle.weeks {
            for day in week.trainingDays {
                // Skip permanently-skipped and completed days; also skip soft-deferred days.
                if !day.isTerminal && !skippedDayIds.contains(day.id) {
                    return (day, week)
                }
            }
        }
        // All non-terminal days were soft-deferred — reset so the user isn't blocked indefinitely
        if !skippedDayIds.isEmpty {
            skippedDayIds = []
            return nextIncompleteDay(in: mesocycle)
        }
        return nil
    }

    /// Searches every week in `mesocycle` for a `TrainingDay` whose `id` matches `id`.
    ///
    /// Used by crash-recovery routing to locate a paused session's training day when
    /// its `trainingDayId` does not match `nextIncompleteDay` (e.g. after programme
    /// regeneration that changed day UUIDs).
    func findTrainingDay(byId id: UUID, in mesocycle: Mesocycle) -> (day: TrainingDay, week: TrainingWeek)? {
        for week in mesocycle.weeks {
            if let day = week.trainingDays.first(where: { $0.id == id }) {
                return (day: day, week: week)
            }
        }
        return nil
    }

}
