// Services/WriteAheadQueue.swift
// ProjectApex — P3-T06
//
// Actor-isolated local write-ahead queue for reliable Supabase writes.
//
// Every set log is written to the local queue first, then async-POSTed to
// Supabase. If the remote write fails, exponential backoff retries ensure
// delivery (1s, 2s, 4s, 8s, 16s — max 5 retries). Items are only removed
// from the queue on HTTP 201 (success).
//
// flush() is called on:
//   • App returning to foreground (scenePhase → .active)
//   • Network restoration (NWPathMonitor)
//
// Queue processes items in strict FIFO order.
//
// IMPORTANT: This actor does NOT use SwiftData/NSManagedObject internally.
// Queue items are plain Codable structs persisted to UserDefaults for
// MVP simplicity, avoiding SwiftData actor-boundary pitfalls (see risk note
// on P3-T06). A SwiftData-backed store can replace the persistence layer
// in a future iteration without changing the public API.

import Foundation
import OSLog

// MARK: - QueuedWrite

/// A single pending write operation stored in the local queue.
nonisolated struct QueuedWrite: Codable, Identifiable, Sendable {
    let id: UUID
    let table: String
    let payload: Data      // JSON-encoded Encodable payload
    let createdAt: Date
    var retryCount: Int

    /// Constructs a QueuedWrite from any Encodable payload.
    init<T: Encodable>(table: String, item: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.id = UUID()
        self.table = table
        self.payload = try encoder.encode(item)
        self.createdAt = Date()
        self.retryCount = 0
    }

    /// Internal init for tests / deserialization.
    init(id: UUID, table: String, payload: Data, createdAt: Date, retryCount: Int) {
        self.id = id
        self.table = table
        self.payload = payload
        self.createdAt = createdAt
        self.retryCount = retryCount
    }
}

// MARK: - WAQFlushOutcome

/// Result of a single WAQ flush attempt, returned by both the default
/// Supabase-insert path and any registered custom flush handlers.
enum WAQFlushOutcome: Sendable, Equatable {
    /// Item was accepted by the remote end — remove from queue.
    case success
    /// Remote end is temporarily unavailable — retain item and retry with backoff.
    case transientFailure
    /// Remote end rejected the item permanently — log and remove without retry.
    case permanentFailure(String)

    static func == (lhs: WAQFlushOutcome, rhs: WAQFlushOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success), (.transientFailure, .transientFailure): return true
        case (.permanentFailure(let l), .permanentFailure(let r)): return l == r
        default: return false
        }
    }
}

// MARK: - WriteAheadQueue

/// Actor that guarantees reliable Supabase writes with local queuing and
/// exponential backoff retry. Per TDD §10.3.
actor WriteAheadQueue {

    // MARK: - Configuration

    /// Maximum number of retry attempts per item (5 retries = 6 total attempts).
    static let maxRetries = 5

    /// Default base delay for exponential backoff (1 second in production).
    /// Injectable via init so tests can exercise retry-exhaustion without
    /// waiting out the real 1+2+4+8+16s schedule.
    static let defaultBaseRetryDelay: TimeInterval = 1.0

    /// Maximum number of items allowed in the queue before rejecting new writes.
    static let maxQueueSize = 500

    /// UserDefaults key for persisting the queue across launches.
    private static let persistenceKey = "com.projectapex.writeAheadQueue"

    /// UserDefaults key for the dead-letter store (#184) — items that exhausted
    /// retries or were permanently rejected, retained for recovery/inspection
    /// instead of being silently lost.
    private static let deadLetterKey = "com.projectapex.writeAheadQueue.deadLetter"

    // MARK: - State

    /// In-memory FIFO queue of pending writes.
    private(set) var queue: [QueuedWrite] = []

    /// True while flush() is actively processing the queue.
    private(set) var isFlushing: Bool = false

    /// Set by clearAll() so an in-flight flush abandons its current item rather
    /// than indexing a queue that clearAll just emptied (#55).
    private var clearRequested = false

    /// Dead-letter store (#184): writes that exhausted retries or were
    /// permanently rejected. Persisted separately so they survive launches and
    /// can be recovered (e.g. by session resume) instead of being silently lost.
    private(set) var deadLetter: [QueuedWrite] = []

    /// Per-table flush handlers. When a table has a registered handler, the WAQ
    /// calls it instead of the default Supabase REST insert path. Registered at
    /// startup by job types such as TraineeModelUpdateJob.
    private var flushHandlers: [String: @Sendable (QueuedWrite) async -> WAQFlushOutcome] = [:]

    private static let logger = Logger(subsystem: "com.projectapex", category: "WriteAheadQueue")

    // MARK: - Dependencies

    private let supabase: SupabaseClient
    private let userDefaults: UserDefaults
    private let baseRetryDelay: TimeInterval

    /// Returns the current authenticated user ID, or nil when no session has
    /// resolved yet. Injected so the actor can check payload ownership at flush
    /// time without coupling to SupabaseAuth directly (#369 slice 5). Defaults to
    /// `{ nil }`, which disables the owner check (existing call-sites unchanged).
    private let currentAuthUid: @Sendable () async -> UUID?

    // MARK: - Init

    init(
        supabase: SupabaseClient,
        userDefaults: UserDefaults = .standard,
        baseRetryDelay: TimeInterval = WriteAheadQueue.defaultBaseRetryDelay,
        currentAuthUid: @escaping @Sendable () async -> UUID? = { nil }
    ) {
        self.supabase = supabase
        self.userDefaults = userDefaults
        self.baseRetryDelay = baseRetryDelay
        self.currentAuthUid = currentAuthUid
        // Restore any persisted queue + dead-letter items from a previous session
        self.queue = Self.loadPersistedQueue(userDefaults: userDefaults)
        self.deadLetter = Self.loadPersistedDeadLetter(userDefaults: userDefaults)
    }

    // MARK: - Handler Registration

    /// Registers a custom flush handler for `table`. When the WAQ encounters
    /// a queued item targeting that table, it calls `handler` instead of the
    /// default `supabase.insertRawJSON` path.
    ///
    /// Call this at app startup (before any WAQ flushes) via the job's
    /// `register(with:)` method.
    func registerFlushHandler(
        forTable table: String,
        _ handler: @escaping @Sendable (QueuedWrite) async -> WAQFlushOutcome
    ) {
        flushHandlers[table] = handler
    }

    // MARK: - Public API

    /// Enqueues a write operation. The item is persisted locally immediately,
    /// then a non-blocking flush attempt is triggered.
    ///
    /// - Parameters:
    ///   - item: The Encodable payload to write.
    ///   - table: The Supabase table name (e.g. "set_logs").
    /// - Throws: If the queue is full or encoding fails.
    func enqueue<T: Encodable & Sendable>(_ item: T, table: String) throws {
        guard queue.count < Self.maxQueueSize else {
            throw WriteAheadQueueError.queueFull
        }
        let entry = try QueuedWrite(table: table, item: item)
        queue.append(entry)
        persistQueue()

        // Non-blocking: attempt to flush
        Task { [weak self] in
            await self?.flush()
        }
    }

    /// Processes all queued items in FIFO order. Each item is dispatched to
    /// either a registered flush handler (for items whose table has a custom
    /// handler) or the default `supabase.insertRawJSON` path.
    ///
    /// Outcome semantics:
    ///   `.success`          — item removed from queue.
    ///   `.transientFailure` — exponential backoff retry up to maxRetries, then drop.
    ///   `.permanentFailure` — logged and removed immediately (no retry).
    ///
    /// Safe to call multiple times concurrently — the isFlushing guard
    /// ensures only one flush runs at a time.
    ///
    /// Persistence strategy [#369 perf-27]:
    ///   The queue is persisted **once** via the `defer` at the end of the flush
    ///   rather than after every individual item. This turns O(N²) UserDefaults
    ///   re-encodes into O(N).
    ///
    ///   Crash-safety reasoning:
    ///   • Items enter UserDefaults on `enqueue()` — before any flush attempt.
    ///   • On crash mid-flush, UserDefaults still holds the last `enqueue()`-time
    ///     snapshot. Items successfully sent in the current flush that haven't yet
    ///     been persisted will be re-sent on next launch. Set_log inserts are
    ///     idempotent by primary key (UUID), so duplicate sends are harmless.
    ///   • Un-sent items are never lost: they are only removed from the in-memory
    ///     queue after a confirmed `.success` or `.permanentFailure`, and the full
    ///     queue is written at flush completion.
    ///   • Dead-letter items are persisted immediately via `recordFailedWrite()`
    ///     so they survive a crash between queue removal and the final persist.
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        clearRequested = false
        defer {
            isFlushing = false
            // Single persist covering all mutations in this flush. [#369 perf-27]
            persistQueue()
        }

        while !queue.isEmpty {
            var item = queue[0]

            let outcome = await dispatch(item)

            // clearAll() may have emptied the queue during the await above;
            // abandon the in-flight item rather than indexing a now-empty
            // queue (which previously trapped with index-out-of-range). #55.
            if clearRequested { break }

            switch outcome {
            case .success:
                queue.removeFirst()
                // No per-item persistQueue() — deferred to end of flush. [#369 perf-27]

            case .permanentFailure(let reason):
                queue.removeFirst()
                recordFailedWrite(item)   // persists dead-letter immediately for crash-safety
                // No per-item persistQueue() — deferred to end of flush. [#369 perf-27]
                Self.logger.error("[WriteAheadQueue] permanent failure (dead-lettered), item \(item.id, privacy: .public), table: \(item.table, privacy: .public) — \(reason, privacy: .public)")

            case .transientFailure:
                item.retryCount += 1

                if item.retryCount > Self.maxRetries {
                    // Exhausted retries — move to the dead-letter store instead
                    // of silently dropping, so the write can be recovered (#184).
                    queue.removeFirst()
                    recordFailedWrite(item)   // persists dead-letter immediately for crash-safety
                    // No per-item persistQueue() — deferred to end of flush. [#369 perf-27]
                    Self.logger.error("[WriteAheadQueue] dead-lettered item \(item.id, privacy: .public) after \(Self.maxRetries) retries — table: \(item.table, privacy: .public)")
                    continue
                }

                // Update the item in the queue with incremented retry count.
                // No per-item persistQueue() — retry-count resets on crash are
                // acceptable; the item will simply restart from retryCount=0. [#369 perf-27]
                queue[0] = item

                // Exponential backoff: 1s, 2s, 4s, 8s, 16s
                let delay = baseRetryDelay * pow(2.0, Double(item.retryCount - 1))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // clearAll() may have fired during the backoff sleep.
                if clearRequested { break }
            }
        }
    }

    /// Routes a queue item to its registered handler, or falls back to the
    /// default Supabase REST insert path for items without a custom handler.
    private func dispatch(_ item: QueuedWrite) async -> WAQFlushOutcome {
        // Owner-mismatch guard (#369 slice 5): if the payload carries a top-level
        // "user_id" that doesn't match the current auth.uid(), dead-letter it
        // immediately — no retry. This fires when a frozen-owner item (stamped in a
        // placeholder/prior-uid window) reaches flush after a real session resolved;
        // retrying 5× would always produce RLS 403. When no session has resolved
        // (currentAuthUid → nil) or the payload has no user_id (e.g. set_logs), the
        // check is skipped and the flush proceeds normally.
        if let uid = await currentAuthUid(),
           let payloadOwnerId = Self.extractUserId(from: item.payload),
           payloadOwnerId != uid {
            let reason = "owner mismatch: payload user_id \(payloadOwnerId) != auth.uid() \(uid)"
            Self.logger.error("[WriteAheadQueue] \(reason, privacy: .public) — item \(item.id, privacy: .public), table: \(item.table, privacy: .public)")
            return .permanentFailure(reason)
        }

        if let handler = flushHandlers[item.table] {
            return await handler(item)
        }
        let success = await sendToSupabase(item)
        return success ? .success : .transientFailure
    }

    /// Returns the number of items currently in the queue.
    var pendingCount: Int { queue.count }

    /// Returns all pending `set_log` entries for the given session that have not
    /// yet been flushed to Supabase.
    ///
    /// Used by `WorkoutViewModel.resumeSession()` to merge local unflushed set_logs
    /// with the remote Supabase view, ensuring crash-recovered sets are never lost.
    /// WAQ entries win over remote entries on conflict (same `SetLog.id`).
    func pendingSetLogs(forSession sessionId: UUID) -> [SetLog] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return queue
            .filter { $0.table == "set_logs" }
            .compactMap { entry in
                guard let log = try? decoder.decode(SetLog.self, from: entry.payload) else { return nil }
                return log.sessionId == sessionId ? log : nil
            }
    }

    /// Returns the dead-lettered writes (#184): items that exhausted retries or
    /// were permanently rejected. Retained so callers (e.g. session resume per
    /// #190) can recover them instead of suffering silent data loss.
    func failedWrites() -> [QueuedWrite] { deadLetter }

    /// Removes a recovered/handled item from the dead-letter store.
    func removeFailedWrite(id: UUID) {
        deadLetter.removeAll { $0.id == id }
        persistDeadLetter()
    }

    /// Clears the dead-letter store.
    func clearFailedWrites() {
        deadLetter.removeAll()
        userDefaults.removeObject(forKey: Self.deadLetterKey)
    }

    /// Clears all queued items AND the dead-letter store (full reset — used on
    /// logout/reset and in tests). Also signals any in-flight flush to abandon
    /// its current item so it doesn't index the now-empty queue (#55).
    func clearAll() {
        queue.removeAll()
        clearRequested = true
        userDefaults.removeObject(forKey: Self.persistenceKey)
        deadLetter.removeAll()
        userDefaults.removeObject(forKey: Self.deadLetterKey)
    }

    // MARK: - Blocking Write (for session summary)

    /// Writes an item directly to Supabase, blocking until success or failure.
    /// Does NOT use the queue — this is for critical writes (e.g. session summary)
    /// that must complete before showing the post-workout UI.
    ///
    /// Falls back to enqueueing if the direct write fails.
    func writeBlocking<T: Encodable & Sendable>(_ item: T, table: String) async throws {
        do {
            try await supabase.insert(item, table: table)
        } catch {
            // Supabase write failed — enqueue for retry
            try enqueue(item, table: table)
            throw error
        }
    }

    /// Updates a row directly in Supabase, blocking until success or failure.
    /// Used for patching workout_sessions with the summary JSONB.
    func updateBlocking<T: Encodable & Sendable>(_ item: T, table: String, id: UUID) async throws {
        try await supabase.update(item, table: table, id: id)
    }

    // MARK: - Private: Supabase Interaction

    /// Attempts to POST the queued item's payload to Supabase.
    /// Returns true on success (HTTP 2xx), false on failure.
    private func sendToSupabase(_ item: QueuedWrite) async -> Bool {
        do {
            // Build a raw insert using the pre-encoded JSON data
            try await supabase.insertRawJSON(item.payload, table: item.table)
            print("[WriteAheadQueue] Flushed item \(item.id) → table: \(item.table)")
            return true
        } catch {
            print("[WriteAheadQueue] Flush failed for item \(item.id), table: \(item.table), retry \(item.retryCount)/\(Self.maxRetries): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private: Persistence

    /// Persists the current queue to UserDefaults.
    private func persistQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        userDefaults.set(data, forKey: Self.persistenceKey)
    }

    /// Loads any previously persisted queue from UserDefaults.
    private nonisolated static func loadPersistedQueue(userDefaults: UserDefaults) -> [QueuedWrite] {
        guard let data = userDefaults.data(forKey: persistenceKey),
              let items = try? JSONDecoder().decode([QueuedWrite].self, from: data)
        else { return [] }
        return items
    }

    /// Appends an item to the dead-letter store and persists it (#184).
    private func recordFailedWrite(_ item: QueuedWrite) {
        deadLetter.append(item)
        persistDeadLetter()
    }

    /// Persists the current dead-letter store to UserDefaults.
    private func persistDeadLetter() {
        guard let data = try? JSONEncoder().encode(deadLetter) else { return }
        userDefaults.set(data, forKey: Self.deadLetterKey)
    }

    /// Loads any previously persisted dead-letter store from UserDefaults.
    private nonisolated static func loadPersistedDeadLetter(userDefaults: UserDefaults) -> [QueuedWrite] {
        guard let data = userDefaults.data(forKey: deadLetterKey),
              let items = try? JSONDecoder().decode([QueuedWrite].self, from: data)
        else { return [] }
        return items
    }

    // MARK: - Private: Owner extraction

    /// Decodes the top-level `"user_id"` string from a JSON payload, if present.
    /// Returns nil when the key is absent (e.g. set_logs, session_notes) or the
    /// value is not a valid UUID — both treated as "no direct owner to check", so
    /// the flush proceeds normally. (#369 slice 5.)
    private static func extractUserId(from payload: Data) -> UUID? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let raw = json["user_id"] as? String
        else { return nil }
        return UUID(uuidString: raw)
    }
}

// MARK: - WriteAheadQueueError

nonisolated enum WriteAheadQueueError: LocalizedError {
    case queueFull
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .queueFull:
            return "Write-ahead queue is full (\(WriteAheadQueue.maxQueueSize) items). Cannot enqueue."
        case .encodingFailed(let detail):
            return "Failed to encode write payload: \(detail)"
        }
    }
}
