// CalibrationReviewStretchPayloadTests.swift
// ProjectApexTests
//
// #269 S4: unit tests for the pure payload helper behind the calibration-review
// screen, `CalibrationReviewView.makeCalibrationStretchPayload(...)`. SwiftUI
// bodies aren't unit-testable, so the wire-payload construction lives in a pure
// static function that takes `now: Date` — these tests pin its behaviour.
//
// The contract under test:
//   • `stretch_edits` includes ONLY patterns whose edited stretch is strictly
//     greater than the original (unchanged → omitted; lowered → omitted).
//   • `acknowledge_calibration_review` is ALWAYS true (even with zero edits, so
//     "review and accept as-is" durably hides the banner).
//
// `makeCalibrationStretchPayload` + the payload structs are `internal`, so
// `@testable` can call/encode them directly.

import Testing
import Foundation
@testable import ProjectApex

@Suite("CalibrationReview stretch payload")
struct CalibrationReviewStretchPayloadTests {

    private static let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static let goalBody = GoalUpsertBody(
        statement: "Hypertrophy",
        focusAreas: [],
        updatedAt: "2026-05-12T10:00:00.000Z"
    )

    private static let original: [PatternProjection] = [
        PatternProjection(pattern: .squat, floor: 140, stretch: 150, progress: .onTrack),
        PatternProjection(pattern: .horizontalPush, floor: 100, stretch: 107.5, progress: .onTrack),
    ]

    /// Encodes the payload the way the Save call site does (bare JSONEncoder)
    /// and deserializes to a JSON object for wire-shape assertions.
    private func encode(_ payload: TraineeGoalUpsertPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(obj)
    }

    // MARK: - Only RAISED patterns appear in stretch_edits

    @Test("A raised pattern is the only entry in stretch_edits")
    func raisedPatternIncluded() throws {
        // squat raised 150 → 160; horizontal_push left at its original 107.5.
        let payload = CalibrationReviewView.makeCalibrationStretchPayload(
            userId: UUID(),
            goal: Self.goalBody,
            editedStretch: [.squat: 160, .horizontalPush: 107.5],
            original: Self.original,
            now: Self.fixedNow
        )

        let edits = try #require(payload.stretchEdits)
        #expect(edits.count == 1)
        #expect(edits.first?.pattern == "squat")
        #expect(edits.first?.stretch == 160)
    }

    @Test("A pattern left at its original stretch is omitted")
    func unchangedPatternOmitted() {
        let payload = CalibrationReviewView.makeCalibrationStretchPayload(
            userId: UUID(),
            goal: Self.goalBody,
            editedStretch: [.squat: 150, .horizontalPush: 107.5],
            original: Self.original,
            now: Self.fixedNow
        )
        // Both unchanged → no raised edits → nil (so the key omits on the wire).
        #expect(payload.stretchEdits == nil)
    }

    @Test("A lowered value is clamped/omitted (never below the original)")
    func loweredValueOmitted() {
        let payload = CalibrationReviewView.makeCalibrationStretchPayload(
            userId: UUID(),
            goal: Self.goalBody,
            editedStretch: [.squat: 145, .horizontalPush: 107.5],
            original: Self.original,
            now: Self.fixedNow
        )
        // 145 < original 150 → not a raise → omitted.
        #expect(payload.stretchEdits == nil)
    }

    // MARK: - acknowledge_calibration_review is ALWAYS true

    @Test("acknowledge_calibration_review is true even with raised edits")
    func ackTrueWithEdits() {
        let payload = CalibrationReviewView.makeCalibrationStretchPayload(
            userId: UUID(),
            goal: Self.goalBody,
            editedStretch: [.squat: 170],
            original: Self.original,
            now: Self.fixedNow
        )
        #expect(payload.acknowledgeCalibrationReview == true)
    }

    @Test("With no edits, stretch_edits omits but the ack flag is still set")
    func ackTrueWithNoEdits() throws {
        let payload = CalibrationReviewView.makeCalibrationStretchPayload(
            userId: UUID(),
            goal: Self.goalBody,
            editedStretch: [.squat: 150, .horizontalPush: 107.5],
            original: Self.original,
            now: Self.fixedNow
        )
        #expect(payload.stretchEdits == nil)
        #expect(payload.acknowledgeCalibrationReview == true)

        // On the wire: no stretch_edits key, but acknowledge_calibration_review: true.
        let json = try encode(payload)
        #expect(json["stretch_edits"] == nil)
        #expect(json["acknowledge_calibration_review"] as? Bool == true)
    }

    // MARK: - Wire shape of a raised edit

    @Test("Raised edit encodes as snake_case {pattern, stretch} under stretch_edits")
    func raisedEditWireShape() throws {
        let payload = CalibrationReviewView.makeCalibrationStretchPayload(
            userId: UUID(),
            goal: Self.goalBody,
            editedStretch: [.squat: 160],
            original: Self.original,
            now: Self.fixedNow
        )
        let json = try encode(payload)
        let edits = try #require(json["stretch_edits"] as? [[String: Any]])
        #expect(edits.count == 1)
        #expect(edits.first?["pattern"] as? String == "squat")
        #expect(edits.first?["stretch"] as? Double == 160)
        #expect(json["acknowledge_calibration_review"] as? Bool == true)
    }
}
