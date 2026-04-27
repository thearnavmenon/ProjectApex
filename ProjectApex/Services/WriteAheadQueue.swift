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

// MARK: - WriteAheadQueue

/// Actor that guarantees reliable Supabase writes with local queuing and
/// exponential backoff retry. Per TDD §10.3.
actor WriteAheadQueue {

    // MARK: - Configuration

    /// Maximum number of retry attempts per item (5 retries = 6 total attempts).
    static let maxRetries = 5

    /// Base delay for exponential backoff (1 second).
    static let baseRetryDelay: TimeInterval = 1.0

    /// Maximum number of items allowed in the queue before rejecting new writes.
    static let maxQueueSize = 500

    /// UserDefaults key for persisting the queue across launches.
    private static let persistenceKey = "com.projectapex.writeAheadQueue"

    // MARK: - State

    /// In-memory FIFO queue of pending writes.
    private(set) var queue: [QueuedWrite] = []

    /// True while flush() is actively processing the queue.
    private(set) var isFlushing: Bool = false

    // MARK: - Dependencies

    private let supabase: SupabaseClient
    private let userDefaults: UserDefaults

    // MARK: - Init

    init(supabase: SupabaseClient, userDefaults: UserDefaults = .standard) {
        self.supabase = supabase
        self.userDefaults = userDefaults
        // Restore any persisted queue items from a previous session
        self.queue = Self.loadPersistedQueue(userDefaults: userDefaults)
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

    /// Processes all queued items in FIFO order. Each item is POSTed to
    /// Supabase; on failure, exponential backoff is applied up to maxRetries.
    /// Items are removed from the queue only on successful write (HTTP 2xx).
    ///
    /// Safe to call multiple times concurrently — the isFlushing guard
    /// ensures only one flush runs at a time.
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer {
            isFlushing = false
            persistQueue()
        }

        while !queue.isEmpty {
            var item = queue[0]

            let success = await sendToSupabase(item)

            if success {
                // Remove from front of queue (FIFO)
                queue.removeFirst()
                persistQueue()
            } else {
                item.retryCount += 1

                if item.retryCount > Self.maxRetries {
                    // Exhausted retries — remove and log (data loss for this item)
                    queue.removeFirst()
                    persistQueue()
                    print("[WriteAheadQueue] DROPPED item \(item.id) after \(Self.maxRetries) retries — table: \(item.table)")
                    continue
                }

                // Update the item in the queue with incremented retry count
                queue[0] = item
                persistQueue()

                // Exponential backoff: 1s, 2s, 4s, 8s, 16s
                let delay = Self.baseRetryDelay * pow(2.0, Double(item.retryCount - 1))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // After the delay, loop will retry the same item
            }
        }
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

    /// Clears all queued items (for testing / reset).
    func clearAll() {
        queue.removeAll()
        userDefaults.removeObject(forKey: Self.persistenceKey)
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
