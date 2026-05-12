// Project Apex — Phase 2 prescription-accuracy aggregator tests.
//
// Per ADR-0014 (rep-error metric, sliding window, deload exclusion,
// gap-bucket stratification, accepted 2026-05-07).
//
// Each test name pins the originating ADR clause or grilling lock-in.
//
// Run locally:
//   deno test supabase/functions/_shared/prescription-accuracy_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  appendObservation,
  type DigestableAccuracy,
  digestableAccuracy,
  gapBucket,
  type InterSessionGapBucket,
  type PerCellAccumulator,
  repError,
  type SetObservation,
  shouldContribute,
  shouldSurfaceInDigest,
} from "./prescription-accuracy.ts";

// Base fixture — all 6 inclusion criteria pass. Each cycle overrides only
// the field(s) under test, leaving the rest at "criteria-pass" defaults.
const baseObs = (overrides: Partial<SetObservation> = {}): SetObservation => ({
  pattern: "horizontal_push",
  prescribedIntent: "top",
  loggedIntent: "top",
  prescribedReps: 5,
  repsCompleted: 5,
  userCorrectedWeight: false,
  completionFlags: [],
  patternPhaseAtPrescription: "accumulation",
  loggedAt: new Date("2026-05-08T12:00:00Z"),
  priorSessionLoggedAt: new Date("2026-05-06T12:00:00Z"), // 48h prior
  ...overrides,
});

Deno.test("ADR-0014 §criterion 1: intent mismatch (loggedIntent !== prescribedIntent) → does NOT contribute", () => {
  // Deviated sets go to prescriptionIntentMismatches log only — different
  // signal. Per ADR-0014: "Deviated sets go to prescriptionIntentMismatches
  // only — different signal."
  const obs = baseObs({ prescribedIntent: "top", loggedIntent: "backoff" });
  assertEquals(shouldContribute(obs), false);
});

Deno.test("ADR-0014 §criterion 2: warmup excluded — not a working set", () => {
  // Per ADR-0014 §"Set-inclusion criteria": working set means intent ∈
  // {top, backoff, amrap}. Warmup is structurally an undertargeted ramp,
  // not a calibration observation; including it would dilute the bias
  // signal toward zero on every pattern.
  const obs = baseObs({ prescribedIntent: "warmup", loggedIntent: "warmup" });
  assertEquals(shouldContribute(obs), false);
});

Deno.test("ADR-0014 §criterion 2: top / backoff / amrap working sets accepted (when all other criteria pass)", () => {
  // Pins the working-set predicate is `intent ∈ {top, backoff, amrap}`,
  // exactly. Each of the three working intents asserted independently so
  // a refactor narrowing the set (e.g., dropping amrap by accident)
  // breaks the specific intent rather than the test as a whole.
  for (const intent of ["top", "backoff", "amrap"] as const) {
    const obs = baseObs({ prescribedIntent: intent, loggedIntent: intent });
    assertEquals(shouldContribute(obs), true, `intent=${intent} should contribute`);
  }
});

Deno.test("ADR-0014 §criterion 3: abandoned set (repsCompleted=0) → does NOT contribute", () => {
  // Per ADR-0014: "Completed: reps_completed ≥ 1. Abandoned sets excluded."
  // A 0-rep set carries no rep-error signal — `(0 - 5) / 5 = -1.0` would
  // dominate the bias estimate as a degenerate observation.
  const obs = baseObs({ repsCompleted: 0 });
  assertEquals(shouldContribute(obs), false);
});

Deno.test("ADR-0014 §criterion 4: user-corrected weight → does NOT contribute (override means it's not an observation of AI accuracy)", () => {
  // Per ADR-0014 §criterion 4: "User overrode the prescription means it's
  // not an observation of AI accuracy." The set was performed at a load
  // the user chose; rep-error against the AI's prescription would conflate
  // user judgment with AI calibration.
  const obs = baseObs({ userCorrectedWeight: true });
  assertEquals(shouldContribute(obs), false);
});

Deno.test("ADR-0014 §criterion 5: pain completion flag → does NOT contribute (pain-driven undershoots would poison the bias estimate)", () => {
  // Per ADR-0014 §criterion 5: "pain-flagged sets are reactive-intervention
  // territory; pain-driven rep undershoots would poison the bias estimate."
  // A set cut short by pain isn't an AI miscalibration signal — it's a
  // physical intervention, surfacing through a different channel.
  const obs = baseObs({ completionFlags: ["pain"] });
  assertEquals(shouldContribute(obs), false);
});

Deno.test("ADR-0014 §criterion 5: form_breakdown alone → CONTRIBUTES (only 'pain' excludes; other flags are still calibration observations)", () => {
  // Pins the criterion-5 predicate to 'pain' specifically. form_breakdown
  // is a coaching cue, not a reactive intervention — the user delivered
  // their reps, just at degraded quality. The bias signal still tracks
  // the AI's prescription accuracy; form-degradation flag surfaces
  // through the technique-failure path separately.
  const obs = baseObs({ completionFlags: ["form_breakdown"] });
  assertEquals(shouldContribute(obs), true);
});

Deno.test("ADR-0014 §criterion 6: deload phase excluded — sets prescribed during .deload don't contribute (composes with ADR-0011 cyclic phase model)", () => {
  // Per ADR-0014 §"Why deload sets are excluded": during deload the AI is
  // intentionally under-prescribing. A user in deload will systematically
  // overshoot reps relative to a deliberately conservative prescription;
  // accumulating those would translate "positive bias → bump load" into
  // the wrong intervention. Excluding deload at the upstream filter keeps
  // the bias signal phase-independent and the digest interpretation
  // trivial. Composes with ADR-0011's cyclic deload phase — every cycle
  // through .deload pauses accumulation for that pattern.
  const obs = baseObs({ patternPhaseAtPrescription: "deload" });
  assertEquals(shouldContribute(obs), false);
});

const emptyCell = (
  pattern = "horizontal_push",
  intent = "top",
): PerCellAccumulator => ({
  pattern,
  intent,
  observations: [],
  observationsByGapBucket: {
    under48h: [],
    between48And72h: [],
    over72h: [],
  },
  observationBuckets: [],
});

const ZERO_BUCKET_RECORD = (): Record<InterSessionGapBucket, number> => ({
  under48h: 0,
  between48And72h: 0,
  over72h: 0,
});

// Direct DigestableAccuracy fixture (skips the cell-aggregation path so
// surfacing tests can isolate the rule from the aggregation pipeline).
const mkDigest = (overrides: Partial<DigestableAccuracy> = {}): DigestableAccuracy => ({
  pattern: "horizontal_push",
  intent: "top",
  bias: 0,
  rmse: 0,
  sampleCount: 0,
  biasByGapBucket: ZERO_BUCKET_RECORD(),
  rmseByGapBucket: ZERO_BUCKET_RECORD(),
  sampleCountByGapBucket: ZERO_BUCKET_RECORD(),
  ...overrides,
});

Deno.test("ADR-0014 §sliding window: 30-obs cell, append 31st → main array stays at 30, oldest (0.01) evicted; per-bucket sub-array stays in sync (also drops oldest)", () => {
  // The window size is overall — when obs #31 lands, obs #1 falls out of
  // the main array AND from its bucket sub-array. All 31 obs use baseObs
  // defaults (48h prior → between48And72h), so bucket sub-array sync is
  // observable on the same bucket.
  const cell = emptyCell();
  for (let i = 1; i <= 30; i++) {
    appendObservation(
      cell,
      baseObs({ prescribedReps: 100, repsCompleted: 100 + i }), // err = i/100
    );
  }
  assertEquals(cell.observations.length, 30);
  assertEquals(cell.observations[0], 0.01); // oldest
  assertEquals(cell.observations[29], 0.30); // newest
  assertEquals(cell.observationsByGapBucket.between48And72h.length, 30);

  // Append the 31st (err = 0.31) — should evict the oldest (0.01).
  appendObservation(
    cell,
    baseObs({ prescribedReps: 100, repsCompleted: 131 }),
  );

  assertEquals(cell.observations.length, 30);
  assertEquals(cell.observations[0], 0.02); // 0.01 evicted
  assertEquals(cell.observations[29], 0.31);
  assertEquals(
    cell.observationsByGapBucket.between48And72h.length,
    30,
    "bucket sub-array length must stay in sync with main window",
  );
  assertEquals(
    cell.observationsByGapBucket.between48And72h[0],
    0.02,
    "bucket sub-array must also drop oldest",
  );
});

Deno.test("ADR-0014 §digest exposure: sampleCount=4 (under PRESCRIPTION_ACCURACY_DIGEST_MIN_SAMPLES=5) → does NOT surface (avoid noise on small N)", () => {
  // Even with a "loud" |bias|=0.10 and rmse=0.20, sampleCount<5 suppresses
  // the surface. Per ADR-0014 §"Digest exposure filter": "avoid surfacing
  // noise on small N." The min-samples gate runs before the magnitude
  // tests; this test pins that ordering.
  const d = mkDigest({ bias: 0.10, rmse: 0.20, sampleCount: 4 });
  assertEquals(shouldSurfaceInDigest(d), false);
});

Deno.test("ADR-0014 §digest exposure: sampleCount=5, bias=0.04, rmse=0.05, no gap divergence → does NOT surface (under both magnitude thresholds)", () => {
  // sampleCount passes the min-N gate (≥5), but |bias|=0.04 ≤ 0.05 and
  // rmse=0.05 ≤ 0.10, so neither magnitude threshold fires; gap-bucket
  // sub-counts are 0 so divergence rule can't fire either. Pinning the
  // under-threshold case so a later refactor of the magnitude checks
  // can't loosen them silently.
  const d = mkDigest({ bias: 0.04, rmse: 0.05, sampleCount: 5 });
  assertEquals(shouldSurfaceInDigest(d), false);
});

Deno.test("ADR-0014 §digest exposure: sampleCount=5, bias=0.06 (|bias| > 0.05 strict), rmse=0.05 → surfaces (bias threshold fires)", () => {
  // Boundary-strict per ADR-0014: `|bias| > 0.05` fires. 0.06 fires;
  // 0.05 would not (the under-threshold C24 partner uses 0.04 explicitly
  // to dodge the boundary question, but the strict-> semantic is locked
  // here for both signs).
  const d = mkDigest({ bias: 0.06, rmse: 0.05, sampleCount: 5 });
  assertEquals(shouldSurfaceInDigest(d), true);

  // Negative bias also fires by absolute value:
  const dNeg = mkDigest({ bias: -0.06, rmse: 0.05, sampleCount: 5 });
  assertEquals(shouldSurfaceInDigest(dNeg), true);
});

Deno.test("ADR-0014 §digest exposure: sampleCount=5, bias=0.04, rmse=0.11 (rmse > 0.10 strict) → surfaces (rmse threshold fires)", () => {
  // Independent of bias: a high-variance delivery (rmse > 0.10) fires
  // even when bias is well-calibrated. Per ADR-0014 §"Digest exposure
  // filter": "the 10% RMSE threshold catches both true miscalibration
  // and high-variability deliveries; the latter is itself a useful
  // coaching signal." Strict > on the boundary, mirroring the bias
  // threshold's strictness.
  const d = mkDigest({ bias: 0.04, rmse: 0.11, sampleCount: 5 });
  assertEquals(shouldSurfaceInDigest(d), true);
});

Deno.test("ADR-0014 §digest exposure: gap-bucket divergence at boundary — divergence=0.05 → no fire (strict >), divergence=0.06 → fires (under48h vs over72h, both sampleCounts ≥ 3)", () => {
  // Stacking signal per ADR-0010: when bias differs meaningfully between
  // short-gap (fatigued) and long-gap (fresh) sessions, the AI is failing
  // to account for inter-session fatigue. Surfacing fires even when
  // overall bias and rmse are small. Strict-> boundary at 0.05.
  // No-fire: divergence exactly 0.05.
  const dNoFire = mkDigest({
    bias: 0,
    rmse: 0,
    sampleCount: 10,
    biasByGapBucket: { under48h: 0, between48And72h: 0, over72h: 0.05 }, // |0 − 0.05| = 0.05
    sampleCountByGapBucket: { under48h: 5, between48And72h: 0, over72h: 5 },
  });
  assertEquals(shouldSurfaceInDigest(dNoFire), false);

  // Fires: divergence 0.06 with both buckets at sampleCount ≥ 3.
  const dFire = mkDigest({
    bias: 0,
    rmse: 0,
    sampleCount: 10,
    biasByGapBucket: { under48h: 0, between48And72h: 0, over72h: 0.06 },
    sampleCountByGapBucket: { under48h: 5, between48And72h: 0, over72h: 5 },
  });
  assertEquals(shouldSurfaceInDigest(dFire), true);
});

Deno.test("ADR-0014 §digest exposure: gap-bucket divergence with under48h sampleCount=2 (under min=3) → does NOT surface even when divergence is large (both buckets need ≥3 obs)", () => {
  // The min-samples-per-bucket gate (≥3) prevents a 1-2 obs short-gap
  // bucket from triggering the stacking signal off noise. Per ADR-0014:
  // "both buckets have sampleCountByGapBucket >= 3." If only one bucket
  // has ≥3, divergence is suppressed regardless of magnitude.
  const d = mkDigest({
    bias: 0,
    rmse: 0,
    sampleCount: 7,
    biasByGapBucket: { under48h: -0.10, between48And72h: 0, over72h: 0.10 }, // div=0.20, large
    sampleCountByGapBucket: { under48h: 2, between48And72h: 0, over72h: 5 }, // under48h=2 < 3
  });
  assertEquals(shouldSurfaceInDigest(d), false);
});

Deno.test("ADR-0014 §sliding window: multiple working sets in a single 5×5 session contribute independently (window counts observations, not sessions)", () => {
  // A 5×5 session of `top` sets generates 5 observations from the same
  // session — each contributes independently. The window is observation-
  // counted, not session-counted; per ADR-0014 §"Sliding window".
  const cell = emptyCell();
  const sessionLoggedAt = new Date("2026-05-08T12:00:00Z");
  const priorSessionLoggedAt = new Date("2026-05-07T12:00:00Z"); // 24h prior
  for (let i = 0; i < 5; i++) {
    appendObservation(
      cell,
      baseObs({
        prescribedReps: 5,
        repsCompleted: 5,
        loggedAt: sessionLoggedAt,
        priorSessionLoggedAt,
      }),
    );
  }
  assertEquals(cell.observations.length, 5);
  assertEquals(digestableAccuracy(cell).sampleCount, 5);
});

Deno.test("ADR-0014 §rep-error / digestable: single observation rep-error = +0.10 (over by 10%) → bias=0.10, rmse=0.10, sampleCount=1; under48h bucket populated; other buckets zero", () => {
  // Pins the rep-error formula `(reps_completed - reps_prescribed) / reps_prescribed`
  // and the basic single-obs aggregation: bias=mean(obs), rmse=sqrt(mean(obs²)).
  // For one observation rmse=|obs| trivially. Gap=24h routes to under48h
  // bucket; the other two buckets stay empty.
  const obs = baseObs({
    prescribedReps: 10,
    repsCompleted: 11, // +0.10 rep-error
    loggedAt: new Date("2026-05-08T12:00:00Z"),
    priorSessionLoggedAt: new Date("2026-05-07T12:00:00Z"), // 24h prior → under48h
  });
  assertEquals(repError(obs), 0.10);

  const cell = emptyCell();
  appendObservation(cell, obs);
  const d = digestableAccuracy(cell);

  assertEquals(d.bias, 0.10);
  assertEquals(d.rmse, 0.10);
  assertEquals(d.sampleCount, 1);
  assertEquals(d.biasByGapBucket.under48h, 0.10);
  assertEquals(d.rmseByGapBucket.under48h, 0.10);
  assertEquals(d.sampleCountByGapBucket.under48h, 1);
  assertEquals(d.sampleCountByGapBucket.between48And72h, 0);
  assertEquals(d.sampleCountByGapBucket.over72h, 0);
});

Deno.test("ADR-0014 §digestable: two observations [+0.05, -0.05] → bias=0 (mean cancels), rmse ≈ 0.05 (sqrt(mean of squares))", () => {
  // Pins the RMSE formula as `sqrt(mean(x²))` — root-mean-squared of the
  // raw rep-error values, NOT root-mean-squared deviation from the mean
  // (that would be standard deviation, a different metric). Cancellation
  // case verifies that bias and rmse decouple cleanly: bias can be zero
  // while rmse is meaningful.
  //
  //   bias = (0.05 + -0.05) / 2 = 0
  //   rmse = sqrt((0.0025 + 0.0025) / 2) = sqrt(0.0025) = 0.05
  const cell = emptyCell();
  appendObservation(
    cell,
    baseObs({ prescribedReps: 20, repsCompleted: 21 }), // +0.05
  );
  appendObservation(
    cell,
    baseObs({ prescribedReps: 20, repsCompleted: 19 }), // -0.05
  );
  const d = digestableAccuracy(cell);

  assertEquals(d.bias, 0);
  assertEquals(Math.abs(d.rmse - 0.05) < 1e-9, true, `rmse=${d.rmse}`);
  assertEquals(d.sampleCount, 2);
});

Deno.test("ADR-0014 §sign convention: positive rep-error = user exceeded prescribed = AI under-prescribed (load should bump up); negative = AI over-prescribed (load should reduce)", () => {
  // Load-bearing semantic test. Pins the sign so a future refactor that
  // inverts the rep-error formula (e.g., `(prescribed - completed) /
  // prescribed`) breaks here — without this cycle, the magnitude tests
  // (C20, C21) would pass even with inverted sign because |0.10| stays
  // 0.10 and rmse is squared. The interpretation rule "positive bias →
  // bump load" depends on this convention; the system prompt tooling
  // anchors to it directly.
  const overObs = baseObs({ prescribedReps: 5, repsCompleted: 7 }); // +0.40
  assertEquals(repError(overObs) > 0, true, `expected positive, got ${repError(overObs)}`);

  const underObs = baseObs({ prescribedReps: 5, repsCompleted: 3 }); // -0.40
  assertEquals(repError(underObs) < 0, true, `expected negative, got ${repError(underObs)}`);

  // And via digestableAccuracy aggregation:
  const cell = emptyCell();
  appendObservation(cell, overObs);
  assertEquals(digestableAccuracy(cell).bias > 0, true);
});

Deno.test("ADR-0014 §digestable: empty cell → bias=0, rmse=0, sampleCount=0 (across overall + all 3 gap buckets)", () => {
  // Tracer for digestableAccuracy. An empty cell yields zeros throughout;
  // the surfacing rule (sampleCount >= 5) handles the no-data case at the
  // shouldSurfaceInDigest layer.
  const cell = emptyCell();
  const d = digestableAccuracy(cell);

  assertEquals(d.bias, 0);
  assertEquals(d.rmse, 0);
  assertEquals(d.sampleCount, 0);
  assertEquals(d.biasByGapBucket.under48h, 0);
  assertEquals(d.biasByGapBucket.between48And72h, 0);
  assertEquals(d.biasByGapBucket.over72h, 0);
  assertEquals(d.sampleCountByGapBucket.under48h, 0);
  assertEquals(d.sampleCountByGapBucket.between48And72h, 0);
  assertEquals(d.sampleCountByGapBucket.over72h, 0);
});

// Gap-bucket fixtures — fix loggedAt and vary priorSessionLoggedAt by minutes.
const GAP_LOGGED_AT = new Date("2026-05-10T12:00:00Z");
const minutesBefore = (mins: number): Date =>
  new Date(GAP_LOGGED_AT.getTime() - mins * 60 * 1000);
const obsWithGap = (mins: number | null): SetObservation =>
  baseObs({
    loggedAt: GAP_LOGGED_AT,
    priorSessionLoggedAt: mins === null ? null : minutesBefore(mins),
  });

Deno.test("ADR-0014 §gap-bucket: 47h59m gap → under48h (strict < 48h boundary)", () => {
  // Just under the 48h boundary. NM readiness ~0.30–0.84 territory per
  // ADR-0010 — "still meaningfully fatigued."
  assertEquals(
    gapBucket(obsWithGap(47 * 60 + 59)),
    "under48h" as InterSessionGapBucket,
  );
});

Deno.test("ADR-0014 §gap-bucket: 72h boundary — 72h00m → between48And72h (inclusive upper bound), 72h01m → over72h (strict > 72h per ADR enum docstring)", () => {
  // Locked precedence: ADR-0014 enum docstring (level 3) wins over issue
  // #80 prose (level 5) which loosely says "72h00m → over72h." Strict
  // reading: `over72h = (gap > 72)`, so 72h00m falls in between48And72h
  // and 72h01m flips to over72h. Coaching corroboration: at NM tau=30h
  // (ADR-0010), readiness at 72h is ~0.94 — meaningfully recovered but
  // not yet asymptotic; treating 72h00m as still-possibly-fatigued biases
  // stacking detection toward over-counting (loud-failure direction per
  // docs/design-principles.md asymmetric-error preference).
  //
  // Both assertions held in one cycle because they jointly pin the
  // partition's upper boundary.  Issue #80 amendment proposed post-merge.
  assertEquals(
    gapBucket(obsWithGap(72 * 60)),
    "between48And72h" as InterSessionGapBucket,
  );
  assertEquals(
    gapBucket(obsWithGap(72 * 60 + 1)),
    "over72h" as InterSessionGapBucket,
  );
});

Deno.test("ADR-0014 §gap-bucket: first-ever pattern (priorSessionLoggedAt === null) → over72h (unbounded gap default; no stacking signal possible without prior session)", () => {
  // Per ADR-0014 §"Edge cases": "first-ever session of a pattern → bucket
  // as over72h (unbounded gap). No stacking signal possible without a
  // prior session." Bias toward "fully fresh" is correct here because
  // first-ever-pattern observations carry no recovery-from-prior-session
  // signal at all; categorising them as over72h means they only
  // contribute to the long-gap bucket where stacking-divergence isn't
  // computable, never as a confounder of the under48h bucket.
  assertEquals(
    gapBucket(obsWithGap(null)),
    "over72h" as InterSessionGapBucket,
  );
});

Deno.test("ADR-0014 §gap-bucket: negative gap (clock skew, priorSessionLoggedAt > loggedAt) → under48h (clamp-to-0 per #80 locked semantic)", () => {
  // Issue #80 explicitly flags: "Negative gap (clock skew) → flag for
  // review, recommendation: clamp to 0 → under48h." Locked Option A
  // (clamp-to-0) per asymmetric-error preference: clock-skewed obs land
  // in the under48h bucket → over-counts stacking signal (loud failure),
  // self-corrects in the 30-obs sliding window. Alternative C (route to
  // over72h) would silently mask actual fatigue stacking — exactly the
  // pathology the bucketing exists to catch.
  //
  // Source impl uses an explicit `if (gap < 0) return 'under48h'` branch
  // rather than relying on the under48h branch's coincidental < 48
  // predicate, so the clamp semantic is visible to readers and a future
  // observability hook (clock_skew event emission) has a place to land.
  // ADR-0014 doesn't currently specify an observability channel for this;
  // tracked as v2.x watch-item per A6's recovery-curve precedent.
  assertEquals(
    gapBucket(obsWithGap(-1)), // priorSessionLoggedAt 1 minute AFTER loggedAt
    "under48h" as InterSessionGapBucket,
  );
});

Deno.test("ADR-0014 §gap-bucket: 71h59m gap → between48And72h (just under 72h boundary)", () => {
  // Pinning the upper interior of the between bucket — anything strictly
  // less than 72h stays in between regardless of how close to 72h.
  assertEquals(
    gapBucket(obsWithGap(71 * 60 + 59)),
    "between48And72h" as InterSessionGapBucket,
  );
});

Deno.test("ADR-0014 §gap-bucket: 48h00m gap → between48And72h (≥ 48h flips to next bucket; lower bound inclusive)", () => {
  // The 48h boundary is inclusive on the between side: 48h flat → between.
  // Pinning the strict-< on under48h with the inclusive-≥ on between as a
  // water-tight partition.
  assertEquals(
    gapBucket(obsWithGap(48 * 60)),
    "between48And72h" as InterSessionGapBucket,
  );
});

Deno.test("ADR-0014 §criterion 6: peaking phase INCLUDED (noisier but informative — peaking-phase exclusion was rejected per ADR-0014 §Considered Options)", () => {
  // Per ADR-0014 §"Peaking-phase caveat": peaking prescription is
  // intentionally aggressive (heavy, low-rep, near-max). Failed peaking
  // sets don't necessarily mean miscalibration — the lifter is at the
  // edge of capacity. ADR-0014 §Considered Options explicitly REJECTED
  // peaking exclusion: "the AI prescription should still track what's
  // deliverable at near-maximal effort." Pinning the predicate to .deload
  // specifically so a future refactor that broadens the exclusion to
  // peaking breaks here.
  const obs = baseObs({ patternPhaseAtPrescription: "peaking" });
  assertEquals(shouldContribute(obs), true);
});

Deno.test("ADR-0014 §criterion 2: technique excluded — not a working set", () => {
  // Technique sets are skill-rehearsal, not calibration. Same exclusion
  // path as warmup; pinning the second non-working-set intent so a future
  // refactor that narrows the working-set predicate can't quietly slip
  // technique sets back into the bias window.
  const obs = baseObs({
    prescribedIntent: "technique",
    loggedIntent: "technique",
  });
  assertEquals(shouldContribute(obs), false);
});
