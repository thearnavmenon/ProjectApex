// Drift-detector tests for `_shared/exercise-library.ts`.
//
// The Swift library at `ProjectApex/Models/ExerciseLibrary.swift` is the
// canonical source of truth. The TS port mirrors only the (id → pattern)
// subset. These tests assert the port stays in sync at the entry-count
// level + spot-checks load-bearing entries.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  EXERCISE_LIBRARY_ENTRY_COUNT,
  EXERCISE_PATTERN_MAP,
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
  assertEquals(lookupPattern("barbell_bench_press"), "horizontalPush");
  assertEquals(lookupPattern("barbell_back_squat"), "squat");
  assertEquals(lookupPattern("barbell_row"), "horizontalPull");
});

Deno.test("exercise-library: lookupPattern returns undefined for unknown IDs", () => {
  // Asymmetric-error: under-bootstrap is silent (caller skips unknown);
  // over-bootstrap would create phantom pattern profiles.
  assertEquals(lookupPattern("not_an_exercise"), undefined);
  assertEquals(lookupPattern(""), undefined);
});

Deno.test("exercise-library: every value is a valid MovementPattern (8-enum)", () => {
  // ADR-0005's pattern taxonomy is closed at 8. Catch any typo in the
  // map that would produce a string outside this set.
  const valid = new Set([
    "horizontalPush",
    "verticalPush",
    "horizontalPull",
    "verticalPull",
    "squat",
    "hipHinge",
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
