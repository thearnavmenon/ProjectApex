// Services/TraineeModelService.swift
// ProjectApex
//
// Read-side actor exposing the canonical interface to the trainee model
// for the rest of the app. Phase 1 / Slice 10, issue #11. ADR-0005 / ADR-0006.
//
// Three async public methods:
//   • read()                    -> TraineeModel?         — cached snapshot or nil
//   • digest()                  -> TraineeModelDigest?   — narrow prompt projection
//   • enqueueUpdate(forSession:setLogs:)                 — WAQ enqueue (#135)
//
// Returning Optional from digest() rather than the issue-specified
// `TraineeModelDigest` is a deliberate Phase-1 choice: the digest carries a
// non-optional GoalState, and synthesising a placeholder goal at cold-start
// would lie about onboarding state. The cold-start path is defined as
// "no digest available yet" — call sites decide whether to skip the
// trainee-model section of the prompt or to wait until the first server
// update lands.
//
// State is held privately (the store and queue references are immutable
// `let`s; there is no per-instance mutable state). Public methods only —
// no reach-into-internals from callers.
//
// The store is @MainActor-isolated (see TraineeModelLocalStore.swift —
// SwiftData ModelContainer requires main-actor executor); calls into it
// hop the actor boundary via `await`. The WriteAheadQueue is its own
// actor; same.
//
// Out of scope (Phase 2 / later slices):
//   • Update-rule logic — runs server-side via Edge Function (ADR-0006).
//   • TraineeModelUpdateJob WAQ flush handler that routes
//     "trainee_model_updates" items to update-trainee-model rather than
//     to a Postgres insert (Slice 11 / #12). Until that lands, items
//     enqueued here will be retried by the existing flush against
//     Supabase REST and dropped after maxRetries — an accepted gap for
//     the slice boundary.
//   • Per-context filtering of prescription accuracy — needs a
//     request-context type that does not yet exist.

import Foundation

actor TraineeModelService {

    // MARK: - Dependencies

    private let store: TraineeModelLocalStore
    private let writeAheadQueue: WriteAheadQueue
    private let now: @Sendable () -> Date

    // MARK: - WAQ table key
    //
    // Sentinel table name for trainee-model-update items. Slice 11 will
    // teach the WAQ flush handler to route this table to the
    // update-trainee-model Edge Function rather than a Postgres insert.
    // Plural form follows the existing WAQ convention (set_logs,
    // workout_sessions, session_notes).
    static let waqTable = "trainee_model_updates"

    // MARK: - Init

    init(store: TraineeModelLocalStore,
         writeAheadQueue: WriteAheadQueue,
         now: @Sendable @escaping () -> Date = Date.init) {
        self.store = store
        self.writeAheadQueue = writeAheadQueue
        self.now = now
    }

    // MARK: - Read

    /// Returns the cached TraineeModel snapshot, or nil if the local
    /// store is empty (cold-start path, before the first server update
    /// hydrates the cache).
    func read() async -> TraineeModel? {
        await store.load()
    }

    /// Returns the request-time digest projection of the cached model,
    /// or nil if the local store is empty (cold-start / pre-onboarding,
    /// before the first server update hydrates the cache).
    ///
    /// Callers must handle the nil case — do not assume a digest is
    /// always present. Typical guard pattern:
    ///
    ///     guard let digest = await service.digest() else {
    ///         // trainee model not yet available; skip prompt section
    ///         return
    ///     }
    ///
    /// See file header for the rationale for the Optional return.
    func digest(weeklyFatigue: WeekFatigueSignals? = nil) async -> TraineeModelDigest? {
        guard let model = await store.load() else { return nil }
        return TraineeModelDigest(from: model, weeklyFatigue: weeklyFatigue, asOf: now())
    }

    // MARK: - Write — local acknowledgment

    /// #258: records local acknowledgment of a heavy-reassessment GPA fire so the
    /// pre-workout banner and the LLM prompt block disappear immediately on Save —
    /// the `update-trainee-goal` EF returns no model, so the cache can't refresh from
    /// the server round-trip; this is the client-side write that hides the banner.
    /// No-op if no model is cached. Idempotent (Set insert).
    func acknowledgeReassessment(triggeringSessionCount: Int) async throws {
        guard var model = await store.load() else { return }
        model.acknowledgedTriggeringSessionCounts.insert(triggeringSessionCount)
        try await store.save(model)
    }

    /// #269: records local acknowledgment of the one-time calibration-review
    /// display so the pre-workout calibration banner disappears immediately once
    /// the user has seen the read-only projection screen. No-op if no model is
    /// cached. Idempotent (a plain Bool set).
    func acknowledgeCalibrationReview() async throws {
        guard var model = await store.load() else { return }
        model.calibrationReviewAcknowledged = true
        try await store.save(model)
    }

    // MARK: - Write — enqueue path

    /// Enqueues a `trainee_model_update` item carrying the session-
    /// completion shape expected by the update-trainee-model Edge
    /// Function:
    ///
    ///     { "user_id": <uuid>, "session_id": <uuid>,
    ///       "session_payload": { "logged_at": "...", "set_logs": [...] } }
    ///
    /// `loggedAt` is generated at call time — it represents the moment the
    /// session was applied, and is the watermark the Edge Function uses for
    /// in-order / late-arrival classification (ADR-0008). Set logs without
    /// an `intent` value are skipped: the Edge Function rejects the entire
    /// payload if any element is missing intent (validateRequest in
    /// supabase/functions/update-trainee-model/index.ts).
    func enqueueUpdate(forSession session: WorkoutSession, setLogs: [SetLog]) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = TraineeModelUpdatePayload(
            userId: session.userId,
            sessionId: session.id,
            sessionPayload: SessionUpdatePayload(
                loggedAt: formatter.string(from: now()),
                setLogs: setLogs.compactMap(TraineeModelSetLogPayload.init(from:))
            )
        )
        try await writeAheadQueue.enqueue(payload, table: Self.waqTable)
    }
}

// MARK: - Edge Function payload shape
//
// Mirrors the contract enforced by supabase/functions/update-trainee-model
// /index.ts (see ADR-0006 §3): top-level keys must be exactly user_id,
// session_id, session_payload — snake_case, with both IDs as UUID strings
// and session_payload as a JSON object.

nonisolated struct TraineeModelUpdatePayload: Codable, Sendable {
    let userId: UUID
    let sessionId: UUID
    let sessionPayload: SessionUpdatePayload

    enum CodingKeys: String, CodingKey {
        case userId         = "user_id"
        case sessionId      = "session_id"
        case sessionPayload = "session_payload"
    }
}

/// Session-level payload consumed by update-trainee-model Edge Function.
/// `logged_at` is the watermark (ADR-0008) and is required — missing/invalid
/// fails applySession before any model mutation. `set_logs` may be empty
/// (the apply still records an idempotency row in `trainee_model_applied_sessions`).
nonisolated struct SessionUpdatePayload: Codable, Sendable {
    let loggedAt: String
    let setLogs: [TraineeModelSetLogPayload]

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at"
        case setLogs  = "set_logs"
    }
}

/// Per-set entry inside `session_payload.set_logs`. Mirrors the fields the
/// Edge Function's rule pipelines consume (per-exercise EWMA, plateau-verdict,
/// stimulus classifier, prescription-accuracy). `intent` is required and must
/// be one of warmup/top/backoff/technique/amrap — Swift `SetLog.intent` is
/// Optional for backwards-compatibility with pre-Phase-2 rows, so sets without
/// intent are filtered out before enqueue.
///
/// Named distinctly from `SetLogPayload` (WorkoutSessionManager's private wire
/// type for direct `set_logs` table inserts) to avoid the module-level
/// redeclaration clash that would otherwise surface.
nonisolated struct TraineeModelSetLogPayload: Codable, Sendable {
    let exerciseId: String
    let setNumber: Int
    let weightKg: Double
    let repsCompleted: Int
    let rpeFelt: Int?
    let intent: String

    enum CodingKeys: String, CodingKey {
        case exerciseId    = "exercise_id"
        case setNumber     = "set_number"
        case weightKg      = "weight_kg"
        case repsCompleted = "reps_completed"
        case rpeFelt       = "rpe_felt"
        case intent
    }

    init?(from setLog: SetLog) {
        guard let intent = setLog.intent else { return nil }
        self.exerciseId    = setLog.exerciseId
        self.setNumber     = setLog.setNumber
        self.weightKg      = setLog.weightKg
        self.repsCompleted = setLog.repsCompleted
        self.rpeFelt       = setLog.rpeFelt
        self.intent        = intent.rawValue
    }
}
