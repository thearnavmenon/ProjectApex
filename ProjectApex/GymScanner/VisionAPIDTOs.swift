// VisionAPIDTOs.swift
// ProjectApex — GymScanner Feature
//
// Data-Transfer Objects used exclusively in the Vision API request/response cycle.
//
// ISOLATION NOTE:
// This target has SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which means every
// type defaults to @MainActor unless explicitly opted out. Types used for JSON
// decoding inside a background actor (VisionAPIService) MUST be marked
// `nonisolated` so their synthesized Codable conformances are not @MainActor-isolated.
//
// Rule: Any struct that needs to be Codable AND decoded inside a non-MainActor
// context (e.g., a Swift actor, a detached Task) must carry `nonisolated` here.

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
