// linalg property tests — Cholesky against the independent reference
// implementation, jitter escalation, and the PSD health check.

import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert";
import { cholesky as refCholesky } from "./reference/kf-reference.ts";
import {
  choleskyWithJitter,
  isSymmetricPsd,
  type Mat,
  matVec,
  symmetrize,
} from "./linalg.ts";

function lcg(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function randPd(rand: () => number, dim: number): Mat {
  const a: Mat = Array.from(
    { length: dim },
    () => Array.from({ length: dim }, () => (rand() - 0.5) * 2),
  );
  const m: Mat = Array.from({ length: dim }, () => new Array(dim).fill(0));
  for (let i = 0; i < dim; i++) {
    for (let j = 0; j < dim; j++) {
      let s = 0;
      for (let k = 0; k < dim; k++) s += a[i][k] * a[j][k];
      m[i][j] = s;
    }
    m[i][i] += 0.05;
  }
  return m;
}

Deno.test("choleskyWithJitter matches the reference factor on random PD matrices", () => {
  const rand = lcg(11);
  for (let trial = 0; trial < 20; trial++) {
    const dim = 2 + Math.floor(rand() * 6);
    const m = randPd(rand, dim);
    const ours = choleskyWithJitter(m);
    const ref = refCholesky(m);
    assertEquals(ours.jitterApplied, 0, `trial ${trial}: PD needed jitter`);
    for (let i = 0; i < dim; i++) {
      for (let j = 0; j < dim; j++) {
        assertAlmostEquals(
          ours.l[i][j],
          ref[i][j],
          1e-9,
          `trial ${trial} L[${i}][${j}]`,
        );
      }
    }
  }
});

Deno.test("choleskyWithJitter recovers a PSD-singular matrix via jitter", () => {
  // Rank-1: [1 1; 1 1] — strict Cholesky fails, jitter path must succeed.
  const { l, jitterApplied } = choleskyWithJitter([[1, 1], [1, 1]]);
  assert(jitterApplied > 0);
  // L·Lᵀ ≈ original within the jitter magnitude.
  const rec00 = l[0][0] * l[0][0];
  assertAlmostEquals(rec00, 1, 1e-6);
});

Deno.test("isSymmetricPsd accepts PD, rejects non-PSD and asymmetric", () => {
  assert(isSymmetricPsd([[2, 0.5], [0.5, 1]]));
  assert(!isSymmetricPsd([[1, 2], [2, 1]])); // eigenvalues 3, −1
  assert(!isSymmetricPsd([[1, 0.5], [0.1, 1]])); // asymmetric
});

Deno.test("symmetrize + matVec basic algebra", () => {
  const s = symmetrize([[1, 2], [4, 3]]);
  assertEquals(s, [[1, 3], [3, 3]]);
  assertEquals(matVec([[1, 2], [3, 4]], [1, 1]), [3, 7]);
});
