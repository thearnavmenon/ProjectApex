// Project Apex — exercise-axis confidence advancement rule (#283, Part of #166).
//
// Per ADR-0020 §"Per-axis gate table": the exercise axis matures on capability
// stability. This pure helper computes the PROPOSED next confidence state from
// an exercise's accumulated signal; the caller routes it through
// `monotonicAdvance` (confidence-lifecycle.ts) so it never regresses or skips.
//
// Pure: no I/O, no clock reads.

import type { ConfidenceWriteState } from "./confidence-lifecycle.ts";
import {
  TOP_SET_REP_VALIDITY_MAX,
  TOP_SET_REP_VALIDITY_MIN,
} from "./constants.ts";
import { type TopSet, transitionModeMean } from "./ewma-engine.ts";

/** → calibrating: enough sessions logged. */
export const EXERCISE_CALIBRATING_MIN_SESSIONS = 3;
/** → calibrating: enough validity-filtered top sets that the e1RM EWMA is genuine. */
export const EXERCISE_CALIBRATING_MIN_TOP_SETS = 3;
/** → established: session-count floor (well inside the ~6-8 calibration window). */
export const EXERCISE_ESTABLISHED_MIN_SESSIONS = 8;
/** → established: e1RM stability is measured over the last N distinct sessions. */
export const EXERCISE_ESTABLISHED_CV_WINDOW = 5;
/** → established: require this many distinct valid e1RM sessions in the window. */
export const EXERCISE_ESTABLISHED_MIN_DISTINCT_SESSIONS = 4;
/** → established: e1RM coefficient of variation must be at or below this. */
export const EXERCISE_ESTABLISHED_MAX_CV = 0.075;

/**
 * Propose the exercise axis's confidence state from its accumulated signal:
 * - `.established` when `sessionCount ≥ 8` AND the e1RM is stable (coefficient
 *   of variation of heaviest-e1RM-per-session over the last 5 distinct sessions
 *   ≤ 7.5%), guarded by ≥4 distinct valid e1RM sessions.
 * - `.calibrating` when `sessionCount ≥ 3` AND there are ≥3 validity-filtered
 *   top sets (so the EWMA reflects real data, not a single lift).
 * - `.bootstrapping` otherwise.
 *
 * Returns the PROPOSED state (pre-clamp); the caller applies `monotonicAdvance`.
 */
export function proposeExerciseConfidence(input: {
  sessionCount: number;
  topSets: TopSet[];
}): ConfidenceWriteState {
  const { sessionCount, topSets } = input;

  if (sessionCount >= EXERCISE_ESTABLISHED_MIN_SESSIONS) {
    const stability = transitionModeMean(topSets, EXERCISE_ESTABLISHED_CV_WINDOW);
    if (
      stability !== null &&
      stability.sessionCount >= EXERCISE_ESTABLISHED_MIN_DISTINCT_SESSIONS &&
      stability.mean > 0
    ) {
      const cv = Math.sqrt(stability.variance) / stability.mean;
      if (cv <= EXERCISE_ESTABLISHED_MAX_CV) return "established";
    }
  }

  const validTopSetCount = topSets.filter(
    (s) => s.reps >= TOP_SET_REP_VALIDITY_MIN && s.reps <= TOP_SET_REP_VALIDITY_MAX,
  ).length;
  if (
    sessionCount >= EXERCISE_CALIBRATING_MIN_SESSIONS &&
    validTopSetCount >= EXERCISE_CALIBRATING_MIN_TOP_SETS
  ) {
    return "calibrating";
  }

  return "bootstrapping";
}
