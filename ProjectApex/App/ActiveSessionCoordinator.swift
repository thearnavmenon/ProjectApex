// App/ActiveSessionCoordinator.swift
// ProjectApex
//
// #440 — single @Observable owner of "which day, if any, has a live or paused
// session right now." Folds the former LiveSessionWatcher behind one published
// enum so the tab badge, the paused banner, the day-detail live-state, and the
// calendar live-highlight all read ONE value and cannot disagree from poll lag.
//
// The state is the enum below; everything else (isLive, pausedSessionExists,
// liveTrainingDayId, per-day accessors) is derived from it, so there is exactly
// one source of truth.
//
// Lifecycle: created and started by AppDependencies at app launch; runs for the
// lifetime of the process. Reads are pure SwiftUI-observed property access, so
// any view that reads `session` (or a derived accessor) re-renders automatically
// when the coordinator updates.
//
// Polling rate [#369 perf-24, preserved]: 500 ms while a session is live or
// paused; 5 s when idle. This avoids hitting the session actor every 500 ms for
// the whole process lifetime when no workout is in progress.

import SwiftUI

/// The single active-session state. `.live` means the WorkoutSessionManager actor
/// is running a session; `.paused` means the actor is idle but a durable paused
/// sentinel exists in UserDefaults. Live wins over a stale paused sentinel for the
/// same session (a live actor is authoritative).
nonisolated enum ActiveSession: Equatable, Sendable {
    case idle
    case live(dayId: UUID, sessionId: UUID)
    case paused(dayId: UUID, sessionId: UUID)
}

@Observable
@MainActor
final class ActiveSessionCoordinator {

    /// The single source of truth for live/paused day identity.
    private(set) var session: ActiveSession = .idle
    /// Aggregated set progress for the live session, nil unless `.live`.
    /// Retained because ProgramOverviewView's calendar highlight renders it.
    private(set) var liveSetSummary: LiveSetSummary? = nil

    private let manager: WorkoutSessionManager
    private var task: Task<Void, Never>? = nil

    /// Poll every 500 ms while a session is live/paused; 5 s when idle.
    private static let activeIntervalNs:  UInt64 = 500_000_000
    private static let idleIntervalNs:    UInt64 = 5_000_000_000

    init(manager: WorkoutSessionManager) {
        self.manager = manager
        start()
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                // Fast interval while live/paused; slow down when idle so we are not
                // hammering the actor 2× per second all day. [#369 perf-24]
                let interval: UInt64 = (self.session == .idle) ? Self.idleIntervalNs : Self.activeIntervalNs
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Performs one poll cycle: reads the actor, applies live-wins-over-paused
    /// precedence, and republishes `session` + `liveSetSummary`. Exposed (and
    /// async) so tests can drive it deterministically without waiting on the timer.
    func refresh() async {
        // One atomic actor hop for the whole live identity (state + dayId + sessionId
        // + set progress). Reading these as separate awaits could tear — the actor can
        // advance between hops — so a future change might publish a day from one instant
        // and a session id from another. uiSnapshot() captures them together (#458).
        let snapshot = await manager.uiSnapshot()
        let live: Bool
        switch snapshot.sessionState {
        case .idle, .sessionComplete, .error: live = false
        default: live = true
        }

        if live, let activeId = snapshot.currentTrainingDayId, let sessionId = snapshot.currentSessionId {
            // Live wins over any stale paused sentinel.
            session = .live(dayId: activeId, sessionId: sessionId)
            let sets = snapshot.completedSets
            let last = sets.max(by: { $0.loggedAt < $1.loggedAt })
            liveSetSummary = LiveSetSummary(
                setsCompleted: sets.count,
                lastWeightKg: last?.weightKg,
                lastRepsCompleted: last?.repsCompleted
            )
            return
        }

        // Not live. Cheap existence check on the raw UserDefaults keys — do NOT call
        // PausedSessionState.load() every tick: load() mutates the static repairPending
        // flag and triggers legacy→v2 migration writes (#440 F4). Only resolve the full
        // (dayId, sessionId) via load() on the edge INTO .paused, not while already paused.
        let sentinelExists = UserDefaults.standard.data(forKey: PausedSessionState.v2PersistenceKey) != nil
            || UserDefaults.standard.data(forKey: PausedSessionState.legacyPersistenceKey) != nil

        if sentinelExists {
            if case .paused = session {
                // Already paused — keep the resolved identity, no load() this tick.
            } else if let saved = PausedSessionState.load() {
                session = .paused(dayId: saved.trainingDayId, sessionId: saved.sessionId)
            } else {
                // Sentinel data present but undecodable (repairPending) — not a
                // renderable paused identity; recovery is handled elsewhere.
                session = .idle
            }
        } else {
            session = .idle
        }
        liveSetSummary = nil
    }

    // MARK: - Derived accessors (so call sites migrate cleanly off LiveSessionWatcher)

    /// True when a session is live (actor running a non-terminal state).
    var isLive: Bool {
        if case .live = session { return true }
        return false
    }

    /// True when a durable paused sentinel exists (and no live session overrides it).
    var pausedSessionExists: Bool {
        if case .paused = session { return true }
        return false
    }

    /// Training day ID of the live session, nil when not live.
    var liveTrainingDayId: UUID? {
        if case .live(let dayId, _) = session { return dayId }
        return nil
    }

    /// Training day ID of the paused session, nil when not paused. Used by the
    /// paused-session banner to resolve which day to offer a resume for.
    var pausedTrainingDayId: UUID? {
        if case .paused(let dayId, _) = session { return dayId }
        return nil
    }

    /// True when the given day is the one currently live.
    func isLive(forDay dayId: UUID) -> Bool {
        if case .live(let liveDay, _) = session { return liveDay == dayId }
        return false
    }

    /// True when the given day is the one currently paused.
    func isPaused(forDay dayId: UUID) -> Bool {
        if case .paused(let pausedDay, _) = session { return pausedDay == dayId }
        return false
    }

    // Prevents ___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED
    // when @State releases this @MainActor class from a CFRunLoop layout-pass
    // callback that is not inside a Swift Concurrency Task. See issue #37.
    nonisolated deinit {}
}
