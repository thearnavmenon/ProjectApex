// Property tests for the twin UKF against the INDEPENDENT reference
// implementation in reference/kf-reference.ts (written from first
// principles by a separate agent, self-tests included):
//
//   1. Reference self-tests (hand-worked numbers) hold.
//   2. UKF ≡ exact KF on random linear systems (the cubature UT is exact
//      for linear dynamics/observations — tight tolerance).
//   3. UKF nonlinear update ≈ Gauss–Hermite quadrature posterior on the
//      twin's REAL observation function (loose tolerance: the UT is a
//      2nd-order approximation).
//   4. Covariance stays symmetric PSD under seeded random predict/update
//      sequences (the "no silent divergence" gate).
//
// Deterministic: a hand-rolled LCG provides the "random" cases — no
// Math.random(), same numbers every run.

import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert";
import {
  ghQuadraturePosterior,
  kfPredict,
  kfUpdateScalar,
  SELF_TEST_CASES,
} from "./reference/kf-reference.ts";
import { predictScalar, ukfPredict, ukfUpdateScalar } from "./ukf.ts";
import { isSymmetricPsd, type Mat, matVec, type Vec } from "./linalg.ts";
import { IDX_C, IDX_G, IDX_R, observationFn } from "./model.ts";

// ── Deterministic LCG (Numerical Recipes constants) ──────────────────────────

function lcg(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function randPsd(rand: () => number, dim: number, scale: number): Mat {
  // A·Aᵀ + ε·I is symmetric PD.
  const a: Mat = Array.from(
    { length: dim },
    () => Array.from({ length: dim }, () => (rand() - 0.5) * scale),
  );
  const m: Mat = Array.from({ length: dim }, () => new Array(dim).fill(0));
  for (let i = 0; i < dim; i++) {
    for (let j = 0; j < dim; j++) {
      let s = 0;
      for (let k = 0; k < dim; k++) s += a[i][k] * a[j][k];
      m[i][j] = s;
    }
    m[i][i] += 0.01 * scale * scale;
  }
  return m;
}

Deno.test("reference self-tests hold (hand-worked numbers)", () => {
  for (const c of SELF_TEST_CASES) {
    const got = c.actual();
    assertEquals(got.length, c.expected.length, c.name);
    got.forEach((v, i) => {
      assert(
        Math.abs(v - c.expected[i]) <= c.tol,
        `${c.name}: element ${i} — got ${v}, expected ${c.expected[i]}`,
      );
    });
  }
});

Deno.test("UKF predict ≡ exact KF predict on random linear systems", () => {
  const rand = lcg(42);
  for (let trial = 0; trial < 25; trial++) {
    const dim = 2 + Math.floor(rand() * 5); // 2..6
    const mean: Vec = Array.from({ length: dim }, () => (rand() - 0.5) * 4);
    const cov = randPsd(rand, dim, 1.0);
    const f: Mat = Array.from(
      { length: dim },
      (_, i) =>
        Array.from(
          { length: dim },
          (_, j) => (i === j ? 1 : 0) + (rand() - 0.5) * 0.4,
        ),
    );
    const q: Mat = Array.from({ length: dim }, (_, i) =>
      Array.from({ length: dim }, (_, j) => (i === j ? 0.05 * rand() : 0)));

    const ref = kfPredict(mean, cov, f, q);
    const ukf = ukfPredict(
      { mean, cov },
      (x) => matVec(f, x),
      q,
    );
    for (let i = 0; i < dim; i++) {
      assertAlmostEquals(ukf.mean[i], ref.mean[i], 1e-9, `mean[${i}] trial ${trial}`);
      for (let j = 0; j < dim; j++) {
        assertAlmostEquals(
          ukf.cov[i][j],
          ref.cov[i][j],
          1e-8,
          `cov[${i}][${j}] trial ${trial}`,
        );
      }
    }
  }
});

Deno.test("UKF scalar update ≡ exact KF update on random linear observations", () => {
  const rand = lcg(1337);
  for (let trial = 0; trial < 25; trial++) {
    const dim = 2 + Math.floor(rand() * 5);
    const mean: Vec = Array.from({ length: dim }, () => (rand() - 0.5) * 4);
    const cov = randPsd(rand, dim, 1.0);
    const h: Vec = Array.from({ length: dim }, () => (rand() - 0.5) * 2);
    const y = (rand() - 0.5) * 6;
    const r = 0.2 + rand();

    const ref = kfUpdateScalar(mean, cov, h, y, r);
    const dot = (x: Vec) => x.reduce((acc, v, i) => acc + v * h[i], 0);
    const ukf = ukfUpdateScalar({ mean, cov }, dot, y, r);
    for (let i = 0; i < dim; i++) {
      assertAlmostEquals(ukf.mean[i], ref.mean[i], 1e-8, `mean[${i}] trial ${trial}`);
      for (let j = 0; j < dim; j++) {
        assertAlmostEquals(
          ukf.cov[i][j],
          ref.cov[i][j],
          1e-7,
          `cov[${i}][${j}] trial ${trial}`,
        );
      }
    }
  }
});

Deno.test("UKF nonlinear update ≈ Gauss–Hermite posterior on the twin observation model", () => {
  const rand = lcg(2026);
  for (let trial = 0; trial < 12; trial++) {
    // 4-dim twin state [C, T, G, r] in the POST-BOOTSTRAP operating regime
    // (prior sd on C ≈ 0.05–0.08 log-units). Regime choice is load-bearing
    // for the comparison's validity, not a convenience: a rep observation
    // constrains C to sd ≈ σ_obs/(dh/dC) ≈ 1.3/36 ≈ 0.036, and the GH
    // reference places its grid at PRIOR scale — with a bootstrap-wide
    // prior (sd 0.2+) the likelihood falls between grid nodes and the
    // quadrature itself is unreliable. In the unresolvable regime the UKF
    // errs CONSERVATIVE (posterior variance too large — measured ~13× vs
    // a then-unreliable reference; wider bands, slower learning for the
    // first few sets, never overconfidence). Documented in ADR-0031.
    const mean: Vec = [
      Math.log(40 + rand() * 80), // C: e1RM 40..120 kg
      (rand() - 0.5) * 0.004, // T
      rand() * 0.03, // G
      Math.log(30) + (rand() - 0.5) * 0.2, // log rho
    ];
    const cSd = 0.05 + 0.03 * rand();
    const cov: Mat = [
      [cSd * cSd, 0, 0, 0],
      [0, 3e-6, 0, 0],
      [0, 0, 1e-4, 0],
      [0, 0, 0, 0.04],
    ];
    // Load at ~75–90% of point-estimate e1RM → 3..10 achievable reps.
    const w = Math.exp(mean[IDX_C]) * (0.75 + rand() * 0.15);
    const h = observationFn(w, -1, 0);
    const priorPred = h(mean);
    const y = priorPred + (rand() - 0.5) * 3; // observation near prior mean
    const r = 1.3 ** 2;

    const ref = ghQuadraturePosterior(mean, cov, h, y, r, 11);
    const ukf = ukfUpdateScalar({ mean, cov }, h, y, r);

    // Tolerance calibrated to what this test is FOR: catching
    // implementation errors (sign/gain/bookkeeping), which produce
    // O(prior-sd) discrepancies. The UT itself is a 2nd-order
    // approximation; measured truncation across these seeded trials
    // peaks at ~13% of the PRIOR sd (on the log-ρ dimension, which is
    // strongly correlated with C in the likelihood). Bound: 16% of
    // prior sd on the mean; posterior variance within ~30% relative.
    for (const idx of [IDX_C, IDX_G, IDX_R]) {
      const priorSd = Math.sqrt(cov[idx][idx]);
      assert(
        Math.abs(ukf.mean[idx] - ref.mean[idx]) <=
          Math.max(0.16 * priorSd, 1e-6),
        `trial ${trial}: mean[${idx}] UKF ${ukf.mean[idx]} vs GH ${
          ref.mean[idx]
        } (prior sd ${priorSd})`,
      );
      const ratio = ukf.cov[idx][idx] / ref.cov[idx][idx];
      assert(
        ratio > 0.7 && ratio < 1.43,
        `trial ${trial}: var[${idx}] ratio ${ratio}`,
      );
    }
  }
});

Deno.test("covariance stays symmetric PSD through seeded random op sequences", () => {
  const rand = lcg(777);
  for (let trial = 0; trial < 10; trial++) {
    const dim = 4;
    let g = {
      mean: [Math.log(60), 0, 0, Math.log(30)] as Vec,
      cov: [
        [0.0625, 0, 0, 0],
        [0, 6.25e-6, 0, 0],
        [0, 0, 1e-4, 0],
        [0, 0, 0, 0.0625],
      ] as Mat,
    };
    for (let step = 0; step < 60; step++) {
      if (rand() < 0.4) {
        const dt = rand() * 7;
        const decay = Math.exp(-dt * 24 / 30);
        g = ukfPredict(
          g,
          (x) => [x[0] + x[1] * dt, x[1], x[2] * decay, x[3]],
          [
            [6.4e-5 * dt, 0, 0, 0],
            [0, 3.6e-7 * dt, 0, 0],
            [0, 0, 1.6e-5 * dt, 0],
            [0, 0, 0, 4e-6 * dt],
          ],
        );
      } else {
        const w = Math.exp(g.mean[IDX_C]) * (0.7 + rand() * 0.25);
        const h = observationFn(w, -1, rand() * 0.03);
        const y = Math.max(0, h(g.mean) + (rand() - 0.5) * 4);
        g = ukfUpdateScalar(g, h, y, 1.69);
      }
      assert(
        isSymmetricPsd(g.cov),
        `trial ${trial} step ${step}: covariance lost symmetric PSD`,
      );
      assert(
        g.mean.every(Number.isFinite),
        `trial ${trial} step ${step}: non-finite mean`,
      );
    }
  }
});

Deno.test("predictScalar moments match direct sigma-point expectation on a linear observable", () => {
  const mean: Vec = [Math.log(80), 0.001, 0.01, Math.log(30)];
  const cov: Mat = [
    [0.04, 0, 0, 0],
    [0, 4e-6, 0, 0],
    [0, 0, 1e-4, 0],
    [0, 0, 0, 0.04],
  ];
  // Linear observable: h = C alone. Predictive mean = mean[C]; variance =
  // cov[C][C] + r (UT exact on linear).
  const r = 0.5;
  const p = predictScalar({ mean, cov }, (x) => x[IDX_C], r);
  assertAlmostEquals(p.mean, mean[IDX_C], 1e-10);
  assertAlmostEquals(p.variance, cov[IDX_C][IDX_C] + r, 1e-10);
});
