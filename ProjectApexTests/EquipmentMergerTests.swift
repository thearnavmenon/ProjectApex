// EquipmentMergerTests.swift
// ProjectApexTests
//
// Unit tests for the revised EquipmentMerger (presence-only, no weight ranges).
//
// Acceptance criteria tested:
//   1. Empty input returns an empty array.
//   2. Single-frame input passes through unchanged.
//   3. Multi-frame deduplication: same type across frames → one output item.
//   4. Count aggregation: output count = max seen across all frames.
//   5. Cardio blocklist: cardio equipment types are filtered out entirely.
//   6. Junk blocklist: non-equipment strings are filtered out.
//   7. Unknown type with confidence < 0.7 is dropped.
//   8. Unknown type with confidence >= 0.7 is kept.
//   9. Alphabetical sort: output is sorted by typeKey.
//  10. Case-insensitive deduplication (type keys are normalised to lowercase).

import XCTest
@testable import ProjectApex

// MARK: - EquipmentMergerTests

final class EquipmentMergerTests: XCTestCase {

    // MARK: ─── Helper factories ───────────────────────────────────────────────

    private func item(
        type: String,
        count: Int = 1,
        confidence: Double? = nil
    ) -> VisionDetectedItem {
        VisionDetectedItem(equipmentType: type, count: count, confidence: confidence)
    }

    // MARK: ─── AC 1: Empty input ──────────────────────────────────────────────

    func test_emptyInput_returnsEmptyArray() {
        let result = EquipmentMerger.merge([])
        XCTAssertTrue(result.isEmpty, "Merging zero frames must return [].")
    }

    // MARK: ─── AC 2: Single frame passthrough ─────────────────────────────────

    func test_singleFrame_twoItems_bothPassThrough() {
        let frame = [
            item(type: "dumbbell_set", count: 1, confidence: 0.9),
            item(type: "barbell",      count: 2, confidence: 0.95)
        ]

        let result = EquipmentMerger.merge([frame])

        XCTAssertEqual(result.count, 2, "Two distinct types must produce two output items.")

        let dumbbell = result.first { $0.equipmentType == .dumbbellSet }
        let barbell  = result.first { $0.equipmentType == .barbell }

        XCTAssertNotNil(dumbbell, "dumbbell_set must be present.")
        XCTAssertNotNil(barbell,  "barbell must be present.")

        XCTAssertEqual(dumbbell?.count, 1)
        XCTAssertEqual(barbell?.count,  2)
    }

    // MARK: ─── AC 3: Multi-frame deduplication ────────────────────────────────

    func test_multiFrame_sameType_deduplicatesToOneItem() {
        let frames: [[VisionDetectedItem]] = Array(repeating: [item(type: "dumbbell_set", count: 1, confidence: 0.9)], count: 5)

        let result = EquipmentMerger.merge(frames)

        XCTAssertEqual(result.count, 1,
            "Five frames with the same type must collapse to exactly one output item.")
        XCTAssertEqual(result.first?.equipmentType, .dumbbellSet)
    }

    // MARK: ─── AC 4: Count aggregation (max across frames) ───────────────────

    func test_countAggregation_maxCountWins() {
        let frames: [[VisionDetectedItem]] = [
            [item(type: "adjustable_bench", count: 1)],
            [item(type: "adjustable_bench", count: 4)],
            [item(type: "adjustable_bench", count: 2)]
        ]

        let result = EquipmentMerger.merge(frames)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 4,
            "Count must be the maximum observed across all frames.")
    }

    // MARK: ─── AC 5: Cardio blocklist filtering ───────────────────────────────

    func test_cardioEquipment_isFilteredOut() {
        let cardioTypes = [
            "treadmill", "rowing_machine", "rower", "stationary_bike",
            "elliptical_machine", "elliptical", "assault_bike", "ski_erg",
            "stair_climber", "cycling_machine"
        ]
        for cardioType in cardioTypes {
            let frames = [[item(type: cardioType, count: 1, confidence: 0.99)]]
            let result = EquipmentMerger.merge(frames)
            XCTAssertTrue(result.isEmpty,
                "Cardio type '\(cardioType)' must be filtered out by the blocklist.")
        }
    }

    func test_cardioMixedWithStrength_onlyStrengthSurvives() {
        let frames: [[VisionDetectedItem]] = [[
            item(type: "treadmill",    count: 3, confidence: 0.95),
            item(type: "dumbbell_set", count: 2, confidence: 0.90),
            item(type: "rowing_machine", count: 1, confidence: 0.88)
        ]]

        let result = EquipmentMerger.merge(frames)

        XCTAssertEqual(result.count, 1, "Only strength equipment should survive.")
        XCTAssertEqual(result.first?.equipmentType, .dumbbellSet)
    }

    // MARK: ─── AC 6: Junk blocklist filtering ────────────────────────────────

    func test_junkStrings_areFilteredOut() {
        let junkTypes = ["mirror", "mat", "floor", "foam roller", "equipment stand"]
        for junkType in junkTypes {
            let frames = [[item(type: junkType, count: 1, confidence: 0.99)]]
            let result = EquipmentMerger.merge(frames)
            XCTAssertTrue(result.isEmpty,
                "Junk string '\(junkType)' must be filtered out by the blocklist.")
        }
    }

    // MARK: ─── AC 7 & 8: Unknown types are always dropped ───────────────────

    func test_unknownType_lowConfidence_isDropped() {
        let frames: [[VisionDetectedItem]] = [[
            item(type: "some_new_mystery_machine", count: 1, confidence: 0.65)
        ]]
        let result = EquipmentMerger.merge(frames)
        XCTAssertTrue(result.isEmpty,
            "Unknown types must always be dropped regardless of confidence.")
    }

    func test_unknownType_highConfidence_isAlsoDropped() {
        // Even high-confidence unknowns are dropped — they mean the model
        // ignored the fixed vocabulary and the detection is unreliable.
        let frames: [[VisionDetectedItem]] = [[
            item(type: "functional_trainer", count: 1, confidence: 0.95)
        ]]
        let result = EquipmentMerger.merge(frames)
        XCTAssertTrue(result.isEmpty,
            "Unknown types must be dropped even at high confidence.")
    }

    // MARK: ─── AC 9: Alphabetical sort ───────────────────────────────────────

    func test_outputSortedAlphabeticallyByTypeKey() {
        let frames: [[VisionDetectedItem]] = [[
            item(type: "pull_up_bar",      count: 1, confidence: 0.9),
            item(type: "dumbbell_set",     count: 1, confidence: 0.9),
            item(type: "adjustable_bench", count: 3, confidence: 0.9),
            item(type: "cable_machine_single", count: 2, confidence: 0.9)
        ]]

        let result = EquipmentMerger.merge(frames)
        let keys = result.map(\.equipmentType.typeKey)

        XCTAssertEqual(keys, keys.sorted(),
            "Output items must be sorted alphabetically by typeKey.")
    }

    // MARK: ─── AC 10: Case-insensitive normalisation ──────────────────────────

    func test_caseInsensitiveDeduplication() {
        // Two frames that differ only in casing should collapse into one item.
        let frames: [[VisionDetectedItem]] = [
            [item(type: "Dumbbell_Set", count: 1, confidence: 0.9)],
            [item(type: "dumbbell_set", count: 1, confidence: 0.9)]
        ]

        let result = EquipmentMerger.merge(frames)
        XCTAssertEqual(result.count, 1,
            "Type keys differing only in case must be treated as the same equipment.")
    }
}
