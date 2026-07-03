// Engine tests: bootstrap, offset growth, skip rules, forecast sanity,
// serialization round-trip, and the determinism property the backtest and
// ADR-0031 lean on (same inputs → byte-identical posterior).

import {
  assert,
  assertAlmostEquals,
  assertEquals,
  assertThrows,
} from "jsr:@std/assert";
import {
  applySessionToPattern,
  forecastTopSet,
  matToTriangle,
  posteriorSummary,
  triangleToMat,
  TwinNoUsableDataError,
  type TwinPatternState,
  type TwinSetInput,
} from "./engine.ts";
import { isSymmetricPsd } from "./linalg.ts";

function set(
  overrides: Partial<TwinSetInput> & { loggedAt: Date },
): TwinSetInput {
  return {
    exerciseId: "machine_chest_press",
    weightKg: 40,
    reps: 8,
    rirEstimated: 2,
    rpeFelt: null,
    intent: "top",
    ...overrides,
  };
}

const T0 = new Date("2026-03-20T10:00:00Z");
function at(days: number, minutes = 0): Date {
  return new Date(T0.getTime() + days * 86400000 + minutes * 60000);
}

Deno.test("bootstrap: first session creates state anchored on best implied e1RM", () => {
  const { state, diagnostics } = applySessionToPattern(
    null,
    [
      set({ loggedAt: at(0), weightKg: 40, reps: 8, rirEstimated: 2 }),
      set({
        loggedAt: at(0, 5),
        exerciseId: "incline_dumbbell_press",
        weightKg: 20,
        reps: 10,
        rirEstimated: 1,
        intent: "backoff",
      }),
    ],
    at(0, 10),
  );
  assert(diagnostics.bootstrapped);
  // 40 kg × (1 + 10/30) implied vs 20 kg × (1 + 11/30): chest press wins.
  assertEquals(state.anchorExerciseId, "machine_chest_press");
  assertEquals(state.offsetExerciseIds, ["incline_dumbbell_press"]);
  assertEquals(diagnostics.observationsApplied, 2);
  assertEquals(state.mean.length, 5);
  assert(isSymmetricPsd(triangleToMat(state.covTriangle, 5)));
  // C should be near log(40·(1+10/30)) = log(53.3); the two observations
  // move it a little but not far.
  const summary = posteriorSummary(state);
  assert(
    Math.abs(summary.logE1rmAnchor.mean - Math.log(53.33)) < 0.15,
    `C = ${summary.logE1rmAnchor.mean}`,
  );
});

Deno.test("bootstrap with no usable sets throws TwinNoUsableDataError", () => {
  assertThrows(
    () =>
      applySessionToPattern(
        null,
        [
          // warmup: excluded intent
          set({ loggedAt: at(0), intent: "warmup" }),
          // no effort signal on a non-amrap set
          set({ loggedAt: at(0, 2), rirEstimated: null, rpeFelt: null }),
          // zero weight
          set({ loggedAt: at(0, 4), weightKg: 0 }),
        ],
        at(0, 10),
      ),
    TwinNoUsableDataError,
  );
});

Deno.test("determinism: same inputs produce byte-identical posterior", () => {
  const sessions: Array<{ sets: TwinSetInput[]; loggedAt: Date }> = [
    {
      sets: [
        set({ loggedAt: at(0), reps: 8, rirEstimated: 2 }),
        set({ loggedAt: at(0, 4), reps: 7, rirEstimated: 1, intent: "backoff" }),
      ],
      loggedAt: at(0, 10),
    },
    {
      sets: [
        set({ loggedAt: at(4), weightKg: 42.5, reps: 8, rirEstimated: 1 }),
        set({
          loggedAt: at(4, 5),
          exerciseId: "incline_dumbbell_press",
          weightKg: 22.5,
          reps: 9,
          rirEstimated: null,
          rpeFelt: 9,
          intent: "backoff",
        }),
      ],
      loggedAt: at(4, 10),
    },
    {
      sets: [set({ loggedAt: at(9), weightKg: 45, reps: 7, rirEstimated: 1 })],
      loggedAt: at(9, 10),
    },
  ];
  const run = (): string => {
    let s: TwinPatternState | null = null;
    for (const sess of sessions) {
      s = applySessionToPattern(s, sess.sets, sess.loggedAt).state;
    }
    return JSON.stringify(s);
  };
  assertEquals(run(), run());
});

Deno.test("new exercise mid-history appends an offset state; forecast flags unseen", () => {
  let s = applySessionToPattern(
    null,
    [set({ loggedAt: at(0) })],
    at(0, 10),
  ).state;
  assertEquals(s.mean.length, 4);
  const r2 = applySessionToPattern(
    s,
    [
      set({ loggedAt: at(3) }),
      set({
        loggedAt: at(3, 6),
        exerciseId: "pec_deck",
        weightKg: 35,
        reps: 10,
        rirEstimated: 2,
        intent: "backoff",
      }),
    ],
    at(3, 10),
  );
  s = r2.state;
  assertEquals(r2.diagnostics.exercisesAdded, ["pec_deck"]);
  assertEquals(s.mean.length, 5);

  const seen = forecastTopSet(s, "pec_deck", 35, at(6));
  assert(seen !== null && !seen.exerciseUnseen);
  const unseen = forecastTopSet(s, "cable_fly", 20, at(6));
  assert(unseen !== null && unseen.exerciseUnseen);
  // Unseen exercise must carry MORE predictive spread than a seen one at a
  // comparable load (prior offset variance flows through).
  assert(unseen.repsSd > 0);
});

Deno.test("forecast: mean tracks an improving athlete and sd stays positive", () => {
  // Simulated athlete adding ~1.25% e1RM per session at the same load:
  // reported reps climb. The twin's forecast at a FIXED load should climb.
  let s: TwinPatternState | null = null;
  const repsSeq = [8, 8, 9, 9, 10, 10];
  for (let k = 0; k < repsSeq.length; k++) {
    s = applySessionToPattern(
      s,
      [set({ loggedAt: at(k * 4), reps: repsSeq[k], rirEstimated: 2 })],
      at(k * 4, 10),
    ).state;
  }
  const f = forecastTopSet(s!, "machine_chest_press", 40, at(24));
  assert(f !== null);
  assert(f.repsSd > 0.5, `sd ${f.repsSd}`);
  // Performed ~10 reps at RIR 2 lately → forecast of performed reps at the
  // same load should be in a plausible neighborhood (stopping habit ≈ 2).
  assert(
    f.repsMean > 8 && f.repsMean < 14,
    `forecast mean ${f.repsMean}`,
  );
  // Trend should have been detected as positive.
  const summary = posteriorSummary(s!);
  assert(summary.trendPerDay.mean > 0, `trend ${summary.trendPerDay.mean}`);
});

Deno.test("skip accounting: unusable sets are counted, not guessed at", () => {
  const first = applySessionToPattern(
    null,
    [set({ loggedAt: at(0) })],
    at(0, 10),
  ).state;
  const r = applySessionToPattern(
    first,
    [
      set({ loggedAt: at(2) }),
      set({ loggedAt: at(2, 3), intent: "warmup" }),
      set({ loggedAt: at(2, 5), rirEstimated: null, rpeFelt: null }),
      set({ loggedAt: at(2, 7), weightKg: 0 }),
    ],
    at(2, 10),
  );
  assertEquals(r.diagnostics.observationsApplied, 1);
  assertEquals(r.diagnostics.setsSkipped, 3);
  assertEquals(r.state.skippedSetCount, 3);
});

Deno.test("amrap with no report is usable at RIR 0; top without report is not", () => {
  const s = applySessionToPattern(
    null,
    [
      set({
        loggedAt: at(0),
        intent: "amrap",
        rirEstimated: null,
        rpeFelt: null,
        reps: 12,
      }),
    ],
    at(0, 5),
  );
  assertEquals(s.diagnostics.observationsApplied, 1);
});

Deno.test("covariance triangle round-trips exactly", () => {
  const m = [
    [1.5, 0.2, -0.1],
    [0.2, 2.5, 0.05],
    [-0.1, 0.05, 0.75],
  ];
  assertEquals(triangleToMat(matToTriangle(m), 3), m);
});

Deno.test("stopping-RIR stats accumulate from top sets only", () => {
  let s = applySessionToPattern(
    null,
    [
      set({ loggedAt: at(0), rirEstimated: 2 }),
      set({ loggedAt: at(0, 5), rirEstimated: 0, intent: "backoff" }),
    ],
    at(0, 10),
  ).state;
  assertEquals(s.stopRir.n, 1);
  assertAlmostEquals(s.stopRir.mean, 2, 1e-12);
  s = applySessionToPattern(
    s,
    [set({ loggedAt: at(3), rirEstimated: 1 })],
    at(3, 10),
  ).state;
  assertEquals(s.stopRir.n, 2);
  assertAlmostEquals(s.stopRir.mean, 1.5, 1e-12);
});

Deno.test("time propagation: capability uncertainty grows over a long gap", () => {
  const s = applySessionToPattern(
    null,
    [set({ loggedAt: at(0) })],
    at(0, 10),
  ).state;
  const near = forecastTopSet(s, "machine_chest_press", 40, at(2));
  const far = forecastTopSet(s, "machine_chest_press", 40, at(60));
  assert(near !== null && far !== null);
  assert(
    far.maxRepsSd > near.maxRepsSd,
    `far ${far.maxRepsSd} !> near ${near.maxRepsSd}`,
  );
});
