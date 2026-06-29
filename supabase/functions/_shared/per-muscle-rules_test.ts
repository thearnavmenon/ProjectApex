// Project Apex — unit tests for the per-muscle rule helpers (#156).
//
// The orchestrator integration tests in update-trainee-model/orchestrator_test.ts
// exercise applyPerMuscleRules end-to-end against the local Supabase Postgres.
// This file pins the pure helpers it delegates to — threshold lookup,
// bootstrap shape, volume aggregation, worst-across-patterns aggregation, and
// focusWeight derivation — at unit level for fast TDD inner-loop.
//
// Run locally:
//   deno test --allow-all supabase/functions/_shared/per-muscle-rules_test.ts

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  aggregateMuscleSetCounts,
  aggregateStagnationStatus,
  bootstrapMuscleProfile,
  cadenceScaledCeiling,
  cadenceScaledTolerance,
  computeCadenceScalingFactor,
  computeFocusWeight,
  computeVolumeDeficit,
  computeVolumeSurplus,
  MUSCLE_VOLUME_CEILING,
  proposeMuscleConfidence,
  type MuscleGroup,
} from "./per-muscle-rules.ts";

Deno.test("bootstrapMuscleProfile: legs returns ADR-0005 defaults + Q1-locked MEV threshold", () => {
  const profile = bootstrapMuscleProfile("legs");
  // muscleGroup-as-field per the #146 pattern (dict key alone is invisible
  // to Swift's inner decoder via decodeEnumKeyedDict).
  assertEquals(profile.muscleGroup, "legs");
  // Q1 lock (2026-05-13): MEV midpoint, per-7-events scaled at 4×/week
  // alpha-cohort cadence. Legs MEV 8–12/wk → 14–21/7e → midpoint 18.
  assertEquals(profile.volumeTolerance, 18);
  // Q3 lock: observedSweetSpot emits null from EF; downstream MuscleSummary
  // already drops it. Zero consumers in B1–B4 scope.
  assertEquals(profile.observedSweetSpot, null);
  // Bootstrap default; later cycles (volume aggregation + deficit
  // computation) populate the actual deficit from setLogs.
  assertEquals(profile.volumeDeficit, 0);
  // Q4 lock: binary focusWeight derived from goal.focusAreas membership.
  // Bootstrap has no goal context; coordinator sets it post-bootstrap.
  assertEquals(profile.focusWeight, 0);
  // ADR-0009 §"Aggregation to MuscleProfile.stagnationStatus" empty-
  // participation case: ProgressionTrend has no .bootstrapping sentinel;
  // .progressing is the no-signal default.
  assertEquals(profile.stagnationStatus, "progressing");
  // Q5 lock: all MuscleProfiles ship in #156 at .bootstrapping confidence.
  // Lifecycle transitions deferred to follow-up ADR.
  assertEquals(profile.confidence, "bootstrapping");
});

Deno.test("aggregateMuscleSetCounts: non-warmup non-technique sets attributed via primary-muscle → MuscleGroup", () => {
  const setLogs = [
    // Quads → legs (top + top = 2 contributing sets)
    { exercise_id: "barbell_back_squat", intent: "top" },
    { exercise_id: "barbell_back_squat", intent: "top" },
    // Excluded: warmup
    { exercise_id: "barbell_back_squat", intent: "warmup" },
    // Hamstrings → legs (1 contributing set)
    { exercise_id: "romanian_deadlift", intent: "backoff" },
    // Chest (1 contributing set)
    { exercise_id: "barbell_bench_press", intent: "top" },
    // Excluded: technique
    { exercise_id: "barbell_bench_press", intent: "technique" },
    // Shoulders (1 contributing set, amrap counts)
    { exercise_id: "lateral_raise", intent: "amrap" },
    // Unknown exercise ID → silent skip (asymmetric-error: under-attribute
    // silent; over-attribute would falsely inflate volume).
    { exercise_id: "not_an_exercise", intent: "top" },
  ];

  const counts = aggregateMuscleSetCounts(setLogs);

  // legs aggregates 2 quads + 1 hamstrings; chest 1:1; shoulders 1:1.
  // Other muscles get no contribution; the result is partial-keyed for the
  // caller to default missing entries to 0.
  assertEquals(counts.legs, 3);
  assertEquals(counts.chest, 1);
  assertEquals(counts.shoulders, 1);
  assertEquals(counts.back, undefined);
  assertEquals(counts.biceps, undefined);
  assertEquals(counts.triceps, undefined);
});

Deno.test("computeVolumeDeficit: max(0, tolerance − sum) over last-7 buckets", () => {
  // Below tolerance — straight subtraction.
  assertEquals(
    computeVolumeDeficit(
      [
        { loggedAtIso: "2026-05-01T10:00:00Z", sets: 3 },
        { loggedAtIso: "2026-05-03T10:00:00Z", sets: 5 },
      ],
      18,
    ),
    10,
  );
  // At-or-above tolerance — clamped to 0 (no negative deficits surface).
  assertEquals(
    computeVolumeDeficit(
      [
        { loggedAtIso: "2026-05-01T10:00:00Z", sets: 10 },
        { loggedAtIso: "2026-05-03T10:00:00Z", sets: 12 },
      ],
      18,
    ),
    0,
  );
  // Empty history (cold-start) — full tolerance surfaces. Downstream
  // consumers temper this via the MuscleProfile.confidence axis (Q5 lock:
  // all profiles ship at .bootstrapping in #156).
  assertEquals(computeVolumeDeficit([], 18), 18);
  // History longer than 7 — only the last 7 buckets contribute.
  assertEquals(
    computeVolumeDeficit(
      [
        { loggedAtIso: "2026-04-01T10:00:00Z", sets: 100 }, // dropped (outside window)
        { loggedAtIso: "2026-05-01T10:00:00Z", sets: 2 },
        { loggedAtIso: "2026-05-02T10:00:00Z", sets: 2 },
        { loggedAtIso: "2026-05-03T10:00:00Z", sets: 2 },
        { loggedAtIso: "2026-05-04T10:00:00Z", sets: 2 },
        { loggedAtIso: "2026-05-05T10:00:00Z", sets: 2 },
        { loggedAtIso: "2026-05-06T10:00:00Z", sets: 2 },
        { loggedAtIso: "2026-05-07T10:00:00Z", sets: 2 },
      ],
      18,
    ),
    4, // sum of last 7 buckets = 14, tolerance 18 − 14 = 4
  );
});

Deno.test("aggregateStagnationStatus: worst-across-patterns with bootstrapping-confidence patterns excluded", () => {
  // Per ADR-0009 §"Aggregation to MuscleProfile.stagnationStatus":
  // worst-trend across patterns participating in this muscle, gated on
  // confidence > .bootstrapping. Empty-participation defaults to
  // .progressing (the no-signal default; cold-start signal carries on
  // confidence=.bootstrapping on MuscleProfile independently).

  // All participating patterns at .bootstrapping confidence — empty
  // effective participation → .progressing.
  assertEquals(
    aggregateStagnationStatus("legs", {
      squat: { trend: "plateaued", confidence: "bootstrapping" },
      hip_hinge: { trend: "declining", confidence: "bootstrapping" },
    }),
    "progressing",
  );

  // One declining (above bootstrapping), one progressing → declining.
  assertEquals(
    aggregateStagnationStatus("legs", {
      squat: { trend: "declining", confidence: "calibrating" },
      hip_hinge: { trend: "progressing", confidence: "established" },
    }),
    "declining",
  );

  // One plateaued, one progressing → plateaued (worst short of declining).
  assertEquals(
    aggregateStagnationStatus("legs", {
      squat: { trend: "plateaued", confidence: "calibrating" },
      hip_hinge: { trend: "progressing", confidence: "established" },
    }),
    "plateaued",
  );

  // Only-progressing → progressing.
  assertEquals(
    aggregateStagnationStatus("legs", {
      squat: { trend: "progressing", confidence: "calibrating" },
      hip_hinge: { trend: "progressing", confidence: "established" },
    }),
    "progressing",
  );

  // Empty patterns dict (cold-start) → progressing.
  assertEquals(aggregateStagnationStatus("chest", {}), "progressing");
});

Deno.test("computeFocusWeight: 1.0 iff muscleGroup ∈ goal.focusAreas (Q4 binary lock)", () => {
  // Alpha-cohort baseline: GoalState.placeholder has empty focusAreas →
  // every muscle gets 0.0 until onboarding hydrates focusAreas.
  assertEquals(computeFocusWeight("legs", []), 0.0);
  // Membership → 1.0.
  assertEquals(computeFocusWeight("legs", ["legs", "back"]), 1.0);
  // Non-membership → 0.0.
  assertEquals(computeFocusWeight("chest", ["legs", "back"]), 0.0);
});

Deno.test("proposeMuscleConfidence: empty effective set (no participating pattern has a profile) → bootstrapping", () => {
  assertEquals(proposeMuscleConfidence("legs", {}), "bootstrapping");
});

Deno.test("proposeMuscleConfidence: all participating patterns still bootstrapping → bootstrapping (no vacuous established)", () => {
  assertEquals(
    proposeMuscleConfidence("legs", {
      squat: { confidence: "bootstrapping" },
      hip_hinge: { confidence: "bootstrapping" },
    }),
    "bootstrapping",
  );
});

Deno.test("proposeMuscleConfidence: ≥1 participating pattern past bootstrapping → calibrating", () => {
  assertEquals(
    proposeMuscleConfidence("legs", {
      squat: { confidence: "calibrating" },
      hip_hinge: { confidence: "bootstrapping" },
    }),
    "calibrating",
  );
});

Deno.test("proposeMuscleConfidence: 2/3 supermajority established (2 of 2 trained) → established", () => {
  assertEquals(
    proposeMuscleConfidence("legs", {
      squat: { confidence: "established" },
      hip_hinge: { confidence: "established" },
    }),
    "established",
  );
});

Deno.test("proposeMuscleConfidence: short of 2/3 (1 of 2 established) → calibrating", () => {
  assertEquals(
    proposeMuscleConfidence("legs", {
      squat: { confidence: "established" },
      hip_hinge: { confidence: "calibrating" },
    }),
    "calibrating",
  );
});

Deno.test("proposeMuscleConfidence: biceps (zero major patterns; isolation only) CAN reach established", () => {
  assertEquals(
    proposeMuscleConfidence("biceps", {
      isolation: { confidence: "established" },
    }),
    "established",
  );
});

// ─────────────────────────────────────────────────────────────────────────
// #164: cadence-scaling of volumeTolerance. Locked targets are per-7-events at
// 4×/week (locked = MEV × 7/4); the cadence-correct factor is 4/cadence_per_week
// = 4 × cadenceDays / 7, clamped to [0.5, 2.0]. Higher frequency → smaller
// factor; lower frequency → larger factor (the 7-event window spans fewer/more
// weeks). null cadence (cold-start) → 1.0.
// ─────────────────────────────────────────────────────────────────────────

Deno.test("#164 computeCadenceScalingFactor: 4×/week (cadenceDays=1.75) → 1.0 (baseline unchanged)", () => {
  assertEquals(computeCadenceScalingFactor(1.75), 1.0);
});

Deno.test("#164 computeCadenceScalingFactor: 6×/week (cadenceDays=7/6) → ~0.667 (scale DOWN for high frequency)", () => {
  assertAlmostEquals(computeCadenceScalingFactor(7 / 6), 4 / 6, 1e-9);
});

Deno.test("#164 computeCadenceScalingFactor: 3×/week (cadenceDays=7/3) → ~1.333 (scale UP for low frequency)", () => {
  assertAlmostEquals(computeCadenceScalingFactor(7 / 3), 4 / 3, 1e-9);
});

Deno.test("#164 computeCadenceScalingFactor: 2×/week (cadenceDays=3.5) → 2.0 (clamp ceiling)", () => {
  assertEquals(computeCadenceScalingFactor(3.5), 2.0);
});

Deno.test("#164 computeCadenceScalingFactor: null cadence (cold-start, <2 events) → 1.0", () => {
  assertEquals(computeCadenceScalingFactor(null), 1.0);
});

Deno.test("#164 computeCadenceScalingFactor: extreme cadences clamp to [0.5, 2.0]", () => {
  // ~14×/week (cadenceDays=0.5) → raw 0.286 → clamped to 0.5 floor.
  assertEquals(computeCadenceScalingFactor(0.5), 0.5);
  // 1×/week (cadenceDays=7) → raw 4.0 → clamped to 2.0 ceiling.
  assertEquals(computeCadenceScalingFactor(7), 2.0);
  // zero/negative guarded → 1.0.
  assertEquals(computeCadenceScalingFactor(0), 1.0);
});

Deno.test("#164 cadenceScaledTolerance: scales the locked baseline by cadence (rounded), null → baseline", () => {
  // legs baseline = 18.
  assertEquals(cadenceScaledTolerance("legs", 1.75), 18); // 4×/week → ×1.0
  assertEquals(cadenceScaledTolerance("legs", 3.5), 36); // 2×/week → ×2.0
  assertEquals(cadenceScaledTolerance("legs", 7 / 6), 12); // 6×/week → round(18×0.667)
  assertEquals(cadenceScaledTolerance("legs", 7 / 3), 24); // 3×/week → round(18×1.333)
  assertEquals(cadenceScaledTolerance("legs", null), 18); // cold-start → baseline
  // back baseline = 21.
  assertEquals(cadenceScaledTolerance("back", 3.5), 42); // ×2.0
});

Deno.test("#164 cadenceScaledTolerance: NO double-scaling — repeated calls derive from the constant baseline, never a prior result", () => {
  // The function takes only (muscleGroup, cadenceDays) — it cannot read a
  // persisted/already-scaled value, so re-applying at the same cadence is
  // idempotent. This is the structural guard against tolerance drift.
  const first = cadenceScaledTolerance("chest", 7 / 3); // 3×/week
  const second = cadenceScaledTolerance("chest", 7 / 3);
  const third = cadenceScaledTolerance("chest", 7 / 3);
  assertEquals(first, second);
  assertEquals(second, third);
  assertEquals(first, 24); // chest 18 × 1.333 rounded
});

// ─────────────────────────────────────────────────────────────────────────
// #570: soft two-sided volume ceiling. MUSCLE_VOLUME_CEILING is an MRV/MAV
// prior in the same per-7-events @4×/week units, cadence-scaled by the SAME
// factor as tolerance. volumeSurplus = max(0, sum − ceiling), advisory only.
// ─────────────────────────────────────────────────────────────────────────

Deno.test("#570 bootstrapMuscleProfile: includes baseline volumeCeiling + 0 volumeSurplus for all six muscles", () => {
  const expectedCeilings: Record<MuscleGroup, number> = {
    back: 28,
    chest: 24,
    shoulders: 24,
    biceps: 20,
    triceps: 16,
    legs: 24,
  };
  for (const muscle of Object.keys(expectedCeilings) as MuscleGroup[]) {
    const profile = bootstrapMuscleProfile(muscle);
    assertEquals(profile.volumeCeiling, expectedCeilings[muscle]);
    assertEquals(profile.volumeCeiling, MUSCLE_VOLUME_CEILING[muscle]);
    assertEquals(profile.volumeSurplus, 0);
  }
});

Deno.test("#570 computeVolumeSurplus: max(0, sum − ceiling) over last-7 buckets", () => {
  const bucket = (sets: number) => ({ loggedAtIso: "2026-05-01T00:00:00Z", sets });
  // Under ceiling → 0.
  assertEquals(computeVolumeSurplus([bucket(10)], 24), 0);
  // At ceiling exactly → 0.
  assertEquals(computeVolumeSurplus([bucket(12), bucket(12)], 24), 0);
  // Over ceiling → positive surplus.
  assertEquals(computeVolumeSurplus([bucket(15), bucket(15)], 24), 6); // 30 − 24
  // Cold-start (empty history) → 0.
  assertEquals(computeVolumeSurplus([], 24), 0);
  // Only the last 7 buckets contribute (8th-oldest dropped).
  const eight = [9, 1, 1, 1, 1, 1, 1, 1].map(bucket); // first (9) is outside last-7
  assertEquals(computeVolumeSurplus(eight, 5), 2); // last-7 sum = 7 → 7 − 5
});

Deno.test("#570 computeVolumeSurplus + computeVolumeDeficit are independent (both directions)", () => {
  const bucket = (sets: number) => ({ loggedAtIso: "2026-05-01T00:00:00Z", sets });
  // 15 sets, tolerance 18, ceiling 24 → deficit 3, surplus 0.
  assertEquals(computeVolumeDeficit([bucket(15)], 18), 3);
  assertEquals(computeVolumeSurplus([bucket(15)], 24), 0);
  // 25 sets, tolerance 18, ceiling 24 → deficit 0, surplus 1.
  assertEquals(computeVolumeDeficit([bucket(25)], 18), 0);
  assertEquals(computeVolumeSurplus([bucket(25)], 24), 1);
});

Deno.test("#570 cadenceScaledCeiling: scales the ceiling baseline by the shared cadence factor; null → baseline", () => {
  // legs ceiling baseline = 24.
  assertEquals(cadenceScaledCeiling("legs", 1.75), 24); // 4×/week → ×1.0
  assertEquals(cadenceScaledCeiling("legs", 3.5), 48); // 2×/week → ×2.0
  assertEquals(cadenceScaledCeiling("legs", 7 / 6), 16); // 6×/week → round(24×0.667)
  assertEquals(cadenceScaledCeiling("legs", null), 24); // cold-start → baseline
  // Uses the same factor as tolerance: factor = scaledCeiling/baseline.
  assertEquals(
    cadenceScaledCeiling("legs", 3.5) / MUSCLE_VOLUME_CEILING["legs"],
    computeCadenceScalingFactor(3.5),
  );
});
