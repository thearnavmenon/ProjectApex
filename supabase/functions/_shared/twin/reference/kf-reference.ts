/**
 * kf_reference.ts
 *
 * Independent reference implementation of Kalman-filter mathematics,
 * written from first principles for property-testing a separately
 * implemented Unscented Kalman Filter.
 *
 * Conventions
 * -----------
 * - Matrices are `number[][]`, row-major: a[i][j] is row i, column j.
 * - Vectors are `number[]` (treated as column vectors in the equations).
 * - Gauss–Hermite quadrature uses the PHYSICISTS' convention:
 *       ∫_{-∞}^{∞} f(t)·e^{-t²} dt ≈ Σ_i w_i·f(t_i),   with Σ_i w_i = √π.
 *   To integrate against a Gaussian prior N(m, P) with P = L·Lᵀ, substitute
 *       x = m + √2·L·ξ   (ξ_j = physicists' node in dimension j),
 *   so E[g(X)] = π^{-d/2} Σ (Π_j w_{i_j}) g(m + √2·L·ξ).
 * - erf: computed from the everywhere-convergent positive-term series
 *       erf(x) = (2/√π)·e^{-x²}·Σ_{k≥0} (2x²)^k · x / (2k+1)!!
 *   summed until the term falls below 1e-17 of the running sum, with
 *   erf(x) = ±1 for |x| > 6 (erfc(6) ≈ 2.15e-17 < double-precision ulp of 1).
 *   Expected absolute accuracy: better than 1e-13 for all real x
 *   (in practice a few units in the last place, ~1e-15), since the series
 *   has no cancellation and only the final exp·sum product rounds.
 *
 * Purity: every function here is deterministic and side-effect free.
 * No imports, no I/O, no Date.now, no Math.random, no console.
 */

// ---------------------------------------------------------------------------
// Matrix helpers (row-major number[][], vectors number[])
// ---------------------------------------------------------------------------

/** Matrix product C = A·B. A is (n×k), B is (k×m), result is (n×m). */
export function matMul(a: number[][], b: number[][]): number[][] {
  if (a.length === 0 || b.length === 0) {
    throw new Error("matMul: empty matrix");
  }
  const n = a.length;
  const k = a[0].length;
  const m = b[0].length;
  if (b.length !== k) {
    throw new Error(`matMul: inner dimensions differ (${k} vs ${b.length})`);
  }
  const out: number[][] = [];
  for (let i = 0; i < n; i++) {
    if (a[i].length !== k) throw new Error("matMul: ragged matrix A");
    const row = new Array<number>(m).fill(0);
    for (let p = 0; p < k; p++) {
      const aip = a[i][p];
      const brow = b[p];
      if (brow.length !== m) throw new Error("matMul: ragged matrix B");
      for (let j = 0; j < m; j++) row[j] += aip * brow[j];
    }
    out.push(row);
  }
  return out;
}

/** Matrix–vector product w = A·v. A is (n×k), v has length k. */
export function matVec(a: number[][], v: number[]): number[] {
  const n = a.length;
  const out = new Array<number>(n).fill(0);
  for (let i = 0; i < n; i++) {
    if (a[i].length !== v.length) {
      throw new Error(`matVec: dimension mismatch (row ${i}: ${a[i].length} vs ${v.length})`);
    }
    let s = 0;
    for (let j = 0; j < v.length; j++) s += a[i][j] * v[j];
    out[i] = s;
  }
  return out;
}

/** Transpose: out[j][i] = a[i][j]. */
export function transpose(a: number[][]): number[][] {
  if (a.length === 0) return [];
  const n = a.length;
  const m = a[0].length;
  const out: number[][] = [];
  for (let j = 0; j < m; j++) {
    const row = new Array<number>(n);
    for (let i = 0; i < n; i++) {
      if (a[i].length !== m) throw new Error("transpose: ragged matrix");
      row[i] = a[i][j];
    }
    out.push(row);
  }
  return out;
}

/** Elementwise sum C = A + B (same shape). */
export function matAdd(a: number[][], b: number[][]): number[][] {
  if (a.length !== b.length) throw new Error("matAdd: row-count mismatch");
  return a.map((row, i) => {
    if (row.length !== b[i].length) throw new Error("matAdd: column-count mismatch");
    return row.map((v, j) => v + b[i][j]);
  });
}

/** Elementwise difference C = A − B (same shape). */
export function matSub(a: number[][], b: number[][]): number[][] {
  if (a.length !== b.length) throw new Error("matSub: row-count mismatch");
  return a.map((row, i) => {
    if (row.length !== b[i].length) throw new Error("matSub: column-count mismatch");
    return row.map((v, j) => v - b[i][j]);
  });
}

/** n×n identity matrix. */
export function identity(n: number): number[][] {
  const out: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = new Array<number>(n).fill(0);
    row[i] = 1;
    out.push(row);
  }
  return out;
}

/** Internal: dot product of two equal-length vectors. */
function dot(a: number[], b: number[]): number {
  if (a.length !== b.length) {
    throw new Error(`dot: length mismatch (${a.length} vs ${b.length})`);
  }
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
}

/** Internal: exact symmetrization (A + Aᵀ)/2, used to scrub rounding skew. */
function symmetrize(a: number[][]): number[][] {
  const n = a.length;
  const out: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = new Array<number>(n);
    for (let j = 0; j < n; j++) row[j] = 0.5 * (a[i][j] + a[j][i]);
    out.push(row);
  }
  return out;
}

/**
 * Cholesky decomposition: returns lower-triangular L with A = L·Lᵀ.
 *
 * Standard inner-product algorithm:
 *   L[j][j] = sqrt( A[j][j] − Σ_{k<j} L[j][k]² )
 *   L[i][j] = ( A[i][j] − Σ_{k<j} L[i][k]·L[j][k] ) / L[j][j]   for i > j
 *
 * Throws if A is not square, is materially asymmetric (relative tolerance
 * 1e-8 — asymmetric matrices are by definition not PSD), or if any diagonal
 * pivot is ≤ 0 or non-finite. Note this is a strict factorization: a
 * PSD-but-singular matrix (zero eigenvalue) also throws, which is the
 * desired behavior here because the quadrature needs an invertible L.
 * Entries are symmetrized ((A[i][j]+A[j][i])/2) before use so that
 * float-level asymmetry below the tolerance cannot skew the factor.
 */
export function cholesky(a: number[][]): number[][] {
  const n = a.length;
  if (n === 0) throw new Error("cholesky: empty matrix");
  for (const row of a) {
    if (row.length !== n) throw new Error("cholesky: matrix must be square");
  }
  let scale = 1;
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) scale = Math.max(scale, Math.abs(a[i][j]));
  }
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      if (!(Math.abs(a[i][j] - a[j][i]) <= 1e-8 * scale)) {
        throw new Error(`cholesky: matrix is not symmetric at (${i},${j}) — not PSD`);
      }
    }
  }
  const L: number[][] = [];
  for (let i = 0; i < n; i++) L.push(new Array<number>(n).fill(0));
  for (let j = 0; j < n; j++) {
    for (let i = j; i < n; i++) {
      let s = 0.5 * (a[i][j] + a[j][i]);
      for (let k = 0; k < j; k++) s -= L[i][k] * L[j][k];
      if (i === j) {
        if (!(s > 0) || !Number.isFinite(s)) {
          throw new Error(`cholesky: matrix is not positive definite (pivot ${j} = ${s})`);
        }
        L[j][j] = Math.sqrt(s);
      } else {
        L[i][j] = s / L[j][j];
      }
    }
  }
  return L;
}

// ---------------------------------------------------------------------------
// Exact linear Kalman filter steps
// ---------------------------------------------------------------------------

/**
 * Exact linear Kalman predict step.
 *
 * Equations (textbook form, e.g. Bar-Shalom or Anderson & Moore):
 *   mean⁻ = F · mean
 *   cov⁻  = F · cov · Fᵀ + Q
 *
 * The returned covariance is symmetrized ((C + Cᵀ)/2) to scrub rounding skew;
 * this is exact for symmetric inputs.
 */
export function kfPredict(
  mean: number[],
  cov: number[][],
  F: number[][],
  Q: number[][],
): { mean: number[]; cov: number[][] } {
  const newMean = matVec(F, mean);
  const newCov = symmetrize(matAdd(matMul(matMul(F, cov), transpose(F)), Q));
  return { mean: newMean, cov: newCov };
}

/**
 * Exact linear Kalman update for a SCALAR observation
 *   y = hᵀ·x + v,   v ~ N(0, r),   h a length-n vector, r > 0.
 *
 * Equations (with P = cov, x = mean; H = hᵀ is the 1×n observation row):
 *   innovation        ν  = y − hᵀ·x
 *   innovation var    S  = hᵀ·P·h + r            (scalar)
 *   Kalman gain       K  = P·h / S               (length-n vector)
 *   posterior mean    x⁺ = x + K·ν
 *   posterior cov     P⁺ = (I − K·hᵀ)·P·(I − K·hᵀ)ᵀ + K·r·Kᵀ   (Joseph form)
 *
 * Joseph form is algebraically identical to the standard P⁺ = (I − K·hᵀ)·P
 * for the optimal gain, but remains symmetric positive-semidefinite under
 * floating-point rounding. The result is additionally symmetrized.
 */
export function kfUpdateScalar(
  mean: number[],
  cov: number[][],
  h: number[],
  y: number,
  r: number,
): { mean: number[]; cov: number[][] } {
  const n = mean.length;
  if (h.length !== n) throw new Error(`kfUpdateScalar: h length ${h.length} != state dim ${n}`);
  if (cov.length !== n) throw new Error(`kfUpdateScalar: cov is ${cov.length}x?, expected ${n}x${n}`);
  if (!(r > 0)) throw new Error("kfUpdateScalar: observation variance r must be > 0");

  const Ph = matVec(cov, h); // P·h (P symmetric, so this is also (hᵀP)ᵀ)
  const S = dot(h, Ph) + r;
  if (!(S > 0) || !Number.isFinite(S)) {
    throw new Error(`kfUpdateScalar: innovation variance S = ${S} is not positive`);
  }
  const K = Ph.map((v: number): number => v / S);
  const innov = y - dot(h, mean);
  const newMean = mean.map((m: number, i: number): number => m + K[i] * innov);

  // A = I − K·hᵀ
  const A: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = new Array<number>(n);
    for (let j = 0; j < n; j++) row[j] = (i === j ? 1 : 0) - K[i] * h[j];
    A.push(row);
  }
  const P = matMul(matMul(A, cov), transpose(A));
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) P[i][j] += r * K[i] * K[j];
  }
  return { mean: newMean, cov: symmetrize(P) };
}

// ---------------------------------------------------------------------------
// Gauss–Hermite quadrature (physicists' convention)
// ---------------------------------------------------------------------------

/**
 * Gauss–Hermite nodes and weights, PHYSICISTS' convention:
 *   ∫_{-∞}^{∞} f(t)·e^{-t²} dt ≈ Σ_{i=1..n} w_i·f(t_i),   Σ w_i = √π.
 *
 * Method: Newton's method on the ORTHONORMAL Hermite polynomials
 * (equivalent to Golub–Welsch — the same three-term recurrence defines the
 * Jacobi matrix; Newton on the polynomial finds the same eigenvalue-nodes).
 * Recurrence (orthonormal, weight e^{-t²}):
 *   ĥ_0(t) = π^{-1/4}
 *   ĥ_j(t) = t·√(2/j)·ĥ_{j-1}(t) − √((j−1)/j)·ĥ_{j-2}(t)
 * Derivative identity:  ĥ_n'(t) = √(2n)·ĥ_{n-1}(t)
 * Weights:              w_i = 1 / ( n · ĥ_{n-1}(t_i)² ) = 2 / (ĥ_n'(t_i))²
 * Initial guesses follow the classical asymptotic seeds (Numerical-Recipes
 * style); each root then converges quadratically to machine precision.
 * For odd n the middle node is exactly 0 by symmetry and is seeded as such.
 *
 * Spot check (n = 5, published 15-digit table, physicists' convention):
 *   nodes   0, ±0.958572464613819, ±2.020182870456086
 *   weights 0.945308720482942 (= 8√π/15), 0.393619323152241, 0.019953242059046
 * Hand check (n = 1): node 0, weight √π.  (n = 2): nodes ±1/√2, weights √π/2.
 *
 * Nodes are returned in ascending order with matching weights.
 * Intended for n ≤ 12 (works beyond, but callers here stay ≤ 12).
 */
export function ghNodes(n: number): { nodes: number[]; weights: number[] } {
  if (!Number.isInteger(n) || n < 1) {
    throw new Error(`ghNodes: n must be a positive integer, got ${n}`);
  }
  const nodes = new Array<number>(n).fill(0);
  const weights = new Array<number>(n).fill(0);
  const m = Math.floor((n + 1) / 2); // number of non-negative roots
  const PIM4 = Math.pow(Math.PI, -0.25); // π^{-1/4} = ĥ_0
  const EPS = 3e-14;

  let z = 0;
  for (let i = 0; i < m; i++) {
    // Initial guess for the (i+1)-th largest root.
    if (n % 2 === 1 && i === m - 1) {
      z = 0; // middle root of odd n is exactly 0 by symmetry
    } else if (i === 0) {
      z = Math.sqrt(2 * n + 1) - 1.85575 * Math.pow(2 * n + 1, -1.0 / 6.0);
    } else if (i === 1) {
      z -= 1.14 * Math.pow(n, 0.426) / z;
    } else if (i === 2) {
      z = 1.86 * z - 0.86 * nodes[0];
    } else if (i === 3) {
      z = 1.91 * z - 0.91 * nodes[1];
    } else {
      z = 2.0 * z - nodes[i - 2];
    }
    // Newton iteration on ĥ_n(z) = 0.
    let pp = 0;
    let converged = false;
    for (let iter = 0; iter < 100; iter++) {
      let p1 = PIM4; // ĥ_0
      let p2 = 0;
      for (let j = 1; j <= n; j++) {
        const p3 = p2;
        p2 = p1;
        p1 = z * Math.sqrt(2 / j) * p2 - Math.sqrt((j - 1) / j) * p3;
      }
      // p1 = ĥ_n(z), p2 = ĥ_{n-1}(z); derivative ĥ_n'(z) = √(2n)·ĥ_{n-1}(z)
      pp = Math.sqrt(2 * n) * p2;
      const z1 = z;
      z = z1 - p1 / pp;
      if (Math.abs(z - z1) <= EPS) {
        converged = true;
        break;
      }
    }
    if (!converged) throw new Error(`ghNodes: Newton failed to converge for n=${n}, root ${i}`);
    // Store descending-positive root and its mirror; sort ascending afterwards.
    nodes[i] = z;
    nodes[n - 1 - i] = -z;
    weights[i] = 2 / (pp * pp); // = 1 / (n · ĥ_{n-1}(z)²)
    weights[n - 1 - i] = weights[i];
  }

  // Sort ascending, keeping node/weight pairs together.
  const order = nodes.map((_, i: number): number => i)
    .sort((p: number, q: number): number => nodes[p] - nodes[q]);
  return {
    nodes: order.map((i: number): number => nodes[i]),
    weights: order.map((i: number): number => weights[i]),
  };
}

/**
 * Brute-force Bayesian posterior moments for a NONLINEAR scalar observation,
 * via tensor-product Gauss–Hermite quadrature.
 *
 * Model:
 *   prior       x ~ N(mean, cov)                         (dimension d)
 *   likelihood  y | x ~ N( hFn(x), r )                   (scalar, r > 0)
 *   posterior   p(x|y) ∝ N(x; mean, cov) · exp( −(y − hFn(x))² / (2r) )
 *
 * Posterior moments computed:
 *   Z    = ∫ N(x; mean, cov) · L(x) dx
 *   μ⁺   = (1/Z) ∫ x · N(x; mean, cov) · L(x) dx
 *   P⁺   = (1/Z) ∫ (x − μ⁺)(x − μ⁺)ᵀ · N(x; mean, cov) · L(x) dx
 * where L(x) = exp( −(y − hFn(x))² / (2r) ). The constant likelihood
 * normalizer 1/√(2πr) and the prior normalizer π^{-d/2} cancel in the
 * ratios and are omitted.
 *
 * Quadrature: with cov = L·Lᵀ (Cholesky) and physicists' GH nodes {t_i, w_i}
 * (pointsPerDim per dimension), each tensor-grid multi-index (i_1..i_d) maps
 * to the state-space point
 *   x = mean + √2 · L · (t_{i_1}, …, t_{i_d})ᵀ
 * with prior weight Π_j w_{i_j}. Each node's weight is multiplied by its
 * likelihood; sums are normalized by their total. Log-weights with a
 * subtract-the-max (log-sum-exp) stabilization avoid underflow when the
 * observation is far in the prior's tail.
 *
 * Accuracy: exact in the limit pointsPerDim → ∞ for smooth hFn; for mildly
 * nonlinear hFn the error decays geometrically in pointsPerDim. Grid size is
 * pointsPerDim^d (callers keep d ≤ 4, pointsPerDim ≤ 12 → ≤ 20,736 nodes).
 */
export function ghQuadraturePosterior(
  mean: number[],
  cov: number[][],
  hFn: (x: number[]) => number,
  y: number,
  r: number,
  pointsPerDim: number,
): { mean: number[]; cov: number[][] } {
  const d = mean.length;
  if (d < 1) throw new Error("ghQuadraturePosterior: empty state");
  if (cov.length !== d) {
    throw new Error(`ghQuadraturePosterior: cov is ${cov.length}x?, expected ${d}x${d}`);
  }
  if (!(r > 0)) throw new Error("ghQuadraturePosterior: r must be > 0");
  if (!Number.isInteger(pointsPerDim) || pointsPerDim < 1) {
    throw new Error(`ghQuadraturePosterior: pointsPerDim must be a positive integer, got ${pointsPerDim}`);
  }

  const L = cholesky(cov);
  const gh = ghNodes(pointsPerDim);
  const nodes = gh.nodes;
  const logW = gh.weights.map((w: number): number => Math.log(w));

  const total = Math.pow(pointsPerDim, d);
  const points: number[][] = new Array(total);
  const logw: number[] = new Array(total);
  const idx = new Array<number>(d).fill(0);

  for (let c = 0; c < total; c++) {
    // x = mean + √2 · L · ξ, with ξ_j = nodes[idx[j]] (L lower-triangular).
    const x = new Array<number>(d);
    for (let i = 0; i < d; i++) {
      let s = mean[i];
      for (let j = 0; j <= i; j++) s += Math.SQRT2 * L[i][j] * nodes[idx[j]];
      x[i] = s;
    }
    // log(node weight) = Σ_j log w_{idx[j]}  −  (y − h(x))²/(2r)
    const resid = y - hFn(x);
    let lw = -(resid * resid) / (2 * r);
    for (let j = 0; j < d; j++) lw += logW[idx[j]];
    points[c] = x;
    logw[c] = lw;
    // Odometer increment of the multi-index.
    for (let p = 0; p < d; p++) {
      idx[p] += 1;
      if (idx[p] < pointsPerDim) break;
      idx[p] = 0;
    }
  }

  // Log-sum-exp normalization.
  let maxLw = -Infinity;
  for (const v of logw) if (v > maxLw) maxLw = v;
  if (!Number.isFinite(maxLw)) {
    throw new Error("ghQuadraturePosterior: degenerate likelihood (all node weights vanished)");
  }
  const w = new Array<number>(total);
  let Z = 0;
  for (let c = 0; c < total; c++) {
    w[c] = Math.exp(logw[c] - maxLw);
    Z += w[c];
  }
  if (!(Z > 0) || !Number.isFinite(Z)) {
    throw new Error(`ghQuadraturePosterior: non-finite normalizer (Z = ${Z}); check hFn output`);
  }

  const postMean = new Array<number>(d).fill(0);
  for (let c = 0; c < total; c++) {
    for (let i = 0; i < d; i++) postMean[i] += w[c] * points[c][i];
  }
  for (let i = 0; i < d; i++) postMean[i] /= Z;

  const P: number[][] = [];
  for (let i = 0; i < d; i++) P.push(new Array<number>(d).fill(0));
  for (let c = 0; c < total; c++) {
    const x = points[c];
    for (let i = 0; i < d; i++) {
      const di = x[i] - postMean[i];
      for (let j = i; j < d; j++) P[i][j] += w[c] * di * (x[j] - postMean[j]);
    }
  }
  for (let i = 0; i < d; i++) {
    for (let j = i; j < d; j++) {
      P[i][j] /= Z;
      P[j][i] = P[i][j];
    }
  }
  return { mean: postMean, cov: P };
}

// ---------------------------------------------------------------------------
// Gaussian CRPS and normal special functions
// ---------------------------------------------------------------------------

/**
 * Error function erf(x) = (2/√π) ∫_0^x e^{-t²} dt.
 *
 * Computed from the everywhere-convergent, all-positive-terms series
 *   erf(x) = (2/√π) · e^{-x²} · Σ_{k=0}^{∞} (2x²)^k · x / (1·3·5···(2k+1))
 * (no cancellation, unlike the alternating Maclaurin series), summed until
 * the term drops below 1e-17 of the running sum. For |x| > 6, returns ±1
 * exactly (erfc(6) ≈ 2.15e-17 is below the double-precision ulp of 1).
 * Expected absolute accuracy: < 1e-13 for all real x (typically ~1e-15).
 * This exceeds Abramowitz–Stegun 7.1.26 (abs error ≤ 1.5e-7).
 */
export function erf(x: number): number {
  if (Number.isNaN(x)) return NaN;
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

/** Standard normal density φ(z) = e^{-z²/2} / √(2π). */
export function stdNormPdf(z: number): number {
  return Math.exp(-0.5 * z * z) / Math.sqrt(2 * Math.PI);
}

/** Standard normal CDF Φ(z) = ½·(1 + erf(z/√2)). Accuracy inherited from erf. */
export function stdNormCdf(z: number): number {
  return 0.5 * (1 + erf(z / Math.SQRT2));
}

/**
 * Closed-form CRPS of a Gaussian forecast N(mean, sd²) against realized y.
 *
 * Gneiting & Raftery (2007), eq. for the normal distribution:
 *   z    = (y − mean) / sd
 *   CRPS = sd · [ z·(2Φ(z) − 1) + 2φ(z) − 1/√π ]
 * CRPS is negatively oriented (smaller is better) and has units of y.
 * Limit sd → 0 gives the point-forecast CRPS |y − mean|, returned exactly
 * when sd === 0. Throws for sd < 0.
 * Reference values: at z = 0, CRPS = sd·(2/√(2π) − 1/√π) ≈ sd·0.233694977255.
 */
export function gaussianCrps(y: number, mean: number, sd: number): number {
  if (!(sd >= 0)) throw new Error(`gaussianCrps: sd must be >= 0, got ${sd}`);
  if (sd === 0) return Math.abs(y - mean);
  const z = (y - mean) / sd;
  return sd * (z * (2 * stdNormCdf(z) - 1) + 2 * stdNormPdf(z) - 1 / Math.sqrt(Math.PI));
}

// ---------------------------------------------------------------------------
// Self-test cases (hand-computable smoke checks)
// ---------------------------------------------------------------------------

export interface SelfTestCase {
  /** What the case checks. */
  name: string;
  /** Expected values, flattened; derivation is worked by hand in comments. */
  expected: number[];
  /** Closure producing the actual values, flattened in the same order. */
  actual: () => number[];
  /** Absolute per-element tolerance for expected vs actual. */
  tol: number;
}

/**
 * Smoke checks with hand-worked numbers. Wire them as:
 *   for (const c of SELF_TEST_CASES) {
 *     const got = c.actual();
 *     assert(got.length === c.expected.length);
 *     got.forEach((v, i) => assert(Math.abs(v - c.expected[i]) <= c.tol));
 *   }
 */
export const SELF_TEST_CASES: SelfTestCase[] = [
  {
    // Constant-velocity predict, worked by hand:
    //   mean = [1, 2], cov = I, F = [[1,1],[0,1]], Q = [[0,0],[0,0.5]]
    //   mean⁻ = F·mean = [1+2, 2] = [3, 2]
    //   F·I·Fᵀ = F·Fᵀ = [[1,1],[0,1]]·[[1,0],[1,1]] = [[2,1],[1,1]]
    //   cov⁻  = [[2,1],[1,1]] + Q = [[2,1],[1,1.5]]
    // Flattened as [mean..., cov row 0..., cov row 1...].
    name: "kfPredict: 2-D constant-velocity step",
    expected: [3, 2, 2, 1, 1, 1.5],
    actual: (): number[] => {
      const p = kfPredict([1, 2], identity(2), [[1, 1], [0, 1]], [[0, 0], [0, 0.5]]);
      return [...p.mean, ...p.cov[0], ...p.cov[1]];
    },
    tol: 1e-12,
  },
  {
    // 1-D scalar update, worked by hand:
    //   prior N(0, 4), h = [1], y = 2, r = 1
    //   S  = hᵀPh + r = 4 + 1 = 5
    //   K  = Ph/S = 4/5 = 0.8
    //   ν  = y − hᵀx = 2 − 0 = 2
    //   x⁺ = 0 + 0.8·2 = 1.6
    //   Joseph: (1 − 0.8)·4·(1 − 0.8) + 0.8·1·0.8 = 0.16 + 0.64 = 0.8
    //   (matches the short form (1 − K·h)·P = 0.2·4 = 0.8)
    name: "kfUpdateScalar: 1-D update, Joseph form",
    expected: [1.6, 0.8],
    actual: (): number[] => {
      const u = kfUpdateScalar([0], [[4]], [1], 2, 1);
      return [u.mean[0], u.cov[0][0]];
    },
    tol: 1e-12,
  },
  {
    // Gaussian CRPS at z = 0 (y at the forecast mean), worked by hand:
    //   CRPS = sd·(0 + 2φ(0) − 1/√π) = sd·(2/√(2π) − 1/√π)
    //        = sd·(0.7978845608028654 − 0.5641895835477563)
    //        = sd·0.2336949772551091
    //   With sd = 2: CRPS = 0.4673899545102182.
    name: "gaussianCrps: z = 0 closed form",
    expected: [0.4673899545102182],
    actual: (): number[] => [gaussianCrps(3, 3, 2)],
    tol: 1e-12,
  },
  {
    // GH quadrature with a LINEAR observation must reproduce the exact
    // conjugate-Gaussian KF update. Worked by hand:
    //   prior N(0, 1), h(x) = x, y = 1, r = 4
    //   S = 1 + 4 = 5, K = 1/5 = 0.2
    //   mean⁺ = 0.2·1 = 0.2, var⁺ = (1 − 0.2)·1 = 0.8
    // GH is not algebraically exact here (the likelihood is a Gaussian in ξ,
    // not a polynomial), but with 12 points/dim on this mild case the
    // quadrature error is far below the 1e-6 tolerance (~1e-10 in practice).
    name: "ghQuadraturePosterior: linear h matches exact KF update",
    expected: [0.2, 0.8],
    actual: (): number[] => {
      const p = ghQuadraturePosterior([0], [[1]], (x: number[]): number => x[0], 1, 4, 12);
      return [p.mean[0], p.cov[0][0]];
    },
    tol: 1e-6,
  },
];
