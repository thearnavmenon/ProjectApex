# Goal-renegotiation stretch re-derivation

**Status**: accepted, 2026-06-09

**Relates to**: [ADR-0021](0021-calibration-review-projection-derivation-and-editing.md) (§"Out of scope (deferred)" — this fills the deferred renegotiation re-derivation) and [ADR-0005](0005-persistent-structured-trainee-model.md) (§"projections" — "re-derived silently on goal renegotiation"). It does not supersede either; it implements the one lifecycle event ADR-0021 left open.

## Context

ADR-0005 defined `ProjectionState.goalLastRenegotiatedAt` and said a pattern's **stretch** is "re-derived silently on goal renegotiation" while the **floor** stays immovable. #269/ADR-0021 built the *initial* derivation (at calibration review) and the *upward-only athlete edit*, but explicitly deferred the renegotiation re-derivation — it needed a renegotiation trigger that did not exist, and `goalLastRenegotiatedAt` was a field that was never written.

A grilling-time discovery (and an independent architecture review) shaped this decision: the ADR-0021 stretch formula — `round-up-2.5kg(floor × (1 + margin(trend)))` — reads **only `floor` and `trend`**. It never reads `goal.statement` or `focusAreas`. Since the floor is immovable, re-running the formula on a goal change moves the number **only when `trend` has shifted** since the original derivation. So renegotiation re-derivation is, by construction, *nearly inert* on the number itself. That is not a defect to paper over: ADR-0005's word "**silently**" indicates the original intent was invisible model hygiene (keep the lifecycle field honest), not an athlete-visible "your targets jumped" event. This ADR honours that intent. The separate, larger question — *should the new goal itself move targets* (focus-area-aware margin, or letting the floor step up when capability has clearly outgrown it) — is genuinely new behaviour with no calibration data behind it and is deferred to **#305** with its own ADR.

A second key finding fixed the placement: to detect "the goal actually changed" you must compare the incoming goal against the **previously stored** goal, and only `update-trainee-goal` ever sees both at once. The moment it writes, `model_json.goal` is overwritten, so a later session-apply has already lost the prior goal and could only fall back to the untrustworthy client `goal.updatedAt` (which is freshened on *every* save, including the no-change calibration-screen save). Detection therefore has to live in the goal writer.

## Decision

### Trigger (server-side, content diff)

In `update-trainee-goal`, the prior `model_json.goal` is read under `FOR UPDATE` before the overwrite. It is a **renegotiation** iff a prior **non-placeholder** goal exists, **and** its `statement` or its order-insensitive `focusAreas` set differs from the incoming goal, **and** projections already exist. This excludes onboarding's first goal-set (no prior goal / the empty-statement `GoalState.placeholder` sentinel) and the calibration-review save (goal byte-identical, stretch-edits only) automatically — no per-caller flag on the wire.

### Placement (atomic, in the goal writer)

The re-derivation runs in `update-trainee-goal`'s `applyGoalWrite`, in **one** `FOR UPDATE` transaction with the goal write, so the new goal, the re-derived projections, and `goalLastRenegotiatedAt` commit atomically. Computing from the locked prior snapshot makes it race-safe against a concurrent session-apply (the same guarantee the #296 stretch-edit path relies on).

### Re-derivation (upward-only, floor immovable)

For each existing projection: `stretch := max(stored, deriveStretch(floor, currentTrend))`, reusing the ADR-0021 formula verbatim. The clamp is **upward-only** — a target the athlete deliberately raised (#269) is never lowered, and a trend that has *declined* since derivation never drops the target. The **floor is untouched** (immovable per ADR-0005). A pattern with no/malformed `trend` defaults to `progressing`, mirroring the calibration-derivation arm.

### Progress (deferred, not recomputed here)

`progress` is **not** recomputed in the goal writer; it is left for the next session-apply, which already recomputes every projection's progress on every apply. This matches the #296 manual-edit path (ADR-0021 §editing) and keeps the goal writer from needing the live per-pattern e1RM history at all — the re-derive needs only `floor` + `trend`. The brief stale-progress window self-heals on the next logged session.

### Timestamp

`goalLastRenegotiatedAt` is set to **server time**, consistent with how the EF already stamps `updated_at`, not the client's `goal.updatedAt`. It is stamped on every real renegotiation even when no stretch number moved — it records *when* renegotiation happened, independent of whether the inert formula changed a value.

## Consequences

- `goalLastRenegotiatedAt` is now written (it was a dead field). It is still consumed by nothing — purely a lifecycle record.
- Asymmetric-error preserved throughout: floor never moves, stretch only ever clamps upward, the immovable floor can't be faked.
- **No SQL migration** (`projections` is an existing JSONB field); **no iOS change** (no screen shows projection numbers right after a goal-review save; the re-derived stretch reaches the model on the next session sync and flows onward to the digest/banner like any other projection change).
- The goal write moved from a standalone `INSERT … ON CONFLICT` to a transaction wrapping it; the goal-write semantics (jsonb_set merge, COALESCE-NULL defense, sibling preservation) are unchanged and all prior `upsertGoal` tests still pass (no existing seed both carries a prior goal *and* changes it while holding projections).
- **Silent by design**: when `trend` is unchanged, a renegotiation moves no number and only stamps the timestamp. That is the intended ADR-0005 behaviour, not a bug.

### Out of scope (deferred to #305)

- **Goal-aware re-derivation** — making the new goal (focus areas) actually move targets, e.g. a focus-area-weighted margin. Needs cohort data to calibrate honestly; inventing a margin now would be the day-1 pseudo-precision ADR-0005 §"goal" rejected.
- **Floor step-up at renegotiation** — letting the immovable floor rise when demonstrated capability has clearly outgrown it. Directly contradicts ADR-0005 ("immovable") and ADR-0021's asymmetric-error thesis; the single most consequential change to the progression model, so it needs its own sign-off, not a sub-decision of this slice.
