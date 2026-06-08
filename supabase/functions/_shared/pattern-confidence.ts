// Project Apex — pattern-axis confidence advancement rule (#285, Part of #166).
//
// Per ADR-0020 §"Per-axis gate table": the pattern axis matures on a session
// count plus a real (data-backed) progression-trend verdict. This pure helper
// computes the PROPOSED next confidence state; the caller routes it through
// `monotonicAdvance` (confidence-lifecycle.ts).
//
// Pattern `.established` is the highest-value transition: at ≥4 of 6 major
// patterns it flips the client-derived `isReadyForCalibrationReview` (which
// #269 builds on). It must not fire on the bootstrap-default trend — hence the
// `trendEvaluable` gate (see `isTrendEvaluable` in plateau-verdict.ts).
//
// Pure: no I/O, no clock reads.

import type { ConfidenceWriteState } from "./confidence-lifecycle.ts";

/** → calibrating: enough trained sessions logged. */
export const PATTERN_CALIBRATING_MIN_SESSIONS = 3;
/** → established: session-count floor (bottom of ADR-0005's ~6-8 window). */
export const PATTERN_ESTABLISHED_MIN_SESSIONS = 6;

/**
 * Propose the pattern axis's confidence state:
 * - `.established` when `sessionCount ≥ 6` AND the trend verdict is data-backed
 *   (`trendEvaluable` — at least one plateau track has enough observations).
 * - `.calibrating` when `sessionCount ≥ 3`.
 * - `.bootstrapping` otherwise.
 *
 * Returns the PROPOSED state (pre-clamp); the caller applies `monotonicAdvance`.
 */
export function proposePatternConfidence(input: {
  sessionCount: number;
  trendEvaluable: boolean;
}): ConfidenceWriteState {
  const { sessionCount, trendEvaluable } = input;

  if (sessionCount >= PATTERN_ESTABLISHED_MIN_SESSIONS && trendEvaluable) {
    return "established";
  }
  if (sessionCount >= PATTERN_CALIBRATING_MIN_SESSIONS) {
    return "calibrating";
  }
  return "bootstrapping";
}
