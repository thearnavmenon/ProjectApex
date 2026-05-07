# Prescription accuracy aggregation: rep-error, deload exclusion, and gap-bucket stratification

**Status**: accepted, 2026-05-07

## Context

ADR-0005 specifies `prescriptionAccuracy: [MovementPattern: [SetIntent: PrescriptionAccuracy]]` as a meta-coaching surface — "the AI's own bias and RMSE per pattern × intent — meta-coaching about the AI's miscalibration." The shipped struct (`PrescriptionAccuracy` in `TraineeModelInteractions.swift:124`) carries `pattern`, `intent`, `bias: Double`, `rmse: Double`, `sampleCount: Int`.

What ADR-0005 did not pin: how `bias` and `rmse` are computed, the aggregation window, set-inclusion criteria, or the digest exposure filter. ADR-0010 added a downstream requirement: the prescription-accuracy field MUST be stratified by inter-session-gap (<48h, 48–72h, >72h) per pattern, to detect stacking error in the recovery model. The shipped struct doesn't yet support this stratification.

This ADR pins the operationalization. Tightly coupled to ADR-0005 (the structural commitment), ADR-0010 (the stratification mandate), and ADR-0011 (the cyclic phase model that introduces deload as a recurring phase, not terminal).

## Decision

### Error metric — rep-error

For each contributing set:

```
error = (reps_completed - reps_prescribed) / reps_prescribed
```

Positive bias = user exceeded rep target = AI under-prescribed; negative = user fell short = AI over-prescribed.

Rep-error is the natural coaching unit. Coaches assess prescription quality by looking at rep-count vs target, not by mentally recomputing e1RM. Rep-error normalizes naturally across rep ranges and maps cleanly to actionable feedback: bias > 0 → bump load; bias < 0 → reduce.

**Known limitation:** rep-error misses *effort*. A user delivering 6/6/6/6 reps could be at RPE 7 (load too light for the target effort) or RPE 9 (well-calibrated). For the alpha cohort with inconsistent RPE logging, rep-error is the right pragmatic floor. If RPE coverage becomes reliable in v2.x, an `rpeError` signal alongside rep-error should be added.

### Aggregation window — 30 observations sliding per (pattern, intent) cell

Last 30 contributing observations per cell. Sliding — when observation 31 lands, observation 1 falls out. `bias` is mean of the 30; `rmse` is root-mean-squared of the 30.

Why 30: <10 observations have wide confidence intervals; 30 are stable enough to act on. Sliding ensures recent observations dominate naturally. 30 observations across pattern × intent ≈ 10–15 sessions of 4-day-split training ≈ 3–4 weeks of recent history — the right tracking window for a metric that should respond to current state, not state from 3 months ago.

### Set-inclusion criteria — six required

A set contributes to its `(pattern, intent)` cell iff ALL of:

1. **Intent match**: `loggedIntent == prescribedIntent`. Deviated sets go to `prescriptionIntentMismatches` only — different signal.
2. **Working set**: `intent ∈ {top, backoff, amrap}`. Warmup and technique excluded.
3. **Completed**: `reps_completed ≥ 1`. Abandoned sets excluded.
4. **Not user-corrected weight**: `user_corrected_weight == false`. User overrode the prescription means it's not an observation of AI accuracy.
5. **No `pain` completion flag**: pain-flagged sets are reactive-intervention territory; pain-driven rep undershoots would poison the bias estimate.
6. **Pattern not in `.deload` phase at prescription time**: see below.

#### Why deload sets are excluded (criterion 6)

During deload, the AI is *intentionally* under-prescribing. The whole point of deload (per ADR-0011's cyclic phase model) is light work to recover from accumulated fatigue. A user in deload will systematically overshoot reps relative to prescription because the prescription was deliberately conservative. That overshoot is the deload working as intended, not a calibration error.

If deload sets contributed to the bias estimate, deload-heavy patterns would accumulate systematically positive bias. The digest interpretation rule ("positive bias → bump load") would translate that into "increase load," which is wrong during deload.

The fix could live in the system prompt ("if pattern is in deload phase, ignore positive bias signal"), but that puts context-dependence into the LLM's interpretation when it can live cleanly in the upstream filter. Excluding deload sets from accumulation makes the bias signal phase-independent and the digest interpretation rule trivial.

Cost: deload phases are short (1–2 weeks per ADR-0011's cyclic structure); data loss is bounded. When the pattern cycles back into accumulation post-deload, the cell populates with accumulation-phase observations and bias is interpretable without phase context.

#### Peaking-phase caveat (known but not excluded)

Peaking prescription is intentionally aggressive (heavy, low-rep, near-max). Failed peaking sets don't necessarily mean miscalibration — they mean the lifter is at the edge of capacity. Peaking sets are still included because the AI prescription should still track what's deliverable at near-maximal effort, but **peaking-phase bias is structurally noisier than accumulation-phase bias**. Future maintainers tuning thresholds should expect this and bias against tightening surfacing thresholds based on peaking-heavy data.

### Gap-bucket stratification — schema extension

Extend `PrescriptionAccuracy` with parallel per-bucket aggregations:

```swift
struct PrescriptionAccuracy: Codable, Sendable, Hashable {
    var pattern: MovementPattern
    var intent: SetIntent
    var bias: Double                // overall, across all gap buckets
    var rmse: Double
    var sampleCount: Int
    // Added per this ADR:
    var biasByGapBucket: [InterSessionGapBucket: Double]
    var rmseByGapBucket: [InterSessionGapBucket: Double]
    var sampleCountByGapBucket: [InterSessionGapBucket: Int]
}

enum InterSessionGapBucket: String, Codable, Sendable, Hashable, CaseIterable {
    case under48h           // < 48 hours since last session of this pattern
    case between48And72h    // 48–72 hours
    case over72h            // > 72 hours
}
```

Bucket boundaries align with the NM recovery curve from ADR-0010 (tau = 30h):
- under48h → NM readiness ~0.30–0.84 ("still meaningfully fatigued")
- 48–72h → NM readiness ~0.84–0.94 ("mostly recovered")
- over72h → NM readiness ~0.94+ ("fully fresh")

For each contributing set, the gap is computed against the previous session of the same pattern (`now - patternProfile.recentSessionDates.dropLast().max()`). Bucket. Increment the right per-bucket aggregation alongside the overall.

Codable migration is additive — existing trainee-model rows decode with empty per-bucket dictionaries; first session-apply post-deploy populates buckets going forward.

### Digest exposure filter

Expose a `PrescriptionAccuracy` cell in the TraineeModelDigest iff:

- `sampleCount >= 5` (avoid surfacing noise on small N), AND
  - (`|bias| > 0.05` OR `rmse > 0.10`) — surface meaningfully-miscalibrated cells, OR
  - **gap-bucket divergence**: `|biasByGapBucket[under48h] - biasByGapBucket[over72h]| > 0.05` AND both buckets have `sampleCountByGapBucket >= 3` — the ADR-0010 stacking signal; surface even when overall bias is small.

The system prompts gain interpretation rules:
- Positive bias → AI under-prescribed; bump load on next prescription for this (pattern, intent), capped at one minimum increment.
- Negative bias → AI over-prescribed; reduce.
- Gap-bucket divergence → fatigue stacking signal; bias toward longer-gap-bucket's prescription when generating for short-gap sessions.

The 5% rep-error bias threshold is tight (for a 6-rep target, ±0.3 reps mean delivery). The 10% RMSE threshold catches both true miscalibration and high-variability deliveries; the latter is itself a useful coaching signal ("this user's delivery is variable on this pattern, prescribe more conservatively").

### Edge cases

- **Brand-new pattern, no observations**: cell doesn't exist; digest skips it. AI prescribes from first principles.
- **Pattern × intent cell at 30 observations, then user goes 6 months without training**: cell stays at 30 until new observations arrive. Slight risk of carrying stale bias from a much earlier user state, but the sliding window self-corrects within 30 new observations.
- **Single session contains multiple top sets** (5×5): each contributes independently. Window counts observations, not sessions.
- **Gap-bucket lookup with no prior session**: first-ever session of a pattern → bucket as `over72h` (unbounded gap). No stacking signal possible without a prior session.
- **Pattern in `.deload` cycles to `.accumulation` mid-window**: criterion 6 was applied at write time, so deload observations were never accumulated. Next accumulation-phase observation lands cleanly.

## Considered Options

- **e1RM-error as the metric**: rejected for v2. Tracks rep-error tightly when weight is constant (which it is for un-corrected sets per criterion 4). Additional sophistication unnecessary at alpha scale.

- **Weight-error as the metric**: rejected. Weight is the AI's prescription; no "achieved weight" exists for un-corrected sets. The metric would be identically zero by construction.

- **EWMA-style aggregation** (α = 0.1): rejected. Bias drifts slowly; sliding window captures it adequately. Adds a parameter without buying signal.

- **50-obs or 100-obs window**: rejected at alpha scale. Slower cold-start delays when meta-coaching becomes useful; 30 trades some stability for earlier signal.

- **Include deload sets**: rejected. Systematic positive bias on deload-heavy patterns would mistranslate into "increase load," wrong during deload. Excluding at the filter is cleaner than papering over in prompt interpretation.

- **Exclude peaking sets**: rejected. Peaking prescription should still track near-maximal capability; failed peaking sets are noisier but informative.

- **Per-exercise granularity instead of per-pattern**: rejected for v2. Per-exercise stratification multiplies cell count and slows cold-start meaningfully. Future surface — if alpha data shows systematic exercise-specific miscalibration that per-pattern aggregation misses, v2.x adds per-exercise.

- **Store raw observations, compute at read-time**: rejected. Storage and read-time costs without benefit (bucket boundaries pinned by ADR-0010's NM tau choice).

- **Context-dependent prompt rule for deload** (instead of upstream exclusion): rejected. Putting phase-context into LLM interpretation when it can live in the upstream filter is the wrong direction.

## Consequences

- The Edge Function's session-apply path (Stage 1 transactional, per ADR-0013) gains the per-set classification + accumulation logic. For each working set meeting all six inclusion criteria, look up the gap bucket and increment both the overall and per-bucket aggregations.

- `PrescriptionAccuracy` Codable schema extends with three new dictionary fields. Existing rows decode with empty dictionaries; first session-apply populates going forward. No backfill required.

- The TraineeModelDigest filter respects the surfacing rules above. The system prompts gain interpretation guidance for positive bias, negative bias, and gap-bucket divergence.

- **RPE-error as future surface (v2.x)**: rep-error misses the under-effort case where the user delivers all reps but at low RPE. When RPE logging coverage is reliable, an `rpeError` field alongside rep-error would catch this. v2 ships rep-only.

- **Per-exercise granularity as future surface (v2.x)**: per-pattern aggregation may mix signals from a well-calibrated barbell-bench user and a systematically-over-delivering dumbbell-incline user within `horizontalPush.top`. If alpha data shows the meta-coaching feedback isn't biting on exercise-specific miscalibration, v2.x adds per-exercise stratification.

- **Peaking-phase noise as known caveat**: peaking-phase bias is structurally noisier. Documented; future tuning should account.

- The deload exclusion composes with ADR-0011's cyclic phase model: every time a pattern cycles into deload, accumulation pauses for that pattern (no new observations); resumes when cycling back to accumulation/intensification/peaking.

- Inter-session-gap bucket boundaries are pinned by ADR-0010's NM tau choice (30h). Any future ADR-0010 amendment that re-tunes tau should also revisit the boundaries here for physiological consistency.
