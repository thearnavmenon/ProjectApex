// ScannerViewModel.swift
// ProjectApex — GymScanner Feature
//
// View model for the manual gym-equipment setup flow. The camera "gym scanner"
// (Vision API single-item capture) was removed in S3 (#527); equipment is now
// entered exclusively through gym presets + the manual BulkEquipmentPickerSheet /
// EquipmentEditSheet. This view model owns the editable equipment list and
// finalises it into a persisted GymProfile.
//
// Key responsibilities:
//   1. Manual equipment management: add / remove / update items.
//   2. Deduplication: mergeItems() collapses duplicates (same type added twice).
//   3. GymProfile finalisation: assembles and persists the confirmed profile.
//
// Threading:
//   • `@MainActor` ensures all `@Observable` state mutations land on the main
//     thread for safe SwiftUI diffing.

import Foundation

// MARK: - ScannerState

/// The finite-state machine driving the manual equipment-setup UI.
enum ScannerState {
    /// Camera was retired; the manual list is the only entry state. Kept as a
    /// distinct case so the view can still drive a confirm → completed flow.
    case confirming

    /// The user has accepted the profile; it has been persisted locally.
    case completed(profile: GymProfile)
}

// MARK: - ScannerViewModel

/// `@Observable` view model for the manual gym-equipment setup flow.
/// Instantiated as `@State` in `EquipmentSetupView` (modern Observation pattern).
@Observable
@MainActor
final class ScannerViewModel {

    // ---------------------------------------------------------------------------
    // MARK: Published State (observed by EquipmentSetupView)
    // ---------------------------------------------------------------------------

    /// Current phase of the setup state machine.
    private(set) var state: ScannerState = .confirming

    /// The accumulated, deduplicated list of equipment the user has confirmed.
    /// Public setter is intentional: SwiftUI's `@Bindable` wrapping needs write access
    /// for the `ForEach($viewModel.detectedEquipment)` pattern in the confirmation list.
    var detectedEquipment: [EquipmentItem] = []

    // ---------------------------------------------------------------------------
    // MARK: Dependencies
    // ---------------------------------------------------------------------------

    /// Optional reference to the app-level DI container. When set,
    /// `confirmProfile()` will also persist to Supabase and reinitialise
    /// `AIInferenceService` with the new profile.
    weak var appDependencies: AppDependencies?

    /// The authenticated user's UUID. Required for Supabase writes.
    var userId: UUID?

    // ---------------------------------------------------------------------------
    // MARK: Public API — called by EquipmentSetupView
    // ---------------------------------------------------------------------------

    /// Enters the manual equipment-entry list. Kept as the single entry point so
    /// existing callers continue to compile.
    ///
    /// Transitions: → Confirming
    func skipToManualEntry() {
        state = .confirming
    }

    /// Resets the equipment list back to an empty confirming state.
    func reset() {
        detectedEquipment = []
        state = .confirming
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
            // The camera scanner is gone; tag the session as manually entered.
            scanSessionId: "manual_\(UUID().uuidString)",
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

    // Prevents ___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED
    // when @State releases this @MainActor class from a CFRunLoop layout-pass
    // callback that is not inside a Swift Concurrency Task. See issue #37.
    nonisolated deinit {}
}
