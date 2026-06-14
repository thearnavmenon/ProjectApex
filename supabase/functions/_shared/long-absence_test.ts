// Project Apex — long-absence trigger predicate tests.
//
// The long-absence re-anchor TRIGGER is FLAT >= 28 calendar days since the
// prior logged session — matching the client's existing
// `requiresReturnPhaseOverride` cue (`daysSinceLastSession >= 28`) in
// SessionPlanService.swift. This is distinct from the cadence-aware
// transition-mode DURATION in computeTransitionModeUntil (unchanged).
//
// Pure: no clock reads. Both inputs are injected.
//
// Run locally:
//   deno test supabase/functions/_shared/long-absence_test.ts

import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  gapDays,
  isLongAbsence,
  LONG_ABSENCE_DAYS,
  postReturnSessions,
} from "./long-absence.ts";
import { currentCapability } from "./calibration-projection.ts";
import type { E1RMSession } from "./plateau-verdict.ts";

const MS_PER_DAY = 86_400_000;
const at = (iso: string) => new Date(iso);
const daysAfter = (base: Date, days: number) =>
  new Date(base.getTime() + days * MS_PER_DAY);

const PRIOR = at("2026-01-01T00:00:00Z");

// ─── gapDays arithmetic ───────────────────────────────────────────────────────

Deno.test("gapDays: null prior → null (no prior session to measure a gap from)", () => {
  assertEquals(gapDays(null, daysAfter(PRIOR, 40)), null);
});

Deno.test("gapDays: exact whole-day delta is computed correctly", () => {
  assertEquals(gapDays(PRIOR, daysAfter(PRIOR, 28)), 28);
});

Deno.test("gapDays: fractional delta is preserved (not rounded)", () => {
  // 12 hours after prior → 0.5 days.
  assertEquals(gapDays(PRIOR, new Date(PRIOR.getTime() + MS_PER_DAY / 2)), 0.5);
});

Deno.test("gapDays: future-dated/negative gap clamps to 0 (clock skew)", () => {
  // Incoming logged BEFORE prior — clock skew. Clamp to 0, never negative.
  assertEquals(gapDays(PRIOR, daysAfter(PRIOR, -5)), 0);
});

// ─── isLongAbsence trigger ──────────────────────────────────────────────────

Deno.test("isLongAbsence: fires at exactly 28 days (boundary is inclusive)", () => {
  assertEquals(isLongAbsence(28), true);
});

Deno.test("isLongAbsence: fires above 28 days", () => {
  assertEquals(isLongAbsence(42), true);
});

Deno.test("isLongAbsence: does NOT fire at 27 days (just under threshold)", () => {
  assertEquals(isLongAbsence(27), false);
});

Deno.test("isLongAbsence: null gap never fires (first-ever session)", () => {
  assertEquals(isLongAbsence(null), false);
});

Deno.test("isLongAbsence: 0 gap (clamped clock skew) does not fire", () => {
  assertEquals(isLongAbsence(0), false);
});

// ─── end-to-end: gapDays feeding isLongAbsence ──────────────────────────────

Deno.test("integration: a 28-day gap fires, a 27-day gap does not, a future-dated gap does not", () => {
  assertEquals(isLongAbsence(gapDays(PRIOR, daysAfter(PRIOR, 28))), true);
  assertEquals(isLongAbsence(gapDays(PRIOR, daysAfter(PRIOR, 27))), false);
  assertEquals(isLongAbsence(gapDays(PRIOR, daysAfter(PRIOR, -3))), false);
  assertEquals(isLongAbsence(gapDays(null, daysAfter(PRIOR, 99))), false);
});

// ─── trigger threshold constant ─────────────────────────────────────────────

Deno.test("LONG_ABSENCE_DAYS is 28 (matches client requiresReturnPhaseOverride flat-28 cue)", () => {
  assertEquals(LONG_ABSENCE_DAYS, 28);
});

// ─── purity: no clock reads ─────────────────────────────────────────────────

// ─── postReturnSessions: re-anchor a session series on the freshest block ─────

const sess = (base: Date, day: number, e1rm: number): E1RMSession => ({
  loggedAt: daysAfter(base, day),
  e1rm,
  avgRPE: null,
});

Deno.test("postReturnSessions: no qualifying gap → input unchanged", () => {
  const items = [
    sess(PRIOR, 0, 100),
    sess(PRIOR, 3, 101),
    sess(PRIOR, 6, 102),
  ];
  assertEquals(postReturnSessions(items), items);
});

Deno.test("postReturnSessions: a >= 28d gap → keeps only the post-return suffix", () => {
  const items = [
    sess(PRIOR, 0, 120),
    sess(PRIOR, 3, 121),
    sess(PRIOR, 45, 110), // 42d gap before this one
    sess(PRIOR, 48, 112),
  ];
  const trimmed = postReturnSessions(items);
  assertEquals(trimmed.length, 2);
  assertEquals(trimmed.map((s) => s.e1rm), [110, 112]);
});

Deno.test("postReturnSessions: gap of exactly 28d cuts; 27d does not", () => {
  const cuts = postReturnSessions([sess(PRIOR, 0, 120), sess(PRIOR, 28, 110)]);
  assertEquals(cuts.map((s) => s.e1rm), [110]);
  const keeps = postReturnSessions([sess(PRIOR, 0, 120), sess(PRIOR, 27, 110)]);
  assertEquals(keeps.map((s) => s.e1rm), [120, 110]);
});

Deno.test("postReturnSessions: multiple gaps → cut at the MOST RECENT one", () => {
  const items = [
    sess(PRIOR, 0, 100),
    sess(PRIOR, 40, 105), // older gap
    sess(PRIOR, 43, 106),
    sess(PRIOR, 90, 95), // most-recent gap (47d)
  ];
  const trimmed = postReturnSessions(items);
  assertEquals(trimmed.map((s) => s.e1rm), [95]);
});

Deno.test("postReturnSessions: empty / single-element input is a no-op", () => {
  assertEquals(postReturnSessions([] as E1RMSession[]), []);
  const one = [sess(PRIOR, 0, 100)];
  assertEquals(postReturnSessions(one), one);
});

// Composition: the calibration-projection consumer's progress capability,
// re-anchored on post-return sessions, reads the fresh block — not the stale
// pre-gap median. This is what gates `deriveProgress` during a long absence.
Deno.test("postReturnSessions + currentCapability: progress capability re-anchors after a layoff", () => {
  const sessions = [
    sess(PRIOR, 0, 120),
    sess(PRIOR, 3, 122),
    sess(PRIOR, 6, 121),
    sess(PRIOR, 48, 110), // 42d gap → return session
  ];
  // Ungated: median over the (cadence-windowed) series is dominated by the
  // stale pre-gap block — well above the return session.
  const stale = currentCapability(sessions, 3)!;
  // Gated: re-anchored on the post-return suffix → the return session itself.
  const fresh = currentCapability(postReturnSessions(sessions), 3)!;
  assertEquals(fresh, 110);
  assertEquals(stale > fresh, true);
});

Deno.test("purity: long-absence module reads no clock (no Date.now / new Date())", async () => {
  const src = await Deno.readTextFile(
    new URL("./long-absence.ts", import.meta.url),
  );
  assertEquals(
    src.includes("Date.now"),
    false,
    "module must not call Date.now — gap is computed from injected Dates",
  );
  // `new Date(` would be a clock read only with no args; the module takes
  // Dates as inputs and never constructs one. Assert it constructs none.
  assertEquals(
    src.includes("new Date("),
    false,
    "module must not construct Dates — both endpoints are injected",
  );
  // Sanity: the trigger-semantics comment naming the client cue is present.
  assertStringIncludes(src, "requiresReturnPhaseOverride");
});
