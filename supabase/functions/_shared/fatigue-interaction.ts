// Project Apex — Phase 2 fatigue-interaction aggregator.
//
// Per ADR-0005 §"Fatigue interaction" + §"Fatigue interaction confidence:
// count-only vs count × consistency": cross-pattern carryover detected by
// pairing each pattern in the current session against every distinct pattern
// in the immediately-prior session, with rolling 10-obs `consistencyFactor`
// window, monotone `totalCount` for the count-factor hard cap at 15, and
// confidence = consistencyFactor × countFactor.
//
// Phase 1 ships the Swift `FatigueInteraction` value type at
// TraineeModelInteractions.swift:77-118 which consumes the data this slice
// produces. The math here mirrors that Swift implementation exactly, locked
// against drift via cross-platform fixtures at docs/fixtures/fatigue-interaction.json.
//
// Per #82 out-of-scope: this rule does NOT compute per-session
// performanceDeltaPct (orchestrator A12), surfacing (Phase 1 Swift digest at
// TraineeModelDigest.swift:62 already filters at confidence ≥ 0.7), or
// decide what counts as "immediately prior" during late-arrival scenarios
// (orchestrator handles via the trainee model's chronological view).

import {
  FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS,
  FATIGUE_INTERACTION_HARD_CAP_VALUE,
  FATIGUE_INTERACTION_MEAN_GUARD,
  FATIGUE_INTERACTION_OBSERVATION_WINDOW,
} from "./constants.ts";

export interface SessionPatternPerformance {
  sessionId: string;
  loggedAt: Date;
  pattern: string;
  /** Aggregated performance metric for this pattern in this session.
   *  Specifically: mean e1RM-delta-percent vs the user's recent baseline EWMA
   *  for that pattern. Negative = pattern under-performed.
   */
  performanceDeltaPct: number;
}

export interface FatigueObservation {
  fromPattern: string;
  toPattern: string;
  /** Performance delta-percent on toPattern in the session that
   *  immediately followed a session containing fromPattern.
   */
  delta: number;
  observedAt: Date;
}

export interface FatigueState {
  fromPattern: string;
  toPattern: string;
  /** Delta-percent observations, oldest first. The Swift-side
   *  FatigueInteraction value type stores `observations: [Double]` as the
   *  rolling window of last FATIGUE_INTERACTION_OBSERVATION_WINDOW (=10);
   *  appendObservations enforces that trim.
   */
  observations: number[];
  /** Monotone counter of all paired observations seen across history;
   *  feeds the count-factor hard-cap rule at FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS.
   */
  totalCount: number;
}

/**
 * Detect pairs from a sequence of session-pattern performances and emit
 * fatigue observations. Per ADR-0005, for each pattern P in `newSession`,
 * pair against every distinct pattern Q ≠ P in the immediately-prior session.
 *
 * `priorSession === null` (first-ever session) → no observations.
 *
 * Iteration order: priorSession.patterns then newSession.patterns, both
 * sorted by MovementPattern string value lexicographically. This ordering
 * is convention-only (any deterministic order satisfies the determinism
 * requirement); pinned for stable test fixtures.
 *
 * `delta` on each observation = `performanceDeltaPct` of the *to* pattern
 * in `newSession`. `observedAt` = `newSession[0].loggedAt` (all entries in a
 * session share the session's logged-at timestamp; the first entry is read
 * as the session timestamp source).
 */
export function detectFatigueObservations(
  newSession: SessionPatternPerformance[],
  priorSession: SessionPatternPerformance[] | null,
): FatigueObservation[] {
  if (priorSession === null) return [];
  if (newSession.length === 0) return [];

  const sortedPrior = [...priorSession].sort((a, b) =>
    a.pattern < b.pattern ? -1 : a.pattern > b.pattern ? 1 : 0
  );
  const sortedNew = [...newSession].sort((a, b) =>
    a.pattern < b.pattern ? -1 : a.pattern > b.pattern ? 1 : 0
  );
  const observedAt = newSession[0].loggedAt;

  const out: FatigueObservation[] = [];
  for (const q of sortedPrior) {
    for (const p of sortedNew) {
      if (q.pattern === p.pattern) continue; // Q ≠ P
      out.push({
        fromPattern: q.pattern,
        toPattern: p.pattern,
        delta: p.performanceDeltaPct,
        observedAt,
      });
    }
  }
  return out;
}

/**
 * Append observations to per-pair state. New (fromPattern, toPattern) keys
 * create a new state entry; existing keys append to their observations and
 * increment totalCount. The observations window is trimmed to the last
 * FATIGUE_INTERACTION_OBSERVATION_WINDOW (=10) entries — totalCount is
 * monotone and is NOT bounded by the window.
 */
export function appendObservations(
  states: FatigueState[],
  newObservations: FatigueObservation[],
): FatigueState[] {
  const out: FatigueState[] = states.map((s) => ({
    ...s,
    observations: [...s.observations],
  }));
  for (const obs of newObservations) {
    const existing = out.find(
      (s) => s.fromPattern === obs.fromPattern && s.toPattern === obs.toPattern,
    );
    if (existing) {
      existing.observations.push(obs.delta);
      if (
        existing.observations.length > FATIGUE_INTERACTION_OBSERVATION_WINDOW
      ) {
        existing.observations = existing.observations.slice(
          -FATIGUE_INTERACTION_OBSERVATION_WINDOW,
        );
      }
      existing.totalCount += 1;
    } else {
      out.push({
        fromPattern: obs.fromPattern,
        toPattern: obs.toPattern,
        observations: [obs.delta],
        totalCount: 1,
      });
    }
  }
  return out;
}

/**
 * Re-implementation of consistencyFactor / countFactor / confidence per
 * ADR-0005, mirroring Swift `FatigueInteraction` at
 * TraineeModelInteractions.swift:98-117. Cross-platform parity is locked
 * by docs/fixtures/fatigue-interaction.json.
 *
 * The Swift digest filter at TraineeModelDigest.swift:62 surfaces interactions
 * at confidence ≥ FATIGUE_INTERACTION_SURFACE_THRESHOLD (=0.7); this rule
 * does not perform that filter (out of scope per #82).
 */
export function fatigueConfidence(state: FatigueState): {
  consistencyFactor: number;
  countFactor: number;
  confidence: number;
} {
  const recent = state.observations.slice(
    -FATIGUE_INTERACTION_OBSERVATION_WINDOW,
  );
  let consistencyFactor = 0;
  if (recent.length >= 2) {
    const mean = recent.reduce((a, b) => a + b, 0) / recent.length;
    // Guard at FATIGUE_INTERACTION_MEAN_GUARD (=0.001) prevents divide-by-zero
    // when mean is near zero. The guard establishes a *floor* on the
    // denominator; consistencyFactor lands near 0 only when stddev > absMean
    // (noise overruns the guarded denominator). For low-magnitude balanced
    // observations like [0.0001, -0.0001], the guard fires but the small
    // stddev keeps consistency high (≈0.9). The "near-zero consistency on
    // guard fire" intuition only holds when stddev itself is large relative
    // to the guard floor. Cycles 9a (guard fires + high consistency) and 9b
    // (clamp to zero when stddev > absMean) pin both behaviors.
    const absMean = Math.max(Math.abs(mean), FATIGUE_INTERACTION_MEAN_GUARD);
    const variance =
      recent.reduce((a, x) => a + (x - mean) ** 2, 0) / recent.length;
    const stddev = Math.sqrt(variance);
    const clamped = Math.max(0, Math.min(1, 1 - stddev / absMean));
    // Float boundary fixups matching Swift implementation
    // (TraineeModelInteractions.swift:106-107).
    if (Math.abs(clamped - 1) < 1e-12) consistencyFactor = 1;
    else if (Math.abs(clamped) < 1e-12) consistencyFactor = 0;
    else consistencyFactor = clamped;
  }
  const countFactor =
    state.totalCount >= FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS
      ? 1.0
      : FATIGUE_INTERACTION_HARD_CAP_VALUE;
  return {
    consistencyFactor,
    countFactor,
    confidence: consistencyFactor * countFactor,
  };
}
