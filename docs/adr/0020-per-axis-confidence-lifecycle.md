# Per-axis confidence lifecycle: bootstrapping → calibrating → established

**Status**: accepted, 2026-06-08

**Relates to**: [ADR-0005](0005-persistent-structured-trainee-model.md) (§"per-axis confidence" and §"calibration review"). This ADR does not supersede ADR-0005; it *fills in* the transition rules ADR-0005 designed but left unbuilt. ADR-0005 defined the `AxisConfidence` enum and the calibration-review trigger (≥4 of 6 major patterns at `.established`); this ADR pins the per-axis rules that actually move an axis through `bootstrapping → calibrating → established`. Also relates to [ADR-0006](0006-server-side-trainee-model-update-logic.md) (EF single-writer — the new per-pattern `sessionCount` is an EF-only `model_json` accumulator) and [ADR-0009](0009-hybrid-plateau-verdict-semantics.md) (the pattern trend verdict the pattern gate reads).

## Context

`PatternProfile`, `ExerciseProfile`, and `MuscleProfile` each carry an `AxisConfidence` (`bootstrapping → calibrating → established → seasoned`). Confidence tells the AI coach (and downstream features) how much to trust an axis's signal.

As of #156/#173, **no axis's confidence ever advanced** — every profile bootstrapped to `.bootstrapping` and stayed there forever. There was no transition logic anywhere in production, despite ADR-0005 designing a calibration review that depends on patterns reaching `.established`. Consequences: the coach treated every axis as permanent no-signal; the calibration review never fired; per-pattern projections never populated (blocking #269).

This ADR was produced via a three-input best-of grilling (a per-question recommendation plus an independent clean-slate reviewer and a memory-carrying cumulative reviewer per question). The umbrella is #166.

## Decision

### Shape

Three **independent** per-axis advancement rules, one in each existing rule pipeline (`applyPerExerciseRules`, `applyPerPatternRules`, `applyPerMuscleRules`). Not a single parameterized helper — the axes accrue genuinely different signals (capability stability vs session-count-plus-trend vs cross-pattern aggregation), so a shared signature would be a false abstraction. The only shared piece is a tiny `monotonicAdvance(current, proposed)` clamp routed through by all three.

### States (3-state; `seasoned` reserved)

The implemented lifecycle is **3-state**: `bootstrapping → calibrating → established`. The enum's 4th case `seasoned` is **deliberately reserved and never written** — nothing consumes a tier above `.established` today, and inventing a trigger would be speculative machinery against the asymmetric-error bias (a tier saying "trust this even more" with no validated basis). The canonical Edge-Function **write-contract** type is the 3-case set (`bootstrapping | calibrating | established`), so an accidental `seasoned` write is a compile error.

### `monotonicAdvance` (the shared clamp)

Forward-only, no-skip: returns a state that never regresses below `current` and advances **at most one stage per call**. A rule proposing `established` from `bootstrapping` advances only to `calibrating`, reaching `established` on a subsequent apply. This is the **only** regression policy — confidence never downgrades (see §Regression).

### Per-axis gate table

| Axis | → calibrating | → established |
|---|---|---|
| **Exercise** | `sessionCount ≥ 3` AND ≥3 validity-filtered top sets | `sessionCount ≥ 8` AND e1RM coefficient of variation (`sqrt(variance)/mean`) of heaviest-e1RM-per-session over the last 5 distinct sessions ≤ **7.5%**, computed via the existing transition-mode mean/variance primitive; guarded by ≥4 distinct valid e1RM sessions |
| **Pattern** | per-pattern `sessionCount ≥ 3` | `sessionCount ≥ 6` AND `trend` is a real (non-default) plateau verdict (ADR-0009 hybrid two-track; the volume-load track lets high-rep patterns establish without valid heavy top sets) |
| **Muscle** | ≥1 participating pattern past `.bootstrapping` | `establishedCount ≥ ceil(participatingCount × 2/3)` over the **full** participating-pattern set (incl. isolation/accessory, NOT major-only), reusing the `aggregateStagnationStatus` walk |

Notes:
- **Pattern needs a new counter.** `PatternProfile` had no total-session counter (`sessionsInPhase` resets on phase transition; `recentSessionDates` saturates). A new per-pattern `sessionCount` EF-only accumulator is added (incremented once per session-apply that trains the pattern, mirroring `ExerciseProfile.sessionCount`), with an idempotent producer-side backfill seeding existing patterns from `recentSessionDates.length` as a conservative floor.
- **Muscle aggregates from patterns, not its own volume.** Its only own counter (≤7 `weeklyVolumeHistory`) saturates instantly. Aggregation reuses the existing participating-patterns walk and runs after the pattern pipeline (so it reads fresh pattern confidence), capping muscle confidence ≤ the evidence beneath it. Consequence: `volumeTolerance` adaptation (#164 cadence-scaling, #165 EWMA-update) stays an independent follow-up — out of scope here.
- **Muscle empty-set guard.** A muscle with an empty participating set, or whose participating patterns are all `.bootstrapping` (effective set empty), must NOT advance to `.established` — mirror `aggregateStagnationStatus`'s empty→default behavior (avoids the `ceil(0) ≥ 0` vacuous-truth trap). Decisive case: `biceps` participates in zero *major* patterns (all biceps exercises are `isolation`), so a major-only rule would make it permanently un-establishable — hence "full participating set."
- `learningPhase` (`sessionCount < 10`) stays an independent concept; established is not coupled to it.

### Regression

Strict **forward-only ratchet**; no downgrade path. Recency (staleness, long absence, phase transition) is handled independently at the *estimate* layer by the EWMA transition-mode collapse (ADR-0005), decoupled from the confidence label. A confidence downgrade would retract #269's already-derived projections and re-fire the calibration review (churn); the asymmetric danger is a *falsely-`.established`* axis, which forward-only cannot create. If real-world staleness ever demands a label response, that is a future forward-only ADR.

### Scope boundary with #269

This feature **only advances confidence**. When ≥4 of 6 major patterns reach `.established`, the client-derived `isReadyForCalibrationReview` flips true on its own (verified to have zero production consumers today, so nothing surfaces a broken/empty screen). Projection derivation, setting `calibrationReviewFiredAt`, and the calibration-review UX remain owned by #269. A boundary-guard test asserts this feature never writes `projections` / `calibrationReviewFiredAt`.

## Consequences

- **Asymmetric-error throughout.** Every gate under-claims rather than over-claims (a falsely-`.established` axis makes the coach over-trust thin data). Backfills seed conservative floors; small participating sets use `ceil`.
- **No migration, no Swift change.** The one new field (`PatternProfile.sessionCount`) is an EF-only JSONB accumulator (ADR-0006-allowed, precedent: `weeklyVolumeHistory`); Swift Codable ignores unknown keys, and the confidence fields already decode.
- **Tuning is deferred.** The gate numbers are conservative-by-design for the alpha cohort; re-tuning from production data is a post-alpha follow-up (e.g. exercise CV switched to detrended residuals if fast-progressers stall at `.calibrating`).
- Delivered as 5 tracer-bullet slices under #166: foundation (#282), exercise (#283), pattern counter+backfill (#284), pattern advance (#285), muscle aggregation (#286).
