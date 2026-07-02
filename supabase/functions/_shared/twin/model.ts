// Project Apex — Athlete Twin (ADR-0031, Phase 1 shadow).
//
// The per-pattern generative model: state layout, priors, dynamics, and the
// observation function mapping latent capability to observed reps.
//
// v1 state vector (per movement pattern):
//   x[0] = C — log e1RM (kg) of the pattern's ANCHOR exercise, true-capability
//              scale (RIR-adjusted: what the athlete could do at 0 reps in
//              reserve), NOT the performed-rep e1RM the EWMA tracks.
//   x[1] = T — capability trend, log-units per day. Replaces the plateau
//              threshold ladder's job: P(T ≤ 0) is a posterior statement.
//   x[2] = G — unrecovered fatigue, log-units of capability depression.
//              v1 collapses ADR-0010's NM/metabolic split into ONE term:
//              at the cohort's observed cadence (median 4–5 days between
//              pattern sessions vs τ_NM = 30 h) the two components are not
//              separately identifiable — G has decayed to ≤ ~4% of any
//              session's impulse by the next session. Named v1 cut.
//   x[3] = r — log rep-response slope ρ (personal Epley denominator).
//              Prior mean log(30) = the generic Epley constant.
//   x[4+] = b_e — log-offset of each non-anchor exercise in the pattern
//              relative to the anchor (patterns mix heterogeneous exercises;
//              a pattern-level C is unobservable without them).
//
// Deferred from the full plan (named cuts, see ADR-0031):
//   - F (fitness reservoir): absorbed into T. At 1–2 sessions/week/pattern
//     a Banister two-compartment F↔C is unidentifiable; a local-linear trend
//     answers the same forecasting question honestly.
//   - Per-session day-readiness factor + cross-pattern transfer: v1 filters
//     are independent per pattern.
//   - Learned per-user observation noise: fixed constants below; innovation
//     diagnostics (NIS) reported by the backtest instead.
//
// Dynamics (Δt days), all linear — the UT propagates them exactly:
//   C ← C + T·Δt
//   T ← T
//   G ← G · exp(−Δt·24 / τ_G)          (τ_G = RECOVERY_TAU_NM_HOURS)
//   r, b_e ← unchanged
// Process noise: diagonal, scaled by Δt (random-walk rates below).
//
// Observation (per working set: weight w > 0 on exercise e, reps n,
// reported RIR ρ̂ or RPE→RIR fallback):
//   y = n + ρ̂  (achievable reps at that moment — reps plus reps in reserve)
//   h(x) = exp(r) · ( exp(C + b_e − G − g_intra) / w − 1 )
// where g_intra = INTRA_SESSION_FATIGUE_PER_SET × (effective sets already
// performed for this pattern in this session). Inverse of the personal
// Epley: e1RM = w·(1 + m/ρ) solved for max reps m.
//
// Pure: no I/O, no clock reads, no randomness.

import { RECOVERY_TAU_NM_HOURS } from "../constants.ts";
import type { Vec } from "./linalg.ts";

// ─── Fixed v1 parameters (not state; flagged in ADR-0031) ───────────────────

/** Epley rep-slope prior mean: ρ = 30 (matches ewma-engine's e1rm). */
export const REP_SLOPE_PRIOR_LOG_MEAN = Math.log(30);
/** Prior sd on log ρ — ±~28% personal deviation from Epley at 1σ. */
export const REP_SLOPE_PRIOR_LOG_SD = 0.25;

/** Prior sd on C at lazy initialization (first-ever observation), log-units. */
export const CAPABILITY_INIT_SD = 0.25;
/**
 * Prior mean/sd on trend T (log-units/day): 0 ± ~15%/month at 1σ.
 * Sized for a NOVICE alpha cohort: the real users showed sustained
 * 20–100%-per-6-weeks gains on light dumbbell/machine movements (skill
 * acquisition + true early adaptation). The initial 0.0025 (±7.5%/mo)
 * declared those rates ~7σ implausible and the filter chronically
 * under-forecast rising athletes (NIS ≈ 10 on the fastest pattern).
 */
export const TREND_PRIOR_SD = 0.005;
/** Prior sd on a new exercise offset b_e at first sight, log-units. */
export const EXERCISE_OFFSET_INIT_SD = 0.15;
/** Prior sd on fatigue G at init (starts at 0 — fresh). */
export const FATIGUE_INIT_SD = 0.01;

/** Fatigue time constant, hours. v1 reuses ADR-0010's NM constant. */
export const FATIGUE_TAU_HOURS = RECOVERY_TAU_NM_HOURS;
/** Capability depression per effective set, log-units (fixed v1). */
export const FATIGUE_PER_EFFECTIVE_SET = 0.006;
/** Relative 1σ uncertainty on the dose impulse (inflates G variance). */
export const FATIGUE_DOSE_UNCERTAINTY = 0.5;
/**
 * Within-session capability depression per prior effective set, log-units.
 * 0.025 ≈ 2.5% capability drop per hard set — the plausible middle of
 * rest-pause / repeated-effort literature. Initial v1 used 0.010; on the
 * real cohort that under-explained the top→backoff rep drop and the free
 * rep-slope ρ collapsed to ~5–10 absorbing the difference (see the
 * backtest identifiability audit). Fixed, not learned, in v1.
 */
export const INTRA_SESSION_FATIGUE_PER_SET = 0.025;

/** Random-walk process noise rates (variance per day). q_T sized so the
 * trend can traverse a novice's ramp-up/plateau transition within weeks
 * (0.0012/√day → ±0.008/day drift after ~45 days), matching the observed
 * cohort dynamics; see TREND_PRIOR_SD note. */
export const Q_CAPABILITY_PER_DAY = 0.008 ** 2;
export const Q_TREND_PER_DAY = 0.0012 ** 2;
export const Q_FATIGUE_PER_DAY = 0.004 ** 2;
export const Q_REP_SLOPE_PER_DAY = 0.002 ** 2;
export const Q_OFFSET_PER_DAY = 0.004 ** 2;

/** Observation noise sd (reps) when RIR was reported directly. */
export const OBS_SD_REPS_RIR = 1.3;
/** Observation noise sd (reps) when RIR was derived from RPE (coarser). */
export const OBS_SD_REPS_RPE = 1.8;
/** Observation noise sd (reps) for AMRAP sets with no report (RIR ≈ 0). */
export const OBS_SD_REPS_AMRAP = 1.3;

/** Extra variance on forecast reps for count discreteness. */
export const FORECAST_DISCRETENESS_VAR = 0.25;

/** Stopping-RIR prior (how far from failure top sets habitually stop). */
export const STOP_RIR_PRIOR_MEAN = 1.0;
export const STOP_RIR_PRIOR_VAR = 1.0;
export const STOP_RIR_PRIOR_WEIGHT = 2;

/** Guard for exp() inside the observation fn (insane sigma points only). */
const EXP_ARG_MIN = -10;
const EXP_ARG_MAX = 10;

// ─── State layout ────────────────────────────────────────────────────────────

export const IDX_C = 0;
export const IDX_T = 1;
export const IDX_G = 2;
export const IDX_R = 3;
export const FIXED_DIM = 4;

/** State index of exercise `offsetIdx` in the offsets list. */
export function offsetStateIndex(offsetIdx: number): number {
  return FIXED_DIM + offsetIdx;
}

// ─── Dynamics ────────────────────────────────────────────────────────────────

/** Linear time-propagation of the state by `dtDays`. */
export function dynamicsFn(dtDays: number): (x: Vec) => Vec {
  const decay = Math.exp(-(dtDays * 24) / FATIGUE_TAU_HOURS);
  return (x: Vec): Vec => {
    const out = [...x];
    out[IDX_C] = x[IDX_C] + x[IDX_T] * dtDays;
    out[IDX_G] = x[IDX_G] * decay;
    return out;
  };
}

/** Diagonal process-noise matrix for `dtDays`, for state dimension `dim`. */
export function processNoise(dtDays: number, dim: number): number[][] {
  const q: number[][] = Array.from(
    { length: dim },
    () => new Array(dim).fill(0),
  );
  const dt = Math.max(dtDays, 0);
  q[IDX_C][IDX_C] = Q_CAPABILITY_PER_DAY * dt;
  q[IDX_T][IDX_T] = Q_TREND_PER_DAY * dt;
  q[IDX_G][IDX_G] = Q_FATIGUE_PER_DAY * dt;
  q[IDX_R][IDX_R] = Q_REP_SLOPE_PER_DAY * dt;
  for (let i = FIXED_DIM; i < dim; i++) q[i][i] = Q_OFFSET_PER_DAY * dt;
  return q;
}

// ─── Observation ─────────────────────────────────────────────────────────────

function clampedExp(arg: number): number {
  return Math.exp(Math.min(EXP_ARG_MAX, Math.max(EXP_ARG_MIN, arg)));
}

/**
 * Max achievable reps at load `weightKg` on the exercise at state offset
 * index `offsetIdx` (−1 = anchor, offset 0), with `gIntra` within-session
 * fatigue already accumulated: m = ρ·(e1RM_now/w − 1), personal Epley.
 */
export function observationFn(
  weightKg: number,
  offsetIdx: number,
  gIntra: number,
): (x: Vec) => number {
  return (x: Vec): number => {
    const b = offsetIdx >= 0 ? x[offsetStateIndex(offsetIdx)] : 0;
    const prepared = clampedExp(
      x[IDX_C] + b - Math.max(0, x[IDX_G]) - gIntra,
    );
    const rho = clampedExp(x[IDX_R]);
    return rho * (prepared / weightKg - 1);
  };
}

/**
 * Effective-set stimulus weight per intent — the dose attribution feeding
 * both G's post-session impulse and the within-session g_intra term.
 * Echoes stimulus-classifier's exclusions (warmup/technique drive nothing).
 */
export function effectiveSetWeight(intent: string): number {
  switch (intent) {
    case "top":
    case "amrap":
      return 1.0;
    case "backoff":
      return 0.7;
    default:
      return 0;
  }
}

/**
 * Effort report for a set: observed reps-in-reserve, its source, and the
 * observation noise to use. Returns null when the set carries no usable
 * effort signal (non-AMRAP set with neither RIR nor RPE) — the filter
 * skips it rather than guessing (no silent defaults).
 */
export function effortReport(
  intent: string,
  rirEstimated: number | null,
  rpeFelt: number | null,
): { rirEff: number; obsSd: number; source: "rir" | "rpe" | "amrap" } | null {
  if (rirEstimated !== null) {
    return { rirEff: Math.max(0, rirEstimated), obsSd: OBS_SD_REPS_RIR, source: "rir" };
  }
  if (rpeFelt !== null) {
    return {
      rirEff: Math.max(0, 10 - rpeFelt),
      obsSd: OBS_SD_REPS_RPE,
      source: "rpe",
    };
  }
  if (intent === "amrap") {
    return { rirEff: 0, obsSd: OBS_SD_REPS_AMRAP, source: "amrap" };
  }
  return null;
}

/**
 * Implied log e1RM of a single set under the PRIOR rep-slope (generic
 * Epley) — used only for lazy state initialization (C and b_e at first
 * sight), never as a filter observation.
 */
export function impliedLogE1rm(
  weightKg: number,
  reps: number,
  rirEff: number,
): number {
  return Math.log(weightKg * (1 + (reps + rirEff) / 30));
}
