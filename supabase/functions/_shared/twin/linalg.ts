// Project Apex — Athlete Twin (ADR-0031, Phase 1 shadow).
//
// Minimal dense linear algebra for the per-pattern UKF. State dimension is
// tiny (4 + one offset per extra exercise in the pattern, ≤ ~10 in practice),
// so plain row-major number[][] with O(n³) algorithms is the right tool —
// no numeric library dependency, same discipline as ewma-engine.ts.
//
// Pure: no I/O, no clock reads, no randomness.

export type Vec = number[];
export type Mat = number[][]; // row-major

export function zeros(n: number): Vec {
  return new Array(n).fill(0);
}

export function zerosMat(rows: number, cols: number): Mat {
  return Array.from({ length: rows }, () => new Array(cols).fill(0));
}

export function identity(n: number): Mat {
  const m = zerosMat(n, n);
  for (let i = 0; i < n; i++) m[i][i] = 1;
  return m;
}

export function cloneMat(a: Mat): Mat {
  return a.map((row) => [...row]);
}

export function matVec(a: Mat, x: Vec): Vec {
  const out = zeros(a.length);
  for (let i = 0; i < a.length; i++) {
    let s = 0;
    for (let j = 0; j < x.length; j++) s += a[i][j] * x[j];
    out[i] = s;
  }
  return out;
}

export function outer(x: Vec, y: Vec): Mat {
  const m = zerosMat(x.length, y.length);
  for (let i = 0; i < x.length; i++) {
    for (let j = 0; j < y.length; j++) m[i][j] = x[i] * y[j];
  }
  return m;
}

export function matAdd(a: Mat, b: Mat): Mat {
  return a.map((row, i) => row.map((v, j) => v + b[i][j]));
}

export function matScale(a: Mat, s: number): Mat {
  return a.map((row) => row.map((v) => v * s));
}

export function vecAdd(x: Vec, y: Vec): Vec {
  return x.map((v, i) => v + y[i]);
}

export function vecSub(x: Vec, y: Vec): Vec {
  return x.map((v, i) => v - y[i]);
}

export function vecScale(x: Vec, s: number): Vec {
  return x.map((v) => v * s);
}

/**
 * Force exact symmetry: (A + Aᵀ)/2. UKF covariance updates accumulate
 * floating-point asymmetry; every write back to a covariance goes through
 * here so downstream Cholesky sees a symmetric input.
 */
export function symmetrize(a: Mat): Mat {
  const n = a.length;
  const m = zerosMat(n, n);
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) m[i][j] = (a[i][j] + a[j][i]) / 2;
  }
  return m;
}

/**
 * Cholesky decomposition A = L·Lᵀ (lower-triangular L) with jitter
 * escalation: on failure, retry with progressively larger diagonal jitter
 * (relative to mean diagonal magnitude) up to `maxTries`. Returns the factor
 * plus the jitter actually applied so callers can log covariance-health
 * incidents instead of diverging silently (the plan's "a filter that
 * diverges silently is worse than no filter").
 *
 * Throws only when even the largest jitter fails — a genuinely broken
 * covariance the caller must treat as a twin-update failure (shadow mode
 * catches and logs; the legacy pipeline is never affected).
 */
export function choleskyWithJitter(
  a: Mat,
  maxTries = 4,
): { l: Mat; jitterApplied: number } {
  const n = a.length;
  let meanDiag = 0;
  for (let i = 0; i < n; i++) meanDiag += Math.abs(a[i][i]);
  meanDiag = meanDiag / n || 1e-12;

  let jitter = 0;
  for (let attempt = 0; attempt <= maxTries; attempt++) {
    const l = tryCholesky(a, jitter);
    if (l !== null) return { l, jitterApplied: jitter };
    jitter = jitter === 0 ? meanDiag * 1e-10 : jitter * 100;
  }
  throw new Error("choleskyWithJitter: matrix not PSD even after jitter");
}

function tryCholesky(a: Mat, jitter: number): Mat | null {
  const n = a.length;
  const l = zerosMat(n, n);
  for (let i = 0; i < n; i++) {
    for (let j = 0; j <= i; j++) {
      let s = a[i][j];
      if (i === j) s += jitter;
      for (let k = 0; k < j; k++) s -= l[i][k] * l[j][k];
      if (i === j) {
        if (s <= 0 || !Number.isFinite(s)) return null;
        l[i][i] = Math.sqrt(s);
      } else {
        l[i][j] = s / l[j][j];
      }
    }
  }
  return l;
}

/**
 * PSD health check used by property tests and the engine's post-update
 * invariant: symmetric within `tol` and Cholesky-factorizable with at most
 * tiny jitter.
 */
export function isSymmetricPsd(a: Mat, tol = 1e-9): boolean {
  const n = a.length;
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) {
      const scale = Math.max(1, Math.abs(a[i][j]), Math.abs(a[j][i]));
      if (Math.abs(a[i][j] - a[j][i]) > tol * scale) return false;
    }
  }
  return tryCholesky(symmetrize(a), n > 0 ? 1e-12 : 0) !== null;
}
