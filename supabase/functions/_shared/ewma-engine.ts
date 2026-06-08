// Project Apex — Phase 2 EWMA engine.
//
// Per ADR-0005 §"e1RM update: EWMA": exponentially weighted moving
// average over the last 5 valid top sets (validity 3..10 reps,
// α = 0.333), with a transition-mode collapse to N=3 plain mean over
// recent SESSIONS — heaviest top set per session, sample variance with
// Bessel correction — when a per-axis confidence has just transitioned
// to `.established` or another ADR-0005 trigger fires.
//
// Pure: no I/O, no clock reads.

import {
  EWMA_ALPHA,
  EWMA_WINDOW_N,
  TOP_SET_REP_VALIDITY_MAX,
  TOP_SET_REP_VALIDITY_MIN,
  TRANSITION_MODE_WINDOW_N,
} from "./constants.ts";

export interface TopSet {
  weight: number; // kg
  reps: number;
  loggedAt: Date;
  sessionId: string;
}

/**
 * Epley estimated 1RM: `weight × (1 + reps / 30)`. Returns null when
 * reps fall outside the ADR-0005 validity range (3..10) — the formula
 * is unreliable below 3 (too rep-spotty) and above 10 (cardiovascular
 * limit dominates).
 */
export function e1rm(weight: number, reps: number): number | null {
  if (reps < TOP_SET_REP_VALIDITY_MIN || reps > TOP_SET_REP_VALIDITY_MAX) {
    return null;
  }
  return weight * (1 + reps / 30);
}

/**
 * EWMA over last 5 valid top sets (α = 0.333) per ADR-0005.
 *
 * Filtering precedes windowing: the validity gate (3..10 reps) is
 * applied first, then the suffix-of-5 is taken from the filtered list.
 * This means the EWMA is over 5 valid observations, not over 5 raw
 * inputs of which some may be invalid.
 *
 * @param topSets - chronologically ordered (oldest first); filtered by
 *                 rep validity, then suffix-of-5 contributes.
 * @returns null when no valid top sets exist.
 */
export function ewmaE1RM(topSets: TopSet[]): number | null {
  const valid = topSets.filter(
    (s) => s.reps >= TOP_SET_REP_VALIDITY_MIN &&
      s.reps <= TOP_SET_REP_VALIDITY_MAX,
  );
  if (valid.length === 0) return null;
  const window = valid.slice(-EWMA_WINDOW_N);
  // Initialize at oldest in window; iterate forward, weighting α toward newer.
  let ema = e1rm(window[0].weight, window[0].reps)!;
  for (let i = 1; i < window.length; i++) {
    ema = EWMA_ALPHA * e1rm(window[i].weight, window[i].reps)! +
      (1 - EWMA_ALPHA) * ema;
  }
  return ema;
}

/**
 * Result of the transition-mode plain-mean computation per ADR-0005.
 *
 * `variance` is sample variance with Bessel correction (n−1 denominator)
 * across the heaviest e1RM per session. For `sessionCount === 1` the
 * Bessel formula is undefined (0/0); the convention returns 0 in that
 * case (the test naming this convention pins the special-case behavior).
 */
export interface TransitionModeResult {
  mean: number;
  variance: number;
  sessionCount: number;
}

/**
 * Transition-mode mean per ADR-0005: plain mean of the heaviest e1RM per
 * session across the most recent `window` SESSIONS (not top sets), with
 * sample variance using Bessel correction.
 *
 * `window` defaults to `TRANSITION_MODE_WINDOW_N` (=3 per ADR-0005's
 * transition-mode collapse). The exercise confidence gate (ADR-0020) passes
 * a wider window to measure e1RM stability over more sessions; the variance
 * it reads is the same Bessel-corrected sample variance.
 *
 * @returns null when no valid top sets exist.
 */
export function transitionModeMean(
  topSets: TopSet[],
  window: number = TRANSITION_MODE_WINDOW_N,
): TransitionModeResult | null {
  const valid = topSets.filter(
    (s) => s.reps >= TOP_SET_REP_VALIDITY_MIN &&
      s.reps <= TOP_SET_REP_VALIDITY_MAX,
  );
  if (valid.length === 0) return null;
  // Group by sessionId in chronological insertion order, retaining the
  // heaviest e1RM per session (per ADR-0005: multi-set sessions in 5×5
  // programmes contribute their hardest top set, not their first).
  const sessionValues = new Map<string, number>();
  for (const s of valid) {
    const e = e1rm(s.weight, s.reps)!;
    const existing = sessionValues.get(s.sessionId);
    if (existing === undefined || e > existing) {
      sessionValues.set(s.sessionId, e);
    }
  }
  const values = Array.from(sessionValues.values()).slice(
    -window,
  );
  const n = values.length;
  const mean = values.reduce((a, b) => a + b, 0) / n;
  // Bessel-corrected sample variance; n=1 returns 0 by convention
  // (formula yields 0/0 — see TransitionModeResult docstring).
  const variance = n === 1
    ? 0
    : values.reduce((acc, v) => acc + (v - mean) ** 2, 0) / (n - 1);
  return { mean, variance, sessionCount: n };
}

/**
 * Single entry point used by the orchestrator. Branches on
 * `inTransitionMode`: true → transition-mode mean (collapsed N=3 plain
 * mean over sessions); false → standard EWMA over the N=5 valid-top-set
 * window. Returns just the central-tendency number — callers needing
 * the variance/sessionCount must call `transitionModeMean` directly.
 */
export function computeE1RM(
  topSets: TopSet[],
  inTransitionMode: boolean,
): number | null {
  if (inTransitionMode) {
    return transitionModeMean(topSets)?.mean ?? null;
  }
  return ewmaE1RM(topSets);
}
