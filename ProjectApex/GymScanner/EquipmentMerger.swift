// EquipmentMerger.swift
// ProjectApex — GymScanner Feature
//
// Stateless struct that collapses multiple frames of Vision API detections into
// a single, deduplicated list of EquipmentItems suitable for the confirmation
// screen.
//
// Merge rules:
//   1. Flatten all frame detections into one array.
//   2. Apply cardio blocklist filter (case-insensitive) — remove all cardio types.
//   3. Apply junk blocklist filter — remove non-equipment detections.
//   4. Group by equipment_type string (lowercased, trimmed).
//   5. For each group: count = max count seen across all frames.
//   6. Map equipment_type string to EquipmentType enum via init(typeKey:).
//   7. Drop ALL .unknown items — model ignored the fixed vocabulary; treat as noise.
//   8. Sort alphabetically by typeKey for consistent display ordering.
//   9. Return [EquipmentItem] — no weight ranges.
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

    // MARK: - Blocklists

    /// Cardio equipment types to block. Any detection whose equipment_type
    /// matches one of these (case-insensitive) is discarded entirely.
    private static let cardioBlocklist: Set<String> = [
        "treadmill",
        "rowing_machine",
        "rower",
        "stationary_bike",
        "recumbent_exercise_bike",
        "stationary_bike_with_screen",
        "stationary_bike_or_exercise_bike",
        "elliptical_machine",
        "elliptical",
        "assault_bike",
        "ski_erg",
        "stair_climber",
        "cycling_machine",
        "exercise_bike",
        "stationary_bike_or_cycling_machine",
        "recumbent_bike"
    ]

    /// Junk detections that are not actual exercise equipment.
    private static let junkBlocklist: Set<String> = [
        "metal equipment base/stand",
        "equipment stand",
        "floor",
        "mirror",
        "mat",
        "foam roller"
    ]

    // MARK: - Public API

    /// Merges `detections` from multiple frames into one deduplicated list.
    ///
    /// - Parameter detections: An array where each element is the list of items
    ///   detected in one camera frame (the output of `VisionAPIService.analyseFrame`
    ///   before conversion, expressed as `[VisionDetectedItem]`).
    /// - Returns: A sorted, deduplicated `[EquipmentItem]` — one entry per
    ///   equipment type, with the highest count seen across all frames.
    static func merge(_ detections: [[VisionDetectedItem]]) -> [EquipmentItem] {
        guard !detections.isEmpty else { return [] }

        // Step 1: Flatten all frame detections
        let flat = detections.flatMap { $0 }

        // Step 2 & 3: Filter cardio and junk
        let filtered = flat.filter { item in
            let key = item.equipmentType.lowercased().trimmingCharacters(in: .whitespaces)
            return !cardioBlocklist.contains(key) && !junkBlocklist.contains(key)
        }

        // Step 4: Group by normalised equipment_type key
        var buckets: [String: [VisionDetectedItem]] = [:]
        for item in filtered {
            let key = item.equipmentType.lowercased().trimmingCharacters(in: .whitespaces)
            buckets[key, default: []].append(item)
        }

        // Step 5–7: Merge each group into one EquipmentItem
        let merged: [EquipmentItem] = buckets.compactMap { key, items in
            let equipmentType = EquipmentType(typeKey: key)

            // Step 7: Drop ALL unknown types — they mean the model ignored the
            // fixed vocabulary constraint and are never legitimate gym equipment.
            if case .unknown = equipmentType {
                return nil
            }

            // Step 5: count = max count seen across all frames
            let maxCount = items.map(\.count).max() ?? 1

            return EquipmentItem(
                equipmentType: equipmentType,
                count: max(1, maxCount),
                detectedByVision: true
            )
        }

        // Step 8: Sort alphabetically by typeKey for consistent display ordering.
        return merged.sorted { lhs, rhs in
            lhs.equipmentType.typeKey < rhs.equipmentType.typeKey
        }
    }
}
