// ScannerViewModel.swift
// ProjectApex — GymScanner Feature
//
// The orchestration brain of the gym scanning pipeline. Connects:
//   CameraManager (frame production) → VisionAPIService (frame analysis)
//   → internal deduplication logic → published equipment list → SwiftUI
//
// Key responsibilities:
//   1. Permission gating: requests camera access before starting the session.
//   2. Frame → API loop: consumes the CameraManager's AsyncStream, fans out
//      concurrent Vision API calls (one Task per frame), and merges results.
//   3. Deduplication (FR-001-E): merges EquipmentItems by `equipmentType` enum,
//      preserving the highest observed count and latest details.
//   4. State machine: drives the UI through Idle → RequestingPermission →
//      Scanning → Confirming → Completed / PermissionDenied / Error states.
//   5. GymProfile finalisation: assembles and locally caches the confirmed profile.
//
// Threading:
//   • `@MainActor` ensures all `@Observable` state mutations land on the main
//     thread for safe SwiftUI diffing — no manual `DispatchQueue.main.async`.
//   • API calls are dispatched via `Task` (inherits the actor context of the caller,
//     which is MainActor here). Since VisionAPIService is itself an actor, calls
//     are serialised within the service but the Tasks run concurrently relative
//     to each other — providing natural parallelism across in-flight frames.
//
// FR coverage: FR-001-A, B, C, D, E, F, G

import Foundation
import AVFoundation

// MARK: - ScannerState

/// The finite-state machine driving the scanner UI.
enum ScannerState {
    /// Initial state before any user interaction.
    case idle

    /// Awaiting the OS permission dialog response.
    case requestingPermission

    /// Session is live; camera is running; frames are being sent to the API.
    /// Associated value: number of frames processed so far.
    case scanning(framesProcessed: Int)

    /// Scanning has stopped; user is reviewing the detected equipment list.
    case confirming

    /// The user has accepted the profile; it has been persisted locally.
    case completed(profile: GymProfile)

    /// Camera permission was denied — graceful degradation path (FR-001-A).
    case permissionDenied

    /// An unrecoverable error occurred during setup or scanning.
    case error(ScannerError)
}

// MARK: - ScannerViewModel

/// `@Observable` view model for the gym equipment scanning flow.
/// Instantiated as `@State` in `ScannerView` (modern Observation pattern).
@Observable
@MainActor
final class ScannerViewModel {

    // ---------------------------------------------------------------------------
    // MARK: Published State (observed by ScannerView)
    // ---------------------------------------------------------------------------

    /// Current phase of the scanning state machine.
    private(set) var state: ScannerState = .idle

    /// The live, deduplicated list of equipment detected so far.
    /// Updated in real time as API responses arrive. Rendered as the checklist.
    /// Public setter is intentional: SwiftUI's `@Bindable` wrapping needs write access
    /// for the `ForEach($viewModel.detectedEquipment)` pattern in the confirmation list.
    var detectedEquipment: [EquipmentItem] = []

    /// Number of camera frames that have been sent to the Vision API.
    private(set) var framesProcessed: Int = 0

    /// Number of API calls currently in-flight (used for a subtle loading indicator).
    private(set) var pendingAPIRequests: Int = 0

    // ---------------------------------------------------------------------------
    // MARK: Dependencies
    // ---------------------------------------------------------------------------

    private let cameraManager: CameraManager
    private let visionService: any VisionAPIServiceProtocol

    /// Configurable frame capture interval in seconds (FR-001-B default: 2s).
    let captureInterval: TimeInterval

    // ---------------------------------------------------------------------------
    // MARK: Internal Scan Task
    // ---------------------------------------------------------------------------

    /// The root Task that drives the frame → API loop. Cancelled on stopScan().
    private var scanTask: Task<Void, Never>?

    // ---------------------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------------------

    /// - Parameters:
    ///   - cameraManager: The AVFoundation session manager. Pass `nil` to use the default.
    ///   - visionService: The Vision API client. Pass `nil` to construct a live
    ///     `VisionAPIService` using the Anthropic API key from the Keychain.
    ///     Pass `MockVisionAPIService()` explicitly for unit tests.
    ///   - captureInterval: Seconds between frame captures. Default: 2.0s (FR-001-B).
    init(
        cameraManager: CameraManager? = nil,
        visionService: (any VisionAPIServiceProtocol)? = nil,
        captureInterval: TimeInterval = 2.0
    ) {
        // Instantiate defaults inside the body to avoid triggering actor-isolation
        // warnings from default parameter expressions being evaluated in a nonisolated context.
        self.cameraManager = cameraManager ?? CameraManager()

        if let injectedService = visionService {
            self.visionService = injectedService
        } else {
            // Load the Anthropic API key from Keychain for the live Vision API service.
            let apiKey = (try? KeychainService.shared.retrieve(.anthropicAPIKey)) ?? ""
            let config = VisionAPIConfiguration(
                provider: .anthropic,
                apiKey: apiKey,
                modelID: "claude-sonnet-4-20250514",
                timeoutSeconds: 30
            )
            self.visionService = VisionAPIService(configuration: config)
        }

        self.captureInterval = captureInterval
    }

    // ---------------------------------------------------------------------------
    // MARK: Public API — called by ScannerView
    // ---------------------------------------------------------------------------

    /// Entry point: requests camera permission and, on success, starts the scan.
    /// Transitions state machine through Idle → RequestingPermission → Scanning.
    func startScan() {
        guard case .idle = state else { return }
        state = .requestingPermission

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await cameraManager.requestAccessAndConfigure()
                guard granted else {
                    state = .permissionDenied
                    return
                }

                // Session is configured — start the camera and enter scanning state
                cameraManager.startSession()
                state = .scanning(framesProcessed: 0)

                // Begin consuming the frame stream
                await runFrameLoop()

            } catch let scannerError as ScannerError {
                state = .error(scannerError)
            } catch {
                state = .error(.cameraSetupFailed(underlying: error))
            }
        }
    }

    /// Stops the active camera session and transitions to the confirmation state.
    /// Called when the user taps "Done Scanning" or after an auto-stop trigger.
    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        cameraManager.stopSession()

        // Only transition to confirming if we actually have results
        if !detectedEquipment.isEmpty {
            state = .confirming
        } else {
            // Nothing detected — go back to idle so user can retry
            state = .idle
        }
    }

    /// Resets the scanner to its initial state. Used for the "Re-scan" flow (FR-001-H).
    func reset() {
        scanTask?.cancel()
        scanTask = nil
        cameraManager.stopSession()
        detectedEquipment = []
        framesProcessed = 0
        pendingAPIRequests = 0
        state = .idle
    }

    // ---------------------------------------------------------------------------
    // MARK: Manual Equipment Management (FR-001-F)
    // ---------------------------------------------------------------------------

    /// Adds a new equipment item to the confirmed list.
    func addEquipment(_ item: EquipmentItem) {
        mergeItems([item])
    }

    /// Removes an equipment item by its UUID.
    func removeEquipment(id: UUID) {
        detectedEquipment.removeAll { $0.id == id }
    }

    /// Updates an existing equipment item (for the manual edit flow).
    func updateEquipment(_ updated: EquipmentItem) {
        guard let idx = detectedEquipment.firstIndex(where: { $0.id == updated.id }) else { return }
        detectedEquipment[idx] = updated
    }

    // ---------------------------------------------------------------------------
    // MARK: Profile Finalisation (FR-001-G)
    // ---------------------------------------------------------------------------

    /// Assembles the final `GymProfile` from the confirmed equipment list,
    /// persists it locally to UserDefaults, and transitions to `.completed`.
    func confirmProfile() {
        let now = Date()
        let profile = GymProfile(
            id: UUID(),
            scanSessionId: UUID().uuidString,
            createdAt: now,
            lastUpdatedAt: now,
            equipment: detectedEquipment,
            isActive: true
        )
        profile.saveToUserDefaults()
        state = .completed(profile: profile)
    }

    // ---------------------------------------------------------------------------
    // MARK: Convenience (read-only preview layer for SwiftUI)
    // ---------------------------------------------------------------------------

    /// Exposes the camera preview layer for `CameraPreviewView`.
    var previewLayer: AVCaptureVideoPreviewLayer {
        cameraManager.previewLayer
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Frame → API Loop
    // ---------------------------------------------------------------------------

    /// Consumes the camera frame stream, dispatching a concurrent Vision API call
    /// for each frame. Runs until `scanTask` is cancelled or the stream finishes.
    private func runFrameLoop() async {
        for await frame in cameraManager.frames(interval: captureInterval) {
            // Check for cancellation between frames (cooperative cancellation)
            guard !Task.isCancelled else { break }

            framesProcessed += 1
            state = .scanning(framesProcessed: framesProcessed)

            // Fire-and-forget: each API call runs concurrently.
            // Results are merged back on MainActor via the `mergeItems` call inside.
            Task { [weak self] in
                guard let self else { return }
                await self.processFrame(frame)
            }
        }
    }

    /// Sends a single frame to the Vision API, handles errors gracefully,
    /// and merges returned items into `detectedEquipment`.
    private func processFrame(_ frame: CapturedFrame) async {
        pendingAPIRequests += 1
        defer { pendingAPIRequests -= 1 }

        do {
            let items = try await visionService.analyseFrame(frame)

            // Guard: empty response is not an error — just skip (no new equipment in frame)
            guard !items.isEmpty else { return }

            // Merge into the master list on MainActor (we're already on it)
            mergeItems(items)

        } catch ScannerError.apiResponseEmpty {
            // Expected: not every frame has equipment — silently continue
            return
        } catch {
            // Non-fatal: log and continue scanning. A single API failure should not
            // abort the session — the next frame will retry naturally.
            print("[ScannerViewModel] Frame \(frame.index) API error: \(error.localizedDescription)")
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Deduplication & Merge Logic (FR-001-E)
    // ---------------------------------------------------------------------------

    /// Merges an array of newly detected items into `detectedEquipment`.
    ///
    /// Deduplication key: `equipmentType` (the EquipmentType enum value).
    /// Merge strategy:
    ///   - If an item with the same `equipmentType` already exists, take the
    ///     **maximum** observed `count` (conservative: avoids inflating counts).
    ///   - Details from the latest detection override only if the existing item
    ///     has `bodyweightOnly` details (a later frame may provide richer weight info).
    private func mergeItems(_ newItems: [EquipmentItem]) {
        for newItem in newItems {
            if let existingIndex = detectedEquipment.firstIndex(where: {
                $0.equipmentType == newItem.equipmentType
            }) {
                // --- Existing item: apply merge strategy ---
                var existing = detectedEquipment[existingIndex]

                // Take the maximum observed count
                existing.count = max(existing.count, newItem.count)

                // Upgrade details if the existing entry is bodyweightOnly and new one is richer
                if case .bodyweightOnly = existing.details,
                   newItem.details != .bodyweightOnly {
                    existing.details = newItem.details
                }

                detectedEquipment[existingIndex] = existing

            } else {
                // --- New equipment type: append ---
                detectedEquipment.append(newItem)
            }
        }
    }
}
