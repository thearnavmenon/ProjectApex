// Project Apex — unit tests for the shared confidence-lifecycle foundation (#282).
//
// Pins the forward-only / no-skip invariant of `monotonicAdvance` that all
// three per-axis rules (exercise/pattern/muscle) route through. Pure helper —
// no DB needed; runs in the fast local TDD inner loop.
//
// Run locally:
//   deno test --allow-all supabase/functions/_shared/confidence-lifecycle_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  CONFIDENCE_ORDER,
  type ConfidenceWriteState,
  monotonicAdvance,
} from "./confidence-lifecycle.ts";

Deno.test("monotonicAdvance: advances exactly one stage bootstrapping → calibrating", () => {
  assertEquals(monotonicAdvance("bootstrapping", "calibrating"), "calibrating");
});

Deno.test("monotonicAdvance: never skips — bootstrapping proposing established advances only to calibrating", () => {
  assertEquals(monotonicAdvance("bootstrapping", "established"), "calibrating");
});

Deno.test("monotonicAdvance: advances calibrating → established", () => {
  assertEquals(monotonicAdvance("calibrating", "established"), "established");
});

Deno.test("monotonicAdvance: never regresses — established proposing bootstrapping stays established", () => {
  assertEquals(monotonicAdvance("established", "bootstrapping"), "established");
});

Deno.test("monotonicAdvance: never regresses — calibrating proposing bootstrapping stays calibrating", () => {
  assertEquals(monotonicAdvance("calibrating", "bootstrapping"), "calibrating");
});

Deno.test("monotonicAdvance: no-op when proposed equals current", () => {
  assertEquals(monotonicAdvance("calibrating", "calibrating"), "calibrating");
});

Deno.test("monotonicAdvance: invariant — result is min(proposed, current+1), never below current, over every pair", () => {
  const order = CONFIDENCE_ORDER as readonly ConfidenceWriteState[];
  for (const current of order) {
    for (const proposed of order) {
      const result = monotonicAdvance(current, proposed);
      const ci = order.indexOf(current);
      const pi = order.indexOf(proposed);
      const ri = order.indexOf(result);
      const expected = pi <= ci ? ci : ci + 1; // no regression, advance ≤1 stage
      assertEquals(
        ri,
        expected,
        `monotonicAdvance(${current}, ${proposed}) = ${result}`,
      );
    }
  }
});
