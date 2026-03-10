// Models.swift
// ProjectApex — GymScanner Feature
//
// Core domain model layer for the gym equipment scanning pipeline.
//
// ISOLATION NOTE — SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor:
// This target defaults every type to @MainActor. Any struct that needs to be
// Codable AND decoded inside a background actor (VisionAPIService) MUST be
// marked `nonisolated` to opt its synthesized conformances out of @MainActor.
// Rule: DTO structs are nonisolated. UI / @Observable view-models are @MainActor.
//
// Dependency: import Foundation only — no SwiftUI, no actor-adjacent types.

import Foundation

// MARK: - EquipmentItem

/// A single piece of gym equipment identified by the Vision API from one camera frame.
///
/// `nonisolated` opts this type out of the target-wide @MainActor default so that
/// its synthesised `Decodable` init is callable from VisionAPIService (a background actor).
nonisolated struct EquipmentItem: Codable, Identifiable, Equatable, Sendable {

    // ---------------------------------------------------------------------------
    // MARK: Stored Properties
    // ---------------------------------------------------------------------------

    /// Stable snake_case identifier — the deduplication key (FR-001-E).
    /// Examples: "dumbbell_set", "barbell", "cable_machine", "adjustable_bench".
    var equipmentType: String

    /// Human-readable display name (computed, not persisted).
    var displayName: String {
        equipmentType
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// Weight range in kg for equipment with a stack or fixed weight.
    /// Nil for bodyweight / non-weighted items.
    var estimatedWeightRangeKg: WeightRange?

    /// Increment between available weights in kg (e.g. 2.5 for a dumbbell rack).
    var incrementsAvailableKg: Double?

    /// Unit count. Aggregated during merge across successive scan frames.
    var count: Int

    // ---------------------------------------------------------------------------
    // MARK: Identifiable
    // ---------------------------------------------------------------------------

    var id: String { equipmentType }

    // ---------------------------------------------------------------------------
    // MARK: CodingKeys
    // ---------------------------------------------------------------------------

    enum CodingKeys: String, CodingKey {
        case equipmentType          = "equipment_type"
        case estimatedWeightRangeKg = "estimated_weight_range_kg"
        case incrementsAvailableKg  = "increments_available_kg"
        case count
    }
}

// MARK: - WeightRange

/// An inclusive weight range [min, max] in kilograms.
/// `nonisolated` for the same reason as EquipmentItem.
nonisolated struct WeightRange: Codable, Equatable, Sendable {
    var minKg: Double
    var maxKg: Double

    enum CodingKeys: String, CodingKey {
        case minKg = "min_kg"
        case maxKg = "max_kg"
    }

    /// Generates the discrete weight array for EquipmentRounder.
    func availableWeights(increment: Double?) -> [Double] {
        guard let step = increment, step > 0 else { return [minKg, maxKg] }
        var weights: [Double] = []
        var current = minKg
        while current <= maxKg + 0.001 { // tolerance for floating-point drift
            weights.append(current)
            current += step
        }
        return weights
    }
}

// MARK: - GymProfile

/// The master equipment profile for the user's gym.
///
/// `nonisolated` so its Codable conformance is not @MainActor-isolated.
/// Persistence (UserDefaults read/write) is handled in GymProfile+Persistence.swift
/// where the call site context can control actor isolation explicitly.
nonisolated struct GymProfile: Codable, Sendable {

    /// Unique ID for this scan session (for Supabase versioning).
    var scanSessionId: String

    /// ISO 8601 timestamp of scan initiation.
    var createdAt: Date

    /// Merged, deduplicated equipment list.
    var equipment: [EquipmentItem]

    enum CodingKeys: String, CodingKey {
        case scanSessionId = "scan_session_id"
        case createdAt     = "created_at"
        case equipment
    }
}

// MARK: - ScannerError

/// Domain-specific errors for the gym scanning pipeline.
/// `nonisolated` so it can be thrown/caught from any actor context.
nonisolated enum ScannerError: LocalizedError {
    case cameraPermissionDenied
    case cameraSetupFailed(underlying: Error)
    case frameCaptureFailed
    case apiRequestFailed(underlying: Error)
    case apiResponseMalformed(rawResponse: String)
    case apiResponseEmpty

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Camera access is required to scan your gym. Please enable it in Settings."
        case .cameraSetupFailed(let error):
            return "Failed to configure the camera: \(error.localizedDescription)"
        case .frameCaptureFailed:
            return "Failed to capture a frame from the camera."
        case .apiRequestFailed(let error):
            return "Vision API request failed: \(error.localizedDescription)"
        case .apiResponseMalformed(let raw):
            return "Vision API returned an unexpected response format. Raw: \(raw.prefix(200))"
        case .apiResponseEmpty:
            return "The Vision API did not detect any equipment in this frame."
        }
    }
}
