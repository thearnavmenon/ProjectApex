// Project Apex — Phase 2 recovery-curve tests.
//
// Per ADR-0010 (recovery readiness curves and time constants), this
// module exposes (a) `readinessCurve(tHours, tauHours)` — the pure
// formula, used directly in numerical-tolerance tests against the
// ADR-0010 Table; and (b) `readiness(axis, lastStimulusAt, now,
// context)` — the public wrapper that handles brand-new users, clamps
// future-dated timestamps, and emits `recovery.clock_skew` (via #74's
// helper) when clock skew is detected.
//
// Numerical tolerance: 2 decimal places per issue #76 (the ADR-0010
// Table values are rounded; the underlying floats differ slightly).
//
// Run locally:
//   deno test supabase/functions/_shared/recovery-curve_test.ts

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { readiness, readinessCurve } from "./recovery-curve.ts";
import {
  RECOVERY_RESIDUAL_FLOOR,
  RECOVERY_TAU_METABOLIC_HOURS,
  RECOVERY_TAU_NM_HOURS,
} from "./constants.ts";

// 2-decimal tolerance per issue #76 (ADR-0010 Table values are rounded).
const TOLERANCE = 0.005;

Deno.test("ADR-0010: brand-new user (lastStimulusAt === null) → readiness 1.0", () => {
  const now = new Date("2026-05-08T12:00:00Z");
  assertEquals(readiness("neuromuscular", null, now, { userId: "u1" }), 1.0);
});

Deno.test("ADR-0010: t = 0 → exactly residual floor (0.3)", () => {
  assertEquals(readinessCurve(0, RECOVERY_TAU_NM_HOURS), RECOVERY_RESIDUAL_FLOOR);
  assertEquals(readinessCurve(0, RECOVERY_TAU_METABOLIC_HOURS), RECOVERY_RESIDUAL_FLOOR);
});

Deno.test("ADR-0010 formula at t=24h, NM tau=30h → 0.6855 (matches Table 0.69)", () => {
  assertAlmostEquals(readinessCurve(24, RECOVERY_TAU_NM_HOURS), 0.6855, TOLERANCE);
});

Deno.test("ADR-0010 formula at t=48h, NM tau=30h → 0.8587 (formula-derived; ADR Table cell 0.84 needs amendment)", () => {
  // Spec divergence flagged in PR description: ADR-0010 Table reads 0.84
  // at NM@48h, but the formula 0.3 + 0.7 × (1 - exp(-48/30)) yields
  // 0.8587 ≈ 0.86. The formula and tau are correct; the Table cell is a
  // hand-computation typo. Test pins the formula output; ADR amendment
  // is a follow-up.
  assertAlmostEquals(readinessCurve(48, RECOVERY_TAU_NM_HOURS), 0.8587, TOLERANCE);
});

Deno.test("ADR-0010 formula at t=72h, NM tau=30h → 0.9365 (matches Table 0.94)", () => {
  assertAlmostEquals(readinessCurve(72, RECOVERY_TAU_NM_HOURS), 0.9365, TOLERANCE);
});

Deno.test("ADR-0010 formula at t=24h, metabolic tau=12h → 0.9053 (Table reads 0.90; rounding-convention discrepancy)", () => {
  // Standard rounding of 0.9053 is 0.91; ADR Table says 0.90 (truncation).
  // Difference is within rounding-convention noise; flagged in PR but
  // lower priority than NM@48h.
  assertAlmostEquals(readinessCurve(24, RECOVERY_TAU_METABOLIC_HOURS), 0.9053, TOLERANCE);
});

Deno.test("ADR-0010 formula at t=48h, metabolic tau=12h → 0.9872 (matches Table 0.99)", () => {
  assertAlmostEquals(readinessCurve(48, RECOVERY_TAU_METABOLIC_HOURS), 0.9872, TOLERANCE);
});

Deno.test("ADR-0010 formula at t=72h, metabolic tau=12h → 0.9983 (matches Table 1.00 asymptote)", () => {
  assertAlmostEquals(readinessCurve(72, RECOVERY_TAU_METABOLIC_HOURS), 0.9983, TOLERANCE);
});

Deno.test("ADR-0010: at t=24h, NM readiness < metabolic readiness (asymmetry — metabolic clears ~2.5× faster)", () => {
  // ADR-0010 §"time constants": "The asymmetry (metabolic clears ~2.5×
  // faster than NM under these constants) is consistent with the design
  // rationale for two-dimensional recovery in ADR-0005."
  const nm24 = readinessCurve(24, RECOVERY_TAU_NM_HOURS);
  const metabolic24 = readinessCurve(24, RECOVERY_TAU_METABOLIC_HOURS);
  if (!(nm24 < metabolic24)) {
    throw new Error(
      `Expected NM readiness < metabolic readiness at t=24h, got NM=${nm24}, metabolic=${metabolic24}`,
    );
  }
});

// ─── readiness wrapper: future-dated clock-skew handling ────────────────────

/**
 * Calls `fn` with `console.log` replaced by a capture sink. Mirrors the
 * helper in `observability_test.ts`. Returns the captured strings (one
 * per call). Restores the original `console.log` unconditionally — even
 * on thrown exceptions — so test failures don't pollute later tests.
 */
function captureConsoleLog(fn: () => void): string[] {
  const captured: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => {
    captured.push(args.map((a) => typeof a === "string" ? a : JSON.stringify(a)).join(" "));
  };
  try {
    fn();
  } finally {
    console.log = original;
  }
  return captured;
}

Deno.test("ADR-0010: future-dated lastStimulusAt clamps readiness to residual floor (0.3) and emits recovery.clock_skew with positive delta_seconds", () => {
  const now = new Date("2026-05-08T12:00:00Z");
  const future = new Date("2026-05-08T13:00:00Z"); // 3600 seconds in the future

  let result = Number.NaN;
  const lines = captureConsoleLog(() => {
    result = readiness("neuromuscular", future, now, { userId: "u1" });
  });

  assertEquals(result, RECOVERY_RESIDUAL_FLOOR);
  assertEquals(lines.length, 1, "expected exactly one console.log envelope");
  const envelope = JSON.parse(lines[0]);
  assertEquals(envelope.channel, "recovery.clock_skew");
  assertEquals(envelope.event.user_id, "u1");
  assertEquals(envelope.event.last_stimulus_at, future.toISOString());
  assertEquals(envelope.event.now, now.toISOString());
  assertEquals(envelope.event.delta_seconds, 3600);
});
