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

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  aggregateMuscleSetCounts,
  aggregateStagnationStatus,
  bootstrapMuscleProfile,
  computeFocusWeight,
  computeVolumeDeficit,
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
