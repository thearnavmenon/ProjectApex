// Project Apex — Phase 2 cadence-aware-duration translator tests.
//
// Per ADR-0015 (canonical translation pattern), each test name pins the
// originating ADR (and Q5 PRD-internal where applicable) so a failure
// surfaces the rule the change touches.
//
// Run locally:
//   deno test supabase/functions/_shared/cadence-translation_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { cadenceAwareDuration } from "./cadence-translation.ts";
import {
  DISRUPTED_PATTERN_CADENCE_MULTIPLIER,
  TRANSITION_MODE_CADENCE_MULTIPLIER,
  TRANSITION_MODE_FLOOR_DAYS,
  TRANSITION_MODE_NIL_CADENCE_FALLBACK_DAYS,
} from "./constants.ts";

Deno.test("ADR-0015: nil cadence falls back to nilFallbackDays", () => {
  assertEquals(cadenceAwareDuration(null, 3, 14, 21), 21);
});

Deno.test("ADR-0015: cadence × N exceeds floor → cadence × N", () => {
  assertEquals(cadenceAwareDuration(7, 3, 14, 21), 21);
});

Deno.test("ADR-0015: cadence × N below floor → floor wins", () => {
  assertEquals(cadenceAwareDuration(3, 3, 14, 21), 14);
});

Deno.test("ADR-0015: pathology guard at high cadence (1d × 3) → floor wins", () => {
  assertEquals(cadenceAwareDuration(1, 3, 14, 21), 14);
});

Deno.test("ADR-0015: pathology guard at very high cadence (0.5d × 3) → floor wins", () => {
  assertEquals(cadenceAwareDuration(0.5, 3, 14, 21), 14);
});

Deno.test("ADR-0015: cadence × N equals floor (boundary) → floor", () => {
  // (14/3) × 3 === 14.0 exactly in IEEE-754 (no rounding error on this
  // division-multiplication round-trip), so Math.max(14, 14) === 14.
  assertEquals(cadenceAwareDuration(14 / 3, 3, 14, 21), 14);
});

Deno.test("ADR-0015: cadence = 0 (degenerate, not nil) → floor applies, not nil fallback", () => {
  assertEquals(cadenceAwareDuration(0, 3, 14, 21), 14);
});

Deno.test("ADR-0015: N = 0 returns floor (degenerate)", () => {
  assertEquals(cadenceAwareDuration(7, 0, 14, 21), 14);
});

Deno.test("Q5 / ADR-0015: 1×/week cadence with 3-session window → 21d (max of 14d floor and 21d)", () => {
  assertEquals(
    cadenceAwareDuration(
      7,
      TRANSITION_MODE_CADENCE_MULTIPLIER,
      TRANSITION_MODE_FLOOR_DAYS,
      TRANSITION_MODE_NIL_CADENCE_FALLBACK_DAYS,
    ),
    21,
  );
});

Deno.test("ADR-0005 / ADR-0015: disruptedPatterns derivation (2 × cadence, no floor) expressible via primitive", () => {
  // ADR-0005's pre-existing `disruptedPatterns` derivation is
  // `daysSinceLastSession > 2 × sessionsCadenceDays`. Set floor=0 to
  // disable the floor; nilFallbackDays is irrelevant when cadence is
  // non-null (sentinel value chosen for clarity).
  const irrelevantNilFallback = 999;
  assertEquals(
    cadenceAwareDuration(
      4,
      DISRUPTED_PATTERN_CADENCE_MULTIPLIER,
      0,
      irrelevantNilFallback,
    ),
    8,
  );
});
