// EquipmentRounder.swift
// ProjectApex — AICoach Feature
//
// Stateless struct that maps an AI-prescribed weight (Double) to the nearest
// achievable weight for a specific piece of equipment in the user's GymProfile.
//
// Rounding strategies:
//   • incrementBased  — safety-biased midpoint: round up if weight >= midpoint,
//                       round down otherwise. Clamped to [minKg, maxKg].
//   • plateBased      — greedy per-side plate selection from heaviest to lightest.
//   • bodyweightOnly  — always returns 0.0 kg.
//
// ISOLATION NOTE:
// Marked `nonisolated` so it is freely usable from background actor contexts
// under the target-wide SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor setting.

import Foundation

// MARK: - RoundingResult

/// The outcome of a single EquipmentRounder.round() call.
nonisolated struct RoundingResult {
    /// The achievable weight after rounding.
    let roundedWeightKg: Double
    /// Whether the prescribed weight was changed.
    let wasAdjusted: Bool
    /// The original AI-prescribed weight before rounding.
    let originalWeightKg: Double
    /// Human-readable explanation of the adjustment (or nil if no change).
    let adjustmentNote: String?
}

// MARK: - EquipmentRounder

/// Maps AI-prescribed weights to the nearest achievable weight for a given
/// equipment type in the user's GymProfile.
nonisolated struct EquipmentRounder {

    let gymProfile: GymProfile

    // MARK: - Public API

    /// Rounds `weight` to the nearest achievable weight for `equipmentType`.
    /// Returns the original weight unchanged (with `wasAdjusted = false`) if the
    /// equipment type is not found in the gym profile.
    func round(aiPrescribedWeightKg weight: Double, for equipmentType: EquipmentType) -> RoundingResult {
        guard let item = gymProfile.item(for: equipmentType) else {
            // Equipment not in profile — return as-is with a note
            return RoundingResult(
                roundedWeightKg: weight,
                wasAdjusted: false,
                originalWeightKg: weight,
                adjustmentNote: "Equipment '\(equipmentType.displayName)' not found in gym profile; weight unchanged."
            )
        }

        switch item.details {
        case .incrementBased(let minKg, let maxKg, let incrementKg):
            return roundIncrement(
                weight: weight,
                minKg: minKg, maxKg: maxKg, incrementKg: incrementKg
            )

        case .plateBased(let barWeightKg, let availablePlatesKg):
            return roundPlate(
                weight: weight,
                barWeightKg: barWeightKg,
                availablePlatesKg: availablePlatesKg
            )

        case .bodyweightOnly:
            let adjusted = weight != 0.0
            return RoundingResult(
                roundedWeightKg: 0.0,
                wasAdjusted: adjusted,
                originalWeightKg: weight,
                adjustmentNote: adjusted ? "Bodyweight-only equipment: weight set to 0 kg." : nil
            )
        }
    }

    // MARK: - Private: Increment-Based Rounding

    /// Safety-biased midpoint rounding for stack/dumbbell equipment.
    ///
    /// The midpoint is biased toward the upper end of each increment step (×0.6)
    /// so borderline weights round up — conservative for hypertrophy progression.
    private func roundIncrement(
        weight: Double,
        minKg: Double,
        maxKg: Double,
        incrementKg: Double
    ) -> RoundingResult {
        guard incrementKg > 0, minKg < maxKg else {
            // Degenerate config — clamp and return
            let clamped = Swift.max(minKg, Swift.min(maxKg, weight))
            let adjusted = abs(clamped - weight) > 0.001
            return RoundingResult(
                roundedWeightKg: clamped,
                wasAdjusted: adjusted,
                originalWeightKg: weight,
                adjustmentNote: adjusted ? "Clamped to equipment range [\(minKg)–\(maxKg)] kg." : nil
            )
        }

        // Number of full increments below the prescribed weight
        let stepsBelow = floor((weight - minKg) / incrementKg)
        let lower = minKg + stepsBelow * incrementKg
        let upper = lower + incrementKg

        // Safety-biased midpoint: 60% of the way from lower to upper
        let midpoint = lower + incrementKg * 0.6

        let candidate = weight >= midpoint ? upper : lower

        // Clamp to valid range
        let clamped = Swift.max(minKg, Swift.min(maxKg, candidate))

        let adjusted = abs(clamped - weight) > 0.001
        let note: String? = adjusted
            ? "Rounded \(formatKg(weight)) → \(formatKg(clamped)) kg " +
              "(increment \(formatKg(incrementKg)) kg, range \(formatKg(minKg))–\(formatKg(maxKg)) kg)."
            : nil

        return RoundingResult(
            roundedWeightKg: clamped,
            wasAdjusted: adjusted,
            originalWeightKg: weight,
            adjustmentNote: note
        )
    }

    // MARK: - Private: Plate-Based Rounding

    /// Greedy per-side plate selection for barbell/plate-loaded equipment.
    ///
    /// Algorithm:
    ///   1. Compute the per-side target load = (total - barWeight) / 2.
    ///   2. Sort plates descending.
    ///   3. Greedily add each plate denomination while it fits within the remaining load.
    ///   4. Return (sum of selected plates × 2) + barWeight.
    ///
    /// Note: plate denominations represent individual plates (one per side),
    /// not pairs. Each denomination can be used multiple times (unbounded).
    private func roundPlate(
        weight: Double,
        barWeightKg: Double,
        availablePlatesKg: [Double]
    ) -> RoundingResult {
        let perSideTarget = Swift.max(0.0, (weight - barWeightKg) / 2.0)

        let sortedPlates = availablePlatesKg
            .filter { $0 > 0 }
            .sorted(by: >)  // heaviest first

        guard !sortedPlates.isEmpty else {
            // No plates available — return bar weight only
            let rounded = barWeightKg
            let adjusted = abs(rounded - weight) > 0.001
            return RoundingResult(
                roundedWeightKg: rounded,
                wasAdjusted: adjusted,
                originalWeightKg: weight,
                adjustmentNote: adjusted ? "No plates available; returning bar weight \(formatKg(barWeightKg)) kg." : nil
            )
        }

        // Greedy unbounded selection
        var remaining = perSideTarget
        var selectedPlates: [Double] = []

        for plate in sortedPlates {
            while remaining >= plate - 0.001 {
                selectedPlates.append(plate)
                remaining -= plate
            }
        }

        let perSideLoad = selectedPlates.reduce(0, +)
        let rounded = barWeightKg + perSideLoad * 2.0

        let adjusted = abs(rounded - weight) > 0.001
        let note: String? = adjusted
            ? "Plate rounding: \(formatKg(weight)) → \(formatKg(rounded)) kg " +
              "(bar \(formatKg(barWeightKg)) kg + \(formatKg(perSideLoad)) kg/side)."
            : nil

        return RoundingResult(
            roundedWeightKg: rounded,
            wasAdjusted: adjusted,
            originalWeightKg: weight,
            adjustmentNote: note
        )
    }

    // MARK: - Formatting helper

    private func formatKg(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(kg))
            : String(format: "%.2g", kg)
    }
}
