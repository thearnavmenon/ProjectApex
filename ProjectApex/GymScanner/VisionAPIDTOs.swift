// VisionAPIDTOs.swift
// ProjectApex — GymScanner Feature
//
// Wire-format DTOs for the Vision API response (TDD Section 5.3).
// The scanner identifies equipment PRESENCE only — no weight ranges.
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

/// The exact JSON shape returned by the Vision API per the gym scan prompt.
///
/// Each item in the flat array looks like:
/// ```json
/// {
///   "equipment_type": "dumbbell_set",
///   "count": 1,
///   "confidence": 0.95
/// }
/// ```
/// No weight range fields — the scanner records presence only.
nonisolated struct VisionDetectedItem: Decodable, Sendable {

    let equipmentType: String
    let count: Int
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case equipmentType = "equipment_type"
        case count
        case confidence
    }
}

// MARK: - VisionDetectedItem → EquipmentItem mapping

extension VisionDetectedItem {

    /// Maps the Vision API wire-format item to the domain `EquipmentItem`.
    ///
    /// - `equipment_type` strings are mapped via `EquipmentType.init(typeKey:rawValue:)`.
    ///   Unknown strings become `EquipmentType.unknown("<string>")`.
    /// - No weight range fields are present; weight defaults come from
    ///   `DefaultWeightIncrements` at runtime.
    func toEquipmentItem() -> EquipmentItem {
        EquipmentItem(
            equipmentType: EquipmentType(typeKey: equipmentType),
            count: max(1, count),
            detectedByVision: true
        )
    }
}
