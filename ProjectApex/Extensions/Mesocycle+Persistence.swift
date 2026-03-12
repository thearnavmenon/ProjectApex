// Mesocycle+Persistence.swift
// ProjectApex — Extensions
//
// Persistence layer for Mesocycle:
//   1. ProgramRow — Codable DTO matching the Supabase `programs` table schema.
//   2. Mesocycle+UserDefaults — offline cache (fast, survives backgrounding).
//
// Table schema (programs):
//   id             UUID PRIMARY KEY DEFAULT gen_random_uuid()
//   user_id        UUID NOT NULL
//   mesocycle_json JSONB NOT NULL      — full Mesocycle struct serialised
//   weeks          INTEGER NOT NULL DEFAULT 12
//   created_at     TIMESTAMPTZ DEFAULT NOW()
//   is_active      BOOLEAN DEFAULT TRUE
//
// ISOLATION NOTE:
// ProgramRow is `nonisolated` to opt its synthesised Codable conformance out
// of @MainActor (target-wide SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

import Foundation

// MARK: - ProgramRow

/// Supabase `programs` row shape used for insert and fetch operations.
///
/// The `mesocycle_json` column stores the full `Mesocycle` struct as JSONB.
/// We encode the `Mesocycle` value to a JSON string before sending and decode
/// it back when fetching.
///
/// Column mapping:
///   id             ← server-generated UUID (nil on insert)
///   user_id        ← authenticated user's UUID
///   mesocycle_json ← full Mesocycle encoded as JSONB
///   weeks          ← totalWeeks for easy SQL querying without JSON parsing
///   created_at     ← server timestamp (nil on insert)
///   is_active      ← whether this is the currently active program
nonisolated struct ProgramRow: Codable, Sendable {

    // MARK: Fields

    /// Server-generated primary key. `nil` when constructing an insert payload.
    var id: UUID?

    /// FK → users.id.
    var userId: UUID

    /// The full `Mesocycle` struct, stored as JSONB in Supabase.
    var mesocycleJson: Mesocycle

    /// Convenience copy of `mesocycleJson.totalWeeks` for easy SQL filtering.
    var weeks: Int

    /// Server-generated insertion timestamp. `nil` on insert.
    var createdAt: Date?

    /// Whether this is the user's currently active program.
    var isActive: Bool

    // MARK: Coding keys

    enum CodingKeys: String, CodingKey {
        case id
        case userId       = "user_id"
        case mesocycleJson = "mesocycle_json"
        case weeks
        case createdAt    = "created_at"
        case isActive     = "is_active"
    }

    // MARK: Helpers

    /// Converts this database row back into a domain `Mesocycle`.
    func toMesocycle() -> Mesocycle {
        mesocycleJson
    }
}

// MARK: - ProgramRow: Insert Factory

extension ProgramRow {

    /// Builds a `ProgramRow` suitable for a Supabase insert (no `id` or
    /// `createdAt` — those are server-generated).
    ///
    /// - Parameters:
    ///   - mesocycle: The confirmed, validated `Mesocycle`.
    ///   - userId:    The authenticated user's UUID.
    static func forInsert(from mesocycle: Mesocycle, userId: UUID) -> ProgramRow {
        ProgramRow(
            id: nil,
            userId: userId,
            mesocycleJson: mesocycle,
            weeks: mesocycle.totalWeeks,
            createdAt: nil,
            isActive: true
        )
    }
}

// MARK: - Mesocycle: UserDefaults cache

extension Mesocycle {

    private static let userDefaultsKey = "com.projectapex.activeProgram"

    // MARK: Load

    /// Loads the most recently cached active `Mesocycle` from UserDefaults.
    ///
    /// Returns `nil` if no program has been cached or if decoding fails.
    /// UserDefaults is the offline cache; Supabase is authoritative.
    @MainActor
    static func loadFromUserDefaults() -> Mesocycle? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder.workoutProgram.decode(Mesocycle.self, from: data)
    }

    // MARK: Save

    /// Serialises this mesocycle to JSON and writes it to UserDefaults.
    /// Silently no-ops if encoding fails.
    @MainActor
    func saveToUserDefaults() {
        guard let data = try? JSONEncoder.workoutProgram.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Mesocycle.userDefaultsKey)
    }

    // MARK: Clear

    /// Removes the cached program from UserDefaults.
    @MainActor
    static func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
