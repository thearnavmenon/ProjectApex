// Project Apex — Athlete Twin (ADR-0031, Phase 1 shadow).
//
// Gaussian special functions shared by the engine's forecast head and the
// backtest scorer. One erf implementation for the whole twin subtree.
//
// Pure: no I/O, no clock reads, no randomness.

/**
 * Error function via the everywhere-convergent positive-term series
 * (no cancellation), matching the independent reference implementation's
 * accuracy class (< 1e-13 absolute for all real x).
 */
export function erf(x: number): number {
  if (x === 0) return 0;
  const ax = Math.abs(x);
  if (ax > 6) return x > 0 ? 1 : -1;
  let term = ax;
  let sum = ax;
  for (let k = 1; k <= 500; k++) {
    term *= (2 * ax * ax) / (2 * k + 1);
    sum += term;
    if (term <= sum * 1e-17) break;
  }
  const v = Math.min(1, (2 / Math.sqrt(Math.PI)) * Math.exp(-ax * ax) * sum);
  return x > 0 ? v : -v;
}

/** Standard normal density φ. */
export function stdNormPdf(z: number): number {
  return Math.exp(-0.5 * z * z) / Math.sqrt(2 * Math.PI);
}

/** Standard normal CDF Φ. */
export function stdNormCdf(z: number): number {
  return 0.5 * (1 + erf(z / Math.SQRT2));
}

/**
 * Closed-form CRPS of a Gaussian forecast N(mean, sd²) against realized y
 * (Gneiting & Raftery 2007). σ = 0 degenerates to |y − mean|.
 */
export function gaussianCrps(y: number, mean: number, sd: number): number {
  if (!(sd >= 0)) throw new Error(`gaussianCrps: sd must be >= 0, got ${sd}`);
  if (sd === 0) return Math.abs(y - mean);
  const z = (y - mean) / sd;
  return sd *
    (z * (2 * stdNormCdf(z) - 1) + 2 * stdNormPdf(z) - 1 / Math.sqrt(Math.PI));
}

/**
 * Mean of the upper-censored Gaussian min(X, cap), X ~ N(mu, sd²):
 *   E[min(X, cap)] = μ·Φ(d) − σ·φ(d) + cap·(1 − Φ(d)),  d = (cap−μ)/σ.
 * cap = null means no censoring.
 */
export function censoredMean(
  mu: number,
  sd: number,
  cap: number | null,
): number {
  if (cap === null) return mu;
  if (sd === 0) return Math.min(mu, cap);
  const d = (cap - mu) / sd;
  return mu * stdNormCdf(d) - sd * stdNormPdf(d) + cap * (1 - stdNormCdf(d));
}
