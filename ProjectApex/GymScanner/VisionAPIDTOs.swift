// VisionAPIDTOs.swift
// ProjectApex — GymScanner Feature
//
// Wire-format DTOs for the Vision API response (TDD Section 5.3).
// EquipmentItem and all domain types live in Models/GymProfile.swift.
//
// ISOLATION NOTE:
// This target has SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor. All types here
// are `nonisolated` so their synthesised Codable conformances are not
// @MainActor-isolated, keeping them decodable from a background actor
// (VisionAPIService).

import Foundation

// MARK: - VisionAPIResponse (legacy wrapper — kept for backward compatibility)

/// Top-level JSON wrapper. Some response paths may still use the wrapped format.
/// `nonisolated` opts this type out of the target-wide @MainActor default,
/// keeping the synthesised `Decodable` init callable from any actor context.
nonisolated struct VisionAPIResponse: Codable, Sendable {

    /// The equipment items detected in this single camera frame.
    let items: [EquipmentItem]

    /// Optional frame-level confidence score (0.0–1.0).
    let frameConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case items           = "equipment"
        case frameConfidence = "frame_confidence"
    }
}

// MARK: - VisionDetectedItem (TDD Section 5.3 wire format)

/// The exact JSON shape returned by the Vision API per TDD Section 5.3.
///
/// Each item in the flat array looks like:
/// ```json
/// {
///   "equipment_type": "dumbbell_set",
///   "estimated_weight_range_kg": { "min": 2.5, "max": 45.0, "increment": 2.5 },
///   "count": 1
/// }
/// ```
/// For bodyweight equipment, `estimated_weight_range_kg` is `null`.
/// Unknown types are encoded as `"unknown:<description>"` (colon-separated).
nonisolated struct VisionDetectedItem: Decodable, Sendable {

    let equipmentType: String
    let estimatedWeightRangeKg: WeightRange?
    let count: Int

    enum CodingKeys: String, CodingKey {
        case equipmentType         = "equipment_type"
        case estimatedWeightRangeKg = "estimated_weight_range_kg"
        case count
    }

    // MARK: - Nested weight range DTO

    nonisolated struct WeightRange: Decodable, Sendable {
        let min: Double
        let max: Double
        let increment: Double?
    }
}

// MARK: - VisionDetectedItem → EquipmentItem mapping

extension VisionDetectedItem {

    /// Maps the Vision API wire-format item to the domain `EquipmentItem`.
    ///
    /// - `equipment_type` strings are mapped via `EquipmentType.init(typeKey:rawValue:)`.
    ///   Unknown strings (including the `"unknown:<desc>"` convention) become
    ///   `EquipmentType.unknown("<string>")`.
    /// - `estimated_weight_range_kg` is mapped to `.incrementBased` when present,
    ///   or `.bodyweightOnly` when nil.
    func toEquipmentItem() -> EquipmentItem {
        // Parse the equipment type, handling the "unknown:<description>" convention
        let parsedType: EquipmentType
        if equipmentType.hasPrefix("unknown:") {
            let description = String(equipmentType.dropFirst("unknown:".count))
            parsedType = .unknown(description)
        } else {
            parsedType = EquipmentType(typeKey: equipmentType)
        }

        // Map weight range to EquipmentDetails
        let details: EquipmentDetails
        if let range = estimatedWeightRangeKg {
            let increment = range.increment ?? 2.5
            details = .incrementBased(minKg: range.min, maxKg: range.max, incrementKg: increment)
        } else {
            details = .bodyweightOnly
        }

        return EquipmentItem(
            equipmentType: parsedType,
            count: max(1, count),
            details: details,
            detectedByVision: true
        )
    }
}
