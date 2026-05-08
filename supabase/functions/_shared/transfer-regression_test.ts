// Project Apex — Phase 2 transfer-regression aggregator tests.
//
// Per Q10 PRD-internal: log-log linear fit with combined gate
// (≥TRANSFER_MIN_PAIRED_OBSERVATIONS paired observations AND
// rSquared ≥ TRANSFER_R_SQUARED_FLOOR), Spearman flag at
// ≥TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS additively widening SE by
// k=1.0 (TRANSFER_SPEARMAN_SE_WIDENING_FACTOR per 2026-05-07 lock-in
// extension), demote-on-drop with no hysteresis. Aligns with ADR-0005
// §"Linearity assumption for transfers".
//
// Each test name pins the originating Q10 / ADR-0005 rule so a failure
// surfaces the rule the change touches. Test ordering matches the
// per-behavior TDD cycle list approved on the slice plan.
//
// Run locally:
//   deno test supabase/functions/_shared/transfer-regression_test.ts

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fitTransfer, type PairedObservation } from "./transfer-regression.ts";
import { TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD } from "./constants.ts";

// Test fixture builder. `daysAgo` is just a sortable day offset; in log-log
// space the only quantities that drive R² and coefficient are fromE1RM and
// toE1RM, but observedAt is part of the locked PairedObservation shape.
const mk = (
  fromE1RM: number,
  toE1RM: number,
  daysAgo: number,
): PairedObservation => ({
  fromE1RM,
  toE1RM,
  observedAt: new Date(2026, 0, 1 + daysAgo),
});

Deno.test(
  "Q10: empty observations → state='candidate', rSquared=0 (degenerate fit, gate fails on N=0)",
  () => {
    const result = fitTransfer([]);
    assertEquals(result.state, "candidate");
    assertEquals(result.rSquared, 0);
    assertEquals(result.pairedObservations, 0);
  },
);

Deno.test(
  "Q10: 4 paired observations on a perfect log-log line → state='candidate' (cold-start; gate fails on N<5 regardless of R²)",
  () => {
    // Perfect linear in log-log: log(toE1RM) = 1.5 × log(fromE1RM).
    // R² would be ≈ 1.0 if N met the floor — but N=4 fails the combined
    // gate per Q10's "≥5 paired observations AND R²≥0.4". This pins that
    // the N gate is unconditional: a high R² cannot rescue a 4-obs fit.
    const obs: PairedObservation[] = [
      mk(100, Math.pow(100, 1.5), 0),
      mk(110, Math.pow(110, 1.5), 1),
      mk(120, Math.pow(120, 1.5), 2),
      mk(130, Math.pow(130, 1.5), 3),
    ];
    const result = fitTransfer(obs);
    assertEquals(result.state, "candidate");
    assertEquals(result.pairedObservations, 4);
  },
);

Deno.test(
  "Q10: 5 paired obs on perfect log-log line (R²=1.0, well above 0.40 floor) → state='published'",
  () => {
    // Perfect linear in log-log: log(toE1RM) = 1.5 × log(fromE1RM).
    // R² ≈ 1.0 satisfies the R²≥0.4 floor; N=5 satisfies the N gate.
    // Combined gate passes → 'published'. This is the first cycle that
    // forces real linear-fit math (cycles 1 & 2 were trivially handled
    // by always-candidate).
    const obs: PairedObservation[] = [
      mk(100, Math.pow(100, 1.5), 0),
      mk(110, Math.pow(110, 1.5), 1),
      mk(120, Math.pow(120, 1.5), 2),
      mk(130, Math.pow(130, 1.5), 3),
      mk(140, Math.pow(140, 1.5), 4),
    ];
    const result = fitTransfer(obs);
    assertEquals(result.state, "published");
    assertEquals(result.pairedObservations, 5);
    assertAlmostEquals(result.rSquared, 1.0, 1e-9);
  },
);

// ─── Closed-form-R² fixtures for the gate-boundary cycles 4/5/6 ─────────────
//
// In log-log space with log_x = [1, 2, 3, 4, 5] and y_perfect = x (slope 1,
// intercept 0), perturbing only the last point's log-y by deviation `e`
// yields a closed-form
//   R² = (5 + e)² / (25 + 10e + 2e²)
// (derived from Sxx=10, Sxy=10+2e, ssRes=2e²/5, ssTot=10+4e+4e²/5). This
// lets us pin specific R² values via clean IEEE-754-exact `e`:
//   e = -3    → R² = 4/13   ≈ 0.3077  (cycle 4: clearly below floor)
//   e = -2.75 → R² = 81/202 ≈ 0.4010  (cycle 5: just above floor — pins
//               "approach-floor-from-above publishes"; the symbolic R²=0.4
//               point is unreachable in IEEE 754 through this pipeline,
//               see cycle-5 test comment)
//   e = -2.5  → R² = 1/2    = 0.5     (cycle 6: clean above-floor)
// Synthetic fromE1RM/toE1RM values (Math.exp of the log-space coords) are
// not realistic e1RMs; they are chosen for closed-form R² control. The
// natural-log roundtrip Math.log(Math.exp(i)) is exact for small integers
// in V8, so log_x = [1,2,3,4,5] survives the impl's `Math.log` call exactly.

Deno.test(
  "Q10: 5 obs with R² ≈ 0.308 (well below 0.40 floor) → state='candidate' (combined gate fails on R² despite N=5 satisfying N gate)",
  () => {
    // e = -3 deviation on last log-y → R² = (5−3)² / (25−30+18) = 4/13.
    const obs: PairedObservation[] = [
      mk(Math.exp(1), Math.exp(1), 0),
      mk(Math.exp(2), Math.exp(2), 1),
      mk(Math.exp(3), Math.exp(3), 2),
      mk(Math.exp(4), Math.exp(4), 3),
      mk(Math.exp(5), Math.exp(2), 4), // log-y deviated from 5 to 2 (e=-3)
    ];
    const result = fitTransfer(obs);
    assertAlmostEquals(result.rSquared, 4 / 13, 1e-9);
    assertEquals(result.state, "candidate");
  },
);

Deno.test(
  "Q10: 5 obs with R² ≈ 0.4010 (just above 0.40 floor) → state='published' — pairs with cycle 4 to pin the floor location at TRANSFER_R_SQUARED_FLOOR=0.4",
  () => {
    // e = -2.75 deviation on last log-y → R² = (5−2.75)² / (25−27.5+15.125)
    //                                       = 5.0625 / 12.625 = 81/202 ≈ 0.4010.
    // The symbolic boundary R²=0.4 (inclusive per Q10's "R²≥0.4") is not
    // reachable in IEEE 754 through fitTransfer's regression pipeline —
    // the closed-form e = -15 + 5√6 lands ~1 ULP below 0.4 due to log/sum/
    // division rounding, which would (correctly) fail the gate. The floor
    // location is pinned jointly by:
    //   1. Cycle 4 above (R²≈0.308 → candidate).
    //   2. This cycle (R²≈0.4010 → published).
    //   3. The TRANSFER_R_SQUARED_FLOOR=0.4 tested-default in
    //      constants_test.ts (single source for the literal 0.4).
    // The `>=` vs `>` distinction at exactly 0.4 is moot: floating-point
    // doesn't preserve that bit pattern through this arithmetic, and the
    // impl's literal is the constant — so flipping the operator has no
    // observable consequence and is pinned at the constant layer.
    const obs: PairedObservation[] = [
      mk(Math.exp(1), Math.exp(1), 0),
      mk(Math.exp(2), Math.exp(2), 1),
      mk(Math.exp(3), Math.exp(3), 2),
      mk(Math.exp(4), Math.exp(4), 3),
      mk(Math.exp(5), Math.exp(5 + -2.75), 4), // e = -2.75 deviation
    ];
    const result = fitTransfer(obs);
    assertAlmostEquals(result.rSquared, 81 / 202, 1e-9);
    assertEquals(result.state, "published");
  },
);

Deno.test(
  "Q10: 5 obs with R² = 0.5 exactly (clean above-floor) → state='published' (imperfect-linear-but-above-floor publishes; differentiates from cycle 3's perfect-linear case)",
  () => {
    // e = -2.5 deviation on last log-y → R² = (5−2.5)² / (25−25+12.5)
    //                                      = 6.25 / 12.5 = 1/2 = 0.5 exactly.
    // Both 2.5 and 0.5 are IEEE-754-exact, so the closed-form value
    // survives floating-point through the regression pipeline.
    const obs: PairedObservation[] = [
      mk(Math.exp(1), Math.exp(1), 0),
      mk(Math.exp(2), Math.exp(2), 1),
      mk(Math.exp(3), Math.exp(3), 2),
      mk(Math.exp(4), Math.exp(4), 3),
      mk(Math.exp(5), Math.exp(5 + -2.5), 4), // e = -2.5 deviation
    ];
    const result = fitTransfer(obs);
    assertAlmostEquals(result.rSquared, 0.5, 1e-9);
    assertEquals(result.state, "published");
  },
);

Deno.test(
  "Q10: synthetic perfect log-log line y=1.5x (intercept 0) → coefficient ≈ 1.5, intercept ≈ 0, R² ≈ 1.0 (pins the regression math, not just the gate)",
  () => {
    // log(toE1RM) = 1.5 × log(fromE1RM) + 0. Distinct from cycle 3, which
    // also uses slope 1.5 but only asserts state and R²; this cycle pins
    // the coefficient and intercept extraction so a future regression-math
    // change (e.g., dropping the intercept term, swapping covariance signs)
    // is caught even when state and R² happen to look right.
    const obs: PairedObservation[] = [
      mk(Math.exp(1), Math.exp(1.5), 0),
      mk(Math.exp(2), Math.exp(3.0), 1),
      mk(Math.exp(3), Math.exp(4.5), 2),
      mk(Math.exp(4), Math.exp(6.0), 3),
      mk(Math.exp(5), Math.exp(7.5), 4),
    ];
    const result = fitTransfer(obs);
    assertAlmostEquals(result.coefficient, 1.5, 1e-9);
    assertAlmostEquals(result.intercept, 0, 1e-9);
    assertAlmostEquals(result.rSquared, 1.0, 1e-9);
  },
);

Deno.test(
  "Q10 (2026-05-07 lock-in extension): k=1.0 — seWidening === residualStddev when Spearman-flagged (catches future change of TRANSFER_SPEARMAN_SE_WIDENING_FACTOR away from 1.0)",
  () => {
    // Reuse cycle 11's fixture (divergence ≈ 0.47 → flag fires). Compute
    // the expected residualStddev from the same data using the reference
    //   residualStddev = sqrt(SSres / (n − 2))   (Q1 lock-in: n−2 dof)
    // and assert seWidening === residualStddev. With k=1.0 from the
    // constant, this is a direct equality. If a future amendment changes
    // TRANSFER_SPEARMAN_SE_WIDENING_FACTOR away from 1.0 (and Q10 +
    // 2026-05-07 lock-in are revised accordingly), this test breaks —
    // which is the desired forcing-function for the maintainer to also
    // update the test rationale alongside the constant.
    const ys = [1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 100];
    const obs: PairedObservation[] = ys.map((y, i) =>
      mk(Math.exp(i + 1), Math.exp(y), i)
    );
    const result = fitTransfer(obs);
    assertEquals(result.spearmanFlagged, true);
    // Reference residualStddev computation (matches the impl's Q1-locked
    // n−2 denominator). Independent of the impl's helper functions; the
    // test stands on the math itself, not on a tautology.
    const xs = obs.map((o) => Math.log(o.fromE1RM));
    const ysLog = obs.map((o) => Math.log(o.toE1RM));
    const n = obs.length;
    const mx = xs.reduce((a, b) => a + b, 0) / n;
    const my = ysLog.reduce((a, b) => a + b, 0) / n;
    let sxx = 0;
    let sxy = 0;
    for (let i = 0; i < n; i++) {
      sxx += (xs[i] - mx) * (xs[i] - mx);
      sxy += (xs[i] - mx) * (ysLog[i] - my);
    }
    const slope = sxy / sxx;
    const icpt = my - slope * mx;
    let ssRes = 0;
    for (let i = 0; i < n; i++) {
      const r = ysLog[i] - (icpt + slope * xs[i]);
      ssRes += r * r;
    }
    const expectedResidualStddev = Math.sqrt(ssRes / (n - 2));
    // k=1.0 ⇒ seWidening === residualStddev. The test name's "===" claim.
    assertAlmostEquals(result.seWidening, expectedResidualStddev, 1e-9);
  },
);

Deno.test(
  "Q10 (Spearman flag, 2026-05-07 lock-in): 10 obs of monotonic-but-nonlinear data → spearmanFlagged=true, seWidening = residualStddev × 1.0 > 0",
  () => {
    // log_y = [1, 1.1, 1.2, ..., 1.8, 100] with log_x = [1..10] gives
    // Spearman ρ = 1 (rank-monotonic) but Pearson r ≈ 0.53 — divergence
    // ≈ 0.47 well above TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD = 0.15.
    // The flag fires because:
    //   - N ≥ TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS (10)
    //   - |ρ − linearR| > TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD (0.15)
    // SE widening is additive with k=1.0 per Q10 2026-05-07 lock-in:
    //   seWidening = residualStddev × TRANSFER_SPEARMAN_SE_WIDENING_FACTOR.
    const ys = [1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 100];
    const obs: PairedObservation[] = ys.map((y, i) =>
      mk(Math.exp(i + 1), Math.exp(y), i)
    );
    const result = fitTransfer(obs);
    assertEquals(result.pairedObservations, 10);
    assertEquals(result.spearmanFlagged, true);
    assertEquals(result.seWidening > 0, true);
  },
);

Deno.test(
  "Q10 (Spearman flag — strict > boundary): 10 obs with divergence ≈ 0.147 (just below 0.15) → spearmanFlagged=false, seWidening=0 — pairs with cycle 11 to bracket the threshold",
  () => {
    // log_y = [1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 3] — long-flat
    // with small outlier. Spearman ρ = 1 (rank-monotonic), Pearson r ≈ 0.853,
    // divergence ≈ 0.147 < TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD = 0.15.
    // Strict-> means divergence at-or-below the threshold does not fire.
    // Like cycles 4–5's R²=0.40 boundary, the literal "exactly 0.15" bit
    // pattern isn't reachable through this regression in IEEE 754; the
    // strict-> behavior is pinned by:
    //   1. This test (just-below → not flagged)
    //   2. Cycle 11 above (divergence ≈ 0.47 → flagged)
    //   3. TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD = 0.15 in
    //      constants_test.ts (single source for the literal 0.15)
    const ys = [1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 3];
    const obs: PairedObservation[] = ys.map((y, i) =>
      mk(Math.exp(i + 1), Math.exp(y), i)
    );
    const result = fitTransfer(obs);
    assertEquals(result.pairedObservations, 10);
    assertEquals(result.spearmanFlagged, false);
    assertEquals(result.seWidening, 0);
  },
);

Deno.test(
  "Q10: tied ranks resolved via average-rank convention — Spearman ρ uses (i+j)/2+1 over each tied range",
  () => {
    // log_y has tied pairs: values [1,1,2,2,3,4,5,6,7,8] place ties at
    // indices 0-1 and 2-3. Average-rank → ranks [1.5, 1.5, 3.5, 3.5, 5,
    // 6, 7, 8, 9, 10]. log_x = [1..10] (no ties → ranks 1..10).
    //
    // If a future change broke tie handling to "first-encounter" ranks
    // [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], Spearman ρ would equal 1.0 exactly,
    // and expectedFlagged would shift. This test computes the expected
    // Spearman ρ via the average-rank algorithm and asserts the impl's
    // spearmanFlagged matches — pinning the average-rank convention.
    const yRaw = [1, 1, 2, 2, 3, 4, 5, 6, 7, 8];
    const obs: PairedObservation[] = yRaw.map((y, i) =>
      mk(Math.exp(i + 1), Math.exp(y), i)
    );
    const result = fitTransfer(obs);

    // Expected Spearman ρ via average-rank convention.
    const xRanks = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    const yRanks = [1.5, 1.5, 3.5, 3.5, 5, 6, 7, 8, 9, 10];
    const n = 10;
    const mx = 5.5;
    const my = yRanks.reduce((a, b) => a + b, 0) / n;
    let sxxR = 0;
    let syyR = 0;
    let sxyR = 0;
    for (let i = 0; i < n; i++) {
      sxxR += (xRanks[i] - mx) * (xRanks[i] - mx);
      syyR += (yRanks[i] - my) * (yRanks[i] - my);
      sxyR += (xRanks[i] - mx) * (yRanks[i] - my);
    }
    const expectedSpearman = sxyR / Math.sqrt(sxxR * syyR);

    // Expected signed Pearson r on log values (the impl's `linearR`).
    const xs = obs.map((o) => Math.log(o.fromE1RM));
    const ys = obs.map((o) => Math.log(o.toE1RM));
    const mxLog = xs.reduce((a, b) => a + b, 0) / n;
    const myLog = ys.reduce((a, b) => a + b, 0) / n;
    let sxxL = 0;
    let syyL = 0;
    let sxyL = 0;
    for (let i = 0; i < n; i++) {
      sxxL += (xs[i] - mxLog) * (xs[i] - mxLog);
      syyL += (ys[i] - myLog) * (ys[i] - myLog);
      sxyL += (xs[i] - mxLog) * (ys[i] - myLog);
    }
    const linearR = sxyL / Math.sqrt(sxxL * syyL);

    const expectedDivergence = Math.abs(expectedSpearman - linearR);
    const expectedFlagged =
      expectedDivergence > TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD;
    assertEquals(result.spearmanFlagged, expectedFlagged);
  },
);

Deno.test(
  "Q10: 9 obs of monotonic-but-nonlinear data (log_y = log_x²) → spearmanFlagged=false, seWidening=0 (Spearman gate suppresses sub-10 even when divergence would fire at ≥10)",
  () => {
    // Spearman ρ ≈ 1 (rank-perfect), but the linear fit's R² and Pearson r
    // are markedly lower because of curvature. At N≥10 the divergence
    // |ρ − r| would exceed 0.15 and the flag would fire; at N=9 it must
    // not fire — the N gate is unconditional per Q10's
    // TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS = 10.
    const obs: PairedObservation[] = [];
    for (let i = 1; i <= 9; i++) {
      obs.push(mk(Math.exp(i), Math.exp(i * i), i - 1));
    }
    const result = fitTransfer(obs);
    assertEquals(result.pairedObservations, 9);
    assertEquals(result.spearmanFlagged, false);
    assertEquals(result.seWidening, 0);
  },
);

Deno.test(
  "Q10: negative coefficient does NOT block publication — gate is on R² and N only, not coefficient sign (orchestrator A12 owns the emit obligation per slice split)",
  () => {
    // log(toE1RM) = −1 × log(fromE1RM) — perfect negative-slope linear
    // (rare; would correspond to a pair where fromE1RM rising while
    // toE1RM falls). R² ≈ 1.0, N = 5, coefficient = −1. Combined gate
    // publishes regardless of coefficient sign.
    //
    // The Q10 recommendation to "log warning" on a negative coefficient
    // lives at the orchestrator (A12) tier per the locked slice split:
    // A12 owns pair-detection (which is needed to populate the warning's
    // pair identifier) and is therefore the right owner of the call site.
    // A10 lands the typed `emitTransferNegativeCoefficient` helper in
    // observability.ts (with `observability_test.ts` coverage) so A12 can
    // call it cleanly when it lands. A future change adding a "block on
    // negative" guard inside fitTransfer would break this regression
    // test — which is the desired behavior, since publication-sign-
    // agnosticism is what this test pins.
    const obs: PairedObservation[] = [];
    for (let i = 1; i <= 5; i++) {
      obs.push(mk(Math.exp(i), Math.exp(-i), i - 1));
    }
    const result = fitTransfer(obs);
    assertAlmostEquals(result.coefficient, -1, 1e-9);
    assertAlmostEquals(result.rSquared, 1.0, 1e-9);
    assertEquals(result.state, "published");
  },
);

Deno.test(
  "Q10 (no hysteresis): demote-on-drop — fit at 10 obs published, then 11th obs (outlier) drops R² below 0.40 → state='candidate' immediately on next fitTransfer call",
  () => {
    // 10 perfect-linear obs → R² = 1.0 → published. Then add 11th obs
    // with log_y = 0 (an outlier that rotates the line and drags R²
    // down to ≈ 0.25). The pure recompute on every fitTransfer call IS
    // the demote-on-drop semantics — no internal state, no waiting period.
    const baseObs: PairedObservation[] = [];
    for (let i = 1; i <= 10; i++) {
      baseObs.push(mk(Math.exp(i), Math.exp(i), i - 1));
    }
    const fitBase = fitTransfer(baseObs);
    assertEquals(fitBase.state, "published");
    assertEquals(fitBase.pairedObservations, 10);

    const droppedObs = [...baseObs, mk(Math.exp(11), Math.exp(0), 10)];
    const fitDropped = fitTransfer(droppedObs);
    assertEquals(fitDropped.pairedObservations, 11);
    assertEquals(fitDropped.rSquared < 0.4, true);
    assertEquals(fitDropped.state, "candidate");
  },
);

Deno.test(
  "Q10 (no hysteresis): recover after demote — once R² climbs back above 0.40, state='published' immediately (no waiting period)",
  () => {
    // 11 obs (10 perfect-linear + 1 outlier) yield candidate per cycle 15.
    // Add a 12th obs that pulls the fit back toward linear: a perfectly
    // on-line point at log_x=12, log_y=12. With outlier averaged across
    // 12 obs the R² recovers above 0.40 → 'published' immediately on
    // the recovery call. No hysteresis: no "minimum N consecutive above-
    // floor calls" requirement.
    const obs: PairedObservation[] = [];
    for (let i = 1; i <= 10; i++) {
      obs.push(mk(Math.exp(i), Math.exp(i), i - 1));
    }
    obs.push(mk(Math.exp(11), Math.exp(0), 10)); // outlier — drops R²
    const demoted = fitTransfer(obs);
    assertEquals(demoted.state, "candidate");

    // Recovery: keep adding on-line points until the fit climbs back.
    // Twelve total perfect-line obs vs one outlier should be enough.
    const recoveryObs = [
      ...obs,
      mk(Math.exp(12), Math.exp(12), 11),
      mk(Math.exp(13), Math.exp(13), 12),
      mk(Math.exp(14), Math.exp(14), 13),
      mk(Math.exp(15), Math.exp(15), 14),
    ];
    const recovered = fitTransfer(recoveryObs);
    assertEquals(recovered.rSquared >= 0.4, true);
    assertEquals(recovered.state, "published");
  },
);

Deno.test(
  "Q10: uncorrelated pairs (Sxy=0 by construction) → R² = 0, slope = 0 → state='candidate' (no monotonic signal in the pair)",
  () => {
    // log_y = [1, 2, 5, 2, 1]. With log_x deviations [-2,-1,0,1,2]:
    //   Sxy = (-2)(1) + (-1)(2) + 0(5) + (1)(2) + (2)(1) = -2-2+0+2+2 = 0.
    // → slope = 0, intercept = mean_y, predicted is the constant mean_y,
    //   ssRes = ssTot, R² = 1 − 1 = 0. R²<0.40 → candidate per Q10's R² gate.
    const obs: PairedObservation[] = [
      mk(Math.exp(1), Math.exp(1), 0),
      mk(Math.exp(2), Math.exp(2), 1),
      mk(Math.exp(3), Math.exp(5), 2),
      mk(Math.exp(4), Math.exp(2), 3),
      mk(Math.exp(5), Math.exp(1), 4),
    ];
    const result = fitTransfer(obs);
    assertAlmostEquals(result.rSquared, 0, 1e-9);
    assertAlmostEquals(result.coefficient, 0, 1e-9);
    assertEquals(result.state, "candidate");
  },
);

Deno.test(
  "Q10: noisy log-log line y=1.5x with mid-point deviation → coefficient still ≈ 1.5 exactly, R² ∈ (0,1) strict (noise drops R² without biasing slope)",
  () => {
    // Deviate only the middle point (x_3 = 3 = mean_x). Zero leverage on
    // slope means coefficient stays exactly 1.5 — pins that the regression
    // recovers the true slope even with non-trivial noise. R² lands at
    //   R² = 1 − (4d²/5) / (22.5 + 4d²/5)
    // for deviation d on log_y_3. d=1.5 → R² = 1 − 1.8/24.3 ≈ 0.9259.
    const obs: PairedObservation[] = [
      mk(Math.exp(1), Math.exp(1.5), 0),
      mk(Math.exp(2), Math.exp(3.0), 1),
      mk(Math.exp(3), Math.exp(4.5 + 1.5), 2), // deviated by +1.5
      mk(Math.exp(4), Math.exp(6.0), 3),
      mk(Math.exp(5), Math.exp(7.5), 4),
    ];
    const result = fitTransfer(obs);
    assertAlmostEquals(result.coefficient, 1.5, 1e-9);
    // R² strictly in (0, 1) — noise present (not perfect) and signal
    // present (not zero correlation).
    assertEquals(result.rSquared > 0, true);
    assertEquals(result.rSquared < 1, true);
  },
);
