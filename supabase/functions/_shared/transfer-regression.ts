// Project Apex — Phase 2 transfer-regression aggregator.
//
// Per Q10 PRD-internal: log-log linear fit with combined gate
// (≥TRANSFER_MIN_PAIRED_OBSERVATIONS paired observations AND
// rSquared ≥ TRANSFER_R_SQUARED_FLOOR), Spearman flag at
// ≥TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS additively widening SE by
// k=1.0 (TRANSFER_SPEARMAN_SE_WIDENING_FACTOR per 2026-05-07 lock-in
// extension), demote-on-drop with no hysteresis. Pure throughout — the
// regression math has no side effects; the negative-coefficient
// observability emit is the orchestrator's (A12) responsibility per
// #81's out-of-scope decision (pair-detection — and therefore pair
// identity — lives in the orchestrator).
//
// Aligns with ADR-0005 §"Transfer matrix: static literature defaults vs
// learned per-user" (architectural rationale) and §"Linearity assumption
// for transfers" (Spearman + SE widening rationale).
//
// docs/design-principles.md (asymmetric-error preference) is load-bearing
// for the k=1.0 choice — under-widening is silent over-prescription on a
// non-linear transfer; over-widening is loud under-prescription via RPE
// drift surfacing through prescription-accuracy bias.

import {
  TRANSFER_MIN_PAIRED_OBSERVATIONS,
  TRANSFER_R_SQUARED_FLOOR,
  TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD,
  TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS,
  TRANSFER_SPEARMAN_SE_WIDENING_FACTOR,
} from "./constants.ts";

export interface PairedObservation {
  fromE1RM: number;
  toE1RM: number;
  observedAt: Date;
}

export interface TransferFit {
  /**
   * Log-log linear coefficient:
   *   log(toE1RM) = coefficient × log(fromE1RM) + intercept.
   */
  coefficient: number;
  intercept: number;
  rSquared: number;
  pairedObservations: number;
  spearmanFlagged: boolean;
  /**
   * Additive SE-widening when Spearman flag fires:
   *   seWidening = residualStddev × TRANSFER_SPEARMAN_SE_WIDENING_FACTOR
   * (k=1.0 per Q10 2026-05-07 lock-in extension). Zero when not flagged.
   */
  seWidening: number;
  /**
   * Per Q10 PRD-internal:
   *   - 'published': passes combined gate (≥5 obs AND R²≥0.4).
   *   - 'candidate': below gate; not surfaced in digest.
   * Demote-on-drop is no-hysteresis: state derives from the current
   * observations on every call, with no waiting period on recovery.
   */
  state: "published" | "candidate";
}

/**
 * Average-rank assignment with tie handling: tied values share the average
 * of the ranks they would occupy if untied. E.g., values [10, 20, 20, 30]
 * → ranks [1, 2.5, 2.5, 4]. Standard convention for Spearman rank
 * correlation; pinned by cycle 14's tied-rank test.
 */
function averageRanks(values: number[]): number[] {
  const indexed = values.map((v, i) => ({ v, i }));
  indexed.sort((a, b) => a.v - b.v);
  const ranks = new Array<number>(values.length);
  let i = 0;
  while (i < indexed.length) {
    let j = i;
    while (j + 1 < indexed.length && indexed[j + 1].v === indexed[i].v) j++;
    // Tied range [i..j] inclusive; average rank = ((i+1)+(j+1))/2.
    const avgRank = (i + j) / 2 + 1;
    for (let k = i; k <= j; k++) ranks[indexed[k].i] = avgRank;
    i = j + 1;
  }
  return ranks;
}

/**
 * Pearson product-moment correlation. Used both for Spearman ρ (Pearson
 * applied to ranks) and as the underlying definition behind
 * `linearR = sign(coefficient) × √R²` (which is mathematically the
 * Pearson correlation of xs and ys).
 */
function pearson(xs: number[], ys: number[]): number {
  const n = xs.length;
  const meanX = xs.reduce((a, b) => a + b, 0) / n;
  const meanY = ys.reduce((a, b) => a + b, 0) / n;
  let sxx = 0;
  let syy = 0;
  let sxy = 0;
  for (let i = 0; i < n; i++) {
    const dx = xs[i] - meanX;
    const dy = ys[i] - meanY;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  return sxy / Math.sqrt(sxx * syy);
}

export function fitTransfer(observations: PairedObservation[]): TransferFit {
  const n = observations.length;
  if (n === 0) {
    return {
      coefficient: 0,
      intercept: 0,
      rSquared: 0,
      pairedObservations: 0,
      spearmanFlagged: false,
      seWidening: 0,
      state: "candidate",
    };
  }

  // Log-log linear fit per Q10:
  //   x_i = ln(fromE1RM_i), y_i = ln(toE1RM_i)
  //   coefficient = Σ(x − x̄)(y − ȳ) / Σ(x − x̄)²
  //   intercept = ȳ − coefficient·x̄
  //   R² = 1 − SSres/SStot
  const xs = observations.map((o) => Math.log(o.fromE1RM));
  const ys = observations.map((o) => Math.log(o.toE1RM));
  const meanX = xs.reduce((a, b) => a + b, 0) / n;
  const meanY = ys.reduce((a, b) => a + b, 0) / n;
  let sxx = 0;
  let sxy = 0;
  let ssTot = 0;
  for (let i = 0; i < n; i++) {
    const dx = xs[i] - meanX;
    const dy = ys[i] - meanY;
    sxx += dx * dx;
    sxy += dx * dy;
    ssTot += dy * dy;
  }
  const coefficient = sxy / sxx;
  const intercept = meanY - coefficient * meanX;
  let ssRes = 0;
  for (let i = 0; i < n; i++) {
    const yHat = intercept + coefficient * xs[i];
    const r = ys[i] - yHat;
    ssRes += r * r;
  }
  const rSquared = 1 - ssRes / ssTot;

  // Combined gate per Q10: ≥TRANSFER_MIN_PAIRED_OBSERVATIONS observations
  // AND rSquared ≥ TRANSFER_R_SQUARED_FLOOR (inclusive at 0.40; FP boundary
  // discussion in transfer-regression_test.ts cycle 5).
  const passesGate = n >= TRANSFER_MIN_PAIRED_OBSERVATIONS &&
    rSquared >= TRANSFER_R_SQUARED_FLOOR;

  // Spearman flag per Q10 §"Linearity assumption" + 2026-05-07 lock-in:
  // when N ≥ 10 and the rank-correlation diverges from the linear
  // correlation by more than 0.15, the linear fit is missing a monotonic-
  // but-non-linear signal — surface it as additive SE widening.
  let spearmanFlagged = false;
  let seWidening = 0;
  if (n >= TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS) {
    const spearman = pearson(averageRanks(xs), averageRanks(ys));
    // Signed Pearson r for the linear fit. Q4 lock-in: signed (not √R²
    // unsigned) — Spearman ρ is naturally signed and comparing it to an
    // unsigned magnitude would systematically flag every negative-slope
    // pair regardless of actual non-linearity.
    const linearR = Math.sign(coefficient) *
      Math.sqrt(Math.max(0, rSquared));
    if (
      Math.abs(spearman - linearR) > TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD
    ) {
      spearmanFlagged = true;
      // Standard regression residual stddev with n−2 degrees of freedom
      // (slope + intercept consume 2 dof) per Q1 lock-in. n−2 > 0 here
      // because the Spearman gate already requires n ≥ 10.
      const residualStddev = Math.sqrt(ssRes / (n - 2));
      seWidening = residualStddev * TRANSFER_SPEARMAN_SE_WIDENING_FACTOR;
    }
  }

  return {
    coefficient,
    intercept,
    rSquared,
    pairedObservations: n,
    spearmanFlagged,
    seWidening,
    state: passesGate ? "published" : "candidate",
  };
}
