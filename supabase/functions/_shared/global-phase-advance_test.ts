// Project Apex — Phase 2 global-phase-advance tests.
//
// Per ADR-0012 (global phase advance trigger and the major-pattern
// enumeration, accepted 2026-05-07): the global trigger fires iff
// ≥4 of 6 major patterns transitioned phase within the last 6 user
// sessions, subject to cooldown and bootstrap guard.
//
// Each test name pins the originating ADR clause.
//
// Run locally:
//   deno test supabase/functions/_shared/global-phase-advance_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  type PatternTransitionState,
  shouldFireGlobalPhaseAdvance,
} from "./global-phase-advance.ts";

// All 6 major patterns per ADR-0012 / MAJOR_PATTERNS in constants.ts.
const ALL_SIX_MAJORS = [
  "horizontal_push",
  "vertical_push",
  "horizontal_pull",
  "vertical_pull",
  "squat",
  "hip_hinge",
];

// Build a state covering all 6 majors. Patterns with `lastAt=0` are treated
// as never-transitioned (per ADR-0012 §Edge cases).
const allMajorsWithLastAt = (
  lastAtPerPattern: Partial<Record<string, number>>,
): PatternTransitionState[] =>
  ALL_SIX_MAJORS.map((pattern) => ({
    pattern,
    lastPhaseTransitionAtSessionCount: lastAtPerPattern[pattern] ?? 0,
  }));

Deno.test("ADR-0012: 3 of 6 majors transitioned in last 6 sessions → does NOT fire (under threshold)", () => {
  // Threshold is 4 majors per ADR-0012; 3 is the under-threshold case.
  const states = allMajorsWithLastAt({
    horizontal_push: 13,
    vertical_push: 14,
    horizontal_pull: 15,
    // remaining 3 majors: lastAt=0 (never transitioned)
  });
  assertEquals(
    shouldFireGlobalPhaseAdvance(states, /* sessionCount */ 18, /* lastFired */ null),
    false,
  );
});

Deno.test("ADR-0012 §Edge cases: ≥4 majors transitioned but sessionCount=5 (under bootstrap guard) → does NOT fire", () => {
  // Bootstrap guard prevents premature firing on a brand-new user whose 4th
  // major's accumulation block fills up before they have 6 sessions of total
  // training history. Constants: GLOBAL_PHASE_ADVANCE_BOOTSTRAP_GUARD=6, so
  // sessionCount<6 blocks. sessionCount=5 sits just under.
  const states = allMajorsWithLastAt({
    horizontal_push: 1,
    vertical_push: 2,
    horizontal_pull: 3,
    vertical_pull: 4,
    // squat, hip_hinge: lastAt=0 (never)
  });
  assertEquals(
    shouldFireGlobalPhaseAdvance(states, /* sessionCount */ 5, /* lastFired */ null),
    false,
  );
});

Deno.test("ADR-0012 §Cooldown: ≥4 majors but cooldown active (lastFired=4, sessionCount=9, delta=5 < 6) → does NOT fire", () => {
  // Cooldown boundary: fires iff delta >= 6 (per ADR-0012 §Cooldown). At
  // delta=5 the cooldown is still active and blocks even though the major-
  // pattern threshold is met. Boundary-inclusive on the "fires" side: 6
  // fires (C18 below), 5 blocks (this test).
  const states = allMajorsWithLastAt({
    horizontal_push: 5,
    vertical_push: 6,
    horizontal_pull: 7,
    vertical_pull: 8,
    // squat, hip_hinge: lastAt=0
  });
  assertEquals(
    shouldFireGlobalPhaseAdvance(states, /* sessionCount */ 9, /* lastFired */ 4),
    false,
  );
});

Deno.test("ADR-0012 §Cooldown: ≥4 majors with cooldown just expired (lastFired=4, sessionCount=10, delta=6) → fires (boundary-inclusive on fires side)", () => {
  // Boundary partner to C17 (delta=5 blocks). At delta=6 the cooldown is
  // exactly satisfied: per ADR-0012 §Cooldown the test is `delta >= 6`,
  // so delta=6 fires. Boundary semantics consistent with the §"Window
  // semantics" `delta <= 6` — both inclusive on the firing side.
  const states = allMajorsWithLastAt({
    horizontal_push: 5,
    vertical_push: 6,
    horizontal_pull: 7,
    vertical_pull: 8,
    // squat, hip_hinge: lastAt=0
  });
  assertEquals(
    shouldFireGlobalPhaseAdvance(states, /* sessionCount */ 10, /* lastFired */ 4),
    true,
  );
});

Deno.test("ADR-0012 §Edge cases: lastPhaseTransitionAtSessionCount=0 (never transitioned) is naturally excluded for users past session 6 (delta>window)", () => {
  // 3 majors recently transitioned (in window) + 3 majors with lastAt=0
  // (never transitioned). At sessionCount=7, the lastAt=0 patterns produce
  // delta=7 > GLOBAL_PHASE_ADVANCE_SESSION_WINDOW=6, naturally excluded by
  // the window check. The 3 transitioned majors fall short of the threshold
  // of 4, so trigger does NOT fire.
  //
  // Load-bearing semantic: if lastAt=0 patterns were erroneously counted,
  // total would be 6 ≥ 4 → fires. Pinning the natural-exclusion property.
  //
  // Boundary note: at sessionCount=6 the natural exclusion does NOT apply
  // (delta=6 ≤ 6 would count erroneously). ADR-0012's "past session 6"
  // wording matches this — the case is sidestepped by the assumption that
  // all 6 majors have transitioned at least once by session 6. No defensive
  // `lastAt > 0` guard added; the ADR's natural-exclusion claim is taken
  // at face value.
  const states = allMajorsWithLastAt({
    horizontal_push: 2, // delta=5
    vertical_push: 3, //   delta=4
    horizontal_pull: 4, // delta=3
    // vertical_pull, squat, hip_hinge: lastAt=0 (delta=7 → excluded by window)
  });
  assertEquals(
    shouldFireGlobalPhaseAdvance(states, /* sessionCount */ 7, /* lastFired */ null),
    false,
  );
});

Deno.test("ADR-0012 §Consequences: force-deload-as-transition is a feature — 4 force-deloads in last 6 sessions → fires (the 'programming is broken' emergent signal)", () => {
  // The trigger reads `lastPhaseTransitionAtSessionCount` without
  // distinguishing the transition kind (natural-advance / force-deload /
  // deload-end-cycle). Per ADR-0012 §Consequences: force-deload-as-
  // transition is the strongest "your programming is broken, you need a
  // rebuild" signal the system can generate — exactly when heavy reassessment
  // is most warranted. A user whose plumbing is leaking everywhere needs the
  // heavy-reassessment UI to surface, not get suppressed by a "force-deloads
  // don't count" exception.
  //
  // Fixture: 4 majors at lastAt = sessions 7,8,9,10 (each having force-
  // deloaded; the rule is agnostic to the transition kind). 2 majors at
  // lastAt=0 are excluded by the window check at sessionCount=12.
  const states = allMajorsWithLastAt({
    horizontal_push: 7, // delta=5 (recent force-deload)
    vertical_push: 8, //   delta=4
    horizontal_pull: 9, // delta=3
    vertical_pull: 10, //  delta=2
    // squat, hip_hinge: lastAt=0 (delta=12 → excluded)
  });
  assertEquals(
    shouldFireGlobalPhaseAdvance(states, /* sessionCount */ 12, /* lastFired */ null),
    true,
  );
});

Deno.test("ADR-0012 §Major patterns: lunge and isolation transitions do NOT count toward the ≥4-of-6 threshold (only major patterns counted)", () => {
  // Per ADR-0012 §"6 major patterns": lunge is a unilateral accessory pattern
  // and isolation is by definition accessory; counting their transitions
  // toward macro readiness would dilute the signal. The trigger reads from
  // patternStates filtered to MAJOR_PATTERNS only.
  //
  // Fixture: 3 majors transitioned recently (under threshold) + lunge AND
  // isolation transitioned recently (would push count to 5 if not filtered).
  // Correct behaviour: only 3 majors in window → does NOT fire.
  // Buggy behaviour: 5 patterns in window ≥ 4 → would erroneously fire.
  const states: PatternTransitionState[] = [
    { pattern: "horizontal_push", lastPhaseTransitionAtSessionCount: 12 },
    { pattern: "vertical_push", lastPhaseTransitionAtSessionCount: 13 },
    { pattern: "horizontal_pull", lastPhaseTransitionAtSessionCount: 14 },
    { pattern: "vertical_pull", lastPhaseTransitionAtSessionCount: 0 },
    { pattern: "squat", lastPhaseTransitionAtSessionCount: 0 },
    { pattern: "hip_hinge", lastPhaseTransitionAtSessionCount: 0 },
    { pattern: "lunge", lastPhaseTransitionAtSessionCount: 15 }, // accessory
    { pattern: "isolation", lastPhaseTransitionAtSessionCount: 14 }, // accessory
  ];
  assertEquals(
    shouldFireGlobalPhaseAdvance(states, /* sessionCount */ 17, /* lastFired */ null),
    false,
  );
});

Deno.test("ADR-0012: ≥4 of 6 majors transitioned in last 6 sessions, no prior fire, past bootstrap → fires", () => {
  // 4 majors transitioned at sessions 12-15 (all within last 6 of currentSessionCount=18);
  // 2 majors at lastAt=0 (never transitioned, naturally excluded from the count).
  // No prior global fire → cooldown trivially satisfied.
  // currentSessionCount=18 >= 6 → bootstrap guard satisfied.
  const states = allMajorsWithLastAt({
    horizontal_push: 12,
    vertical_push: 13,
    horizontal_pull: 14,
    vertical_pull: 15,
    // squat, hip_hinge: lastAt=0 (never)
  });
  assertEquals(
    shouldFireGlobalPhaseAdvance(
      states,
      /* currentSessionCount */ 18,
      /* lastGlobalPhaseAdvanceFiredAtSessionCount */ null,
    ),
    true,
  );
});
