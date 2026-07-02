// Incumbent-replication tests: the harness's EWMA forecaster must follow
// production's applyPerExerciseRules behavior (top-intent only, 3..10 rep
// validity, session-timestamp stamping, retention cap) and produce numbers
// identical to driving ewma-engine's computeE1RM directly.

import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert";
import {
  incumbentApplySession,
  incumbentE1rm,
  incumbentForecastReps,
  newIncumbentState,
} from "./incumbent.ts";
import { ewmaE1RM } from "../../ewma-engine.ts";

const T = (d: number) => new Date(Date.UTC(2026, 0, 5 + d, 10));

Deno.test("only valid top-intent sets enter the EWMA history", () => {
  const s = newIncumbentState();
  incumbentApplySession(s, [
    { exerciseId: "bench", weightKg: 40, reps: 8, intent: "top" },
    { exerciseId: "bench", weightKg: 30, reps: 6, intent: "warmup" },
    { exerciseId: "bench", weightKg: 35, reps: 9, intent: "backoff" },
    { exerciseId: "bench", weightKg: 40, reps: 12, intent: "top" }, // >10 reps
    { exerciseId: "bench", weightKg: 45, reps: 2, intent: "top" }, // <3 reps
  ], T(0), "s1", false);
  assertEquals(s.topSets.get("bench")!.length, 1);
  // e1RM = 40·(1+8/30) = 50.667
  assertAlmostEquals(incumbentE1rm(s, "bench")!, 40 * (1 + 8 / 30), 1e-9);
});

Deno.test("EWMA numbers match driving ewma-engine directly (α=0.333, window 5)", () => {
  const s = newIncumbentState();
  const seq: Array<[number, number]> = [
    [40, 8],
    [40, 9],
    [42.5, 8],
    [42.5, 9],
    [45, 8],
    [45, 9],
  ];
  seq.forEach(([w, r], i) => {
    incumbentApplySession(
      s,
      [{ exerciseId: "bench", weightKg: w, reps: r, intent: "top" }],
      T(i * 3),
      `s${i}`,
      false,
    );
  });
  const direct = ewmaE1RM(
    seq.map(([w, r], i) => ({
      weight: w,
      reps: r,
      loggedAt: T(i * 3),
      sessionId: `s${i}`,
    })),
  )!;
  assertAlmostEquals(incumbentE1rm(s, "bench")!, direct, 1e-9);
});

Deno.test("retention cap: only the newest 10 top sets are kept (prod parity)", () => {
  const s = newIncumbentState();
  for (let i = 0; i < 14; i++) {
    incumbentApplySession(
      s,
      [{ exerciseId: "row", weightKg: 30 + i, reps: 8, intent: "top" }],
      T(i * 2),
      `s${i}`,
      false,
    );
  }
  assertEquals(s.topSets.get("row")!.length, 10);
  assertEquals(s.topSets.get("row")![0].weight, 34); // oldest retained = i=4
});

Deno.test("zero-weight top sets: kept as prod does, excluded in the clean variant", () => {
  const dirty = newIncumbentState();
  const clean = newIncumbentState();
  const sets = [
    { exerciseId: "pull_up", weightKg: 0, reps: 8, intent: "top" },
    { exerciseId: "pull_up", weightKg: 10, reps: 8, intent: "top" },
  ];
  incumbentApplySession(dirty, sets, T(0), "s1", false);
  incumbentApplySession(clean, sets, T(0), "s1", true);
  assertEquals(dirty.topSets.get("pull_up")!.length, 2);
  assertEquals(clean.topSets.get("pull_up")!.length, 1);
  // Dirty EWMA is dragged toward 0 by the bodyweight set, exactly as prod.
  assert(incumbentE1rm(dirty, "pull_up")! < incumbentE1rm(clean, "pull_up")!);
});

Deno.test("forecast inverts Epley and clamps at zero", () => {
  const s = newIncumbentState();
  incumbentApplySession(
    s,
    [{ exerciseId: "bench", weightKg: 40, reps: 8, intent: "top" }],
    T(0),
    "s1",
    false,
  );
  const e = 40 * (1 + 8 / 30);
  assertAlmostEquals(
    incumbentForecastReps(s, "bench", 40)!,
    30 * (e / 40 - 1),
    1e-9,
  );
  // Load far above e1RM → clamped to 0, not negative.
  assertEquals(incumbentForecastReps(s, "bench", 60), 0);
  // Unknown exercise / non-positive load → null.
  assertEquals(incumbentForecastReps(s, "squat", 40), null);
  assertEquals(incumbentForecastReps(s, "bench", 0), null);
});
