// Models.swift
// ProjectApex — GymScanner Feature
//
// Scanner-specific error types. All domain model types (EquipmentItem, GymProfile, etc.)
// live in Models/GymProfile.swift — this file is intentionally lean.

import Foundation

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
