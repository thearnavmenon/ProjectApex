// Services/LateArrivalNotificationQueue.swift
// ProjectApex — Phase 2 / Slice A3 / issue #74
//
// UserDefaults-backed FIFO queue of pending `LateArrivalNotification`s
// awaiting display on the post-session summary. Producer:
// `TraineeModelUpdateJob` on `late_arrival:true` Edge Function responses
// (per ADR-0008). Consumer: `PostWorkoutSummaryView` on `.task { ... }`.
//
// Why UserDefaults: matches the WriteAheadQueue's persistence pattern
// for transient operational state. Notification volume is tiny
// (minutes-to-hours lifecycle, dismiss-on-tap, alpha cohort scale) and
// SwiftData's value-add — schema migration, relationships, querying —
// doesn't apply. Convention: UserDefaults for transient operational
// state (queues, sentinels, flags); SwiftData for entity snapshots.
//
// Threading: `@MainActor` because UserDefaults reads/writes from
// arbitrary threads can race; the actor isolation centralises that.
// `TraineeModelUpdateJob.parseResponse` already runs in async context;
// the enqueue call hops to MainActor naturally via `await`.

import Foundation

// MARK: - LateArrivalNotificationQueue

@MainActor
final class LateArrivalNotificationQueue {

    // MARK: - Constants

    /// UserDefaults key under which the encoded `[LateArrivalNotification]`
    /// JSON is stored. Production callers use `makeShared()`; tests use
    /// `makeInMemory()` which scopes to a fresh suite.
    nonisolated static let storageKey = "com.projectapex.lateArrivalNotificationQueue"

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let key: String

    // MARK: - Init

    init(defaults: UserDefaults, key: String = LateArrivalNotificationQueue.storageKey) {
        self.defaults = defaults
        self.key      = key
    }

    nonisolated deinit {}

    // MARK: - Factories

    /// Production queue persisted to `UserDefaults.standard`.
    static func makeShared() -> LateArrivalNotificationQueue {
        LateArrivalNotificationQueue(defaults: .standard)
    }

    /// In-memory queue scoped to a fresh ephemeral `UserDefaults` suite —
    /// no cross-test leakage even when several queues exist concurrently.
    static func makeInMemory() -> LateArrivalNotificationQueue {
        let suiteName = "com.projectapex.tests.\(UUID().uuidString)"
        // UserDefaults(suiteName:) returning nil means the suite name was
        // reserved (e.g. `Globals`) — UUID-based suite names cannot collide.
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        return LateArrivalNotificationQueue(defaults: suite, key: storageKey)
    }

    // MARK: - Public API

    /// Number of pending notifications without dequeuing.
    var pendingCount: Int { load().count }

    /// Appends `notification` to the persisted FIFO list.
    func enqueue(_ notification: LateArrivalNotification) {
        var pending = load()
        pending.append(notification)
        save(pending)
    }

    /// Returns every pending notification and clears the persisted list
    /// atomically. Callers render the returned notifications and treat
    /// them as consumed — there is no separate `markAsRead` step.
    func dequeueAll() -> [LateArrivalNotification] {
        let pending = load()
        defaults.removeObject(forKey: key)
        return pending
    }

    // MARK: - Persistence

    private func load() -> [LateArrivalNotification] {
        guard let data = defaults.data(forKey: key) else { return [] }
        // Default Date strategy (.deferredToDate / TimeInterval-since-reference)
        // round-trips Date exactly. ISO-8601 would truncate to seconds and
        // break Equatable round-trip on sub-second receiptDates.
        return (try? JSONDecoder().decode([LateArrivalNotification].self, from: data)) ?? []
    }

    private func save(_ notifications: [LateArrivalNotification]) {
        guard let data = try? JSONEncoder().encode(notifications) else { return }
        defaults.set(data, forKey: key)
    }
}
