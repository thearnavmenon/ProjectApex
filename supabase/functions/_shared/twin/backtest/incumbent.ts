// Project Apex — Athlete Twin backtest (ADR-0031, Phase 1 shadow).
//
// The incumbent forecaster: a byte-faithful replication of how production
// maintains per-exercise e1RM (applyPerExerciseRules in
// update-trainee-model/index.ts) driving the SAME ewma-engine the Edge
// Function calls. This is the null model the twin must beat.
//
//   - topSets accumulate ONLY intent=="top" sets with reps in 3..10
//     (validity window), stamped with the SESSION's logged_at, appended in
//     payload order, capped to the most recent TOP_SET_RETENTION_COUNT.
//   - e1rmCurrent = computeE1RM(topSets, longAbsence, preGapCutoff) — the
//     standard EWMA (α = 0.333, last-5 window) unless a ≥28-day gap sits in
//     the retained window (long-absence re-anchor), exactly as prod.
//   - Weight-0 top sets (bodyweight movements logged at 0 kg) ARE appended,
//     exactly as prod does today — their e1RM of 0 drags the EWMA. The
//     harness also runs an "ewma-clean" variant that excludes them, so the
//     twin-vs-incumbent comparison is not won on that data-hygiene quirk.
//
// Forecast: predicted reps at load w = ρ_Epley · (ê/w − 1), the inversion
// of the same Epley formula the engine's e1RM rests on. The incumbent is a
// point forecaster; its CRPS equals its absolute error. The "dressed"
// variant wraps the point in a Gaussian whose sd is the running RMSE of its
// own past errors on that pattern (expanding window, cold-start default) —
// giving the incumbent a fair distributional entry for CRPS/coverage.
//
// Pure: no I/O, no clock reads, no randomness.

import {
  computeE1RM,
  type TopSet,
} from "../../ewma-engine.ts";
import { mostRecentAbsenceCutoff } from "../../long-absence.ts";
import { TOP_SET_RETENTION_COUNT } from "../../constants.ts";

export interface IncumbentSetInput {
  exerciseId: string; // canonical
  weightKg: number;
  reps: number;
  intent: string;
}

export interface IncumbentState {
  /** Per-exercise retained top sets, newest last (prod shape). */
  topSets: Map<string, TopSet[]>;
}

export function newIncumbentState(): IncumbentState {
  return { topSets: new Map() };
}

/**
 * Apply one session's sets, mirroring applyPerExerciseRules: append valid
 * top-intent sets stamped with the session timestamp, cap retention.
 * `excludeZeroWeight` switches on the "ewma-clean" variant.
 */
export function incumbentApplySession(
  state: IncumbentState,
  sets: IncumbentSetInput[],
  sessionLoggedAt: Date,
  sessionId: string,
  excludeZeroWeight: boolean,
): void {
  for (const s of sets) {
    if (s.intent !== "top") continue;
    if (s.reps < 3 || s.reps > 10) continue;
    if (excludeZeroWeight && !(s.weightKg > 0)) continue;
    const list = state.topSets.get(s.exerciseId) ?? [];
    list.push({
      weight: s.weightKg,
      reps: s.reps,
      loggedAt: sessionLoggedAt,
      sessionId,
    });
    if (list.length > TOP_SET_RETENTION_COUNT) {
      list.splice(0, list.length - TOP_SET_RETENTION_COUNT);
    }
    state.topSets.set(s.exerciseId, list);
  }
}

/**
 * Current e1RM for an exercise exactly as prod computes it, or null when
 * the exercise has no valid history.
 */
export function incumbentE1rm(
  state: IncumbentState,
  exerciseId: string,
): number | null {
  const topSets = state.topSets.get(exerciseId);
  if (!topSets || topSets.length === 0) return null;
  const preGapCutoff = mostRecentAbsenceCutoff(topSets);
  const longAbsenceFires = preGapCutoff !== null;
  return computeE1RM(topSets, longAbsenceFires, preGapCutoff ?? undefined);
}

/**
 * Point forecast of performed reps at `weightKg`: inverse Epley on the
 * current e1RM. Null when no estimate exists or the load is non-positive.
 * Clamped at 0 (the engine cannot predict negative reps).
 */
export function incumbentForecastReps(
  state: IncumbentState,
  exerciseId: string,
  weightKg: number,
): number | null {
  if (!(weightKg > 0)) return null;
  const e1rm = incumbentE1rm(state, exerciseId);
  if (e1rm === null) return null;
  return Math.max(0, 30 * (e1rm / weightKg - 1));
}
