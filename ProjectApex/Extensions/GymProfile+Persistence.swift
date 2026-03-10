// Extensions/GymProfile+Persistence.swift
// ProjectApex
//
// UserDefaults persistence layer for GymProfile.
//
// Separated from the DTO definition (Models/GymProfile.swift) so that the
// @MainActor annotation required by UserDefaults under
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor does not leak into GymProfile's
// synthesised Codable conformances and cause actor-isolation diagnostics.
//
// Call sites:
//   • ScannerViewModel.confirmProfile()  — saves after onboarding scan
//   • ProjectApexApp / app startup        — loads on launch for offline access

import Foundation

extension GymProfile {

    // MARK: - Storage Key

    private static let userDefaultsKey = "com.projectapex.gymProfile"

    // MARK: - Load

    /// Loads the most recently saved GymProfile from UserDefaults.
    /// Returns nil if no profile has been saved or if decoding fails.
    ///
    /// @MainActor: UserDefaults.standard is a MainActor-isolated API under
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor. The GymProfile struct itself
    /// is nonisolated, so decoding happens safely on whichever actor calls this.
    @MainActor
    static func loadFromUserDefaults() -> GymProfile? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder.gymProfile.decode(GymProfile.self, from: data)
    }

    // MARK: - Save

    /// Serialises this profile to JSON and writes it to UserDefaults.
    /// Silently no-ops if encoding fails (non-critical path; Supabase is the
    /// authoritative remote store; UserDefaults is the offline cache).
    @MainActor
    func saveToUserDefaults() {
        guard let data = try? JSONEncoder.gymProfile.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: GymProfile.userDefaultsKey)
    }

    // MARK: - Clear

    /// Removes the cached GymProfile from UserDefaults.
    /// Used when the user initiates a re-scan (FR-001-H) to prevent stale data
    /// from being displayed if the new scan fails mid-way.
    @MainActor
    static func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
