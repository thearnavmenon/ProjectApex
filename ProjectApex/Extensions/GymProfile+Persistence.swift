// Extensions/GymProfile+Persistence.swift
// ProjectApex
//
// Persistence layer for GymProfile:
//   1. UserDefaults — offline cache (fast, survives backgrounding).
//   2. GymProfileRow — Codable DTO that matches the Supabase `gym_profiles`
//      table schema for insert and fetch operations.
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

// MARK: - GymProfileRow

/// Supabase `gym_profiles` row shape used for insert and fetch operations.
///
/// The `equipment` column is stored as JSONB. We encode the `[EquipmentItem]`
/// array to a JSON string on the way in and decode it on the way back out.
///
/// Column mapping:
///   id              ← server-generated UUID (omit on insert)
///   user_id         ← authenticated user's UUID
///   scan_session_id ← opaque string from the scan session
///   equipment       ← JSONB array of EquipmentItem
///   created_at      ← server timestamp (omit on insert)
///   is_active       ← whether this is the current active profile
nonisolated struct GymProfileRow: Codable, Sendable {

    // MARK: Fields

    /// Server-generated primary key. Nil when constructing an insert payload.
    var id: UUID?

    /// FK → users.id. Required for RLS-based access control.
    var userId: UUID

    /// Opaque token linking the profile to its originating scan session.
    var scanSessionId: String

    /// Equipment array, encoded to/from JSON for the JSONB column.
    var equipment: [EquipmentItem]

    /// Server-generated insertion timestamp. Nil when constructing an insert payload.
    var createdAt: Date?

    /// Whether this profile is currently active. Defaults to `true` on new inserts.
    var isActive: Bool

    // MARK: Coding keys

    enum CodingKeys: String, CodingKey {
        case id
        case userId         = "user_id"
        case scanSessionId  = "scan_session_id"
        case equipment
        case createdAt      = "created_at"
        case isActive       = "is_active"
    }

    // MARK: Helpers

    /// Converts this row back into a domain `GymProfile`.
    func toGymProfile() -> GymProfile {
        GymProfile(
            id: id ?? UUID(),
            scanSessionId: scanSessionId,
            createdAt: createdAt ?? Date(),
            lastUpdatedAt: createdAt ?? Date(),
            equipment: equipment,
            isActive: isActive
        )
    }
}

// MARK: - GymProfileRow: Insert Factory

extension GymProfileRow {

    /// Builds a `GymProfileRow` suitable for a Supabase insert (no `id` or
    /// `createdAt` — those are server-generated).
    ///
    /// - Parameters:
    ///   - profile: The confirmed `GymProfile` from the scanner.
    ///   - userId:  The authenticated user's UUID.
    static func forInsert(from profile: GymProfile, userId: UUID) -> GymProfileRow {
        GymProfileRow(
            id: nil,
            userId: userId,
            scanSessionId: profile.scanSessionId,
            equipment: profile.equipment,
            createdAt: nil,
            isActive: true
        )
    }
}

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
