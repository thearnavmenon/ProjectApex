// Models/DefaultWeightIncrements.swift
// ProjectApex
//
// Standard commercial gym weight assumptions.
// These are defaults used by the AI for program generation.
// They are NOT scanned — they are baked in and refined at runtime
// via GymFactStore weight corrections.

import Foundation

// MARK: - DefaultWeightIncrements

nonisolated enum DefaultWeightIncrements {

    static let dumbbells: [Double] = [
        2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20,
        22.5, 25, 27.5, 30, 32.5, 35, 37.5, 40,
        42.5, 45, 47.5, 50, 55, 60
    ]

    static let barbellLoadings: [Double] = {
        // 20kg bar + standard plates in 2.5kg steps to 200kg
        stride(from: 20.0, through: 200.0, by: 2.5).map { $0 }
    }()

    static let cableStack: [Double] = [
        5, 10, 15, 20, 25, 30, 35, 40, 45, 50,
        55, 60, 65, 70, 75, 80, 90, 100
    ]

    /// Weight stack machines (leg press, hack squat, chest press, shoulder press, etc.).
    /// Stacks go up in 5 kg steps — 2.5 kg plates do not exist on most commercial machines.
    static let machineStack: [Double] = [
        5, 10, 15, 20, 25, 30, 35, 40, 45, 50,
        55, 60, 65, 70, 75, 80, 90, 100, 110, 120,
        130, 140, 150, 160, 180, 200
    ]

    static let kettlebells: [Double] = [
        4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 40
    ]

    /// Returns the standard commercial weight array for the given equipment type.
    /// Returns an empty array for equipment types that don't use weight loading
    /// (benches, pull-up bars, etc.).
    static func defaults(for type: EquipmentType) -> [Double] {
        switch type {
        case .dumbbellSet:              return dumbbells
        case .barbell, .ezCurlBar:      return barbellLoadings
        case .cableMachine,
             .cableMachineDual,
             .latPulldown,
             .seatedRow,
             .cableCrossover:           return cableStack
        case .smithMachine,
             .legPress,
             .hackSquat,
             .chestPressMachine,
             .shoulderPressMachine,
             .legExtension,
             .legCurl,
             .pecDeck,
             .preacherCurl,
             .reverseFly,
             .hipThrustMachine,
             .calfRaiseMachine,
             .tBarRow:                  return machineStack
        case .kettlebellSet:            return kettlebells
        default:                        return []
        }
    }

    /// Returns the two nearest available weights to a prescribed weight.
    /// Used by WeightCorrectionView to suggest options to the user.
    ///
    /// - Parameters:
    ///   - prescribed: The weight the AI prescribed.
    ///   - type: The equipment type being used.
    ///   - unavailable: Known unavailable weights to exclude from results.
    /// - Returns: The nearest lower and upper bounds from the standard array.
    static func nearestWeights(
        to prescribed: Double,
        for type: EquipmentType,
        excluding unavailable: [Double] = []
    ) -> (lower: Double?, upper: Double?) {
        let available = defaults(for: type)
            .filter { !unavailable.contains($0) }
        let lower = available.filter { $0 < prescribed }.last
        let upper = available.filter { $0 > prescribed }.first
        return (lower, upper)
    }

    /// Snaps a prescribed weight to an available increment per PRD §7.1.1
    /// (#318 U7 / G-F8): round DOWN to the lower neighbour unless the target
    /// is ≥ lower + 0.6 × (upper − lower), in which case round UP. At the
    /// table edges: below-min snaps UP, above-max snaps DOWN.
    ///
    /// Returns nil when no snap applies: the equipment has no weight table,
    /// the weight is non-positive, the weight is already available (epsilon
    /// membership — never exact `==`), or every table entry is excluded.
    static func snap(
        _ weight: Double,
        for type: EquipmentType,
        excluding unavailable: [Double] = []
    ) -> Double? {
        let epsilon = 0.05
        let table = defaults(for: type)
        guard !table.isEmpty, weight > 0 else { return nil }
        // Exclusion matching uses the GymFactStore convention (abs < 0.1).
        let available = table.filter { w in
            !unavailable.contains { abs($0 - w) < 0.1 }
        }
        guard !available.isEmpty else { return nil }
        // Already available — no snap needed.
        guard !available.contains(where: { abs($0 - weight) < epsilon }) else { return nil }

        let lower = available.last(where: { $0 < weight })
        let upper = available.first(where: { $0 > weight })
        switch (lower, upper) {
        case (nil, nil):
            return nil
        case (nil, .some(let up)):           // below-min → snap UP
            return up
        case (.some(let low), nil):          // above-max → snap DOWN
            return low
        case (.some(let low), .some(let up)):
            let threshold = low + 0.6 * (up - low)   // bias-down rule (PRD §7.1.1)
            return weight >= threshold ? up : low
        }
    }

    /// Largest available weight ≤ `weight` (#318 U7 / G-F3) — used to re-snap
    /// a clamped cap so the stored weight is a real available weight. Returns
    /// nil when the equipment has no weight table or nothing is ≤ `weight`.
    static func snapDown(
        _ weight: Double,
        for type: EquipmentType,
        excluding unavailable: [Double] = []
    ) -> Double? {
        let available = defaults(for: type).filter { w in
            !unavailable.contains { abs($0 - w) < 0.1 }
        }
        return available.last(where: { $0 <= weight + 0.05 })
    }
}
