// Project Apex — unit tests for the pattern-axis confidence rule (#285).
//
// Run locally:
//   deno test --allow-all supabase/functions/_shared/pattern-confidence_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { proposePatternConfidence } from "./pattern-confidence.ts";
import { isTrendEvaluable } from "./plateau-verdict.ts";

Deno.test("pattern: below the session floor stays bootstrapping", () => {
  assertEquals(
    proposePatternConfidence({ sessionCount: 2, trendEvaluable: false }),
    "bootstrapping",
  );
});

Deno.test("pattern: 3 sessions → calibrating", () => {
  assertEquals(
    proposePatternConfidence({ sessionCount: 3, trendEvaluable: false }),
    "calibrating",
  );
});

Deno.test("pattern: 6 sessions with a data-backed trend → established", () => {
  assertEquals(
    proposePatternConfidence({ sessionCount: 6, trendEvaluable: true }),
    "established",
  );
});

Deno.test("pattern: 6 sessions but trend not yet evaluable stays calibrating", () => {
  assertEquals(
    proposePatternConfidence({ sessionCount: 6, trendEvaluable: false }),
    "calibrating",
  );
});

// --- isTrendEvaluable (plateau-verdict.ts) ---

const DAY = new Date("2026-05-10T10:00:00Z");
const e1 = (n: number) =>
  Array.from({ length: n }, () => ({ loggedAt: DAY, e1rm: 100, avgRPE: 8 }));
const vol = (n: number) =>
  Array.from({ length: n }, () => ({ loggedAt: DAY, weeklyVolumeLoad: 1000, avgRPE: 8 }));

Deno.test("isTrendEvaluable: e1RM track reaches its window (3 at fast cadence) → evaluable", () => {
  assertEquals(isTrendEvaluable(e1(3), vol(0), 1), true);
});

Deno.test("isTrendEvaluable: 2 e1RM sessions at fast cadence, no volume buckets → not evaluable", () => {
  assertEquals(isTrendEvaluable(e1(2), vol(0), 1), false);
});

Deno.test("isTrendEvaluable: slow cadence needs 4 e1RM sessions (3 is not enough)", () => {
  assertEquals(isTrendEvaluable(e1(3), vol(0), 7), false);
  assertEquals(isTrendEvaluable(e1(4), vol(0), 7), true);
});

Deno.test("isTrendEvaluable: high-rep pattern (no valid e1RM) becomes evaluable via 4 volume buckets", () => {
  assertEquals(isTrendEvaluable(e1(0), vol(3), 1), false);
  assertEquals(isTrendEvaluable(e1(0), vol(4), 1), true);
});
