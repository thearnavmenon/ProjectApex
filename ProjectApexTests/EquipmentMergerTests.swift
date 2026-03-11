// EquipmentMergerTests.swift
// ProjectApexTests — P1-T03
//
// Unit tests for EquipmentMerger covering the acceptance criteria:
//   1. Empty input returns an empty array.
//   2. Single-frame input passes through unchanged (no spurious deduplication).
//   3. Multi-frame deduplication: same type across frames → one output item.
//   4. Count aggregation: output count = max seen across all frames.
//   5. WeightRange merging: min=min of mins, max=max of maxes, increment=mode.
//   6. Unknown type passthrough: raw description preserved.
//   7. Alphabetical sort: output is sorted by typeKey.
//   8. Increment mode resolution: tie-break picks smallest increment.
//   9. No-range frames (bodyweightOnly): when all frames omit weight range.
//  10. Mixed bodyweight + weight range: richer details win.

import XCTest
@testable import ProjectApex

// MARK: - EquipmentMergerTests

final class EquipmentMergerTests: XCTestCase {

    // MARK: ─── Helper factories ───────────────────────────────────────────────

    /// Builds a `VisionDetectedItem` with an increment-based weight range.
    private func item(
        type: String,
        count: Int = 1,
        minKg: Double? = nil,
        maxKg: Double? = nil,
        increment: Double? = nil
    ) -> VisionDetectedItem {
        let range: VisionDetectedItem.WeightRange? = (minKg != nil || maxKg != nil)
            ? VisionDetectedItem.WeightRange(min: minKg ?? 0, max: maxKg ?? 0, increment: increment)
            : nil
        return VisionDetectedItem(
            equipmentType: type,
            estimatedWeightRangeKg: range,
            count: count
        )
    }

    // MARK: ─── AC 1: Empty input ──────────────────────────────────────────────

    /// Empty detections array must return an empty list without crashing.
    func test_emptyInput_returnsEmptyArray() {
        let result = EquipmentMerger.merge([])
        XCTAssertTrue(result.isEmpty, "Merging zero frames must return [].")
    }

    // MARK: ─── AC 2: Single frame passthrough ─────────────────────────────────

    /// A single frame with two distinct equipment types must produce two items,
    /// one per type, with their details intact.
    func test_singleFrame_twoItems_bothPassThrough() {
        let frame = [
            item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 45.0, increment: 2.5),
            item(type: "barbell",      count: 2, minKg: 20.0, maxKg: 140.0, increment: nil)
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

    /// The same equipment type appearing in every frame must collapse into a
    /// single output item — not one item per frame.
    func test_multiFrame_sameType_deduplicatesToOneItem() {
        let frames: [[VisionDetectedItem]] = [
            [item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 30.0, increment: 2.5)],
            [item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 30.0, increment: 2.5)],
            [item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 30.0, increment: 2.5)],
            [item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 30.0, increment: 2.5)],
            [item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 30.0, increment: 2.5)]
        ]

        let result = EquipmentMerger.merge(frames)

        XCTAssertEqual(result.count, 1,
            "Five frames with the same type must collapse to exactly one output item.")
        XCTAssertEqual(result.first?.equipmentType, .dumbbellSet)
    }

    // MARK: ─── AC 4: Count aggregation (max across frames) ───────────────────

    /// When different frames report different counts for the same type,
    /// the merged item's count must be the maximum observed.
    func test_countAggregation_maxCountWins() {
        let frames: [[VisionDetectedItem]] = [
            [item(type: "adjustable_bench", count: 1, minKg: nil, maxKg: nil)],
            [item(type: "adjustable_bench", count: 4, minKg: nil, maxKg: nil)],
            [item(type: "adjustable_bench", count: 2, minKg: nil, maxKg: nil)]
        ]

        let result = EquipmentMerger.merge(frames)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 4,
            "Count must be the maximum observed across all frames.")
    }

    // MARK: ─── AC 5: WeightRange merging ─────────────────────────────────────

    /// WeightRange merging: min=min-of-mins, max=max-of-maxes, increment=mode.
    func test_weightRangeMerging_widestRangeAndModeIncrement() {
        // Frame 1: 5–30 kg, 5 kg steps
        // Frame 2: 2.5–40 kg, 2.5 kg steps
        // Frame 3: 5–35 kg, 5 kg steps
        //
        // Expected merged: min=2.5, max=40.0, increment=5.0 (mode: 5 appears 2×, 2.5 appears 1×)
        let frames: [[VisionDetectedItem]] = [
            [item(type: "dumbbell_set", count: 1, minKg: 5.0,  maxKg: 30.0, increment: 5.0)],
            [item(type: "dumbbell_set", count: 1, minKg: 2.5,  maxKg: 40.0, increment: 2.5)],
            [item(type: "dumbbell_set", count: 1, minKg: 5.0,  maxKg: 35.0, increment: 5.0)]
        ]

        let result = EquipmentMerger.merge(frames)
        XCTAssertEqual(result.count, 1)

        let merged = result[0]
        guard case .incrementBased(let minKg, let maxKg, let incKg) = merged.details else {
            return XCTFail("Expected incrementBased details, got \(merged.details).")
        }

        XCTAssertEqual(minKg,  2.5,  accuracy: 0.001, "min must be the smallest min observed.")
        XCTAssertEqual(maxKg,  40.0, accuracy: 0.001, "max must be the largest max observed.")
        XCTAssertEqual(incKg,  5.0,  accuracy: 0.001, "increment must be the mode (5.0 seen 2×).")
    }

    /// When all frames report the same increment, the output increment equals that value.
    func test_weightRangeMerging_singleIncrementValue_usedDirectly() {
        let frames: [[VisionDetectedItem]] = [
            [item(type: "cable_machine", count: 1, minKg: 2.5, maxKg: 90.0, increment: 2.5)],
            [item(type: "cable_machine", count: 1, minKg: 2.5, maxKg: 90.0, increment: 2.5)]
        ]

        let result = EquipmentMerger.merge(frames)
        guard case .incrementBased(_, _, let incKg) = result.first?.details else {
            return XCTFail("Expected incrementBased details.")
        }
        XCTAssertEqual(incKg, 2.5, accuracy: 0.001)
    }

    // MARK: ─── AC 6: Unknown type passthrough ────────────────────────────────

    /// Equipment types the API doesn't recognise are encoded as "unknown:<desc>".
    /// The merger must preserve the raw description and not discard these items.
    func test_unknownType_passesThroughWithRawDescription() {
        let frames: [[VisionDetectedItem]] = [
            [item(type: "unknown:functional trainer", count: 1, minKg: 5.0, maxKg: 100.0, increment: 5.0)],
            [item(type: "unknown:functional trainer", count: 2, minKg: 5.0, maxKg: 100.0, increment: 5.0)]
        ]

        let result = EquipmentMerger.merge(frames)

        XCTAssertEqual(result.count, 1,
            "Two frames with the same unknown type must merge to one item.")

        let mergedItem = result[0]
        guard case .unknown(let raw) = mergedItem.equipmentType else {
            return XCTFail("Expected .unknown(...), got \(mergedItem.equipmentType).")
        }
        XCTAssertEqual(raw, "functional trainer",
            "The raw description must be preserved exactly.")
        XCTAssertEqual(mergedItem.count, 2,
            "Count of unknown items must also use the max rule.")
    }

    /// Two different unknown types must produce two separate output items.
    func test_unknownTypes_differentDescriptions_produceSeparateItems() {
        let frames: [[VisionDetectedItem]] = [
            [
                item(type: "unknown:rower", count: 1),
                item(type: "unknown:assault bike", count: 1)
            ]
        ]

        let result = EquipmentMerger.merge(frames)
        XCTAssertEqual(result.count, 2,
            "Two distinct unknown descriptions must produce two output items.")
    }

    // MARK: ─── AC 7: Alphabetical sort ───────────────────────────────────────

    /// Output must be sorted by the canonical typeKey string alphabetically
    /// so the confirmation screen renders in a consistent, predictable order.
    func test_outputSortedAlphabeticallyByTypeKey() {
        let frames: [[VisionDetectedItem]] = [
            [
                item(type: "pull_up_bar",     count: 1),
                item(type: "dumbbell_set",    count: 1, minKg: 5, maxKg: 50, increment: 2.5),
                item(type: "adjustable_bench",count: 3),
                item(type: "cable_machine",   count: 2, minKg: 5, maxKg: 90, increment: 5)
            ]
        ]

        let result = EquipmentMerger.merge(frames)
        let keys = result.map(\.equipmentType.typeKey)

        // "adjustable_bench" < "cable_machine" < "dumbbell_set" < "pull_up_bar"
        XCTAssertEqual(keys, keys.sorted(),
            "Output items must be sorted alphabetically by typeKey.")
    }

    // MARK: ─── AC 8: Increment tie-break (smallest wins) ─────────────────────

    /// When two increment values are equally frequent, the smaller one wins
    /// (finest resolution is preferred).
    func test_incrementModeTieBreak_smallestWins() {
        // 2.5 appears 1×, 5.0 appears 1× → tie → smallest (2.5) wins.
        let frames: [[VisionDetectedItem]] = [
            [item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 50.0, increment: 2.5)],
            [item(type: "dumbbell_set", count: 1, minKg: 2.5, maxKg: 50.0, increment: 5.0)]
        ]

        let result = EquipmentMerger.merge(frames)
        guard case .incrementBased(_, _, let incKg) = result.first?.details else {
            return XCTFail("Expected incrementBased details.")
        }
        XCTAssertEqual(incKg, 2.5, accuracy: 0.001,
            "On a tie, the smallest (finest) increment must win.")
    }

    // MARK: ─── AC 9: All-bodyweight frames ───────────────────────────────────

    /// When no frame includes a weight range for an equipment type,
    /// the merged details must be `.bodyweightOnly`.
    func test_allFramesBodyweightOnly_producesBodyweightOnlyDetails() {
        let frames: [[VisionDetectedItem]] = [
            [item(type: "pull_up_bar", count: 1)],   // nil weight range
            [item(type: "pull_up_bar", count: 1)],
            [item(type: "pull_up_bar", count: 1)]
        ]

        let result = EquipmentMerger.merge(frames)
        XCTAssertEqual(result.count, 1)

        guard case .bodyweightOnly = result[0].details else {
            XCTFail("When no frame has a weight range, details must be .bodyweightOnly.")
            return
        }
    }

    // MARK: ─── AC 10: Mixed bodyweight + weight-range frames ─────────────────

    /// If some frames have bodyweightOnly (nil range) and others carry an actual
    /// weight range, the richer incrementBased details must win.
    func test_mixedBodyweightAndWeightRange_richerDetailsWin() {
        let frames: [[VisionDetectedItem]] = [
            [item(type: "dumbbell_set", count: 1)],                               // no range
            [item(type: "dumbbell_set", count: 1, minKg: 5.0, maxKg: 45.0, increment: 5.0)], // has range
            [item(type: "dumbbell_set", count: 1)]                                // no range
        ]

        let result = EquipmentMerger.merge(frames)
        XCTAssertEqual(result.count, 1)

        guard case .incrementBased(let minKg, let maxKg, _) = result[0].details else {
            XCTFail("Richer incrementBased details must win over bodyweightOnly.")
            return
        }
        XCTAssertEqual(minKg, 5.0,  accuracy: 0.001)
        XCTAssertEqual(maxKg, 45.0, accuracy: 0.001)
    }
}
