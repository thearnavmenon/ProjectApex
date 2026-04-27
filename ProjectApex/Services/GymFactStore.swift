// Services/GymFactStore.swift
// ProjectApex
//
// Persistent store of confirmed weight availability facts.
// Populated at runtime when users report a weight does not exist in their gym.
// Injected into every WorkoutContext so the AI never prescribes unavailable loads.
//
// WRITE TRIGGER: User taps "My gym doesn't have this weight" on the prescription
//   card and confirms the nearest available weight. All corrections are permanent.
//
// PERSISTENCE: UserDefaults (local only, not synced to Supabase for MVP).
//
// LEARNING CURVE: After 2-3 sessions the AI has enough facts to stop prescribing
//   unavailable weights entirely.

import Foundation

// MARK: - GymFactStore

actor GymFactStore {

    // MARK: - Model

    struct WeightFact: Codable, Identifiable, Sendable {

        // MARK: CodingKeys (explicit — custom init(from:) needs them)
        enum CodingKeys: CodingKey {
            case id, equipmentType, unavailableWeight, availableWeight
            case confirmedAt, confirmationCount, isPermanent
        }

        let id: UUID
        let equipmentType: EquipmentType
        let unavailableWeight: Double   // What the AI prescribed (does not exist in gym)
        let availableWeight: Double     // What the user confirmed exists
        let confirmedAt: Date
        var confirmationCount: Int      // Increments each time same fact confirmed
        /// True for all corrections made via the "My gym doesn't have this weight" flow.
        /// Stored so future flows (e.g. session-local overrides) can use a different flag.
        let isPermanent: Bool

        // Memberwise init — isPermanent defaults to true (all user-confirmed corrections are permanent)
        init(
            id: UUID, equipmentType: EquipmentType,
            unavailableWeight: Double, availableWeight: Double,
            confirmedAt: Date, confirmationCount: Int,
            isPermanent: Bool = true
        ) {
            self.id = id
            self.equipmentType = equipmentType
            self.unavailableWeight = unavailableWeight
            self.availableWeight = availableWeight
            self.confirmedAt = confirmedAt
            self.confirmationCount = confirmationCount
            self.isPermanent = isPermanent
        }

        // Custom decoder — defaults isPermanent = true for facts saved before this field was added
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id               = try c.decode(UUID.self,          forKey: .id)
            equipmentType    = try c.decode(EquipmentType.self, forKey: .equipmentType)
            unavailableWeight = try c.decode(Double.self,       forKey: .unavailableWeight)
            availableWeight  = try c.decode(Double.self,        forKey: .availableWeight)
            confirmedAt      = try c.decode(Date.self,          forKey: .confirmedAt)
            confirmationCount = try c.decode(Int.self,          forKey: .confirmationCount)
            isPermanent      = (try? c.decode(Bool.self,        forKey: .isPermanent)) ?? true
        }
    }

    // MARK: - State

    private(set) var facts: [WeightFact] = []
    private let userDefaults: UserDefaults

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.facts = Self.loadFromUserDefaults(userDefaults: userDefaults)
    }

    // MARK: - Write

    // MARK: - Sanity Check

    /// Returns true if this would be a suspiciously low weight correction for the given
    /// equipment type — e.g. blocking a sub-15kg dumbbell when no other low weights are
    /// blocked. Used by callers to optionally surface a confirmation before writing.
    ///
    /// Thresholds (conservative — only fires when the flag is clearly unusual):
    ///   • dumbbell_set: unavailableWeight ≤ 15 kg AND no existing correction below 20 kg
    ///   • cable stacks (any): unavailableWeight ≤ 10 kg AND no existing correction below 15 kg
    func isSuspiciouslyLowCorrection(
        equipmentType: EquipmentType,
        unavailableWeight: Double
    ) -> Bool {
        switch equipmentType {
        case .dumbbellSet:
            let threshold: Double = 15
            guard unavailableWeight <= threshold else { return false }
            let existingLowBlocks = facts.filter {
                $0.equipmentType == equipmentType && $0.unavailableWeight <= 20
            }
            return existingLowBlocks.isEmpty
        case .cableMachine, .cableMachineDual, .latPulldown, .seatedRow, .cableCrossover:
            let threshold: Double = 10
            guard unavailableWeight <= threshold else { return false }
            let existingLowBlocks = facts.filter {
                $0.equipmentType == equipmentType && $0.unavailableWeight <= 15
            }
            return existingLowBlocks.isEmpty
        default:
            return false
        }
    }

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
    ///
    /// Format: "42.5kg does not exist in this gym. Never prescribe it. Nearest available: 40.0kg or 45.0kg."
    ///
    /// Uses DefaultWeightIncrements to compute both flanking available weights,
    /// filtering out all other known unavailable weights for the same equipment type.
    func contextStrings(for equipmentType: EquipmentType) -> [String] {
        let factsForType = facts.filter { $0.equipmentType == equipmentType }
        guard !factsForType.isEmpty else { return [] }
        let unavailableSet = factsForType.map { $0.unavailableWeight }
        let defaults = DefaultWeightIncrements.defaults(for: equipmentType)
        let available = defaults.filter { w in !unavailableSet.contains { abs($0 - w) < 0.1 } }
        return factsForType.map { fact in
            let below = available.filter { $0 < fact.unavailableWeight }.max()
            let above = available.filter { $0 > fact.unavailableWeight }.min()
            let nearestStr: String
            if let lb = below, let ub = above {
                nearestStr = " Nearest available: \(formatWeight(lb)) or \(formatWeight(ub))."
            } else if let lb = below {
                nearestStr = " Nearest available below: \(formatWeight(lb))."
            } else if let ub = above {
                nearestStr = " Nearest available above: \(formatWeight(ub))."
            } else {
                nearestStr = ""
            }
            return "\(formatWeight(fact.unavailableWeight)) is not available in this gym. Never prescribe it.\(nearestStr)"
        }
    }

    /// Returns all context strings across all equipment types (for full injection).
    func allContextStrings() -> [String] {
        let allEquipmentTypes = Set(facts.map { $0.equipmentType })
        return allEquipmentTypes.flatMap { equipmentType in
            contextStrings(for: equipmentType).map { "\(equipmentType.displayName): \($0)" }
        }
    }

    /// Returns the available standard weights nearest to `weight` for the given equipment type,
    /// filtered to remove all known unavailable weights. Used by ActiveSetView to show a hint.
    /// Returns an empty array if no corrections exist for this equipment type.
    func nearbyAvailableWeights(near weight: Double, for equipmentType: EquipmentType) -> [Double] {
        let factsForType = facts.filter { $0.equipmentType == equipmentType }
        guard !factsForType.isEmpty else { return [] }
        let unavailableSet = factsForType.map { $0.unavailableWeight }
        let defaults = DefaultWeightIncrements.defaults(for: equipmentType)
        guard !defaults.isEmpty else { return [] }
        let available = defaults.filter { w in !unavailableSet.contains { abs($0 - w) < 0.1 } }
        let below = available.filter { $0 <= weight }.suffix(2)
        let above = available.filter { $0 > weight }.prefix(3)
        return Array(below) + Array(above)
    }

    // MARK: - Private format helper

    private func formatWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fkg", kg)
            : String(format: "%.1fkg", kg)
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "com.projectapex.gymFactStore"

    private func saveToUserDefaults() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }

    private static func loadFromUserDefaults(userDefaults: UserDefaults) -> [WeightFact] {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let facts = try? JSONDecoder().decode([WeightFact].self, from: data)
        else { return [] }
        return facts
    }

    /// Removes a single weight correction fact. Used to fix incorrectly recorded corrections.
    func removeFact(for equipmentType: EquipmentType, unavailableWeight: Double) {
        facts.removeAll {
            $0.equipmentType == equipmentType && abs($0.unavailableWeight - unavailableWeight) < 0.1
        }
        saveToUserDefaults()
    }

    /// Clears all stored facts. Used for testing.
    func clearAll() {
        facts = []
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
    }
}
