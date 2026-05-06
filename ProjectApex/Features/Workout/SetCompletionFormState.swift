// SetCompletionFormState.swift
// ProjectApex — Features/Workout
//
// Unit-testable state model for the rep / RPE / intent confirmation sheet
// shown when the user taps "Set Complete" (Slice 6, issue #10).
//
// REDESIGN NOTE (supersedes the prior intentTouched-based shape):
//   The prior model was wrong — it asked the user to confirm an intent
//   the AI had already explicitly told them via the prescription. That's
//   redundant data entry, not no-silent-defaults enforcement.
//
//   The correct model is: the AI's prescription IS the explicit intent.
//   The picker captures DEVIATION (when the user actually did something
//   different), not confirmation. AI-prescribed sets default to the
//   prescribed intent — zero friction, Save Set always enabled.
//   Freestyle sets (no AI prescription) still require an explicit pick
//   before Save Set enables (the picker is the only source of intent
//   in that case).
//
// LIFECYCLE ASSUMPTION (load-bearing, unchanged from prior version):
//   The form is constructed once when the rep/RPE sheet appears (user
//   taps "Set Complete") and discarded when the sheet dismisses on
//   commit. While the sheet is on-screen, `prescribedIntent` does NOT
//   change. If a future flow introduces a path where it can change,
//   that path must reset `resolvedIntent` to the new prescribed value
//   (collapsing any deviation the user already expressed) — otherwise
//   the user's deviation gets silently re-attached to a different
//   prescription, which is meaningless data.

import Foundation

struct SetCompletionFormState: Equatable {

    // MARK: - User-entered fields

    /// Reps the user actually completed. Pre-filled from the prescription
    /// at init; mutated by the +/- stepper.
    var actualReps: Int

    /// 0 = too easy, 1 = on target, 2 = too hard. Mapped to RPE 5/7/9 at
    /// commit time (matches the existing ActiveSetView mapping).
    var rpeFelt: Int

    // MARK: - Intent (Slice 6 redesign)

    /// What the AI prescribed, captured immutably at construction.
    /// Nil for freestyle sets (no AI prescription).
    let prescribedIntent: SetIntent?

    /// What ends up persisted to SetLog. Defaults to `prescribedIntent`
    /// for AI-prescribed sets; nil for freestyle until the user picks.
    var resolvedIntent: SetIntent?

    /// True when the deviation chip-row is currently visible.
    /// AI-prescribed: false by default; flips true when the user taps
    /// "Did something different?". Cannot revert to false (no need to
    /// re-hide; user just picks the prescribed value if they change their
    /// mind).
    /// Freestyle: true by default — picker is the only path to an intent.
    var isDeviationPickerVisible: Bool

    /// User-reported flags raised on the rep/RPE sheet immediately
    /// post-set. Multi-select; default empty. Slice 6 / #10.
    var completionFlags: Set<SetCompletionFlag>

    // MARK: - Derived

    /// True when the user explicitly picked an intent that differs from
    /// the prescribed value. Drives the `is_deviation` analytics signal
    /// surfaced in `WorkoutContext` for in-session AI reasoning.
    /// Always false for freestyle (no prescription to deviate from).
    var isDeviation: Bool {
        guard let prescribed = prescribedIntent,
              let resolved = resolvedIntent else { return false }
        return prescribed != resolved
    }

    /// Whether "Log Set" should enable.
    ///   AI-prescribed: always submittable (resolvedIntent always set
    ///                  to prescribedIntent on init; the user can change
    ///                  it but cannot make it nil).
    ///   Freestyle:     requires resolvedIntent != nil — i.e., the user
    ///                  has made an explicit pick.
    var canSubmit: Bool {
        resolvedIntent != nil
    }

    // MARK: - Init

    /// Construct fresh state for a new sheet appearance.
    ///   - prescribedIntent: AI's intent for this set, or nil for freestyle.
    ///     Sets `resolvedIntent` to the same value (zero-friction default
    ///     for AI-prescribed) and seeds `isDeviationPickerVisible` based
    ///     on whether the picker is the only path (freestyle: yes;
    ///     AI-prescribed: hidden behind the "Did something different?"
    ///     affordance).
    init(actualReps: Int, rpeFelt: Int = 1, prescribedIntent: SetIntent?) {
        self.actualReps = actualReps
        self.rpeFelt = rpeFelt
        self.prescribedIntent = prescribedIntent
        self.resolvedIntent = prescribedIntent
        self.isDeviationPickerVisible = (prescribedIntent == nil)
        self.completionFlags = []
    }

    // MARK: - Mutators

    /// User tapped "Did something different?" on an AI-prescribed set.
    /// Reveals the chip row. The prescribed intent is already selected
    /// (resolvedIntent == prescribedIntent at this point) — the chip
    /// row gives the user a way to change it. Idempotent: calling on
    /// an already-visible picker is a no-op.
    mutating func revealDeviationPicker() {
        isDeviationPickerVisible = true
    }

    /// User picked an intent from the chip row. Updates resolvedIntent.
    /// For AI-prescribed sets where this matches `prescribedIntent`,
    /// `isDeviation` stays false (re-affirming the prescription is not
    /// deviation). For freestyle, this is the ONLY path to a non-nil
    /// resolvedIntent.
    mutating func selectIntent(_ next: SetIntent) {
        self.resolvedIntent = next
    }

    /// Toggle a completion flag on or off. Multi-select — pain and
    /// formBreakdown can both be raised.
    mutating func toggleFlag(_ flag: SetCompletionFlag) {
        if completionFlags.contains(flag) {
            completionFlags.remove(flag)
        } else {
            completionFlags.insert(flag)
        }
    }
}
