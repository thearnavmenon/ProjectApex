// Scoring tests: Gaussian CRPS against the independent reference, the
// censored-Gaussian CRPS/mean/coverage against limits and seeded Monte
// Carlo, and bootstrap determinism.

import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert";
import { gaussianCrps as refCrps } from "../reference/kf-reference.ts";
import {
  censoredGaussianCrps,
  censoredInCentral90,
  censoredMean,
  gaussianCrps,
  inCentral90,
  lcg,
  pairedBootstrapCi,
} from "./scoring.ts";

Deno.test("gaussianCrps matches the independent reference across the z range", () => {
  for (const [y, mu, sd] of [
    [8, 8, 2],
    [10, 8, 2],
    [3, 8, 1.5],
    [8.1, 8, 0.5],
    [-4, 0, 3],
  ] as const) {
    assertAlmostEquals(
      gaussianCrps(y, mu, sd),
      refCrps(y, mu, sd),
      1e-12,
      `y=${y} mu=${mu} sd=${sd}`,
    );
  }
});

Deno.test("censoredGaussianCrps degenerates to Gaussian CRPS as cap → ∞", () => {
  for (const [y, mu, sd] of [[8, 9, 1.5], [12, 9, 2], [5, 9, 2]] as const) {
    assertAlmostEquals(
      censoredGaussianCrps(y, mu, sd, 1e6),
      gaussianCrps(y, mu, sd),
      1e-4,
    );
    assertAlmostEquals(
      censoredGaussianCrps(y, mu, sd, null),
      gaussianCrps(y, mu, sd),
      1e-12,
    );
  }
});

Deno.test("censoredGaussianCrps matches seeded Monte Carlo estimate", () => {
  // CRPS(F, y) = E|X − y| − ½·E|X − X′| with X, X′ ~ F independent.
  const mu = 14, sd = 3, cap = 11, y = 10;
  const rand = lcg(505);
  const gauss = () => {
    // Box–Muller from LCG uniforms (deterministic).
    const u1 = Math.max(rand(), 1e-12);
    const u2 = rand();
    return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
  };
  const draw = () => Math.min(mu + sd * gauss(), cap);
  const n = 200_000;
  let e1 = 0, e2 = 0;
  for (let i = 0; i < n; i++) {
    const a = draw(), b = draw();
    e1 += Math.abs(a - y);
    e2 += Math.abs(a - b);
  }
  const mc = e1 / n - 0.5 * (e2 / n);
  const analytic = censoredGaussianCrps(y, mu, sd, cap);
  assert(
    Math.abs(mc - analytic) < 0.02,
    `MC ${mc} vs quadrature ${analytic}`,
  );
});

Deno.test("censoredMean limits and monotonicity", () => {
  // Far-below cap: unaffected. Far-above cap: pinned to cap.
  assertAlmostEquals(censoredMean(5, 1, 100), 5, 1e-9);
  assertAlmostEquals(censoredMean(50, 1, 10), 10, 1e-6);
  // Mean of min(X, cap) is always ≤ both mu and cap.
  const m = censoredMean(9, 2, 10);
  assert(m < 9 && m < 10 && m > 8);
});

Deno.test("censoredInCentral90 handles the atom at the cap", () => {
  // y above cap: model called it impossible → always a miss.
  assert(!censoredInCentral90(12, 9, 1, 11));
  // y at cap with substantial atom mass: covered.
  assert(censoredInCentral90(11, 10.5, 1, 11));
  // y at cap when the model puts <5% at/above the cap: miss.
  assert(!censoredInCentral90(11, 6, 1, 11));
  // No cap → plain Gaussian coverage.
  assertEquals(censoredInCentral90(9, 9, 1, null), inCentral90(9, 9, 1));
});

Deno.test("pairedBootstrapCi is deterministic and sane", () => {
  const deltas = [0.5, 1.2, -0.3, 0.8, 0.9, 1.5, -0.1, 0.4];
  const a = pairedBootstrapCi(deltas, 42)!;
  const b = pairedBootstrapCi(deltas, 42)!;
  assertEquals(a, b);
  assertAlmostEquals(a.meanDelta, 0.6125, 1e-9);
  assert(a.lo95 < a.meanDelta && a.meanDelta < a.hi95);
});
