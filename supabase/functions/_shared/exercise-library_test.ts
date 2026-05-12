// Drift-detector tests for `_shared/exercise-library.ts`.
//
// The Swift library at `ProjectApex/Models/ExerciseLibrary.swift` is the
// canonical source of truth. The TS port mirrors only the (id → pattern)
// subset. These tests assert the port stays in sync at the entry-count
// level + spot-checks load-bearing entries.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  canonicalizeExerciseId,
  EXERCISE_LIBRARY_ENTRY_COUNT,
  EXERCISE_NORMALIZATION_ENTRY_COUNT,
  EXERCISE_NORMALIZATION_MAP,
  EXERCISE_PATTERN_MAP,
  EXERCISE_PRIMARY_MUSCLE_MAP,
  EXERCISE_PRIMARY_MUSCLE_MAP_ENTRY_COUNT,
  lookupPattern,
} from "./exercise-library.ts";

Deno.test("exercise-library: entry count matches the pinned constant", () => {
  // If this fires, the Swift library probably gained a new exercise but the
  // TS port wasn't updated. Add the new entry here, bump
  // EXERCISE_LIBRARY_ENTRY_COUNT, and re-run.
  assertEquals(
    Object.keys(EXERCISE_PATTERN_MAP).length,
    EXERCISE_LIBRARY_ENTRY_COUNT,
  );
});

Deno.test("exercise-library: load-bearing pattern resolutions for the smoke fixture's IDs", () => {
  // The smoke test (smoke_test.ts) uses these three exercise IDs across
  // its synthetic session_payload. If a Swift renaming changes one of
  // these, the smoke's pattern-bootstrap assertion would silently fail
  // to map. Pinning here catches that drift loudly.
  assertEquals(lookupPattern("barbell_bench_press"), "horizontal_push");
  assertEquals(lookupPattern("barbell_back_squat"), "squat");
  assertEquals(lookupPattern("barbell_row"), "horizontal_pull");
});

Deno.test("exercise-library: lookupPattern returns undefined for unknown IDs", () => {
  // Asymmetric-error: under-bootstrap is silent (caller skips unknown);
  // over-bootstrap would create phantom pattern profiles.
  assertEquals(lookupPattern("not_an_exercise"), undefined);
  assertEquals(lookupPattern(""), undefined);
});

// MARK: ─── canonicalizeExerciseId + normalizationMap drift detector ────────

Deno.test("normalizationMap: entry count matches the pinned constant", () => {
  assertEquals(
    Object.keys(EXERCISE_NORMALIZATION_MAP).length,
    EXERCISE_NORMALIZATION_ENTRY_COUNT,
  );
});

Deno.test("normalizationMap: keys must NOT be canonical IDs", () => {
  // A legacy alias key MUST NOT collide with a canonical ID — otherwise
  // canonicalizeExerciseId would short-circuit on the canonical branch
  // and silently skip the alias mapping. Catches the case where someone
  // adds a new canonical exercise whose ID was previously a legacy alias.
  for (const key of Object.keys(EXERCISE_NORMALIZATION_MAP)) {
    assertEquals(
      key in EXERCISE_PATTERN_MAP,
      false,
      `normalizationMap key "${key}" collides with a canonical ID in EXERCISE_PATTERN_MAP`,
    );
  }
});

Deno.test("normalizationMap: values must all be canonical IDs", () => {
  // The alias-resolution target must be a real canonical ID so downstream
  // lookupPattern resolves cleanly.
  for (const [key, value] of Object.entries(EXERCISE_NORMALIZATION_MAP)) {
    assertEquals(
      value in EXERCISE_PATTERN_MAP,
      true,
      `normalizationMap value "${value}" (alias for "${key}") is not a canonical ID in EXERCISE_PATTERN_MAP`,
    );
  }
});

Deno.test("canonicalizeExerciseId: returns canonical IDs unchanged", () => {
  assertEquals(canonicalizeExerciseId("barbell_bench_press"), "barbell_bench_press");
  assertEquals(canonicalizeExerciseId("lat_pulldown_wide"), "lat_pulldown_wide");
  assertEquals(canonicalizeExerciseId("leg_press"), "leg_press");
});

Deno.test("canonicalizeExerciseId: resolves live-data legacy aliases", () => {
  // The two aliases observed in the alpha user's set_logs that motivated
  // this port. Pinning here prevents future Swift renamings from breaking
  // the canonical resolution silently.
  assertEquals(canonicalizeExerciseId("lat_pulldown_wide_grip"), "lat_pulldown_wide");
  assertEquals(canonicalizeExerciseId("dumbbell_flat_press"), "dumbbell_bench_press");
  assertEquals(canonicalizeExerciseId("cable_pulldown_neutral_grip"), "lat_pulldown_close");
});

Deno.test("canonicalizeExerciseId: passes unknown IDs through unchanged", () => {
  // Unknown IDs are not normalized — callers handle them (skip with no
  // bootstrap, log, etc.). Asymmetric-error: silent under-bootstrap is
  // preferred to phantom rewrites.
  assertEquals(canonicalizeExerciseId("not_an_exercise"), "not_an_exercise");
  assertEquals(canonicalizeExerciseId(""), "");
});

Deno.test("lookupPattern: resolves legacy aliases to the canonical pattern", () => {
  // Pre-port behavior: lookupPattern("lat_pulldown_wide_grip") returned
  // undefined, dropping the set from pattern-bootstrap. Post-port: it
  // resolves via canonicalizeExerciseId → lat_pulldown_wide → vertical_pull.
  assertEquals(lookupPattern("lat_pulldown_wide_grip"), "vertical_pull");
  assertEquals(lookupPattern("dumbbell_flat_press"), "horizontal_push");
  assertEquals(lookupPattern("cable_pulldown_neutral_grip"), "vertical_pull");
});

Deno.test("exercise-library: primaryMuscleMap entry count matches the pinned constant", () => {
  // Drift detector for the primary-muscle mirror. If this fires, the Swift
  // library probably gained / removed an exercise but the TS port wasn't
  // updated. Add or remove the matching entry here AND bump
  // EXERCISE_PRIMARY_MUSCLE_MAP_ENTRY_COUNT in lockstep with
  // EXERCISE_LIBRARY_ENTRY_COUNT (the two maps share the same key set).
  assertEquals(
    Object.keys(EXERCISE_PRIMARY_MUSCLE_MAP).length,
    EXERCISE_PRIMARY_MUSCLE_MAP_ENTRY_COUNT,
  );
});

Deno.test("exercise-library: every value is a valid MovementPattern (8-enum)", () => {
  // ADR-0005's pattern taxonomy is closed at 8. Catch any typo in the
  // map that would produce a string outside this set.
  const valid = new Set([
    "horizontal_push",
    "vertical_push",
    "horizontal_pull",
    "vertical_pull",
    "squat",
    "hip_hinge",
    "lunge",
    "isolation",
  ]);
  for (const [id, pattern] of Object.entries(EXERCISE_PATTERN_MAP)) {
    if (!valid.has(pattern)) {
      throw new Error(
        `exercise-library: ${id} maps to invalid pattern '${pattern}'`,
      );
    }
  }
});
