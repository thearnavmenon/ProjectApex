// Project Apex — unit tests for backfillPatternSessionCount (#284).
//
// Run locally:
//   deno test --allow-all supabase/functions/_shared/pattern-session-count-backfill_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { backfillPatternSessionCount } from "./pattern-session-count-backfill.ts";

Deno.test("backfill: seeds missing sessionCount from recentSessionDates.length", () => {
  const { patterns, backfilledCount } = backfillPatternSessionCount({
    horizontal_push: { pattern: "horizontal_push", recentSessionDates: ["a", "b", "c"] },
  });
  assertEquals(patterns.horizontal_push.sessionCount, 3);
  assertEquals(backfilledCount, 1);
});

Deno.test("backfill: missing recentSessionDates seeds floor of 0", () => {
  const { patterns, backfilledCount } = backfillPatternSessionCount({
    squat: { pattern: "squat" },
  });
  assertEquals(patterns.squat.sessionCount, 0);
  assertEquals(backfilledCount, 1);
});

Deno.test("backfill: leaves an existing sessionCount untouched (idempotent)", () => {
  const { patterns, backfilledCount } = backfillPatternSessionCount({
    squat: { pattern: "squat", sessionCount: 9, recentSessionDates: ["a", "b"] },
  });
  assertEquals(patterns.squat.sessionCount, 9);
  assertEquals(backfilledCount, 0);
});

Deno.test("backfill: a second run writes nothing (idempotent by construction)", () => {
  const first = backfillPatternSessionCount({
    p: { pattern: "horizontal_push", recentSessionDates: ["a", "b"] },
  });
  const second = backfillPatternSessionCount(first.patterns);
  assertEquals(second.backfilledCount, 0);
  assertEquals(second.patterns.p.sessionCount, 2);
});

Deno.test("backfill: does not mutate the original patterns dict", () => {
  const original = { p: { pattern: "squat", recentSessionDates: ["a"] } } as Record<
    string,
    Record<string, unknown>
  >;
  backfillPatternSessionCount(original);
  assertEquals(original.p.sessionCount, undefined);
});

Deno.test("backfill: counts only patterns actually written across a mixed dict", () => {
  const { backfilledCount } = backfillPatternSessionCount({
    a: { pattern: "squat", recentSessionDates: ["x"] }, // missing → written
    b: { pattern: "hinge", sessionCount: 4 }, // present → skipped
    c: { pattern: "horizontal_push" }, // missing → written (floor 0)
  });
  assertEquals(backfilledCount, 2);
});
