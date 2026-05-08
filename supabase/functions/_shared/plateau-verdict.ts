// Project Apex — Phase 2 plateau-verdict module.
//
// Per ADR-0009 (hybrid plateau verdict, accepted 2026-05-07; amended
// 2026-05-07 for muscle-level aggregation): this module computes
// per-pattern `ProgressionTrend` from a hybrid two-track verdict
// combining e1RM EWMA flatness with weekly-volume-load flatness, and
// aggregates upward to `MuscleProfile.stagnationStatus` via
// worst-across-patterns.
//
// Architectural commitment from ADR-0005: the trainee model is hybrid
// strength/hypertrophy. The verdict surface MUST not silently flag
// volume-shifted progression (e1RM stuck while volume rising) as
// plateau — that's the v1 → v2 shift this slice operationalizes.
//
// Pure: no I/O, no clock reads. e1RM values are consumed (computed by
// A6's EWMA engine in #77), not recomputed here.

import {
  DECLINE_E1RM_DROP_THRESHOLD,
  DECLINE_EFFORT_GATE_RPE,
  DECLINE_VOLUME_DROP_THRESHOLD,
  FREQUENCY_SCALED_WINDOW_CADENCE_THRESHOLD_DAYS,
  OVERREACH_VOLUME_LOAD_RATIO,
  PLATEAU_E1RM_SPREAD_THRESHOLD,
  PLATEAU_EFFORT_GATE_RPE,
  PLATEAU_VOLUME_LOAD_SPREAD_THRESHOLD,
} from "./constants.ts";

const VOLUME_LOAD_PLATEAU_WINDOW_N = 4;
const VOLUME_LOAD_OVERREACH_TRAILING_WINDOW_N = 4;

export type ProgressionTrend = "progressing" | "plateaued" | "declining";
type TrackVerdict = "improving" | "flat" | "declining";

export interface E1RMSession {
  loggedAt: Date;
  e1rm: number;
  avgRPE: number | null;
}

/**
 * Frequency-scaled window per ADR-0009 §Tracks: 3 sessions when the
 * pattern's cadence is ≤ 3.5d (≥2×/week training), 4 sessions when
 * cadence > 3.5d (≤1×/week — needs an extra session to compensate
 * for the wider between-session noise floor). Nil cadence (no
 * derived value yet) defaults to the 3-session window.
 */
const windowSize = (cadenceDays: number | null): number => {
  if (cadenceDays === null) return 3;
  return cadenceDays <= FREQUENCY_SCALED_WINDOW_CADENCE_THRESHOLD_DAYS ? 3 : 4;
};

/**
 * e1RM track per ADR-0009 §Tracks.
 *
 * Spread formula: `(max − min) / mean` over the e1RM values in the
 * frequency-scaled window — coefficient-of-range form, symmetric
 * (does not bias against the high or low tail of the window).
 */
export function e1rmTrack(
  sessions: E1RMSession[],
  cadenceDays: number | null,
): TrackVerdict {
  const baseN = windowSize(cadenceDays);
  if (sessions.length < baseN) return "improving";

  // Manual-log defence (ADR-0009 §"Plateau effort gate"): if any session
  // in the base window has nil avgRPE, defer firing until window+1
  // sessions are present. The evaluation window then expands to
  // window+1 (the extra data point participates in spread + gate).
  const baseWindow = sessions.slice(-baseN);
  const hasNilInBase = baseWindow.some((s) => s.avgRPE === null);
  if (hasNilInBase && sessions.length < baseN + 1) return "improving";
  const evalWindow = hasNilInBase ? sessions.slice(-(baseN + 1)) : baseWindow;

  const e1rms = evalWindow.map((s) => s.e1rm);
  const max = Math.max(...e1rms);
  const min = Math.min(...e1rms);
  const mean = e1rms.reduce((a, b) => a + b, 0) / e1rms.length;
  const spread = (max - min) / mean;

  const avgRPEs = evalWindow
    .map((s) => s.avgRPE)
    .filter((r): r is number => r !== null);
  // Gate behaviour:
  //   - All non-nil:        require mean(non-nil) < 8.0 to fire
  //   - Mixed (partial-nil): require mean(non-nil) < 8.0 to fire (Q3 refinement)
  //   - All nil (manual-log only at window+1): gate suspended, fire on spread alone
  const gatePassed = avgRPEs.length === 0
    ? true
    : (avgRPEs.reduce((a, b) => a + b, 0) / avgRPEs.length) <
      PLATEAU_EFFORT_GATE_RPE;

  // Decline rule (ADR-0009 §"Decline rules"): e1RM dropped ≥ 5% from
  // start to end of the window AND avgRPE ≥ 7 across the window.
  // Drops on low-RPE sessions are coasting, not decline — the gate
  // suppresses false-positives during light/recovery weeks.
  const start = e1rms[0];
  const end = e1rms[e1rms.length - 1];
  const drop = (start - end) / start;
  const declineEffortPasses = avgRPEs.length > 0 &&
    (avgRPEs.reduce((a, b) => a + b, 0) / avgRPEs.length) >=
      DECLINE_EFFORT_GATE_RPE;
  if (drop >= DECLINE_E1RM_DROP_THRESHOLD && declineEffortPasses) {
    return "declining";
  }

  if (spread <= PLATEAU_E1RM_SPREAD_THRESHOLD && gatePassed) return "flat";
  return "improving";
}

export interface VolumeLoadSession {
  loggedAt: Date;
  /** Σ weight × reps × sets for non-warmup sets per ADR-0009; one weekly aggregate. */
  weeklyVolumeLoad: number;
  avgRPE: number | null;
}

/**
 * Volume-load track per ADR-0009 §Tracks. Operates on weekly aggregates
 * (the orchestrator computes `weeklyVolumeLoad` per ADR-0002's 7-event
 * windowing; this slice consumes the values).
 *
 * Plateau: spread ≤ 5% across the trailing 4 weeks AND avgRPE < 8.0.
 */
export function volumeLoadTrack(sessions: VolumeLoadSession[]): TrackVerdict {
  if (sessions.length < VOLUME_LOAD_PLATEAU_WINDOW_N) return "improving";
  const window = sessions.slice(-VOLUME_LOAD_PLATEAU_WINDOW_N);

  const vls = window.map((s) => s.weeklyVolumeLoad);
  const max = Math.max(...vls);
  const min = Math.min(...vls);
  const mean = vls.reduce((a, b) => a + b, 0) / vls.length;
  const spread = (max - min) / mean;

  const avgRPEs = window
    .map((s) => s.avgRPE)
    .filter((r): r is number => r !== null);
  const meanRPE = avgRPEs.length === 0
    ? Number.POSITIVE_INFINITY // no data → conservatively block plateau (gate fails)
    : avgRPEs.reduce((a, b) => a + b, 0) / avgRPEs.length;

  // Decline rule (drop): week-over-week comparison — most recent week
  // vs the preceding week. ADR-0009 §"Decline rules" wording is "drops
  // ≥ 10% in the most recent window relative to the prior window";
  // v2 reads "window" as a single week (the literal reading given that
  // weeklyVolumeLoad is already a weekly aggregate). v2.x watch-item:
  // if alpha cohort shows decline firing on benign single-week dips
  // (illness, travel, taper weeks), revisit as a window-based
  // comparison (trailing 2 vs preceding 2 weeks) for additional
  // smoothing. Asymmetric-error reasoning still favours the louder
  // (more-firing) direction, so single-week is the right v2 default.
  if (sessions.length >= 2) {
    const prior = sessions[sessions.length - 2].weeklyVolumeLoad;
    const current = sessions[sessions.length - 1].weeklyVolumeLoad;
    const drop = (prior - current) / prior;
    if (drop >= DECLINE_VOLUME_DROP_THRESHOLD) return "declining";
  }

  // Decline rule (overreach): current week's volume-load > 115% of the
  // mean of the trailing 4 weeks (excluding the current). ADR-0009 uses
  // strict ">115%" — at exactly 115%, overreach does NOT fire.
  if (sessions.length >= VOLUME_LOAD_OVERREACH_TRAILING_WINDOW_N + 1) {
    const current = sessions[sessions.length - 1].weeklyVolumeLoad;
    const trailing = sessions.slice(
      -(VOLUME_LOAD_OVERREACH_TRAILING_WINDOW_N + 1),
      -1,
    );
    const trailingMean =
      trailing.reduce((a, s) => a + s.weeklyVolumeLoad, 0) / trailing.length;
    if (current > OVERREACH_VOLUME_LOAD_RATIO * trailingMean) return "declining";
  }

  if (
    spread <= PLATEAU_VOLUME_LOAD_SPREAD_THRESHOLD &&
    meanRPE < PLATEAU_EFFORT_GATE_RPE
  ) {
    return "flat";
  }
  return "improving";
}

/**
 * Hybrid plateau verdict per ADR-0009 §"Verdict aggregation".
 *
 * Aggregation precedence (Option B — declining-wins):
 *   1. either track declining → declining
 *   2. both tracks flat       → plateaued
 *   3. otherwise              → progressing
 *
 * ADR-0009's verdict table has internal precedence conflicts in the cells
 * {improving e1RM, declining volume} and {declining e1RM, improving volume}.
 * The ADR prose says "OR for progressing and AND for plateaued" but does
 * not address declining precedence. Resolved here per `docs/design-
 * principles.md` asymmetric-error preference: prefer the loud failure
 * (over-firing declining) over the silent failure (under-flagging
 * overreach). The {declining e1RM, improving volume} cell is the classic
 * overreach signature — silently calling it 'progressing' would let
 * fatigue accumulate to crash. ADR-0009 amendment proposed post-merge to
 * make this precedence explicit in the prose.
 */
export function plateauVerdict(
  e1rmSessions: E1RMSession[],
  volumeLoadSessions: VolumeLoadSession[],
  cadenceDays: number | null,
): ProgressionTrend {
  const e1rmV = e1rmTrack(e1rmSessions, cadenceDays);
  const volumeV = volumeLoadTrack(volumeLoadSessions);
  if (e1rmV === "declining" || volumeV === "declining") return "declining";
  if (e1rmV === "flat" && volumeV === "flat") return "plateaued";
  return "progressing";
}

/**
 * Per-pattern trend + confidence used for muscle-level aggregation.
 * `confidence` is the `PatternProfile.confidence` field; only patterns
 * above `bootstrapping` participate per the ADR-0009 amendment.
 */
export interface PatternTrendForMuscleAggregation {
  pattern: string;
  trend: ProgressionTrend;
  confidence: "bootstrapping" | "calibrating" | "established" | "seasoned";
}

/**
 * Muscle-level aggregation per ADR-0009 amendment (2026-05-07).
 *
 * Rule: worst-across-patterns over participating patterns, where worst
 * order is `declining > plateaued > progressing`.
 *
 * Participation precondition: a pattern P participates iff
 * `PatternProfile[P].confidence > .bootstrapping` (the trend is only
 * trustworthy once enough data has accumulated). Bootstrapping patterns
 * are filtered out before aggregation regardless of their trend value.
 *
 * Empty-participation default: when zero patterns participate (the
 * cold-start case for muscle M), the result is `'progressing'` — the
 * `ProgressionTrend` enum has no `.bootstrapping` case, and the cold-
 * start signal is carried by `MuscleProfile.confidence` independently.
 * LLM digest consumers MUST read both fields per ADR-0009 amendment.
 */
export function aggregateMuscleStagnationStatus(
  patterns: PatternTrendForMuscleAggregation[],
): ProgressionTrend {
  const participating = patterns.filter(
    (p) => p.confidence !== "bootstrapping",
  );
  if (participating.some((p) => p.trend === "declining")) return "declining";
  if (participating.some((p) => p.trend === "plateaued")) return "plateaued";
  return "progressing";
}
