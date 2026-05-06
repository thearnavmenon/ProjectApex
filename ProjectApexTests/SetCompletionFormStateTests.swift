// SetCompletionFormStateTests.swift
// ProjectApexTests — Slice 6 (#10)
//
// Unit tests for the rep / RPE / intent confirmation sheet's state model.
// Encodes the AC from issue #10:
//   "Save button on freestyle completion is disabled until the user
//    explicitly interacts with the intent picker (UI test asserts this)"
// Since the project has no UITests target, the rule is enforced via
// SetCompletionFormState — `canSubmit` is false until `recordIntentTap`
// has been called at least once, even when an AI prefill provides
// `intent != nil`.

import XCTest
@testable import ProjectApex

final class SetCompletionFormStateTests: XCTestCase {

    // MARK: - C1: default state cannot submit

    func test_freshState_noPrefill_cannotSubmit() {
        let state = SetCompletionFormState(actualReps: 8)
        XCTAssertNil(state.intent)
        XCTAssertFalse(state.canSubmit, "Save must be disabled before any tap.")
        XCTAssertFalse(state.hasUnconfirmedAIPrefill,
                       "No prefill means no unconfirmed prefill.")
    }

    // MARK: - C2: AI-prefilled state still requires explicit interaction

    func test_aiPrefilledState_stillRequiresTouch() {
        // The "even if the initial selection matches their intent" rule —
        // a prefilled SetIntent must not auto-enable Save.
        let state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        XCTAssertEqual(state.intent, .top,
                       "Prefill should populate the picker selection.")
        XCTAssertFalse(state.canSubmit,
                       "Prefilled selection must NOT enable Save before touch.")
        XCTAssertTrue(state.hasUnconfirmedAIPrefill,
                      "Prefill present but un-tapped — render distinct visual.")
    }

    // MARK: - C3: explicit tap promotes to submittable

    func test_recordTap_enablesSubmit() {
        var state = SetCompletionFormState(actualReps: 8)
        state.recordIntentTap(.top)
        XCTAssertEqual(state.intent, .top)
        XCTAssertTrue(state.canSubmit,
                      "Tap on a chip must enable Save.")
        XCTAssertFalse(state.hasUnconfirmedAIPrefill,
                       "After tap, the prefill is confirmed.")
    }

    // MARK: - C4: changing selection after first tap stays submittable

    func test_changeSelectionAfterFirstTap_remainsSubmittable() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.recordIntentTap(.top)
        XCTAssertTrue(state.canSubmit)

        state.recordIntentTap(.backoff)
        XCTAssertEqual(state.intent, .backoff,
                       "Re-tap should change the selection.")
        XCTAssertTrue(state.canSubmit,
                      "Re-tapping a different chip stays submittable.")
    }

    // MARK: - C5 (variant): tapping the same prefilled chip confirms

    func test_tapMatchingPrefilledChip_confirms() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        XCTAssertFalse(state.canSubmit)
        state.recordIntentTap(.top)   // tap the already-prefilled selection
        XCTAssertTrue(state.canSubmit,
                      "Confirming the prefill via tap must enable Save.")
    }

    // MARK: - All five SetIntent cases route through cleanly

    func test_recordTap_eachSetIntentCase() {
        for intent in SetIntent.allCases {
            var state = SetCompletionFormState(actualReps: 5)
            state.recordIntentTap(intent)
            XCTAssertEqual(state.intent, intent)
            XCTAssertTrue(state.canSubmit, "Should submit for \(intent)")
        }
    }

    // MARK: - Other picker fields don't toggle the gate

    func test_repsAndRpeChanges_doNotEnableSubmit_withoutTap() {
        var state = SetCompletionFormState(actualReps: 8)
        state.actualReps = 10
        state.rpeFelt    = 2
        XCTAssertFalse(state.canSubmit,
                       "Reps/RPE changes must not bypass the intent gate.")
    }
}
