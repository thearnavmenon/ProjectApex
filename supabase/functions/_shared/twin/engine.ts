// Project Apex — Athlete Twin (ADR-0031, Phase 1 shadow).
//
// Per-pattern twin driver: owns the serializable posterior state, applies a
// session's sets as filter observations, and produces next-session top-set
// forecasts. This is the module the shadow dual-write and the backtest
// harness both call — one code path, so backtest numbers speak for what
// would run in production.
//
// The filter's clock is the DATA's timestamps (set logged_at / session
// logged_at) — never the wall clock. Same inputs → same posterior, byte for
// byte; the backtest asserts this determinism property.
//
// Pure: no I/O, no clock reads, no randomness.

import {
  CAPABILITY_INIT_SD,
  dynamicsFn,
  effectiveSetWeight,
  effortReport,
  EXERCISE_OFFSET_INIT_SD,
  FATIGUE_DOSE_UNCERTAINTY,
  FATIGUE_INIT_SD,
  FATIGUE_PER_EFFECTIVE_SET,
  FIXED_DIM,
  FORECAST_DISCRETENESS_VAR,
  IDX_C,
  IDX_G,
  IDX_R,
  IDX_T,
  impliedLogE1rm,
  INTRA_SESSION_FATIGUE_PER_SET,
  OBS_SD_REPS_RIR,
  observationFn,
  offsetStateIndex,
  processNoise,
  REP_SLOPE_PRIOR_LOG_MEAN,
  REP_SLOPE_PRIOR_LOG_SD,
  STOP_RIR_PRIOR_MEAN,
  STOP_RIR_PRIOR_VAR,
  STOP_RIR_PRIOR_WEIGHT,
  TREND_PRIOR_SD,
} from "./model.ts";
import type { Mat, Vec } from "./linalg.ts";
import { isSymmetricPsd } from "./linalg.ts";
import { predictScalar, ukfPredict, ukfUpdateScalar } from "./ukf.ts";
import { censoredMean } from "./gauss.ts";

/** Window of recent top-intent sets feeding the rep-habit ceiling. */
const REP_HABIT_WINDOW = 8;

// ─── Serializable state (the `twin` block in model_json) ────────────────────

export interface StopRirStats {
  /** Observation count (excludes the prior pseudo-weight). */
  n: number;
  mean: number;
  /** Welford M2 (sum of squared deviations). */
  m2: number;
}

export interface TwinPatternState {
  version: 1;
  anchorExerciseId: string;
  /** State indices 4.. map to these exercise ids, in order. */
  offsetExerciseIds: string[];
  mean: number[];
  /** Lower-triangle of the covariance, row-major: [c00, c10, c11, c20, …]. */
  covTriangle: number[];
  /** ISO timestamp of the last processed observation — the filter's clock. */
  lastEventAt: string;
  /** Running stats of observed stopping-RIR on top-intent sets. */
  stopRir: StopRirStats;
  /**
   * Performed reps of the last ≤8 top-intent sets (weight > 0), effort
   * report or not — the athlete's demonstrated rep-habit ceiling. Cohort
   * data showed performed top-set reps are CENSORED at the program's rep
   * target (athletes rack at ~10 whatever their remaining capability), so
   * forecasts of performed reps are min(capability-based reps, habit cap).
   */
  recentTopReps: number[];
  observationCount: number;
  skippedSetCount: number;
  /** Cholesky jitter incidents — covariance-health telemetry. */
  jitterIncidents: number;
}

export interface TwinSetInput {
  /** CANONICAL exercise id — callers canonicalize via exercise-library. */
  exerciseId: string;
  weightKg: number;
  reps: number;
  rirEstimated: number | null;
  rpeFelt: number | null;
  intent: string;
  loggedAt: Date;
}

export interface TwinApplyDiagnostics {
  observationsApplied: number;
  setsSkipped: number;
  /** Normalized innovation squared per applied observation (NIS). */
  nisValues: number[];
  jitterIncidents: number;
  bootstrapped: boolean;
  exercisesAdded: string[];
}

export interface TwinForecast {
  /**
   * Point forecast of performed reps: the mean of min(X, repCap) with
   * X ~ N(repsMu, repsSd²) — capability-based reps censored at the
   * athlete's demonstrated rep habit.
   */
  repsMean: number;
  /** Mean of the UNDERLYING (uncensored) capability-based rep forecast. */
  repsMu: number;
  /** Sd of the underlying Gaussian (state + stopping + noise floor). */
  repsSd: number;
  /** Rep-habit ceiling (max of recent top-set reps + 1), null if <2 seen. */
  repCap: number | null;
  /** Predictive mean/sd of MAX achievable reps (before stopping-RIR). */
  maxRepsMean: number;
  maxRepsSd: number;
  /** True if the exercise has never been seen (offset at prior). */
  exerciseUnseen: boolean;
}

// ─── Triangle (de)serialization ──────────────────────────────────────────────

export function matToTriangle(m: Mat): number[] {
  const out: number[] = [];
  for (let i = 0; i < m.length; i++) {
    for (let j = 0; j <= i; j++) out.push(m[i][j]);
  }
  return out;
}

export function triangleToMat(tri: number[], dim: number): Mat {
  const m: Mat = Array.from({ length: dim }, () => new Array(dim).fill(0));
  let k = 0;
  for (let i = 0; i < dim; i++) {
    for (let j = 0; j <= i; j++) {
      m[i][j] = tri[k];
      m[j][i] = tri[k];
      k++;
    }
  }
  return m;
}

// ─── Internal helpers ────────────────────────────────────────────────────────

const MS_PER_DAY = 24 * 60 * 60 * 1000;

interface Working {
  mean: Vec;
  cov: Mat;
  offsetExerciseIds: string[];
  anchorExerciseId: string;
}

function stateToWorking(s: TwinPatternState): Working {
  const dim = FIXED_DIM + s.offsetExerciseIds.length;
  return {
    mean: [...s.mean],
    cov: triangleToMat(s.covTriangle, dim),
    offsetExerciseIds: [...s.offsetExerciseIds],
    anchorExerciseId: s.anchorExerciseId,
  };
}

/** Append a new state dimension (exercise offset) with prior (mean, var). */
function appendState(w: Working, mean: number, variance: number): void {
  const dim = w.mean.length;
  w.mean.push(mean);
  for (const row of w.cov) row.push(0);
  const newRow = new Array(dim + 1).fill(0);
  newRow[dim] = variance;
  w.cov.push(newRow);
}

function offsetIdxFor(w: Working, exerciseId: string): number {
  if (exerciseId === w.anchorExerciseId) return -1;
  return w.offsetExerciseIds.indexOf(exerciseId);
}

/** Sort a session's sets chronologically (loggedAt, then insertion order). */
function chronological(sets: TwinSetInput[]): TwinSetInput[] {
  return sets
    .map((s, i) => ({ s, i }))
    .sort((a, b) =>
      a.s.loggedAt.getTime() - b.s.loggedAt.getTime() || a.i - b.i
    )
    .map((x) => x.s);
}

function stopRirMeanVar(stats: StopRirStats): { mean: number; variance: number } {
  // Blend the running stats with the prior pseudo-observations so a cold
  // pattern forecasts with the population stopping habit.
  const n = stats.n + STOP_RIR_PRIOR_WEIGHT;
  const mean = (stats.mean * stats.n + STOP_RIR_PRIOR_MEAN * STOP_RIR_PRIOR_WEIGHT) / n;
  const priorSs = STOP_RIR_PRIOR_VAR * STOP_RIR_PRIOR_WEIGHT;
  const variance = (stats.m2 + priorSs) / n;
  return { mean, variance: Math.max(variance, 0.1) };
}

// ─── Public API ──────────────────────────────────────────────────────────────

/**
 * Apply one session's sets for ONE pattern to the twin state. Pass
 * `state = null` for a pattern never seen before — the state bootstraps
 * from the session's own sets (lazy initialization: C centered on the
 * session's best implied e1RM with a deliberately wide prior; noted in
 * ADR-0031 as an empirical-Bayes initialization).
 *
 * Returns the updated state plus diagnostics. NEVER throws on bad set data
 * (skips and counts); throws only on internal numerical failure, which the
 * shadow caller catches and logs (legacy pipeline unaffected).
 */
export function applySessionToPattern(
  state: TwinPatternState | null,
  sets: TwinSetInput[],
  sessionLoggedAt: Date,
): { state: TwinPatternState; diagnostics: TwinApplyDiagnostics } {
  const diagnostics: TwinApplyDiagnostics = {
    observationsApplied: 0,
    setsSkipped: 0,
    nisValues: [],
    jitterIncidents: 0,
    bootstrapped: false,
    exercisesAdded: [],
  };

  const ordered = chronological(sets);
  // Usable sets: positive load, positive reps, some effort signal.
  const usable = ordered.filter((s) => {
    if (!(s.weightKg > 0) || !(s.reps >= 1)) return false;
    if (effectiveSetWeight(s.intent) === 0) return false;
    return effortReport(s.intent, s.rirEstimated, s.rpeFelt) !== null;
  });
  diagnostics.setsSkipped = ordered.length - usable.length;

  let working: Working;
  let stopRir: StopRirStats;
  let recentTopReps: number[];
  let observationCount: number;
  let skippedSetCount: number;
  let priorJitterIncidents: number;
  let lastEventAt: Date;

  if (state === null) {
    if (usable.length === 0) {
      // Nothing to bootstrap from; report a skip-only application.
      throw new TwinNoUsableDataError(
        "cannot bootstrap twin state from a session with no usable sets",
      );
    }
    // Anchor = exercise of the best implied-e1RM usable set this session.
    let best = usable[0];
    let bestE1rm = -Infinity;
    for (const s of usable) {
      const rep = effortReport(s.intent, s.rirEstimated, s.rpeFelt)!;
      const e = impliedLogE1rm(s.weightKg, s.reps, rep.rirEff);
      if (e > bestE1rm) {
        bestE1rm = e;
        best = s;
      }
    }
    working = {
      mean: [bestE1rm, 0, 0, REP_SLOPE_PRIOR_LOG_MEAN],
      cov: [
        [CAPABILITY_INIT_SD ** 2, 0, 0, 0],
        [0, TREND_PRIOR_SD ** 2, 0, 0],
        [0, 0, FATIGUE_INIT_SD ** 2, 0],
        [0, 0, 0, REP_SLOPE_PRIOR_LOG_SD ** 2],
      ],
      offsetExerciseIds: [],
      anchorExerciseId: best.exerciseId,
    };
    stopRir = { n: 0, mean: 0, m2: 0 };
    recentTopReps = [];
    observationCount = 0;
    skippedSetCount = 0;
    priorJitterIncidents = 0;
    lastEventAt = usable[0].loggedAt;
    diagnostics.bootstrapped = true;
  } else {
    working = stateToWorking(state);
    stopRir = { ...state.stopRir };
    recentTopReps = [...state.recentTopReps];
    observationCount = state.observationCount;
    skippedSetCount = state.skippedSetCount;
    priorJitterIncidents = state.jitterIncidents;
    lastEventAt = new Date(state.lastEventAt);
  }

  // ── Time update to this session ──
  const sessionTime = usable.length > 0
    ? usable[0].loggedAt
    : sessionLoggedAt;
  const dtDays = Math.max(
    0,
    (sessionTime.getTime() - lastEventAt.getTime()) / MS_PER_DAY,
  );
  if (dtDays > 0) {
    const g = ukfPredict(
      { mean: working.mean, cov: working.cov },
      dynamicsFn(dtDays),
      processNoise(dtDays, working.mean.length),
    );
    working.mean = g.mean;
    working.cov = g.cov;
  }

  // ── Measurement updates, set by set, chronological ──
  let effSetsSoFar = 0;
  for (const s of usable) {
    const rep = effortReport(s.intent, s.rirEstimated, s.rpeFelt)!;

    // First sight of an exercise → append an offset state at its implied
    // offset from the current C estimate, with a wide prior. (offsetIdxFor
    // returns −1 both for the anchor and for an unseen exercise; the anchor
    // check below disambiguates — −1 on the anchor means "offset 0".)
    let oi = offsetIdxFor(working, s.exerciseId);
    if (s.exerciseId !== working.anchorExerciseId && oi === -1) {
      const implied = impliedLogE1rm(s.weightKg, s.reps, rep.rirEff);
      appendState(
        working,
        implied - working.mean[IDX_C],
        EXERCISE_OFFSET_INIT_SD ** 2,
      );
      working.offsetExerciseIds.push(s.exerciseId);
      oi = working.offsetExerciseIds.length - 1;
      diagnostics.exercisesAdded.push(s.exerciseId);
    }

    const y = s.reps + rep.rirEff;
    const h = observationFn(s.weightKg, oi, effSetsSoFar * INTRA_SESSION_FATIGUE_PER_SET);
    const res = ukfUpdateScalar(
      { mean: working.mean, cov: working.cov },
      h,
      y,
      rep.obsSd ** 2,
    );
    working.mean = res.mean;
    working.cov = res.cov;
    if (res.jitterApplied > 0) diagnostics.jitterIncidents++;
    diagnostics.nisValues.push(
      (res.innovation * res.innovation) / res.innovationVariance,
    );
    diagnostics.observationsApplied++;
    observationCount++;

    // Track the stopping habit on top-intent sets with a real report.
    if (s.intent === "top" && rep.source !== "amrap") {
      const x = rep.rirEff;
      stopRir.n += 1;
      const delta = x - stopRir.mean;
      stopRir.mean += delta / stopRir.n;
      stopRir.m2 += delta * (x - stopRir.mean);
    }

    effSetsSoFar += effectiveSetWeight(s.intent);
  }

  // ── Rep-habit tracking: performed reps of top-intent sets, effort
  // report or not (performed reps are observed behavior regardless of
  // whether the set was usable as a filter observation). ──
  for (const s of ordered) {
    if (s.intent === "top" && s.weightKg > 0 && s.reps >= 1) {
      recentTopReps.push(s.reps);
    }
  }
  recentTopReps = recentTopReps.slice(-REP_HABIT_WINDOW);

  // ── Post-session fatigue impulse (deterministic dose from the data) ──
  if (effSetsSoFar > 0) {
    const impulse = FATIGUE_PER_EFFECTIVE_SET * effSetsSoFar;
    working.mean[IDX_G] += impulse;
    working.cov[IDX_G][IDX_G] += (FATIGUE_DOSE_UNCERTAINTY * impulse) ** 2;
  }

  skippedSetCount += diagnostics.setsSkipped;

  if (!isSymmetricPsd(working.cov)) {
    throw new Error(
      "twin covariance lost PSD after session application — refusing to persist",
    );
  }

  const newLastEvent = usable.length > 0
    ? usable[usable.length - 1].loggedAt
    : lastEventAt;

  return {
    state: {
      version: 1,
      anchorExerciseId: working.anchorExerciseId,
      offsetExerciseIds: working.offsetExerciseIds,
      mean: working.mean,
      covTriangle: matToTriangle(working.cov),
      lastEventAt: newLastEvent.toISOString(),
      stopRir,
      recentTopReps,
      observationCount,
      skippedSetCount,
      jitterIncidents: priorJitterIncidents + diagnostics.jitterIncidents,
    },
    diagnostics,
  };
}

/** Raised when a bootstrap is requested with no usable sets. */
export class TwinNoUsableDataError extends Error {}

/**
 * Forecast the PERFORMED reps of a top set at load `weightKg` on
 * `exerciseId`, at time `atTime` (typically the next session's timestamp).
 * Performed reps = max achievable reps − habitual stopping RIR; the
 * predictive variance combines posterior state uncertainty, the stopping
 * habit's variance, and a discreteness term.
 */
export function forecastTopSet(
  state: TwinPatternState,
  exerciseId: string,
  weightKg: number,
  atTime: Date,
): TwinForecast | null {
  if (!(weightKg > 0)) return null;
  const working = stateToWorking(state);
  const dtDays = Math.max(
    0,
    (atTime.getTime() - new Date(state.lastEventAt).getTime()) / MS_PER_DAY,
  );
  let g = { mean: working.mean, cov: working.cov };
  if (dtDays > 0) {
    g = ukfPredict(
      g,
      dynamicsFn(dtDays),
      processNoise(dtDays, working.mean.length),
    );
  }

  let oi = offsetIdxFor(working, exerciseId);
  let exerciseUnseen = false;
  if (exerciseId !== working.anchorExerciseId && oi === -1) {
    // Unseen exercise: forecast through a prior offset of 0 with the init
    // variance — wide, honest, flagged.
    exerciseUnseen = true;
    const dim = g.mean.length;
    g = {
      mean: [...g.mean, 0],
      cov: g.cov.map((row) => [...row, 0]).concat([
        [...new Array(dim).fill(0), EXERCISE_OFFSET_INIT_SD ** 2],
      ]),
    };
    oi = working.offsetExerciseIds.length;
  }

  // Top set assumed first hard set of its session: g_intra = 0. The
  // predictive variance includes the OBSERVATION-noise floor: a future
  // performed set carries the same day-to-day performance wobble and
  // report-granularity noise the filter models as R on incoming sets —
  // omitting it produced empirically overconfident bands (54% coverage at
  // nominal 90% on the cohort backtest before this term).
  const pred = predictScalar(
    g,
    observationFn(weightKg, oi, 0),
    OBS_SD_REPS_RIR ** 2,
  );
  const stop = stopRirMeanVar(state.stopRir);
  const repsMu = pred.mean - stop.mean;
  const repsSd = Math.sqrt(
    pred.variance + stop.variance + FORECAST_DISCRETENESS_VAR,
  );
  // Rep-habit ceiling: max demonstrated top-set reps + 1 rep of headroom.
  // Needs ≥2 observed top sets; null (no censoring) before that.
  const repCap = state.recentTopReps.length >= 2
    ? Math.max(...state.recentTopReps) + 1
    : null;
  return {
    repsMean: censoredMean(repsMu, repsSd, repCap),
    repsMu,
    repsSd,
    repCap,
    maxRepsMean: pred.mean,
    maxRepsSd: Math.sqrt(pred.variance),
    exerciseUnseen,
  };
}

/**
 * Predictive distribution of the log PREPARED e1RM (C + b_e − G) for an
 * exercise at a future time — the capability-scale forecast the load
 * inversion uses (predict the load that lands the athlete's target reps).
 * The observable is linear in the state, so the UT is exact here.
 * Returns null for an unseen exercise (callers decide their own prior
 * handling for that case).
 */
export function forecastPreparedLogE1rm(
  state: TwinPatternState,
  exerciseId: string,
  atTime: Date,
): { logMean: number; logSd: number; repSlope: number; stopRirMean: number } | null {
  const working = stateToWorking(state);
  const oi = offsetIdxFor(working, exerciseId);
  if (exerciseId !== working.anchorExerciseId && oi === -1) return null;
  const dtDays = Math.max(
    0,
    (atTime.getTime() - new Date(state.lastEventAt).getTime()) / MS_PER_DAY,
  );
  let g = { mean: working.mean, cov: working.cov };
  if (dtDays > 0) {
    g = ukfPredict(
      g,
      dynamicsFn(dtDays),
      processNoise(dtDays, working.mean.length),
    );
  }
  const h = (x: Vec): number => {
    const b = oi >= 0 ? x[offsetStateIndex(oi)] : 0;
    return x[IDX_C] + b - Math.max(0, x[IDX_G]);
  };
  const pred = predictScalar(g, h, 0);
  return {
    logMean: pred.mean,
    logSd: Math.sqrt(pred.variance),
    repSlope: Math.exp(g.mean[IDX_R]),
    stopRirMean: stopRirMeanVar(state.stopRir).mean,
  };
}

/**
 * Posterior summary used by the shadow dual-write's divergence log and by
 * identifiability reporting: per-state mean and sd.
 */
export function posteriorSummary(state: TwinPatternState): {
  logE1rmAnchor: { mean: number; sd: number };
  trendPerDay: { mean: number; sd: number };
  fatigue: { mean: number; sd: number };
  repSlope: { mean: number; sd: number };
  offsets: Array<{ exerciseId: string; mean: number; sd: number }>;
} {
  const dim = FIXED_DIM + state.offsetExerciseIds.length;
  const cov = triangleToMat(state.covTriangle, dim);
  const sd = (i: number) => Math.sqrt(Math.max(0, cov[i][i]));
  return {
    logE1rmAnchor: { mean: state.mean[IDX_C], sd: sd(IDX_C) },
    trendPerDay: { mean: state.mean[IDX_T], sd: sd(IDX_T) },
    fatigue: { mean: state.mean[IDX_G], sd: sd(IDX_G) },
    repSlope: { mean: Math.exp(state.mean[IDX_R]), sd: sd(IDX_R) },
    offsets: state.offsetExerciseIds.map((id, i) => ({
      exerciseId: id,
      mean: state.mean[offsetStateIndex(i)],
      sd: sd(offsetStateIndex(i)),
    })),
  };
}
