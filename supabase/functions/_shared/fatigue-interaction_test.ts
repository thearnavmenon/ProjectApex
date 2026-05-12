// Project Apex — Phase 2 fatigue-interaction aggregator tests.
//
// Per ADR-0005 §"Fatigue interaction" + §"Fatigue interaction confidence:
// count-only vs count × consistency": cross-pattern carryover detected by
// pairing each pattern in the current session against every distinct pattern
// in the immediately-prior session, with rolling 10-obs `consistencyFactor`
// window, monotone `totalCount` for the count-factor hard cap at 15, and
// confidence = consistencyFactor × countFactor. Phase 1 ships the Swift
// value type at TraineeModelInteractions.swift:77-118 that consumes the data
// this slice produces.
//
// Each test name pins the originating ADR-0005 rule so a failure surfaces the
// rule the change touches. Test ordering matches the per-behavior TDD cycle
// list approved on the slice plan.
//
// Run locally:
//   deno test supabase/functions/_shared/fatigue-interaction_test.ts

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  appendObservations,
  detectFatigueObservations,
  fatigueConfidence,
  type FatigueObservation,
  type FatigueState,
  type SessionPatternPerformance,
} from "./fatigue-interaction.ts";

// Test fixture builder for SessionPatternPerformance. `dayOffset` keeps the
// loggedAt deterministic without a clock.
const mkPerf = (
  pattern: string,
  performanceDeltaPct: number,
  dayOffset: number,
  sessionId = `s-${dayOffset}`,
): SessionPatternPerformance => ({
  sessionId,
  loggedAt: new Date(2026, 0, 1 + dayOffset),
  pattern,
  performanceDeltaPct,
});

const mkObs = (
  fromPattern: string,
  toPattern: string,
  delta: number,
  dayOffset: number,
): FatigueObservation => ({
  fromPattern,
  toPattern,
  delta,
  observedAt: new Date(2026, 0, 1 + dayOffset),
});

Deno.test(
  "ADR-0005: pair detection — first-ever session (priorSession=null) emits no observations",
  () => {
    const newSession: SessionPatternPerformance[] = [
      mkPerf("squat", -0.05, 0),
    ];
    const result = detectFatigueObservations(newSession, null);
    assertEquals(result, []);
  },
);

Deno.test(
  "ADR-0005: pair detection — same-pattern self-pair excluded (Q ≠ P)",
  () => {
    // Yesterday squat, today squat — only-pattern overlap. The Cartesian
    // product Q ∈ prior × P ∈ new contains exactly one entry (squat, squat),
    // which the Q ≠ P clause excludes → 0 observations.
    const prior: SessionPatternPerformance[] = [mkPerf("squat", -0.04, 0)];
    const today: SessionPatternPerformance[] = [mkPerf("squat", -0.05, 1)];
    const result = detectFatigueObservations(today, prior);
    assertEquals(result, []);
  },
);

Deno.test(
  "ADR-0005: pair detection — Cartesian product across distinct patterns (2×2 = 4 observations, no self-pairs)",
  () => {
    // Yesterday: squat + horizontal_push. Today: vertical_push + hip_hinge.
    // No pattern overlap → 4 observations:
    //   {squat → vertical_push, squat → hip_hinge,
    //    horizontal_push → vertical_push, horizontal_push → hip_hinge}
    // delta on each obs = performanceDeltaPct of the *to* pattern in newSession.
    // observedAt on each obs = the new session's loggedAt.
    // Iteration order: priorSession.patterns then newSession.patterns, both
    // sorted by MovementPattern string value lexicographically (cycle 4 in
    // the slice plan). Sorted prior: [horizontal_push, squat]. Sorted new:
    // [hip_hinge, vertical_push].
    const prior: SessionPatternPerformance[] = [
      mkPerf("squat", -0.02, 0, "s-prior"),
      mkPerf("horizontal_push", -0.01, 0, "s-prior"),
    ];
    const today: SessionPatternPerformance[] = [
      mkPerf("vertical_push", -0.07, 1, "s-today"),
      mkPerf("hip_hinge", -0.05, 1, "s-today"),
    ];
    const result = detectFatigueObservations(today, prior);
    const todayLoggedAt = new Date(2026, 0, 2);
    assertEquals(result, [
      {
        fromPattern: "horizontal_push",
        toPattern: "hip_hinge",
        delta: -0.05,
        observedAt: todayLoggedAt,
      },
      {
        fromPattern: "horizontal_push",
        toPattern: "vertical_push",
        delta: -0.07,
        observedAt: todayLoggedAt,
      },
      {
        fromPattern: "squat",
        toPattern: "hip_hinge",
        delta: -0.05,
        observedAt: todayLoggedAt,
      },
      {
        fromPattern: "squat",
        toPattern: "vertical_push",
        delta: -0.07,
        observedAt: todayLoggedAt,
      },
    ]);
  },
);

Deno.test(
  "ADR-0005: appendObservations — empty state + 1 observation → new state with observations=[delta], totalCount=1",
  () => {
    // Tracer for appendObservations: starting with no per-pair state, the
    // first observation creates a new FatigueState entry keyed by
    // (fromPattern, toPattern) with the delta in observations and totalCount=1.
    const result = appendObservations([], [mkObs("squat", "hip_hinge", -0.05, 1)]);
    assertEquals(result.length, 1);
    assertEquals(result[0].fromPattern, "squat");
    assertEquals(result[0].toPattern, "hip_hinge");
    assertEquals(result[0].observations, [-0.05]);
    assertEquals(result[0].totalCount, 1);
  },
);

Deno.test(
  "ADR-0005: appendObservations — window slides at FATIGUE_INTERACTION_OBSERVATION_WINDOW=10 (oldest evicted on 11th)",
  () => {
    // Build a state at 10 obs with deltas -0.01..-0.10 (oldest first), then
    // append an 11th delta -0.11. Window evicts the oldest (-0.01) and the
    // new delta lands at the tail. observations.length stays at 10.
    const seedObs: FatigueObservation[] = [];
    for (let i = 1; i <= 10; i++) {
      seedObs.push(mkObs("squat", "hip_hinge", -0.01 * i, i));
    }
    const seeded = appendObservations([], seedObs);
    assertEquals(seeded[0].observations.length, 10);
    assertEquals(seeded[0].totalCount, 10);

    const after = appendObservations(seeded, [
      mkObs("squat", "hip_hinge", -0.11, 11),
    ]);
    assertEquals(after[0].observations.length, 10);
    // Oldest (-0.01) evicted; tail is -0.11.
    assertEquals(after[0].observations[0], -0.02);
    assertEquals(after[0].observations[9], -0.11);
    assertEquals(after[0].totalCount, 11);
  },
);

Deno.test(
  "ADR-0005: appendObservations — totalCount is monotonic, NOT bounded by the window (≤10 obs in window, but totalCount keeps climbing)",
  () => {
    // Append 20 observations. The rolling window stays at 10, but totalCount
    // is the unbounded count of every paired observation seen — load-bearing
    // for the count-factor hard cap at FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS=15.
    let state: FatigueState[] = [];
    for (let i = 1; i <= 20; i++) {
      state = appendObservations(state, [
        mkObs("squat", "hip_hinge", -0.001 * i, i),
      ]);
    }
    assertEquals(state.length, 1);
    assertEquals(state[0].observations.length, 10);
    assertEquals(state[0].totalCount, 20);
  },
);

Deno.test(
  "ADR-0005: fatigueConfidence — 1 observation → consistencyFactor=0 (need ≥2 for sample variance)",
  () => {
    // Tracer for fatigueConfidence: with a single observation, the recent
    // window has count=1, which fails the `recent.count >= 2` guard in the
    // Swift implementation (TraineeModelInteractions.swift:100). Returns 0.
    const state: FatigueState = {
      fromPattern: "squat",
      toPattern: "hip_hinge",
      observations: [-0.05],
      totalCount: 1,
    };
    const result = fatigueConfidence(state);
    assertEquals(result.consistencyFactor, 0);
  },
);

Deno.test(
  "ADR-0005: fatigueConfidence — 2 identical observations → consistencyFactor=1.0 (zero variance + Swift's `< 1e-12` exact-1 fixup)",
  () => {
    // Two identical observations have zero variance → stddev=0 → 1 - 0/|mean|
    // = 1, which the Swift `if abs(clamped - 1) < 1e-12 { return 1 }` fixup
    // (TraineeModelInteractions.swift:106) snaps to exactly 1.0.
    const state: FatigueState = {
      fromPattern: "squat",
      toPattern: "hip_hinge",
      observations: [-0.05, -0.05],
      totalCount: 2,
    };
    const result = fatigueConfidence(state);
    assertEquals(result.consistencyFactor, 1);
  },
);

Deno.test(
  "ADR-0005: fatigueConfidence — mean-guard fires on near-zero mean — guard prevents NaN; with [0.0001, -0.0001] absMean=0.001 (guarded), stddev=1e-4, ratio=0.1, consistencyFactor=0.9 (issue body's 'near zero' assertion was incorrect for this fixture; see PR description for issue amendment)",
  () => {
    // mean = 0; absMean = max(0, 0.001) = 0.001 (guarded — without the
    // FATIGUE_INTERACTION_MEAN_GUARD this would be a divide-by-zero / NaN).
    // variance = ((1e-4)² + (-1e-4)²) / 2 = 1e-8; stddev = 1e-4.
    // clamped = max(0, min(1, 1 - 1e-4/1e-3)) = max(0, min(1, 0.9)) = 0.9 exactly.
    // The exact 0.9 assertion locks the guard's denominator value: changing
    // FATIGUE_INTERACTION_MEAN_GUARD from 0.001 to 0.01 would shift this to
    // 1 - 1e-4/1e-2 = 0.99 and break the test.
    const state: FatigueState = {
      fromPattern: "squat",
      toPattern: "hip_hinge",
      observations: [0.0001, -0.0001],
      totalCount: 2,
    };
    const result = fatigueConfidence(state);
    assertAlmostEquals(result.consistencyFactor, 0.9, 1e-12);
    assertEquals(Number.isFinite(result.consistencyFactor), true);
  },
);

Deno.test(
  "ADR-0005: fatigueConfidence — consistency clamps to 0 when stddev exceeds absMean — with [0.005, -0.005] absMean=0.001 (guarded), stddev=0.005, ratio=5, clamp(1-5)=0",
  () => {
    // mean = 0; absMean = max(0, 0.001) = 0.001 (guarded).
    // variance = ((5e-3)² + (-5e-3)²) / 2 = 2.5e-5; stddev = 5e-3.
    // 1 - stddev/absMean = 1 - 5 = -4 → clamp at 0 → exact-0 fixup yields 0.
    // Pairs with cycle 9a to bracket the guard: 9a pins the denominator value
    // (low stddev → high consistency); 9b pins the clamp-to-zero behavior
    // (high stddev → zero consistency). Together they pin the full range of
    // the guarded ratio's effect on consistencyFactor.
    const state: FatigueState = {
      fromPattern: "squat",
      toPattern: "hip_hinge",
      observations: [0.005, -0.005],
      totalCount: 2,
    };
    const result = fatigueConfidence(state);
    assertEquals(result.consistencyFactor, 0);
  },
);

Deno.test(
  "ADR-0005: fatigueConfidence — countFactor boundary at FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS=15 (totalCount=14 → 0.5; totalCount=15 → 1.0)",
  () => {
    // Per Swift: `totalCount >= 15 ? 1.0 : 0.5` (TraineeModelInteractions.swift:112).
    // Inclusive at 15 (>=, not >). Below threshold → hard cap at 0.5.
    const below: FatigueState = {
      fromPattern: "squat",
      toPattern: "hip_hinge",
      observations: [-0.05, -0.05],
      totalCount: 14,
    };
    assertEquals(fatigueConfidence(below).countFactor, 0.5);

    const at: FatigueState = {
      fromPattern: "squat",
      toPattern: "hip_hinge",
      observations: [-0.05, -0.05],
      totalCount: 15,
    };
    assertEquals(fatigueConfidence(at).countFactor, 1.0);
  },
);

Deno.test(
  "ADR-0005: fatigueConfidence — confidence = consistencyFactor × countFactor (composition with non-degenerate factors)",
  () => {
    // observations = [0.1, 0.2], totalCount = 14:
    //   mean    = 0.15
    //   absMean = max(0.15, 0.001) = 0.15  (guard does NOT fire)
    //   variance= ((0.1-0.15)² + (0.2-0.15)²) / 2 = 0.0025
    //   stddev  = 0.05
    //   ratio   = 0.05 / 0.15 = 1/3
    //   clamped = 1 - 1/3 = 2/3
    // countFactor = 0.5 (totalCount < 15).
    // confidence = 2/3 × 0.5 = 1/3.
    // Non-degenerate factors (neither is 0 or 1) so a future change dropping
    // the multiplication or swapping × for + would break this test. The
    // user's issue-body example (0.8 × 1.0 = 0.8) was multiplicatively
    // degenerate — × 1.0 is identity — so wouldn't catch that regression.
    const state: FatigueState = {
      fromPattern: "squat",
      toPattern: "hip_hinge",
      observations: [0.1, 0.2],
      totalCount: 14,
    };
    const result = fatigueConfidence(state);
    assertAlmostEquals(result.consistencyFactor, 2 / 3, 1e-12);
    assertEquals(result.countFactor, 0.5);
    assertAlmostEquals(result.confidence, 1 / 3, 1e-12);
  },
);

// ─── Cross-validation: parity with Swift FatigueInteraction.confidence ─────
//
// The fixture file at docs/fixtures/fatigue-interaction.json is the single
// source of expected outputs across both implementations. Swift loads the
// same JSON via ProjectApexTests/FatigueInteractionCrossValidationTests.swift
// and asserts FatigueInteraction.confidence (TraineeModelInteractions.swift:115)
// against the same expected values. A drift between TS and Swift surfaces as
// a failure on whichever side regressed; both sides being green proves cross-
// platform parity to within 1e-12 on every fixture row.

interface FixtureFile {
  fixtures: Array<{
    name: string;
    observations: number[];
    totalCount: number;
    expected: {
      consistencyFactor: number;
      countFactor: number;
      confidence: number;
    };
  }>;
}

const fixturePath = new URL(
  "../../../docs/fixtures/fatigue-interaction.json",
  import.meta.url,
);
const fixtureFile: FixtureFile = JSON.parse(
  Deno.readTextFileSync(fixturePath),
);

for (const row of fixtureFile.fixtures) {
  Deno.test(
    `ADR-0005: cross-validation fixture "${row.name}" — TS fatigueConfidence matches expected (Swift parity to 1e-12)`,
    () => {
      const state: FatigueState = {
        fromPattern: "squat",
        toPattern: "hip_hinge",
        observations: row.observations,
        totalCount: row.totalCount,
      };
      const result = fatigueConfidence(state);
      assertAlmostEquals(
        result.consistencyFactor,
        row.expected.consistencyFactor,
        1e-12,
      );
      assertAlmostEquals(
        result.countFactor,
        row.expected.countFactor,
        1e-12,
      );
      assertAlmostEquals(
        result.confidence,
        row.expected.confidence,
        1e-12,
      );
    },
  );
}
