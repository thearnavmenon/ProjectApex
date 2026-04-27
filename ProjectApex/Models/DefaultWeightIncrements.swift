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
             .preacherCurl:             return machineStack
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
}
