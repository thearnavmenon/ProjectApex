// Project Apex — Athlete Twin (ADR-0031, Phase 1 shadow).
//
// Additive-noise Unscented Kalman Filter with cubature-style sigma points
// (scaled UT with λ = 0): 2L symmetric points at mean ± √L · (√P)ᵢ, all
// weights 1/(2L) and strictly positive. Positive weights guarantee the
// reconstructed covariance is PSD by construction — chosen over the
// classic (α, β, κ) parametrization whose negative central weight can
// break PSD as the state grows (this model appends one exercise-offset
// state per new exercise in a pattern).
//
// Property-tested against an independent reference implementation
// (reference/kf-reference.ts): exact-KF equivalence on linear systems,
// Gauss–Hermite posterior-moment agreement on the nonlinear observation,
// PSD preservation under seeded random operation sequences.
//
// Pure: no I/O, no clock reads, no randomness.

import {
  choleskyWithJitter,
  cloneMat,
  type Mat,
  matAdd,
  outer,
  symmetrize,
  type Vec,
  vecAdd,
  vecScale,
  vecSub,
  zeros,
  zerosMat,
} from "./linalg.ts";

export interface Gaussian {
  mean: Vec;
  cov: Mat;
}

export interface ScalarUpdateResult extends Gaussian {
  /** y − ŷ, the innovation. */
  innovation: number;
  /** Innovation variance S = Var(ŷ) + R. */
  innovationVariance: number;
  /** Diagonal jitter the Cholesky needed, 0 in healthy operation. */
  jitterApplied: number;
}

/**
 * Cubature sigma points: 2L points X_i = m ± (√(L·P))·e_i, equal weights
 * 1/(2L). √P via jittered Cholesky. Exact for linear functions; matches
 * mean and covariance of any Gaussian through quadratic error terms.
 */
export function sigmaPoints(
  g: Gaussian,
): { points: Vec[]; weight: number; jitterApplied: number } {
  const L = g.mean.length;
  const { l, jitterApplied } = choleskyWithJitter(symmetrize(g.cov));
  const scale = Math.sqrt(L);
  const points: Vec[] = [];
  for (let i = 0; i < L; i++) {
    const col = zeros(L);
    for (let r = 0; r < L; r++) col[r] = l[r][i] * scale;
    points.push(vecAdd(g.mean, col));
    points.push(vecSub(g.mean, col));
  }
  return { points, weight: 1 / (2 * L), jitterApplied };
}

/**
 * UKF predict with additive process noise Q:
 *   m' = Σ w·f(X_i),   P' = Σ w·(f(X_i)−m')(f(X_i)−m')ᵀ + Q.
 */
export function ukfPredict(
  g: Gaussian,
  f: (x: Vec) => Vec,
  q: Mat,
): Gaussian {
  const { points, weight } = sigmaPoints(g);
  const propagated = points.map(f);
  const L = g.mean.length;
  const mean = zeros(L);
  for (const p of propagated) {
    for (let i = 0; i < L; i++) mean[i] += weight * p[i];
  }
  let cov = zerosMat(L, L);
  for (const p of propagated) {
    const d = vecSub(p, mean);
    cov = matAdd(cov, outer(vecScale(d, weight), d));
  }
  return { mean, cov: symmetrize(matAdd(cov, cloneMat(q))) };
}

/**
 * UKF update for a SCALAR observation y with additive noise variance r:
 *   ŷ = Σ w·h(X_i)
 *   S = Σ w·(h(X_i)−ŷ)² + r
 *   Pxy = Σ w·(X_i−m)(h(X_i)−ŷ)
 *   K = Pxy / S
 *   m⁺ = m + K·(y−ŷ),   P⁺ = P − K·S·Kᵀ  (= P − Pxy·Pxyᵀ/S)
 *
 * Scalar-sequential updates keep every step O(L²) and avoid matrix
 * inversion entirely — S is a scalar. Sets within a session are applied
 * as consecutive scalar updates (their self-report errors are modeled
 * as independent given the state).
 */
export function ukfUpdateScalar(
  g: Gaussian,
  h: (x: Vec) => number,
  y: number,
  r: number,
): ScalarUpdateResult {
  const L = g.mean.length;
  const { points, weight, jitterApplied } = sigmaPoints(g);
  const ys = points.map(h);
  let yHat = 0;
  for (const yi of ys) yHat += weight * yi;
  let pyy = 0;
  const pxy = zeros(L);
  for (let i = 0; i < points.length; i++) {
    const dy = ys[i] - yHat;
    pyy += weight * dy * dy;
    const dx = vecSub(points[i], g.mean);
    for (let k = 0; k < L; k++) pxy[k] += weight * dx[k] * dy;
  }
  const s = pyy + r;
  const gain = pxy.map((v) => v / s);
  const innovation = y - yHat;
  const mean = vecAdd(g.mean, vecScale(gain, innovation));
  // P⁺ = P − Pxy·Pxyᵀ/S, symmetrized. With positive weights this stays PSD
  // up to floating-point error; symmetrize + downstream jittered Cholesky
  // absorb the roundoff.
  const correction = outer(
    pxy.map((v) => -v / s),
    pxy,
  );
  const cov = symmetrize(matAdd(g.cov, correction));
  return {
    mean,
    cov,
    innovation,
    innovationVariance: s,
    jitterApplied,
  };
}

/**
 * Predictive distribution of a scalar observable h(x) (+ additive noise
 * variance r) under the current state Gaussian — used for forecasts:
 * returns mean and variance of the unscented-transformed observable.
 */
export function predictScalar(
  g: Gaussian,
  h: (x: Vec) => number,
  r: number,
): { mean: number; variance: number } {
  const { points, weight } = sigmaPoints(g);
  const ys = points.map(h);
  let yHat = 0;
  for (const yi of ys) yHat += weight * yi;
  let pyy = 0;
  for (const yi of ys) pyy += weight * (yi - yHat) * (yi - yHat);
  return { mean: yHat, variance: pyy + r };
}
