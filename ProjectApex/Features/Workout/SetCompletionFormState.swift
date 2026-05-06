// SetCompletionFormState.swift
// ProjectApex — Features/Workout
//
// Unit-testable state model for the rep / RPE / intent confirmation sheet
// shown when the user taps "Set Complete" (Slice 6, issue #10).
//
// The shape exists to make the AC "Save is disabled until the user has
// explicitly interacted with the picker, even if the initial selection
// matches their intent" observable from XCTest. ActiveSetView consumes
// this struct via `@State`; tests construct it directly and drive
// transitions through `recordIntentTap(_:)`.
//
// Visual distinction between an AI-prefilled-pending-confirmation chip and
// a user-explicitly-tapped chip is HITL territory and lives in the SwiftUI
// view; this struct only carries the boolean separation that distinguishes
// the two states.
//
// LIFECYCLE ASSUMPTION (load-bearing):
//   The form is constructed once when the rep/RPE sheet appears (user taps
//   "Set Complete") and discarded when the sheet dismisses on commit. While
//   the sheet is on-screen, `prescribedIntent` does NOT change — every path
//   that mutates `WorkoutViewModel.currentPrescription` (AI re-prescribe,
//   weight correction, weight override, manual fallback) operates on the
//   underlying ActiveSetView card BEFORE Set Complete is tapped, not while
//   the rep/RPE sheet is presented modally.
//
//   If a future flow introduces a path where `prescribedIntent` can change
//   while the form is open, that path MUST reset `intentTouched` to false on
//   meaningful prefill change — otherwise the AC silently breaks (the user
//   would see a NEW AI suggestion already "confirmed" without explicit tap,
//   defeating the no-silent-default rule). The reset hook would live as a
//   new mutating method like `noteRePrefill(_ next: SetIntent?)` that wipes
//   `intentTouched`. Add a unit test alongside it that asserts
//   `canSubmit == false` after re-prefill.

import Foundation

struct SetCompletionFormState: Equatable {

    // MARK: - User-entered fields

    /// Reps the user actually completed. Pre-filled from the prescription at
    /// init; mutated by the +/- stepper.
    var actualReps: Int

    /// 0 = too easy, 1 = on target, 2 = too hard. Mapped to RPE 5/7/9 at
    /// commit time (matches the existing ActiveSetView mapping).
    var rpeFelt: Int

    /// The selected SetIntent. Pre-filled from `prescription.intent` for AI-
    /// prescribed sets so the picker can highlight the AI's suggestion;
    /// `nil` for freestyle sets where there is no AI pre-fill.
    var intent: SetIntent?

    /// Whether the user has explicitly tapped a chip in this session of the
    /// sheet. The "even if initial selection matches their intent" rule from
    /// issue #10 forces this to be a separate signal from `intent != nil`.
    /// Once true, never resets within the sheet's lifetime — re-tapping
    /// keeps it true.
    private(set) var intentTouched: Bool

    // MARK: - Derived

    /// Whether "Log Set" should enable. Both conditions are required:
    ///   1. An intent is selected (`intent != nil`).
    ///   2. The user has explicitly interacted with the picker
    ///      (`intentTouched == true`).
    /// The second condition is the load-bearing rule for Slice 6.
    var canSubmit: Bool {
        intent != nil && intentTouched
    }

    /// True when an AI prefill is sitting un-confirmed. Used by the view to
    /// render the prefilled chip in a visually distinct "AI suggested,
    /// awaiting confirmation" state vs. a confirmed selection.
    var hasUnconfirmedAIPrefill: Bool {
        intent != nil && !intentTouched
    }

    // MARK: - Init

    /// Construct fresh state for a new sheet appearance.
    /// - Parameter prescribedIntent: when non-nil, the AI's suggested intent
    ///   pre-fills the picker selection. `intentTouched` stays `false` until
    ///   the user explicitly taps.
    init(actualReps: Int, rpeFelt: Int = 1, prescribedIntent: SetIntent? = nil) {
        self.actualReps    = actualReps
        self.rpeFelt       = rpeFelt
        self.intent        = prescribedIntent
        self.intentTouched = false
    }

    // MARK: - Mutators

    /// Record an explicit picker tap. Sets `intent` and flips
    /// `intentTouched` to true. Subsequent taps keep `intentTouched` true
    /// even if the user changes selection.
    mutating func recordIntentTap(_ next: SetIntent) {
        self.intent        = next
        self.intentTouched = true
    }
}
