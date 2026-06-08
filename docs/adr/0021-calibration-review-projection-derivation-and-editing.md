# Calibration-review projection derivation + athlete editing

**Status**: accepted, 2026-06-09

**Relates to**: [ADR-0005](0005-persistent-structured-trainee-model.md) (§"goal" / §"projections" — floor+stretch at calibration review) and [ADR-0020](0020-per-axis-confidence-lifecycle.md) (the confidence lifecycle whose pattern-`.established` transitions fire the review). This ADR *implements* the projection layer ADR-0005 designed and left deferred, and consumes ADR-0020's now-real pattern confidence. It does not supersede ADR-0005; it fills in the "set at calibration review" mechanics and adds the athlete-editing path.

## Context

ADR-0005 defined `ProjectionState`/`PatternProjection` (per-pattern `floor` + `stretch` capability targets, set at "calibration review") but the derivation was never built — `patternProjections` stayed `[]` and `isReadyForCalibrationReview` was inert. #166/ADR-0020 then made pattern confidence actually reach `.established`, so the review can fire. #269 builds the projection layer end-to-end: derive → surface → edit. (Issue #269 umbrella; slices #294–#298.)

A grilling-time discovery shaped the formulas: `ExerciseProfile.e1rmMedian`/`e1rmPeak` are **dead fields** (bootstrapped to 0, never written). The only live per-pattern capability signal is `patternE1RMSessions` (Epley e1RM per session, heaviest top set) plus the pattern's cadence and `trend`.

## Decision

### Derivation (server, `update-trainee-model` pipeline tail)

Runs after the per-pattern pipeline (reads finalized confidence). Once ≥4 of 6 major patterns are `.established`:
- **Per-pattern lazy derive**: each established **major** pattern lacking a projection gets one; floors are never re-derived; late-maturing majors are picked up when they establish. Only the 6 major patterns (lunge/isolation excluded in v1).
- **`calibrationReviewFiredAt`** is set once (the review-fired event; drives the one-time banner).
- **`progress`** is recomputed for every existing projection each apply.
- Uses ONLY live inputs (`patternE1RMSessions`, cadence, trend).

Formulas (per pattern, kg):
- **floor** = `round-down-2.5kg(median(last windowSize(cadence)=3–4 per-session Epley e1RMs))` — recent demonstrated capability, immovable; round-down keeps it from overstating.
- **stretch** = `round-up-2.5kg(floor × (1 + margin(trend)))`, margin = progressing 7.5% / plateaued 4% / declining 2.5%; enforce `stretch ≥ floor + 2.5`. User-adjustable upward only.
- **progress** ∈ {behind, on_track, ahead, achieved}: with `current` = the same recent-window median, `behind` iff `current < floor`, `achieved` iff `current ≥ stretch`, else `on_track`/`ahead` split at the floor→stretch midpoint.

This derivation is **advance/derive-only** — it never writes goal/renegotiation state.

### Surface (iOS)

A one-time calibration-review banner (`deriveCalibrationReviewSignal`, gated on `calibrationReviewFiredAt != nil` + non-empty projections + not-acknowledged) → a dedicated read-only-then-editable `CalibrationReviewView`. Distinct from the repeating heavy-reassessment banner/`GoalReviewView` (one-time + numeric vs repeating + goal-text); calibration banner takes precedence when both are derivable.

### Editing + ack (iOS + EF)

The athlete raises stretch targets (upward only; floor immovable). `update-trainee-goal` gains optional `stretch_edits` (server clamps `max(stored, edited)` in a `FOR UPDATE` transaction, race-safe vs session-apply; writes only the `projections.patternProjections` leaf; never accepts a client floor) and `acknowledge_calibration_review` (durably sets `model_json.calibrationReviewAcknowledged = true` so the banner doesn't reappear after a session sync). The client mirrors the clamp locally + acks locally for an immediate banner-hide (the EF returns `{ok, goal}`, not the model). Progress after an edit is refreshed by the next session-apply's recompute arm.

### Out of scope (deferred)

- Goal-renegotiation stretch re-derivation (`goalLastRenegotiatedAt`) — needs a renegotiation trigger that doesn't exist yet.
- Lunge/isolation projections — future "majors ∪ focus-area patterns".
- Peak-anchored stretch — blocked on wiring the dead `e1rmMedian`/`e1rmPeak` first.

## Consequences

- Asymmetric-error throughout: floor never overstates (round-down median); edits clamp rather than reject; the immovable floor can't be lowered or faked.
- No SQL migration (projections is an existing JSONB field); the only schema-ish addition is the EF-written `calibrationReviewAcknowledged` boolean (tolerant-decoded on the client).
- Built as 5 slices: #294 EF derivation, #295 iOS read-only display + banner, #296 EF stretch-edit write-path, #297 iOS editing + durable ack, #298 docs/ADR.
- Tuning deferred: the stretch margins + the progress midpoint are conservative-by-design for the alpha cohort.
