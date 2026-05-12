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
import { bootstrapMuscleProfile } from "./per-muscle-rules.ts";

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
