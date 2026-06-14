// Project Apex — Phase 2 EWMA engine tests.
//
// Per ADR-0005 §"e1RM update: EWMA": EWMA over last 5 valid top sets
// (validity 3..10 reps, α = 0.333), with transition-mode collapse to
// N=3 plain mean over recent SESSIONS (heaviest top set per session,
// sample variance with Bessel correction).
//
// Each test name pins the originating ADR so a failure surfaces the
// rule the change touches. Test ordering matches the per-behavior TDD
// cycle list approved on the slice plan.
//
// Run locally:
//   deno test supabase/functions/_shared/ewma-engine_test.ts

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  computeE1RM,
  e1rm,
  ewmaE1RM,
  type TopSet,
  transitionModeMean,
} from "./ewma-engine.ts";
import { EWMA_ALPHA } from "./constants.ts";

// Test fixture builder. `daysAgo` is just a sortable day offset; sessionId
// defaults to one-per-day so tests that don't care about session boundaries
// (ewmaE1RM cases) get distinct sessions for free, and tests that DO care
// (transitionModeMean cases) override it to group sets into a session.
const mk = (
  weight: number,
  reps: number,
  daysAgo: number,
  sessionId: string = `s${daysAgo}`,
): TopSet => ({
  weight,
  reps,
  loggedAt: new Date(2026, 0, 1 + daysAgo),
  sessionId,
});

Deno.test("ADR-0005: ewmaE1RM([]) returns null (no top sets to weight)", () => {
  assertEquals(ewmaE1RM([]), null);
});

Deno.test("ADR-0005: all reps out of 3..10 validity → null", () => {
  // reps=2 below TOP_SET_REP_VALIDITY_MIN, reps=11 above
  // TOP_SET_REP_VALIDITY_MAX → both filtered, no observations remain.
  assertEquals(ewmaE1RM([mk(100, 2, 0), mk(100, 11, 1)]), null);
});

Deno.test("ADR-0005: single valid top set → that set's Epley e1RM (EWMA degenerates to single value)", () => {
  // Epley: weight × (1 + reps / 30) = 100 × (1 + 5/30) = 116.666…
  const result = ewmaE1RM([mk(100, 5, 0)]);
  assertAlmostEquals(result!, 100 * (1 + 5 / 30), 1e-9);
});

Deno.test("ADR-0005: EWMA α is 0.333 (single-step formula on 2 sets, oldest-first input)", () => {
  // Input ordered oldest → newest. Single-step EWMA collapses to:
  //   ema = α × newer + (1 − α) × older
  // (Initialize at older; one update step weighted at α toward newer.)
  const older = mk(100, 5, 0);
  const newer = mk(110, 5, 1);
  const expected = EWMA_ALPHA * e1rm(110, 5)! +
    (1 - EWMA_ALPHA) * e1rm(100, 5)!;
  assertAlmostEquals(ewmaE1RM([older, newer])!, expected, 1e-9);
});

Deno.test("ADR-0005: filter-first then suffix — invalid sets do not shrink the EWMA window", () => {
  // 7 raw sets with one invalid (reps=11) interleaved at index 4.
  // Filter-first (CORRECT, locked here): filtered=[v1..v6] (6 valid),
  //   suffix-5 = [v2..v6] → 5 valid contribute, EWMA initialized at v2.
  // Suffix-then-filter (INCORRECT divergent interpretation): raw suffix-5
  //   = [v3, INVALID, v4, v5, v6]; filtering drops INVALID, leaving 4
  //   valid; EWMA initialized at v3. v2 never contributes.
  // The two interpretations only diverge when ≥6 raw sets exist with at
  // least one invalid interleaved such that filtered.length > 5; this
  // case satisfies that condition by construction (110kg distinctive at v2).
  const raw: TopSet[] = [
    mk(1000, 5, 0), // v1 — beyond suffix under both interpretations
    mk(110, 5, 1), // v2 — only contributes under filter-first
    mk(100, 5, 2), // v3
    mk(100, 5, 3), // v4
    mk(100, 11, 4), // INVALID
    mk(100, 5, 5), // v5
    mk(100, 5, 6), // v6
  ];
  // Closed-form filter-first expectation: window = [v2..v6] e1RMs.
  const w = [110, 100, 100, 100, 100].map((kg) => e1rm(kg, 5)!);
  const a = EWMA_ALPHA;
  const expected = Math.pow(1 - a, 4) * w[0] +
    a * Math.pow(1 - a, 3) * w[1] +
    a * Math.pow(1 - a, 2) * w[2] +
    a * (1 - a) * w[3] +
    a * w[4];
  assertAlmostEquals(ewmaE1RM(raw)!, expected, 1e-9);
});

Deno.test("ADR-0005: EWMA window is suffix-of-5 — older sets beyond the window do not contribute", () => {
  // Oldest set is 1000kg×5 (a wildly high outlier). The remaining 5 are
  // 100×5. If the window were 6 (or no window), the outlier would pull
  // the EWMA up via the (1−α)⁵ tail weight. With suffix-of-5 the outlier
  // is dropped and the EWMA over 5 identical 100×5 sets equals e1rm(100,5).
  const sets = [
    mk(1000, 5, 0),
    mk(100, 5, 1),
    mk(100, 5, 2),
    mk(100, 5, 3),
    mk(100, 5, 4),
    mk(100, 5, 5),
  ];
  assertAlmostEquals(ewmaE1RM(sets)!, e1rm(100, 5)!, 1e-9);
});

Deno.test("ADR-0005: transition-mode mean over 3 sessions — plain mean + Bessel-corrected sample variance (n−1 denominator)", () => {
  // Three sessions, one valid top set each, chronologically ordered.
  const sets = [
    mk(100, 5, 0, "session-A"),
    mk(110, 5, 1, "session-B"),
    mk(120, 5, 2, "session-C"),
  ];
  const e = sets.map((s) => e1rm(s.weight, s.reps)!);
  const expectedMean = (e[0] + e[1] + e[2]) / 3;
  const expectedVariance =
    ((e[0] - expectedMean) ** 2 + (e[1] - expectedMean) ** 2 +
      (e[2] - expectedMean) ** 2) / (3 - 1);

  const result = transitionModeMean(sets);
  assertEquals(result?.sessionCount, 3);
  assertAlmostEquals(result!.mean, expectedMean, 1e-9);
  assertAlmostEquals(result!.variance, expectedVariance, 1e-9);
});

Deno.test("ADR-0005: transition-mode 4 sessions → suffix-3 (only the 3 most recent contribute)", () => {
  // Oldest session is a 1000kg outlier; if not dropped from the window
  // the mean would skew an order of magnitude high. Suffix-3 → mean is
  // computed over sessions B, C, D only.
  const sets = [
    mk(1000, 5, 0, "session-A"), // dropped under suffix-3
    mk(100, 5, 1, "session-B"),
    mk(110, 5, 2, "session-C"),
    mk(120, 5, 3, "session-D"),
  ];
  const e = [e1rm(100, 5)!, e1rm(110, 5)!, e1rm(120, 5)!];
  const expectedMean = (e[0] + e[1] + e[2]) / 3;
  const expectedVariance =
    ((e[0] - expectedMean) ** 2 + (e[1] - expectedMean) ** 2 +
      (e[2] - expectedMean) ** 2) / (3 - 1);

  const result = transitionModeMean(sets);
  assertEquals(result?.sessionCount, 3);
  assertAlmostEquals(result!.mean, expectedMean, 1e-9);
  assertAlmostEquals(result!.variance, expectedVariance, 1e-9);
});

Deno.test("ADR-0005: computeE1RM(inTransitionMode=false) delegates to ewmaE1RM (standard 5-set window)", () => {
  const sets = [
    mk(100, 5, 0),
    mk(102, 5, 1),
    mk(104, 5, 2),
    mk(106, 5, 3),
    mk(108, 5, 4),
  ];
  assertAlmostEquals(computeE1RM(sets, false)!, ewmaE1RM(sets)!, 1e-9);
});

Deno.test("ADR-0005: computeE1RM(inTransitionMode=true) returns transitionModeMean.mean (drops variance/sessionCount — orchestrator only needs central tendency here)", () => {
  const sets = [
    mk(100, 5, 0, "session-A"),
    mk(110, 5, 1, "session-B"),
    mk(120, 5, 2, "session-C"),
  ];
  const tm = transitionModeMean(sets);
  assertAlmostEquals(computeE1RM(sets, true)!, tm!.mean, 1e-9);
});

Deno.test("ADR-0005: transition-mode multi-set session → heaviest e1RM per session is used (not first-logged)", () => {
  // Two sets in the same session: 80×5 (logged first) and 120×5 (logged
  // later, heavier). Heaviest-e1RM-per-session selects the 120×5.
  // First-encounter selection would pick 80×5 and fail this test.
  const sets = [
    mk(80, 5, 0, "session-A"),
    mk(120, 5, 0, "session-A"),
  ];
  const result = transitionModeMean(sets);
  assertEquals(result?.sessionCount, 1);
  assertAlmostEquals(result!.mean, e1rm(120, 5)!, 1e-9);
  assertEquals(result?.variance, 0);
});

Deno.test("ADR-0005: transition-mode mean over 1 session — variance=0 is a convention (n=1 special case, not derived from Bessel-corrected formula which would be 0/0)", () => {
  // With one session the sample-variance numerator is 0 (the single
  // observation IS the mean) and the n−1 denominator is 0, so the
  // formula yields 0/0. Implementations must special-case n=1 to
  // return variance = 0; this test pins that convention.
  const result = transitionModeMean([mk(100, 5, 0, "session-A")]);
  assertEquals(result?.sessionCount, 1);
  assertAlmostEquals(result!.mean, e1rm(100, 5)!, 1e-9);
  assertEquals(result?.variance, 0);
});

Deno.test("ADR-0005: EWMA over 5-set window applies α weighting across full window (oldest → newest)", () => {
  // Closed-form check (independent of the iterative implementation):
  //   ema = (1−α)⁴ x₀ + α(1−α)³ x₁ + α(1−α)² x₂ + α(1−α) x₃ + α x₄
  // Weights of expanding the recurrence ema_n = α x_n + (1−α) ema_{n-1}.
  const sets = [
    mk(100, 5, 0),
    mk(102, 5, 1),
    mk(104, 5, 2),
    mk(106, 5, 3),
    mk(108, 5, 4),
  ];
  const e = sets.map((s) => e1rm(s.weight, s.reps)!);
  const a = EWMA_ALPHA;
  const expected = Math.pow(1 - a, 4) * e[0] +
    a * Math.pow(1 - a, 3) * e[1] +
    a * Math.pow(1 - a, 2) * e[2] +
    a * (1 - a) * e[3] +
    a * e[4];
  assertAlmostEquals(ewmaE1RM(sets)!, expected, 1e-9);
});

// ─── Slice 2 (#369 long-absence re-anchor): preGapCutoff trimming ────────────
//
// When a lifter returns after a long break the transition-mode window must
// average only POST-RETURN sessions. Without trimming, the last-3 plain mean
// pulls in pre-gap (stale, inflated) sessions and moves the estimate the WRONG
// way. `preGapCutoff` drops any session whose representative loggedAt is at or
// before the gap boundary BEFORE the N=3 windowing.

// 6-week-gap worked scenario (Epley e1RM = weight × (1 + reps/30)):
//   S1=100×5  (116.67)  day 0
//   S2=100×5  (116.67)  day 1
//   S3=102.5×5(119.58)  day 2
//   S4=102.5×5(119.58)  day 3
//   S5=105×5  (122.50)  day 4   ← last pre-gap session
//   ...6-week gap...
//   S6=95×5   (110.83)  day 46  ← return session (decayed)
const longAbsenceScenario = (): TopSet[] => [
  mk(100, 5, 0, "S1"),
  mk(100, 5, 1, "S2"),
  mk(102.5, 5, 2, "S3"),
  mk(102.5, 5, 3, "S4"),
  mk(105, 5, 4, "S5"),
  mk(95, 5, 46, "S6"),
];

Deno.test("Slice 2: preGapCutoff trims pre-gap sessions → only post-return S6 survives (mean ≈ 110.83, n=1, var=0)", () => {
  const sets = longAbsenceScenario();
  // Cutoff at the S5 boundary: S5 is logged at day 4 (loggedAt time T5); a
  // cutoff equal to T5 drops S5 (at-or-before) and every earlier session,
  // leaving only S6.
  const s5LoggedAt = sets[4].loggedAt;
  const result = transitionModeMean(sets, undefined, s5LoggedAt);
  assertEquals(result?.sessionCount, 1, "only the return session survives");
  assertAlmostEquals(result!.mean, e1rm(95, 5)!, 1e-9); // 110.833…
  assertAlmostEquals(result!.mean, 110.833, 1e-3); // pinned numeric form
  assertEquals(result?.variance, 0, "single surviving session → variance 0");
});

Deno.test("Slice 2: WITHOUT trim the last-3 plain mean is {S4,S5,S6} ≈ 117.64 — why the trim is MANDATORY", () => {
  // Contrast assertion: the untrimmed last-3 window pulls in the two stale
  // pre-gap sessions S4 and S5, dragging the mean UP to ~117.64 — the wrong
  // direction for a returner whose actual return e1RM is 110.83. This is the
  // proof that the plain untrimmed mean moves the estimate the wrong way.
  const sets = longAbsenceScenario();
  const untrimmed = transitionModeMean(sets); // no preGapCutoff
  const expected = (e1rm(102.5, 5)! + e1rm(105, 5)! + e1rm(95, 5)!) / 3;
  assertEquals(untrimmed?.sessionCount, 3);
  assertAlmostEquals(untrimmed!.mean, expected, 1e-9);
  assertAlmostEquals(untrimmed!.mean, 117.639, 1e-3);
});

Deno.test("Slice 2: cutoff is at-or-before (sessions logged exactly AT the boundary are dropped)", () => {
  // A return session logged exactly AT the cutoff is NOT post-return — it is
  // pre-gap and must be dropped. Two sessions on the same day, cutoff at that
  // day's loggedAt → both dropped, only the strictly-later one survives.
  const sets: TopSet[] = [
    mk(120, 5, 0, "old"),
    mk(95, 5, 10, "back"),
  ];
  const cutoff = sets[0].loggedAt; // == "old"'s loggedAt
  const result = transitionModeMean(sets, undefined, cutoff);
  assertEquals(result?.sessionCount, 1, "the at-boundary session is dropped");
  assertAlmostEquals(result!.mean, e1rm(95, 5)!, 1e-9);
});

Deno.test("Slice 2: preGapCutoff uses the heaviest (representative) set's loggedAt per session", () => {
  // A multi-set session straddling the cutoff: its representative is the
  // heaviest set. Here both sets share the session's loggedAt (sessions are
  // logged atomically), so the whole session is kept or dropped together.
  const sets: TopSet[] = [
    mk(100, 5, 0, "pre"),
    mk(80, 5, 20, "back"), // logged first within the return session
    mk(110, 5, 20, "back"), // heavier, same session
  ];
  const cutoff = sets[0].loggedAt;
  const result = transitionModeMean(sets, undefined, cutoff);
  assertEquals(result?.sessionCount, 1);
  // Heaviest-per-session selects 110×5 for the surviving "back" session.
  assertAlmostEquals(result!.mean, e1rm(110, 5)!, 1e-9);
});

Deno.test("Slice 2: ABSENT preGapCutoff → byte-identical to today (backward-compat)", () => {
  // Every pre-Slice-2 transition-mode call passes no cutoff. Assert the result
  // is identical to the no-arg form across a representative input.
  const sets = [
    mk(100, 5, 0, "session-A"),
    mk(110, 5, 1, "session-B"),
    mk(120, 5, 2, "session-C"),
    mk(130, 5, 3, "session-D"),
  ];
  const withoutArg = transitionModeMean(sets);
  const withUndefinedCutoff = transitionModeMean(sets, undefined, undefined);
  assertEquals(withUndefinedCutoff?.sessionCount, withoutArg?.sessionCount);
  assertAlmostEquals(withUndefinedCutoff!.mean, withoutArg!.mean, 1e-12);
  assertAlmostEquals(
    withUndefinedCutoff!.variance,
    withoutArg!.variance,
    1e-12,
  );
});

Deno.test("Slice 2: preGapCutoff that drops everything → null (no surviving sessions)", () => {
  const sets = [mk(100, 5, 0, "only")];
  // Cutoff strictly after the only session → it is dropped.
  const cutoff = new Date(sets[0].loggedAt.getTime() + 1);
  assertEquals(transitionModeMean(sets, undefined, cutoff), null);
});

Deno.test("Slice 2: computeE1RM passes preGapCutoff through to transitionModeMean (transition branch)", () => {
  const sets = longAbsenceScenario();
  const s5LoggedAt = sets[4].loggedAt;
  // Transition branch with cutoff → trimmed mean (110.83), NOT the EWMA
  // (~116.74) and NOT the no-trim last-3 mean (~117.64).
  const trimmed = computeE1RM(sets, true, s5LoggedAt);
  assertAlmostEquals(trimmed!, e1rm(95, 5)!, 1e-9);
  assertAlmostEquals(trimmed!, 110.833, 1e-3);
});

Deno.test("Slice 2: computeE1RM(inTransitionMode=false) ignores preGapCutoff (EWMA branch unaffected)", () => {
  const sets = longAbsenceScenario();
  const s5LoggedAt = sets[4].loggedAt;
  // The standard branch never trims — a cutoff arg passed alongside
  // inTransitionMode=false is inert.
  assertAlmostEquals(
    computeE1RM(sets, false, s5LoggedAt)!,
    ewmaE1RM(sets)!,
    1e-12,
  );
});
