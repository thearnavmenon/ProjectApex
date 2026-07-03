//
//  NetworkMonitor.swift
//  ProjectApex
//
//  Watches the network path and fires a callback when connectivity is restored,
//  so the write-ahead queue can be flushed the instant the network returns.
//
//  Background: WriteAheadQueue's header documented that flush() is called on
//  "network restoration (NWPathMonitor)", but no such monitor existed — the only
//  flush triggers were per-enqueue and app-foreground. A write that failed while
//  the app stayed foregrounded with the network down therefore waited for the
//  next set-log or a background→foreground round-trip before retrying. This type
//  closes that gap.
//

import Foundation
import Network

/// Fires `onRestore` when the network transitions from offline (`.unsatisfied`)
/// back to online (`.satisfied`). Wired at app startup to `WriteAheadQueue.flush()`.
///
/// The edge-detection lives in `handle(_:)` so it is unit-testable without the
/// real `NWPathMonitor`. `onRestore` fires only on a genuine offline→online
/// transition — never on every path update, and never at launch when the device
/// is already online (the per-enqueue and foreground flushes cover launch).
final class NetworkMonitor: @unchecked Sendable {

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.projectapex.networkMonitor")
    private let onRestore: @Sendable () -> Void

    /// Last observed path status. Guarded by `lock` because `pathUpdateHandler`
    /// fires on `monitorQueue` while tests may call `handle(_:)` directly.
    private var previousStatus: NWPath.Status?
    private let lock = NSLock()

    init(onRestore: @escaping @Sendable () -> Void) {
        self.monitor = NWPathMonitor()
        self.onRestore = onRestore
    }

    /// Begins watching the network path. Call once at app startup.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path.status)
        }
        monitor.start(queue: monitorQueue)
    }

    /// Stops watching. The monitor cannot be restarted after this.
    func stop() {
        monitor.cancel()
    }

    /// Testable core. Records the new status and invokes `onRestore` exactly once
    /// on an `.unsatisfied` → `.satisfied` transition. All other transitions
    /// (initial observation, satisfied→satisfied, →unsatisfied, requiresConnection)
    /// do not fire, so a healthy always-online session never triggers a redundant
    /// flush.
    func handle(_ status: NWPath.Status) {
        lock.lock()
        let previous = previousStatus
        previousStatus = status
        lock.unlock()

        if status == .satisfied, previous == .unsatisfied {
            onRestore()
        }
    }
}
