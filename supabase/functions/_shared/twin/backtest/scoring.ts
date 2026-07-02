// Project Apex — Athlete Twin backtest (ADR-0031, Phase 1 shadow).
//
// Scoring: MAE, Gaussian CRPS (closed form), central-interval coverage,
// and a seeded paired bootstrap for the MAE/CRPS deltas. The Gaussian
// CRPS here is cross-checked in tests against the independent reference
// implementation (reference/kf-reference.ts).
//
// CRPS convention (Gneiting & Raftery 2007), negatively oriented:
//   z = (y − μ)/σ,  CRPS = σ·[ z·(2Φ(z) − 1) + 2φ(z) − 1/√π ]
// A point forecast is the σ → 0 limit: CRPS = |y − μ| — which is why the
// incumbent EWMA's CRPS equals its absolute error, and why the harness
// also runs a variance-dressed EWMA variant for a fair distributional
// comparison.
//
// Deterministic: bootstrap resampling uses a seeded LCG, no Math.random.

import {
  censoredMean,
  gaussianCrps,
  stdNormCdf,
} from "../gauss.ts";

export { censoredMean, gaussianCrps, stdNormCdf };

/** z multiplier of the central 90% Gaussian interval: Φ⁻¹(0.95). */
export const Z_90 = 1.6448536269514722;

export function inCentral90(y: number, mean: number, sd: number): boolean {
  return Math.abs(y - mean) <= Z_90 * sd;
}

// ── Upper-censored Gaussian (voluntary-stopping forecast distribution) ──────
//
// The twin forecasts performed top-set reps as min(X, cap) where
// X ~ N(μ, σ²) is achievable-reps-minus-stopping-RIR and `cap` is the
// athlete's demonstrated rep-habit ceiling (they rack the bar at the
// program's rep target regardless of remaining capability). The censored
// distribution has CDF F(t) = Φ((t−μ)/σ) for t < cap and 1 at t ≥ cap
// (an atom at cap).

/**
 * CRPS of the upper-censored Gaussian against realized y, by deterministic
 * numerical quadrature of ∫ (F(t) − 1{t ≥ y})² dt (Simpson, step σ/200,
 * over μ ± 8σ ∪ {y}, with the exact tail contribution (y − cap) when the
 * realization exceeds the atom). Cross-checked in tests against the
 * closed-form Gaussian CRPS as cap → ∞. Accuracy ~1e-6·σ — far below
 * scoring resolution.
 */
export function censoredGaussianCrps(
  y: number,
  mu: number,
  sd: number,
  cap: number | null,
): number {
  if (cap === null) return gaussianCrps(y, mu, sd);
  if (sd === 0) return Math.abs(y - Math.min(mu, cap));
  // Integration domain: everything below `hi`, where F < 1 strictly below
  // cap; above max(cap, y) the integrand is 0 (F = 1, indicator = 1).
  // The integrand has a JUMP at t = y (the indicator), so the quadrature
  // is split there — Simpson across the discontinuity costs O(h) accuracy.
  const lo = Math.min(mu - 8 * sd, y - sd);
  const hi = Math.min(cap, Math.max(mu + 8 * sd, y + sd));
  const cdf = (t: number): number =>
    t < cap ? stdNormCdf((t - mu) / sd) : 1;
  const simpson = (a: number, b: number, ind: number): number => {
    if (b <= a) return 0;
    const f = (t: number): number => (cdf(t) - ind) ** 2;
    const n = Math.max(200, Math.ceil((b - a) / (sd / 200)));
    const steps = n % 2 === 0 ? n : n + 1;
    const h = (b - a) / steps;
    let sum = f(a) + f(b);
    for (let i = 1; i < steps; i++) {
      sum += f(a + i * h) * (i % 2 === 1 ? 4 : 2);
    }
    return (sum * h) / 3;
  };
  const split = Math.min(Math.max(y, lo), hi);
  let crps = simpson(lo, split, 0) + simpson(split, hi, 1);
  // If y > cap: for t in [cap, y), F = 1 and 1{t≥y} = 0 → integrand 1.
  if (y > cap) crps += y - cap;
  return crps;
}

/**
 * Central-90% coverage for the censored distribution, atom-aware: y is
 * covered iff neither extreme 5% tail contains it —
 *   P(X_c < y) ≤ 0.95  AND  P(X_c > y) ≤ 0.95
 * with X_c = min(X, cap):
 *   P(X_c < y) = y > cap ? 1 : Φ((y−μ)/σ)
 *   P(X_c > y) = y ≥ cap ? 0 : 1 − Φ((y−μ)/σ)
 * A realization ABOVE the cap is always a miss (the model called it
 * impossible); a realization AT the cap is covered iff the atom + upper
 * tail hold ≥ 5% mass.
 */
export function censoredInCentral90(
  y: number,
  mu: number,
  sd: number,
  cap: number | null,
): boolean {
  if (cap === null) return inCentral90(y, mu, sd);
  if (sd === 0) return y === Math.min(mu, cap);
  const below = y > cap ? 1 : stdNormCdf((y - mu) / sd);
  const above = y >= cap ? 0 : 1 - stdNormCdf((y - mu) / sd);
  return below <= 0.95 && above <= 0.95;
}

// ── Seeded LCG for the bootstrap ────────────────────────────────────────────

export function lcg(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

export interface BootstrapCi {
  meanDelta: number;
  lo95: number;
  hi95: number;
}

/**
 * Paired bootstrap 95% CI for the mean of `deltas` (per-transition score
 * differences, incumbent − twin: positive favors the twin). Seeded,
 * deterministic. Returns null for n < 2.
 */
export function pairedBootstrapCi(
  deltas: number[],
  seed: number,
  resamples = 4000,
): BootstrapCi | null {
  const n = deltas.length;
  if (n < 2) return null;
  const rand = lcg(seed);
  const means: number[] = new Array(resamples);
  for (let b = 0; b < resamples; b++) {
    let s = 0;
    for (let i = 0; i < n; i++) s += deltas[Math.floor(rand() * n) % n];
    means[b] = s / n;
  }
  means.sort((a, b) => a - b);
  const q = (p: number) => means[Math.min(resamples - 1, Math.max(0, Math.floor(p * resamples)))];
  return {
    meanDelta: deltas.reduce((a, b) => a + b, 0) / n,
    lo95: q(0.025),
    hi95: q(0.975),
  };
}

export function mean(xs: number[]): number {
  return xs.length === 0 ? NaN : xs.reduce((a, b) => a + b, 0) / xs.length;
}
