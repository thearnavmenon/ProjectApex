// GymProfilePersistence.swift
// ProjectApex — GymScanner Feature
//
// UserDefaults persistence helpers for GymProfile, separated from the DTO
// definition so that @MainActor isolation (required for UserDefaults in Swift 6
// strict concurrency) does not leak into the nonisolated GymProfile struct and
// taint its synthesised Codable conformances.
//
// Call sites: ScannerViewModel.confirmProfile() and app startup.

import Foundation

extension GymProfile {

    private static let userDefaultsKey = "com.projectapex.gymProfile"

    /// Saves this profile to UserDefaults as JSON (FR-001-G local cache).
    /// Marked @MainActor because UserDefaults.standard is a MainActor-isolated
    /// API under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
    @MainActor
    func saveLocally() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            UserDefaults.standard.set(data, forKey: GymProfile.userDefaultsKey)
        }
    }

    /// Loads the most recently saved GymProfile from UserDefaults, or nil if none exists.
    @MainActor
    static func loadFromLocal() -> GymProfile? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GymProfile.self, from: data)
    }
}
