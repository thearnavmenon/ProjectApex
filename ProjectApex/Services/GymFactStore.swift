// Services/GymFactStore.swift
// ProjectApex
//
// Persistent store of confirmed weight availability facts.
// Populated at runtime when users report a prescribed weight is unavailable.
// Injected into every WorkoutContext so the AI learns the gym's real weight
// inventory over time.
//
// WRITE TRIGGER: User taps "Weight not available" on a prescription card and
//   confirms an alternative weight.
//
// PERSISTENCE: UserDefaults (local only, not synced to Supabase for MVP).
//
// LEARNING CURVE: After 2-3 sessions the AI has enough weight facts to stop
//   prescribing unavailable weights entirely.

import Foundation

// MARK: - GymFactStore

actor GymFactStore {

    // MARK: - Model

    struct WeightFact: Codable, Sendable {
        let id: UUID
        let equipmentType: EquipmentType
        let unavailableWeight: Double   // What the AI prescribed
        let availableWeight: Double     // What the user confirmed exists
        let confirmedAt: Date
        var confirmationCount: Int      // Increments each time same fact confirmed
    }

    // MARK: - State

    private(set) var facts: [WeightFact] = []

    // MARK: - Init

    init() {
        self.facts = Self.loadFromUserDefaults()
    }

    // MARK: - Write

    /// Records a weight correction confirmed by the user.
    /// If this exact fact already exists (same equipment type and unavailable weight),
    /// increments the confirmation count rather than creating a duplicate.
    func recordCorrection(
        equipmentType: EquipmentType,
        unavailableWeight: Double,
        availableWeight: Double
    ) {
        if let index = facts.firstIndex(where: {
            $0.equipmentType == equipmentType &&
            abs($0.unavailableWeight - unavailableWeight) < 0.1
        }) {
            let existing = facts[index]
            facts[index] = WeightFact(
                id: existing.id,
                equipmentType: equipmentType,
                unavailableWeight: unavailableWeight,
                availableWeight: availableWeight,
                confirmedAt: Date(),
                confirmationCount: existing.confirmationCount + 1
            )
        } else {
            facts.append(WeightFact(
                id: UUID(),
                equipmentType: equipmentType,
                unavailableWeight: unavailableWeight,
                availableWeight: availableWeight,
                confirmedAt: Date(),
                confirmationCount: 1
            ))
        }
        saveToUserDefaults()
    }

    // MARK: - Read

    /// Returns a proactive substitution if we already know this weight is unavailable.
    /// Call this BEFORE showing the prescription to the user — if a substitution exists,
    /// apply it silently so the user never sees the unavailable weight.
    func knownSubstitution(
        for equipmentType: EquipmentType,
        prescribedWeight: Double
    ) -> Double? {
        facts.first(where: {
            $0.equipmentType == equipmentType &&
            abs($0.unavailableWeight - prescribedWeight) < 0.1
        })?.availableWeight
    }

    /// Returns human-readable fact strings for injection into WorkoutContext.
    /// Format: "16.0kg not available — use 15.0kg instead"
    func contextStrings(for equipmentType: EquipmentType) -> [String] {
        facts
            .filter { $0.equipmentType == equipmentType }
            .map {
                "\($0.unavailableWeight.formatted())kg not available — " +
                "use \($0.availableWeight.formatted())kg instead"
            }
    }

    /// Returns all context strings across all equipment types (for full injection).
    func allContextStrings() -> [String] {
        facts.map {
            "\($0.equipmentType.displayName): " +
            "\($0.unavailableWeight.formatted())kg not available — " +
            "use \($0.availableWeight.formatted())kg instead"
        }
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "com.projectapex.gymFactStore"

    private func saveToUserDefaults() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    private static func loadFromUserDefaults() -> [WeightFact] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let facts = try? JSONDecoder().decode([WeightFact].self, from: data)
        else { return [] }
        return facts
    }

    /// Clears all stored facts. Used for testing.
    func clearAll() {
        facts = []
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
    }
}
