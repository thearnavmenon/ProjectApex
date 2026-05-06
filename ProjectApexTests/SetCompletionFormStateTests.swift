// SetCompletionFormStateTests.swift
// ProjectApexTests — Slice 6 (#10)
//
// Unit tests for the redesigned rep/RPE/intent/flag state struct.
//
// REDESIGN NOTE (supersedes the prior intentTouched-based test set):
//   The prior tests asserted that AI-prescribed sets required an explicit
//   chip tap before Save enabled — the wrong model. The correct model is:
//     - AI-prescribed: zero friction. resolvedIntent defaults to
//       prescribedIntent. canSubmit immediately true.
//     - Freestyle: requires explicit pick. canSubmit false until selectIntent.
//   Deviation is captured separately via `isDeviation` (true when
//   resolvedIntent differs from prescribedIntent).
//   Pain / form_breakdown flags are independent multi-select toggles.

import XCTest
@testable import ProjectApex

final class SetCompletionFormStateTests: XCTestCase {

    // MARK: - AI-prescribed default path (zero friction)

    /// The most important assertion in the file: AI-prescribed sets
    /// can submit immediately with no picker friction.
    func test_aiPrescribed_resolvesToPrescribedIntent_canSubmitImmediately() {
        let state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        XCTAssertEqual(state.prescribedIntent, .top)
        XCTAssertEqual(state.resolvedIntent, .top,
                       "Default resolvedIntent should mirror the prescription.")
        XCTAssertTrue(state.canSubmit,
                      "AI-prescribed sets must be submittable without picker interaction.")
        XCTAssertFalse(state.isDeviation,
                       "Default state is not a deviation.")
        XCTAssertFalse(state.isDeviationPickerVisible,
                       "Picker is collapsed by default for AI-prescribed sets.")
    }

    func test_aiPrescribed_revealDeviationPicker_doesNotChangeIntent() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.revealDeviationPicker()
        XCTAssertTrue(state.isDeviationPickerVisible,
                      "revealDeviationPicker flips the visibility.")
        XCTAssertEqual(state.resolvedIntent, .top,
                       "Revealing the picker does not change the resolved intent.")
        XCTAssertFalse(state.isDeviation,
                       "Revealing the picker is not by itself a deviation.")
        XCTAssertTrue(state.canSubmit,
                      "Revealing the picker keeps the gate open.")
    }

    func test_aiPrescribed_recordDeviation_resolvedIntentChanges_isDeviationTrue() {
        var state = SetCompletionFormState(actualReps: 12, prescribedIntent: .top)
        state.revealDeviationPicker()
        state.selectIntent(.amrap)
        XCTAssertEqual(state.resolvedIntent, .amrap,
                       "selectIntent updates the resolved value.")
        XCTAssertTrue(state.isDeviation,
                      "User picked amrap when prescribed top — deviation true.")
        XCTAssertTrue(state.canSubmit,
                      "Deviation is still submittable.")
    }

    func test_aiPrescribed_pickSamePrescribed_isDeviationFalse() {
        // Reaffirming the prescription is NOT a deviation. The user just
        // tapped the same chip; nothing actually differs.
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.revealDeviationPicker()
        state.selectIntent(.top)
        XCTAssertFalse(state.isDeviation,
                       "Picking the same intent the AI prescribed is not a deviation.")
    }

    func test_aiPrescribed_pickThenChangeMind_lastSelectionWins() {
        var state = SetCompletionFormState(actualReps: 10, prescribedIntent: .top)
        state.revealDeviationPicker()
        state.selectIntent(.amrap)
        state.selectIntent(.backoff)
        XCTAssertEqual(state.resolvedIntent, .backoff,
                       "Last selection wins; previous deviation is overwritten.")
        XCTAssertTrue(state.isDeviation,
                      "backoff still differs from prescribed top.")
    }

    // MARK: - Dismiss deviation picker (forgiving over strict)

    /// Reveal then dismiss without picking → state matches the
    /// post-init shape. The user changed their mind about deviating;
    /// the deviation affordance must be reversible.
    func test_aiPrescribed_revealThenDismiss_withoutPick_resetsToInitial() {
        let initial = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        var state = initial
        state.revealDeviationPicker()
        XCTAssertTrue(state.isDeviationPickerVisible)
        state.dismissDeviationPicker()
        XCTAssertFalse(state.isDeviationPickerVisible,
                       "Dismiss collapses the picker.")
        XCTAssertEqual(state.resolvedIntent, .top,
                       "Dismiss resets resolvedIntent to the prescription.")
        XCTAssertFalse(state.isDeviation)
        XCTAssertEqual(state, initial,
                       "After reveal+dismiss-without-pick, state matches the init shape.")
    }

    /// Reveal, pick a deviation, dismiss → resolvedIntent resets to
    /// prescribed; isDeviation goes back to false. Forgiving rule: a
    /// tentative deviation pick that the user backs out of must not
    /// persist on the SetLog.
    func test_aiPrescribed_revealPickDeviation_dismiss_resetsResolvedIntent() {
        var state = SetCompletionFormState(actualReps: 10, prescribedIntent: .top)
        state.revealDeviationPicker()
        state.selectIntent(.amrap)
        XCTAssertEqual(state.resolvedIntent, .amrap)
        XCTAssertTrue(state.isDeviation)

        state.dismissDeviationPicker()
        XCTAssertFalse(state.isDeviationPickerVisible)
        XCTAssertEqual(state.resolvedIntent, .top,
                       "Dismiss after deviation must reset to prescribed.")
        XCTAssertFalse(state.isDeviation,
                       "After dismiss, the set is no longer a deviation.")
    }

    /// Reveal → dismiss → reveal again. Each cycle starts from the
    /// prescribed-intent baseline. Cycling the picker doesn't accumulate
    /// stale state.
    func test_aiPrescribed_revealDismissReveal_picksUpFreshFromPrescribed() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.revealDeviationPicker()
        state.selectIntent(.warmup)            // tentative deviation
        state.dismissDeviationPicker()         // discard it
        state.revealDeviationPicker()          // open again

        XCTAssertTrue(state.isDeviationPickerVisible)
        XCTAssertEqual(state.resolvedIntent, .top,
                       "After dismiss, the next reveal starts from prescribed, not from the discarded warmup.")
        XCTAssertFalse(state.isDeviation,
                       "Re-revealing the picker doesn't restore the discarded deviation.")
    }

    /// Freestyle has no prescribed intent to fall back to — dismiss
    /// must be a no-op (otherwise resolvedIntent could be wiped to nil
    /// after the user picked, stranding them in a non-submittable form).
    /// The UI also hides the dismiss affordance for freestyle, but the
    /// state struct guard is defence in depth.
    func test_freestyle_dismissDeviationPicker_isNoop() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: nil)
        state.selectIntent(.warmup)
        state.dismissDeviationPicker()
        XCTAssertTrue(state.isDeviationPickerVisible,
                      "Freestyle picker stays visible — no dismiss path.")
        XCTAssertEqual(state.resolvedIntent, .warmup,
                       "Freestyle resolvedIntent is preserved on dismiss.")
        XCTAssertTrue(state.canSubmit)
    }

    // MARK: - Freestyle path (no prescription)

    func test_freestyle_pickerVisibleByDefault() {
        let state = SetCompletionFormState(actualReps: 8, prescribedIntent: nil)
        XCTAssertNil(state.prescribedIntent)
        XCTAssertNil(state.resolvedIntent,
                     "Freestyle starts with no resolved intent.")
        XCTAssertTrue(state.isDeviationPickerVisible,
                      "Freestyle shows the picker by default — only path to an intent.")
        XCTAssertFalse(state.canSubmit,
                       "Freestyle blocks submission until an intent is picked.")
        XCTAssertFalse(state.isDeviation,
                       "Freestyle is never a deviation (nothing to deviate from).")
    }

    func test_freestyle_pickIntent_canSubmit() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: nil)
        state.selectIntent(.warmup)
        XCTAssertEqual(state.resolvedIntent, .warmup)
        XCTAssertTrue(state.canSubmit)
        XCTAssertFalse(state.isDeviation,
                       "Freestyle never has isDeviation=true regardless of selection.")
    }

    // MARK: - Completion flags

    func test_completionFlags_emptyByDefault() {
        let state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        XCTAssertTrue(state.completionFlags.isEmpty)
    }

    func test_completionFlags_toggleAddsAndRemoves() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.toggleFlag(.pain)
        XCTAssertTrue(state.completionFlags.contains(.pain))
        state.toggleFlag(.pain)
        XCTAssertFalse(state.completionFlags.contains(.pain),
                       "Toggle is symmetric — second tap removes.")
    }

    func test_completionFlags_multipleAllowedSimultaneously() {
        // Pain AND form_breakdown can be raised on the same set.
        var state = SetCompletionFormState(actualReps: 6, prescribedIntent: .top)
        state.toggleFlag(.pain)
        state.toggleFlag(.formBreakdown)
        XCTAssertTrue(state.completionFlags.contains(.pain))
        XCTAssertTrue(state.completionFlags.contains(.formBreakdown))
        XCTAssertEqual(state.completionFlags.count, 2)
    }

    func test_completionFlags_persistAcrossOtherStateChanges() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.toggleFlag(.pain)
        // Other state changes must not clobber flags.
        state.actualReps = 10
        state.rpeFelt = 2
        state.revealDeviationPicker()
        state.selectIntent(.backoff)
        XCTAssertTrue(state.completionFlags.contains(.pain),
                      "Flags persist across reps/RPE/picker changes.")
    }

    // MARK: - Sanity: gate-and-fields don't entangle

    func test_repsAndRpeChanges_doNotChangeIntent() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.actualReps = 10
        state.rpeFelt = 2
        XCTAssertEqual(state.resolvedIntent, .top,
                       "Reps/RPE mutations don't touch the intent value.")
    }

    func test_repsAndRpeChanges_canSubmitUnaffected_aiPrescribed() {
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: .top)
        state.actualReps = 10
        XCTAssertTrue(state.canSubmit)
    }

    func test_repsAndRpeChanges_canSubmitUnaffected_freestyle() {
        // Freestyle gate is intent-only; reps/RPE changes don't open it.
        var state = SetCompletionFormState(actualReps: 8, prescribedIntent: nil)
        state.actualReps = 10
        state.rpeFelt = 2
        XCTAssertFalse(state.canSubmit,
                       "Freestyle without a picked intent stays blocked.")
    }
}
