// ManualLogIntentGateTests.swift
// ProjectApexTests — Slice 6 (#10)
//
// Unit tests for the manual-session-log Save-button gate.
// AC from issue #10:
//   "Save button on freestyle completion is disabled until the user has
//    explicitly interacted with the intent picker."
//
// In ManualSessionLogView this is per-set: every non-empty entry
// (weight > 0 OR reps > 0) must have `intentTouched == true`. Empty
// entries (no weight, no reps) are skipped — they don't gate and don't
// contribute at submit time.
//
// The gating logic lives in `manualLogCanSubmit(entries:)` — pulled to
// file scope so it's testable without a SwiftUI / @State harness.

import XCTest
@testable import ProjectApex

final class ManualLogIntentGateTests: XCTestCase {

    // MARK: - Test factories

    private func entry(
        sets: [(weightString: String, reps: Int, intent: SetIntent?, touched: Bool)]
    ) -> ManualExerciseEntry {
        let exercise = PlannedExercise(
            id: UUID(),
            exerciseId: "test_exercise",
            name: "Test",
            primaryMuscle: "pectoralis_major",
            synergists: [],
            equipmentRequired: .barbell,
            sets: max(1, sets.count),
            repRange: RepRange(min: 5, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 120,
            rirTarget: 2,
            coachingCues: []
        )
        var built = ManualExerciseEntry(exercise: exercise)
        // Override the auto-generated empty sets with the test fixture.
        built.sets = sets.map { tuple in
            var e = ManualSetEntry()
            e.weightString  = tuple.weightString
            e.reps          = tuple.reps
            e.intent        = tuple.intent
            e.intentTouched = tuple.touched
            return e
        }
        return built
    }

    // MARK: - Empty entries don't gate

    func test_noEntries_canSubmit() {
        XCTAssertTrue(manualLogCanSubmit(entries: []),
                      "Empty entry list (degenerate) does not gate submission.")
    }

    func test_allEmptySets_canSubmit() {
        let e = entry(sets: [
            ("",   0, nil, false),
            ("",   0, nil, false),
        ])
        XCTAssertTrue(manualLogCanSubmit(entries: [e]),
                      "Entries with all-empty sets do not gate.")
    }

    // MARK: - Non-empty without touched intent → gated

    func test_nonEmptySet_withoutTouchedIntent_blocksSubmit() {
        let e = entry(sets: [
            ("80", 10, nil, false),
        ])
        XCTAssertFalse(manualLogCanSubmit(entries: [e]),
                       "Non-empty set without touched intent must block save.")
    }

    func test_nonEmptySet_withIntentButNotTouched_blocksSubmit() {
        // The "even if initial selection matches their intent" rule —
        // having `intent` set without an explicit tap doesn't pass the gate.
        let e = entry(sets: [
            ("80", 10, .top, false),
        ])
        XCTAssertFalse(manualLogCanSubmit(entries: [e]),
                       "Intent assigned but not touched still blocks save.")
    }

    // MARK: - Non-empty with touched intent → submittable

    func test_nonEmptySet_withTouchedIntent_canSubmit() {
        let e = entry(sets: [
            ("80", 10, .top, true),
        ])
        XCTAssertTrue(manualLogCanSubmit(entries: [e]))
    }

    func test_weightOnlyNoReps_isNonEmpty_andGates() {
        // weight > 0 alone counts as content — the user has typed
        // something. They must pick an intent before saving.
        let e = entry(sets: [
            ("80", 0, nil, false),
        ])
        XCTAssertFalse(manualLogCanSubmit(entries: [e]))
    }

    func test_repsOnlyNoWeight_isNonEmpty_andGates() {
        // Bodyweight exercises log reps with weight = 0. They must still
        // pick an intent — no silent default.
        let e = entry(sets: [
            ("0", 8, nil, false),
        ])
        XCTAssertFalse(manualLogCanSubmit(entries: [e]))
    }

    // MARK: - Mixed empty + non-empty

    func test_mixedSets_emptyDoesntGate_butNonEmptyDoes() {
        let e = entry(sets: [
            ("80", 10, .top, true),       // touched OK
            ("",    0, nil,  false),      // empty — skipped
            ("70",  8, nil,  false),      // non-empty, NOT touched → gates
        ])
        XCTAssertFalse(manualLogCanSubmit(entries: [e]),
                       "One ungated non-empty set blocks the whole submission.")
    }

    func test_mixedSets_allNonEmptyTouched_canSubmit() {
        let e = entry(sets: [
            ("80", 10, .top,     true),
            ("",    0, nil,      false),  // empty — skipped, no gate
            ("70",  8, .backoff, true),
        ])
        XCTAssertTrue(manualLogCanSubmit(entries: [e]))
    }

    // MARK: - Cross-exercise gate (any one entry blocks all)

    func test_crossExercise_oneUntouched_blocksSubmit() {
        let ok = entry(sets: [("80", 10, .top, true)])
        let bad = entry(sets: [("60", 8, nil, false)])
        XCTAssertFalse(manualLogCanSubmit(entries: [ok, bad]),
                       "An untouched non-empty set in any entry blocks save.")
    }
}
