// App/LiveSessionWatcher.swift
// ProjectApex
//
// Single polling source of truth for "is a workout live, and what's its
// summary." Replaces three independent .task loops previously living in
// ContentView (badge / pausedSessionExists), ProgramOverviewView (live-day
// highlight / set summary), and any future view that wants this signal.
//
// Lifecycle: created and started by AppDependencies at app launch; runs for
// the lifetime of the process. Reads are pure SwiftUI-observed property
// access, so any view that reads `isLive`, `currentTrainingDayId`,
// `liveSetSummary`, or `pausedSessionExists` re-renders automatically when
// the watcher updates them.

import SwiftUI

@Observable
@MainActor
final class LiveSessionWatcher {

    /// True when WorkoutSessionManager is in any non-terminal session state.
    private(set) var isLive: Bool = false
    /// Training day ID of the live session, nil when idle.
    private(set) var currentTrainingDayId: UUID? = nil
    /// Aggregated set progress for the live session, nil when no session active.
    private(set) var liveSetSummary: LiveSetSummary? = nil
    /// True when a PausedSessionState exists in UserDefaults (v2 or legacy key).
    private(set) var pausedSessionExists: Bool = false

    private let manager: WorkoutSessionManager
    private var task: Task<Void, Never>? = nil

    init(manager: WorkoutSessionManager) {
        self.manager = manager
        start()
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func poll() async {
        let state = await manager.sessionState
        let activeId = await manager.currentTrainingDayId
        let live: Bool
        switch state {
        case .idle, .sessionComplete, .error: live = false
        default: live = true
        }
        isLive = live
        currentTrainingDayId = live ? activeId : nil
        if live {
            let sets = await manager.completedSets
            let last = sets.max(by: { $0.loggedAt < $1.loggedAt })
            liveSetSummary = LiveSetSummary(
                setsCompleted: sets.count,
                lastWeightKg: last?.weightKg,
                lastRepsCompleted: last?.repsCompleted
            )
        } else {
            liveSetSummary = nil
        }
        pausedSessionExists = UserDefaults.standard.data(forKey: PausedSessionState.v2PersistenceKey) != nil
            || UserDefaults.standard.data(forKey: PausedSessionState.legacyPersistenceKey) != nil
    }
}
