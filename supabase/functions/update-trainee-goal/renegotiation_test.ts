// Project Apex — unit tests for goal-renegotiation stretch re-derivation
// (#304, ADR-0022). Pure helpers — no DB, no clock.
//
// Run locally:
//   deno test supabase/functions/update-trainee-goal/renegotiation_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { isRenegotiation, rederiveStretchOnRenegotiation } from "./renegotiation.ts";
import type { PatternProjection } from "../_shared/calibration-projection.ts";

// ─── isRenegotiation ────────────────────────────────────────────────────────

Deno.test("isRenegotiation: null prior (onboarding first-ever goal) → false", () => {
  assertEquals(
    isRenegotiation(null, { statement: "Get strong", focusAreas: ["legs"] }),
    false,
  );
});

Deno.test("isRenegotiation: placeholder prior (empty statement sentinel) → false", () => {
  assertEquals(
    isRenegotiation(
      { statement: "", focusAreas: [] },
      { statement: "Get strong", focusAreas: ["legs"] },
    ),
    false,
  );
});

Deno.test("isRenegotiation: identical goal → false", () => {
  assertEquals(
    isRenegotiation(
      { statement: "Hypertrophy", focusAreas: ["chest", "back"] },
      { statement: "Hypertrophy", focusAreas: ["chest", "back"] },
    ),
    false,
  );
});

Deno.test("isRenegotiation: same focus areas in a different order → false (order-insensitive)", () => {
  assertEquals(
    isRenegotiation(
      { statement: "Hypertrophy", focusAreas: ["chest", "back"] },
      { statement: "Hypertrophy", focusAreas: ["back", "chest"] },
    ),
    false,
  );
});

Deno.test("isRenegotiation: statement changed → true", () => {
  assertEquals(
    isRenegotiation(
      { statement: "Hypertrophy", focusAreas: ["chest"] },
      { statement: "Strength (1RM focus)", focusAreas: ["chest"] },
    ),
    true,
  );
});

Deno.test("isRenegotiation: focus area added → true", () => {
  assertEquals(
    isRenegotiation(
      { statement: "Hypertrophy", focusAreas: ["chest"] },
      { statement: "Hypertrophy", focusAreas: ["chest", "legs"] },
    ),
    true,
  );
});

Deno.test("isRenegotiation: focus area removed → true", () => {
  assertEquals(
    isRenegotiation(
      { statement: "Hypertrophy", focusAreas: ["chest", "legs"] },
      { statement: "Hypertrophy", focusAreas: ["chest"] },
    ),
    true,
  );
});

// ─── rederiveStretchOnRenegotiation ─────────────────────────────────────────
//
// deriveStretch(floor, trend) = roundUp-2.5(floor × (1 + margin)), ≥ floor+2.5.
// floor=140 → progressing 152.5, plateaued 147.5, declining 145.
// floor=100 → progressing 107.5, plateaued 105,   declining 102.5.

const proj = (
  pattern: string,
  floor: number,
  stretch: number,
  progress: PatternProjection["progress"] = "on_track",
): PatternProjection => ({ pattern, floor, stretch, progress });

Deno.test("rederive: trend improved (plateaued→progressing) raises stretch; floor + progress untouched", () => {
  // stored 147.5 = the original plateaued derivation off floor 140.
  const out = rederiveStretchOnRenegotiation(
    [proj("squat", 140, 147.5, "on_track")],
    { squat: "progressing" },
  );
  assertEquals(out[0].stretch, 152.5); // now progressing → raised
  assertEquals(out[0].floor, 140); // immovable
  assertEquals(out[0].progress, "on_track"); // NOT recomputed here
});

Deno.test("rederive: a user-raised stretch above the re-derived value is never lowered", () => {
  const out = rederiveStretchOnRenegotiation(
    [proj("squat", 140, 160, "ahead")], // athlete raised it to 160
    { squat: "progressing" }, // re-derives to 152.5
  );
  assertEquals(out[0].stretch, 160); // max(160, 152.5) — unchanged
  assertEquals(out[0].progress, "ahead");
});

Deno.test("rederive: trend declined never lowers the stored stretch (upward-only)", () => {
  const out = rederiveStretchOnRenegotiation(
    [proj("squat", 140, 152.5, "on_track")], // original progressing derivation
    { squat: "declining" }, // re-derives to 145
  );
  assertEquals(out[0].stretch, 152.5); // max(152.5, 145) — unchanged
});

Deno.test("rederive: a pattern with no trend entry defaults to progressing", () => {
  const out = rederiveStretchOnRenegotiation(
    [proj("horizontal_push", 100, 105, "on_track")], // stored from plateaued
    {}, // no trend → progressing → 107.5
  );
  assertEquals(out[0].stretch, 107.5);
});

Deno.test("rederive: a malformed trend value is treated as progressing", () => {
  const out = rederiveStretchOnRenegotiation(
    [proj("horizontal_push", 100, 105, "on_track")],
    { horizontal_push: "garbage" },
  );
  assertEquals(out[0].stretch, 107.5);
});

Deno.test("rederive: only the projections that should rise change; others preserved exactly", () => {
  const out = rederiveStretchOnRenegotiation(
    [
      proj("squat", 140, 147.5, "on_track"), // plateaued→progressing: rises to 152.5
      proj("horizontal_push", 100, 120, "ahead"), // user-raised high: stays 120
    ],
    { squat: "progressing", horizontal_push: "progressing" },
  );
  assertEquals(out[0].stretch, 152.5);
  assertEquals(out[1].stretch, 120); // unchanged
  assertEquals(out[1].progress, "ahead");
  assertEquals(out[1].floor, 100);
});

Deno.test("rederive: progress is never recomputed even when stretch rises", () => {
  // 'behind' is deliberately inconsistent with the numbers — proves we don't touch it.
  const out = rederiveStretchOnRenegotiation(
    [proj("squat", 140, 147.5, "behind")],
    { squat: "progressing" },
  );
  assertEquals(out[0].stretch, 152.5);
  assertEquals(out[0].progress, "behind");
});

Deno.test("rederive: empty projection list → empty", () => {
  assertEquals(rederiveStretchOnRenegotiation([], { squat: "progressing" }), []);
});
