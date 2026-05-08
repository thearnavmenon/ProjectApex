// Project Apex — Phase 2 transition-mode expiry composer tests.
//
// Per Q5 PRD-internal lock-in (memory: project_phase_2_grilling_prd_internal_lockins.md)
// and ADR-0015 (cadence-aware translation pattern):
//
//   transitionModeUntil = now + cadenceAwareDuration(cadence, 3, 14d, 21d)
//
//   - On overlap (currentUntil non-null and in the future):
//       new transitionModeUntil = max(currentUntil, computedUntil)
//   - After expiry (currentUntil non-null and in the past, or null):
//       new transitionModeUntil = computedUntil (fresh from now)
//
// Run locally:
//   deno test supabase/functions/_shared/transition-mode-expiry_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { computeTransitionModeUntil } from "./transition-mode-expiry.ts";

const MS_PER_DAY = 24 * 60 * 60 * 1000;
const NOW = new Date("2026-05-08T12:00:00Z");
const daysAfter = (base: Date, days: number) =>
  new Date(base.getTime() + days * MS_PER_DAY);

Deno.test("Q5 / ADR-0015: no prior expiry + cadence 4d → now + 14d (floor wins over 3 × 4 = 12d)", () => {
  const result = computeTransitionModeUntil(NOW, 4, null);
  assertEquals(result.getTime(), daysAfter(NOW, 14).getTime());
});

Deno.test("Q5 / ADR-0015: no prior expiry + cadence 7d → now + 21d (cadence × 3 = 21d wins over 14d floor)", () => {
  const result = computeTransitionModeUntil(NOW, 7, null);
  assertEquals(result.getTime(), daysAfter(NOW, 21).getTime());
});

Deno.test("Q5 / ADR-0015: no prior expiry + nil cadence → now + 21d (long-absence-returner nil fallback)", () => {
  const result = computeTransitionModeUntil(NOW, null, null);
  assertEquals(result.getTime(), daysAfter(NOW, 21).getTime());
});

Deno.test("Q5: overlap with currentUntil 5d in future and computed 14d → computed wins (max-of-untils)", () => {
  // Both candidates are in the future; max(now+5d, now+14d) = now+14d.
  const currentUntil = daysAfter(NOW, 5);
  const result = computeTransitionModeUntil(NOW, 4, currentUntil);
  assertEquals(result.getTime(), daysAfter(NOW, 14).getTime());
});

Deno.test("Q5: overlap with currentUntil 20d in future and computed 14d → currentUntil preserved (max-of-untils, extend-don't-shrink)", () => {
  // currentUntil > computed → max-of-untils preserves currentUntil so a
  // re-trigger inside an existing window cannot shrink the deadline.
  const currentUntil = daysAfter(NOW, 20);
  const result = computeTransitionModeUntil(NOW, 4, currentUntil);
  assertEquals(result.getTime(), currentUntil.getTime());
});

Deno.test("Q5 / ADR-0015: high-cadence pathology guard — cadence 1d → now + 14d (3 × 1d = 3d, floor wins)", () => {
  // Mirrors the cadence-translator's pathology test: at very high
  // cadence the session-derived candidate would shrink the window
  // implausibly small; the 14d calendar floor is the guard.
  const result = computeTransitionModeUntil(NOW, 1, null);
  assertEquals(result.getTime(), daysAfter(NOW, 14).getTime());
});

Deno.test("Q5: expired currentUntil (1d past) + cadence 7d → fresh-from-now (now + 21d) — past currentUntil is ignored, no carry-over", () => {
  // Pins two semantics in one assertion: an expired currentUntil never
  // participates in max-of-untils (it would otherwise drag the new until
  // backwards into the past), and the cadence × 3 = 21d formula is used
  // (since 21d > 14d floor).
  const currentUntil = daysAfter(NOW, -1);
  const result = computeTransitionModeUntil(NOW, 7, currentUntil);
  assertEquals(result.getTime(), daysAfter(NOW, 21).getTime());
});
