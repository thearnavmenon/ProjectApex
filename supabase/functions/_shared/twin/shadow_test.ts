// Shadow dual-write tests: the containment contract (twin never breaks an
// apply, never mutates legacy fields), block persistence across applies,
// divergence logging, and corrupt-state recovery.

import { assert, assertEquals, assertExists } from "jsr:@std/assert";
import { applyTwinShadow } from "./shadow.ts";
import type {
  TwinShadowAppliedEvent,
  TwinShadowFailedEvent,
} from "../observability.ts";
import type { TwinPatternState } from "./engine.ts";

const T1 = new Date("2026-03-20T10:00:00Z");
const T2 = new Date("2026-03-24T10:00:00Z");

function spies(): {
  applied: TwinShadowAppliedEvent[];
  failed: TwinShadowFailedEvent[];
  deps: {
    emitApplied: (e: TwinShadowAppliedEvent) => void;
    emitFailed: (e: TwinShadowFailedEvent) => void;
  };
} {
  const applied: TwinShadowAppliedEvent[] = [];
  const failed: TwinShadowFailedEvent[] = [];
  return {
    applied,
    failed,
    deps: {
      emitApplied: (e) => applied.push(e),
      emitFailed: (e) => failed.push(e),
    },
  };
}

const legacyProfile = {
  pattern: "horizontal_push",
  currentPhase: "accumulation",
  sessionsInPhase: 3,
  trend: "progressing",
  confidence: "bootstrapping",
};

function chestSet(overrides: Record<string, unknown> = {}) {
  return {
    exercise_id: "machine_chest_press",
    set_number: 1,
    weight_kg: 40,
    reps_completed: 8,
    rpe_felt: 9,
    intent: "top",
    ...overrides,
  };
}

Deno.test("first apply bootstraps a twin block; legacy fields untouched; divergence logged", () => {
  const { applied, failed, deps } = spies();
  const patterns = { horizontal_push: { ...legacyProfile } };
  const exercises = {
    machine_chest_press: { exerciseId: "machine_chest_press", e1rmCurrent: 50.6 },
  };
  const result = applyTwinShadow(
    patterns,
    exercises,
    [chestSet(), chestSet({ set_number: 2, weight_kg: 35, reps_completed: 9, intent: "backoff" })],
    T1,
    "u-1",
    deps,
  );
  assertEquals(failed.length, 0);
  assertEquals(applied.length, 1);
  assert(applied[0].bootstrapped);
  assertEquals(applied[0].observations_applied, 2);
  assertEquals(applied[0].anchor_exercise_id, "machine_chest_press");
  assertExists(applied[0].divergence_pct);
  const twin = result.patterns.horizontal_push.twin as TwinPatternState;
  assertEquals(twin.version, 1);
  // Every legacy field byte-identical.
  for (const [k, v] of Object.entries(legacyProfile)) {
    assertEquals(result.patterns.horizontal_push[k], v, `legacy field ${k}`);
  }
  assert(result.rulesFired.has("twin-shadow"));
  assertEquals(result.fieldsChanged, ["patterns.horizontal_push.twin"]);
});

Deno.test("second apply continues from the persisted posterior (no re-bootstrap)", () => {
  const { applied, deps } = spies();
  const first = applyTwinShadow(
    { horizontal_push: { ...legacyProfile } },
    {},
    [chestSet()],
    T1,
    "u-1",
    deps,
  );
  const second = applyTwinShadow(
    first.patterns,
    {},
    [chestSet({ weight_kg: 42.5 })],
    T2,
    "u-1",
    deps,
  );
  assertEquals(applied.length, 2);
  assert(applied[0].bootstrapped);
  assert(!applied[1].bootstrapped);
  const twin = second.patterns.horizontal_push.twin as TwinPatternState;
  assertEquals(twin.observationCount, 2);
  assertEquals(twin.lastEventAt, T2.toISOString());
});

Deno.test("containment: a pattern with no usable sets fails soft, others proceed", () => {
  const { applied, failed, deps } = spies();
  const patterns = {
    horizontal_push: { ...legacyProfile },
    squat: { ...legacyProfile, pattern: "squat" },
  };
  const result = applyTwinShadow(
    patterns,
    {},
    [
      // squat: technique-only set → TwinNoUsableDataError on bootstrap
      {
        exercise_id: "back_squat",
        weight_kg: 60,
        reps_completed: 5,
        rpe_felt: null,
        intent: "technique",
      },
      chestSet(),
    ],
    T1,
    "u-1",
    deps,
  );
  assertEquals(failed.length, 1);
  assertEquals(failed[0].pattern, "squat");
  assertEquals(failed[0].error_class, "no_usable_sets");
  assertEquals(result.patterns.squat.twin, undefined);
  assertExists(result.patterns.horizontal_push.twin);
  assertEquals(applied.length, 1);
});

Deno.test("corrupt persisted twin block is treated as absent and re-bootstraps", () => {
  const { applied, deps } = spies();
  const patterns = {
    horizontal_push: {
      ...legacyProfile,
      twin: { version: 99, garbage: true },
    },
  };
  const result = applyTwinShadow(patterns, {}, [chestSet()], T1, "u-1", deps);
  assert(applied[0].bootstrapped);
  const twin = result.patterns.horizontal_push.twin as TwinPatternState;
  assertEquals(twin.version, 1);
  assertEquals(result.fieldsChanged, ["patterns.horizontal_push.twin"]);
});

Deno.test("sets with unknown exercises or missing fields are skipped silently", () => {
  const { applied, failed, deps } = spies();
  const result = applyTwinShadow(
    { horizontal_push: { ...legacyProfile } },
    {},
    [
      { exercise_id: "not_a_real_exercise", weight_kg: 40, reps_completed: 8, intent: "top" },
      { exercise_id: "machine_chest_press", intent: "top" }, // no weight/reps
      chestSet(),
    ],
    T1,
    "u-1",
    deps,
  );
  assertEquals(failed.length, 0);
  assertEquals(applied.length, 1);
  assertEquals(applied[0].observations_applied, 1);
  assertExists(result.patterns.horizontal_push.twin);
});

Deno.test("untouched patterns keep their profiles by reference (no spurious writes)", () => {
  const { deps } = spies();
  const squatProfile = { ...legacyProfile, pattern: "squat" };
  const result = applyTwinShadow(
    { horizontal_push: { ...legacyProfile }, squat: squatProfile },
    {},
    [chestSet()],
    T1,
    "u-1",
    deps,
  );
  assertEquals(result.patterns.squat, squatProfile);
  assertEquals(result.fieldsChanged, ["patterns.horizontal_push.twin"]);
});

Deno.test("no legacy comparator → divergence_pct null, apply still logged", () => {
  const { applied, deps } = spies();
  applyTwinShadow(
    { horizontal_push: { ...legacyProfile } },
    {}, // no exercises dict entries
    [chestSet()],
    T1,
    "u-1",
    deps,
  );
  assertEquals(applied[0].legacy_anchor_e1rm, null);
  assertEquals(applied[0].divergence_pct, null);
});
