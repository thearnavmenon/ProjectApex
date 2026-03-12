// ScannerViewModel.swift
// ProjectApex — GymScanner Feature
//
// The orchestration brain of the guided gym scanning pipeline. Connects:
//   CameraManager (one-shot capture) → VisionAPIService (single-item identification)
//   → user review (confirm / discard) → accumulated equipment list → SwiftUI
//
// Key responsibilities:
//   1. Permission gating: requests camera access before starting the session.
//   2. Guided capture loop: user triggers one photo at a time via the shutter button.
//      Each photo is sent to the Vision API for single-item identification.
//   3. Review flow: detected item is shown for user confirmation before being added.
//   4. Deduplication: mergeItems() collapses duplicates (same type photographed twice).
//   5. State machine: drives the UI through:
//      Idle → RequestingPermission → Previewing → Analyzing → Reviewed
//      → (back to Previewing or Confirming) → Completed
//   6. GymProfile finalisation: assembles and persists the confirmed profile.
//
// Threading:
//   • `@MainActor` ensures all `@Observable` state mutations land on the main
//     thread for safe SwiftUI diffing.
//   • `captureAndIdentify()` uses structured concurrency — awaits the one-shot
//     frame capture and the Vision API call in sequence.

import Foundation
import AVFoundation

// MARK: - ScannerState

/// The finite-state machine driving the guided scanner UI.
enum ScannerState {
    /// Initial state before any user interaction.
    case idle

    /// Awaiting the OS permission dialog response.
    case requestingPermission

    /// Camera is live; user sees the preview and can tap the shutter button.
    case previewing

    /// A photo was taken; the Vision API call is in-flight.
    case analyzing

    /// The Vision API returned a result. User reviews the identified item
    /// and either confirms (adds to list) or discards it.
    case reviewed(item: EquipmentItem)

    /// Camera has stopped; user is reviewing and editing the full equipment list.
    case confirming

    /// The user has accepted the profile; it has been persisted locally.
    case completed(profile: GymProfile)

    /// Camera permission was denied — graceful degradation path.
    case permissionDenied

    /// An unrecoverable error occurred during setup or capture.
    case error(ScannerError)
}

// MARK: - ScannerViewModel

/// `@Observable` view model for the guided gym equipment scanning flow.
/// Instantiated as `@State` in `ScannerView` (modern Observation pattern).
@Observable
@MainActor
final class ScannerViewModel {

    // ---------------------------------------------------------------------------
    // MARK: Published State (observed by ScannerView)
    // ---------------------------------------------------------------------------

    /// Current phase of the scanning state machine.
    private(set) var state: ScannerState = .idle

    /// The accumulated, deduplicated list of equipment the user has confirmed.
    /// Public setter is intentional: SwiftUI's `@Bindable` wrapping needs write access
    /// for the `ForEach($viewModel.detectedEquipment)` pattern in the confirmation list.
    var detectedEquipment: [EquipmentItem] = []

    /// Brief toast message shown when a capture returns no result (e.g. non-gym image).
    /// Automatically clears after a short delay.
    private(set) var nothingDetectedToast: Bool = false

    // ---------------------------------------------------------------------------
    // MARK: Dependencies
    // ---------------------------------------------------------------------------

    private let cameraManager: CameraManager
    private let visionService: any VisionAPIServiceProtocol

    /// Optional reference to the app-level DI container. When set,
    /// `confirmProfile()` will also persist to Supabase and reinitialise
    /// `AIInferenceService` with the new profile.
    weak var appDependencies: AppDependencies?

    /// The authenticated user's UUID. Required for Supabase writes.
    var userId: UUID?

    // ---------------------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------------------

    init(
        cameraManager: CameraManager? = nil,
        visionService: (any VisionAPIServiceProtocol)? = nil
    ) {
        self.cameraManager = cameraManager ?? CameraManager()

        if let injectedService = visionService {
            self.visionService = injectedService
        } else {
            let apiKey = (try? KeychainService.shared.retrieve(.anthropicAPIKey)) ?? ""
            let config = VisionAPIConfiguration(
                provider: .anthropic,
                apiKey: apiKey,
                modelID: "claude-sonnet-4-20250514",
                timeoutSeconds: 30
            )
            self.visionService = VisionAPIService(configuration: config)
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Public API — called by ScannerView
    // ---------------------------------------------------------------------------

    /// Entry point: requests camera permission and, on success, starts the live preview.
    /// Transitions: Idle → RequestingPermission → Previewing.
    func startCapture() {
        guard case .idle = state else { return }
        state = .requestingPermission

        Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await cameraManager.requestAccessAndConfigure()
                guard granted else {
                    state = .permissionDenied
                    return
                }
                cameraManager.startSession()
                state = .previewing
            } catch let scannerError as ScannerError {
                state = .error(scannerError)
            } catch {
                state = .error(.cameraSetupFailed(underlying: error))
            }
        }
    }

    /// Bypasses the camera and jumps directly to the manual equipment entry list.
    /// Used on the iOS Simulator where no camera hardware is available.
    ///
    /// Transitions: Idle → Confirming
    func skipToManualEntry() {
        state = .confirming
    }

    /// User tapped the shutter button. Captures one photo, sends it to the Vision API,
    /// and transitions to `.reviewed` with the identified item, or back to `.previewing`
    /// with a toast if nothing was detected.
    ///
    /// Transitions: Previewing → Analyzing → Reviewed | Previewing
    func captureAndIdentify() {
        guard case .previewing = state else { return }
        state = .analyzing

        Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await cameraManager.captureOneFrame()
                let items = try await visionService.analyseFrame(frame)

                // Take the first item — the prompt instructs the model to return
                // exactly one item for a single-equipment photo.
                let best = items.first

                if let detected = best {
                    state = .reviewed(item: detected)
                } else {
                    // Nothing recognisable — show a brief toast and go back to preview.
                    state = .previewing
                    showNothingDetectedToast()
                }
            } catch ScannerError.apiResponseEmpty {
                state = .previewing
                showNothingDetectedToast()
            } catch {
                // Non-fatal: log and return to preview so user can try again.
                print("[ScannerViewModel] Capture error: \(error.localizedDescription)")
                state = .previewing
                showNothingDetectedToast()
            }
        }
    }

    /// User confirmed the reviewed item. Adds it to the accumulated list and
    /// returns to previewing for the next capture.
    ///
    /// Transitions: Reviewed → Previewing
    func confirmDetection() {
        guard case .reviewed(let item) = state else { return }
        mergeItems([item])
        state = .previewing
    }

    /// User discarded the reviewed item. Returns to previewing without adding anything.
    ///
    /// Transitions: Reviewed → Previewing
    func rejectDetection() {
        guard case .reviewed = state else { return }
        state = .previewing
    }

    /// User tapped "Done" — stops the camera and moves to the confirmation list.
    /// If the list is empty, goes back to idle.
    ///
    /// Transitions: Previewing → Confirming | Idle
    func doneCapturing() {
        cameraManager.stopSession()
        if !detectedEquipment.isEmpty {
            state = .confirming
        } else {
            state = .idle
        }
    }

    /// Resets the scanner to its initial state. Used for the "Re-scan" flow.
    func reset() {
        cameraManager.stopSession()
        detectedEquipment = []
        nothingDetectedToast = false
        state = .idle
    }

    // ---------------------------------------------------------------------------
    // MARK: Manual Equipment Management
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
    // MARK: Profile Finalisation
    // ---------------------------------------------------------------------------

    /// Assembles the final `GymProfile` from the confirmed equipment list,
    /// persists it locally, and (when dependencies are set) writes to Supabase.
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
        appDependencies?.reinitialiseAIInference()

        guard let deps = appDependencies, let uid = userId else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.persistProfileToSupabase(profile, userId: uid, deps: deps)
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Convenience
    // ---------------------------------------------------------------------------

    /// Exposes the camera preview layer for `CameraPreviewView`.
    var previewLayer: AVCaptureVideoPreviewLayer {
        cameraManager.previewLayer
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Supabase persistence
    // ---------------------------------------------------------------------------

    private(set) var lastSupabaseError: Error?

    private func persistProfileToSupabase(
        _ profile: GymProfile,
        userId: UUID,
        deps: AppDependencies
    ) async {
        do {
            try await deps.supabaseClient.deactivateGymProfiles(userId: userId)
            let row = GymProfileRow.forInsert(from: profile, userId: userId)
            try await deps.supabaseClient.insert(row, table: "gym_profiles")
            lastSupabaseError = nil
        } catch {
            lastSupabaseError = error
            print("[ScannerViewModel] Supabase write failed (non-fatal): \(error.localizedDescription)")
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Deduplication & Merge Logic
    // ---------------------------------------------------------------------------

    /// Merges newly confirmed items into `detectedEquipment`.
    /// Deduplication key: `equipmentType`. Merge strategy: max count.
    private func mergeItems(_ newItems: [EquipmentItem]) {
        for newItem in newItems {
            if let existingIndex = detectedEquipment.firstIndex(where: {
                $0.equipmentType == newItem.equipmentType
            }) {
                var existing = detectedEquipment[existingIndex]
                existing.count = max(existing.count, newItem.count)
                detectedEquipment[existingIndex] = existing
            } else {
                detectedEquipment.append(newItem)
            }
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Toast
    // ---------------------------------------------------------------------------

    private func showNothingDetectedToast() {
        nothingDetectedToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 seconds
            nothingDetectedToast = false
        }
    }
}


