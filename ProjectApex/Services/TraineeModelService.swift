// Services/TraineeModelService.swift
// ProjectApex
//
// Read-side actor exposing the canonical interface to the trainee model
// for the rest of the app. Phase 1 / Slice 10, issue #11. ADR-0005 / ADR-0006.
//
// Three async public methods:
//   • read()                    -> TraineeModel?         — cached snapshot or nil
//   • digest()                  -> TraineeModelDigest?   — narrow prompt projection
//   • enqueueUpdate(forSession:)                         — WAQ enqueue (Phase 1 storage path)
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
    /// or nil if the local store is empty. See file header for the
    /// rationale for the Optional return.
    func digest() async -> TraineeModelDigest? {
        guard let model = await store.load() else { return nil }
        return TraineeModelDigest(from: model, asOf: now())
    }

    // MARK: - Write — enqueue path only (Phase 1)

    /// Enqueues a `trainee_model_update` item carrying the session-
    /// completion shape expected by the update-trainee-model Edge
    /// Function:
    ///
    ///     { "user_id": <uuid>, "session_id": <uuid>, "session_payload": { … } }
    ///
    /// Phase 1 sends an empty `session_payload` object — the
    /// shape is the contract; the contents are filled in by Phase 2
    /// when rule logic ships and the Edge Function actually consumes
    /// session data.
    func enqueueUpdate(forSession session: WorkoutSession) async throws {
        let payload = TraineeModelUpdatePayload(
            userId: session.userId,
            sessionId: session.id,
            sessionPayload: SessionUpdatePayload()
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

/// Phase 1 placeholder — encodes as an empty JSON object `{}`. Phase 2
/// extends this struct with set_logs, session notes, and any other fields
/// the Edge Function rule logic needs. Keeping it as a dedicated type
/// (rather than `[String: String]()`) means Phase 2 changes are additive
/// — the empty object remains valid against any future fields-all-optional
/// shape.
nonisolated struct SessionUpdatePayload: Codable, Sendable {}
