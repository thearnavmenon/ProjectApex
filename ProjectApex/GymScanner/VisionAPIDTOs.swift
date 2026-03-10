// VisionAPIDTOs.swift
// ProjectApex — GymScanner Feature
//
// Top-level JSON wrapper for the Vision API response envelope.
// EquipmentItem and all domain types live in Models/GymProfile.swift.
//
// ISOLATION NOTE:
// This target has SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor. This struct must be
// `nonisolated` so its synthesized Codable conformance is not @MainActor-isolated,
// keeping it decodable from a background actor (VisionAPIService).

import Foundation

// MARK: - VisionAPIResponse

/// Top-level JSON wrapper returned by the Vision API.
/// `nonisolated` opts this type out of the target-wide @MainActor default,
/// keeping the synthesized `Decodable` init callable from any actor context.
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
