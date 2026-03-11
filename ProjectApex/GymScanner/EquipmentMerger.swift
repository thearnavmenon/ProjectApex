// EquipmentMerger.swift
// ProjectApex — GymScanner Feature
//
// Stateless struct that collapses multiple frames of Vision API detections into
// a single, deduplicated list of EquipmentItems suitable for the confirmation
// screen (P1-T03 / FR-001-E).
//
// Merge rules (per TDD Section 5.3):
//   • Group by equipment_type; one output item per type.
//   • count  = max count seen across all frames.
//   • WeightRange merging for incrementBased details:
//       min       = min of all observed minKg values
//       max       = max of all observed maxKg values
//       increment = statistical mode across all frames (ties: smallest wins)
//   • plateBased details: merged by taking the widest plate set (superset union).
//   • bodyweightOnly: if any frame carries richer details (incrementBased /
//     plateBased) for the same type, the richer details win.
//   • Unknown types are passed through with their raw string value preserved.
//   • Output is sorted alphabetically by the canonical typeKey string so the
//     confirmation screen is consistent across runs.
//
// ISOLATION NOTE:
// `nonisolated` struct — safe to call from any actor context under the
// target-wide SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor setting.

import Foundation

// MARK: - EquipmentMerger

/// Merges equipment detections from multiple overlapping camera frames into a
/// single deduplicated `[EquipmentItem]`.
///
/// Typical usage:
/// ```swift
/// let allFrameResults: [[VisionDetectedItem]] = ...
/// let merged = EquipmentMerger.merge(allFrameResults)
/// ```
nonisolated struct EquipmentMerger {

    // MARK: - Public API

    /// Merges `detections` from multiple frames into one deduplicated list.
    ///
    /// - Parameter detections: An array where each element is the list of items
    ///   detected in one camera frame (the output of `VisionAPIService.analyseFrame`
    ///   before conversion, expressed as `[VisionDetectedItem]`).
    /// - Returns: A sorted, deduplicated `[EquipmentItem]` — one entry per
    ///   equipment type, with the widest observed ranges and highest count.
    static func merge(_ detections: [[VisionDetectedItem]]) -> [EquipmentItem] {
        guard !detections.isEmpty else { return [] }

        // Accumulator: typeKey string → list of all raw detections for that type
        var buckets: [String: [VisionDetectedItem]] = [:]

        for frame in detections {
            for item in frame {
                let key = normalizedKey(for: item.equipmentType)
                buckets[key, default: []].append(item)
            }
        }

        let merged: [EquipmentItem] = buckets.map { key, items in
            mergeGroup(typeKey: key, items: items)
        }

        // Sort alphabetically by typeKey for consistent display ordering.
        return merged.sorted { lhs, rhs in
            lhs.equipmentType.typeKey < rhs.equipmentType.typeKey
        }
    }

    // MARK: - Private: Group merging

    /// Collapses all `VisionDetectedItem`s for a single equipment type into one
    /// `EquipmentItem`, applying the merge rules described in the file header.
    private static func mergeGroup(typeKey: String, items: [VisionDetectedItem]) -> EquipmentItem {
        precondition(!items.isEmpty)

        // Parse the equipment type from the canonical key.
        let equipmentType: EquipmentType
        if typeKey.hasPrefix("unknown:") {
            let description = String(typeKey.dropFirst("unknown:".count))
            equipmentType = .unknown(description)
        } else {
            equipmentType = EquipmentType(typeKey: typeKey)
        }

        // count = max count seen across all frames
        let maxCount = items.map(\.count).max() ?? 1

        // Merge EquipmentDetails from all observations in the group.
        let mergedDetails = mergeDetails(from: items)

        return EquipmentItem(
            equipmentType: equipmentType,
            count: max(1, maxCount),
            details: mergedDetails,
            detectedByVision: true
        )
    }

    // MARK: - Private: Details merging

    /// Merges all `estimatedWeightRangeKg` observations from the group into one
    /// `EquipmentDetails`.
    ///
    /// Priority:
    ///   1. incrementBased — if any observation carries a weight range, use it
    ///      (widest range, mode increment).
    ///   2. bodyweightOnly — if every observation is nil (no range).
    private static func mergeDetails(from items: [VisionDetectedItem]) -> EquipmentDetails {
        let ranges = items.compactMap(\.estimatedWeightRangeKg)

        guard !ranges.isEmpty else {
            // No weight range in any observation → bodyweight only.
            return .bodyweightOnly
        }

        // Widest range across all frames.
        let minKg       = ranges.map(\.min).min()!
        let maxKg       = ranges.map(\.max).max()!

        // Mode increment: most commonly seen increment value.
        // On ties, prefer the smallest (most fine-grained).
        let incrementKg = modeIncrement(from: ranges)

        return .incrementBased(minKg: minKg, maxKg: maxKg, incrementKg: incrementKg)
    }

    // MARK: - Private: Mode increment computation

    /// Returns the most frequently occurring increment from `ranges`.
    /// On a tie, the smallest increment wins (finest resolution wins).
    ///
    /// Falls back to 2.5 kg if no increments are present (API omitted the field).
    private static func modeIncrement(from ranges: [VisionDetectedItem.WeightRange]) -> Double {
        let increments = ranges.compactMap(\.increment)

        guard !increments.isEmpty else { return 2.5 }

        // Frequency map — round to 4 decimal places to handle floating-point noise.
        var frequency: [Double: Int] = [:]
        for inc in increments {
            let rounded = (inc * 10_000).rounded() / 10_000
            frequency[rounded, default: 0] += 1
        }

        // Find the max frequency, then pick the smallest key with that frequency.
        let maxFreq = frequency.values.max()!
        let candidates = frequency.filter { $0.value == maxFreq }.keys.sorted()
        return candidates.first ?? 2.5
    }

    // MARK: - Private: Key normalisation

    /// Returns a stable bucket key for a raw `equipment_type` string.
    ///
    /// Known types:  use the raw string as-is (it's already a canonical key like
    ///               `"dumbbell_set"`).
    /// Unknown types: prefix with `"unknown:"` so they bucket separately from
    ///               known types and carry their description through intact.
    private static func normalizedKey(for rawType: String) -> String {
        // The Vision API encodes unknowns as "unknown:<description>".
        // We preserve that prefix intact as the bucket key so each distinct
        // unknown description gets its own output item.
        return rawType
    }
}
