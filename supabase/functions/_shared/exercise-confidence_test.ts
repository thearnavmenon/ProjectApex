// Project Apex — unit tests for the exercise-axis confidence rule (#283).
//
// Run locally:
//   deno test --allow-all supabase/functions/_shared/exercise-confidence_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { proposeExerciseConfidence } from "./exercise-confidence.ts";
import type { TopSet } from "./ewma-engine.ts";

const DAY = new Date("2026-05-10T10:00:00Z");

/** Build a top set for session `sid` with the given load/reps. */
function ts(weight: number, reps: number, sid: string): TopSet {
  return { weight, reps, loggedAt: DAY, sessionId: sid };
}

/** N distinct sessions, one stable top set each (identical load/reps). */
function stableSessions(n: number, weight = 100, reps = 5): TopSet[] {
  return Array.from({ length: n }, (_, i) => ts(weight, reps, `s${i}`));
}

Deno.test("exercise: below the session floor stays bootstrapping", () => {
  assertEquals(
    proposeExerciseConfidence({ sessionCount: 2, topSets: stableSessions(2) }),
    "bootstrapping",
  );
});

Deno.test("exercise: 3 sessions + 3 valid top sets → calibrating", () => {
  assertEquals(
    proposeExerciseConfidence({ sessionCount: 3, topSets: stableSessions(3) }),
    "calibrating",
  );
});

Deno.test("exercise: 3 sessions but only 2 valid top sets stays bootstrapping", () => {
  assertEquals(
    proposeExerciseConfidence({ sessionCount: 3, topSets: stableSessions(2) }),
    "bootstrapping",
  );
});

Deno.test("exercise: only out-of-range-rep top sets don't count toward calibrating", () => {
  // reps 12 are outside the 3-10 validity window → zero valid top sets.
  const invalid = [ts(60, 12, "s0"), ts(60, 12, "s1"), ts(60, 12, "s2")];
  assertEquals(
    proposeExerciseConfidence({ sessionCount: 5, topSets: invalid }),
    "bootstrapping",
  );
});

Deno.test("exercise: 8 sessions with stable e1RM over ≥4 distinct sessions → established", () => {
  assertEquals(
    proposeExerciseConfidence({ sessionCount: 8, topSets: stableSessions(5) }),
    "established",
  );
});

Deno.test("exercise: 8 sessions but noisy e1RM (CV > 7.5%) stays calibrating", () => {
  const noisy = [
    ts(80, 5, "s0"),
    ts(120, 5, "s1"),
    ts(80, 5, "s2"),
    ts(120, 5, "s3"),
    ts(80, 5, "s4"),
  ];
  assertEquals(
    proposeExerciseConfidence({ sessionCount: 8, topSets: noisy }),
    "calibrating",
  );
});

Deno.test("exercise: 8 sessions but fewer than 4 distinct valid e1RM sessions stays calibrating", () => {
  // Only 3 distinct sessions with valid top sets → fails the ≥4 guard.
  assertEquals(
    proposeExerciseConfidence({ sessionCount: 8, topSets: stableSessions(3) }),
    "calibrating",
  );
});
