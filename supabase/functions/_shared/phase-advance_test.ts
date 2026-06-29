// Project Apex — Phase 2 phase-advance tests.
//
// Per ADR-0011 (per-pattern phase advance — plateau-aware
// composition, force-deload safety valve, cyclic mesocycle).
//
// Each test name pins the originating ADR clause so a failure
// surfaces the rule the change touches.
//
// Run locally:
//   deno test supabase/functions/_shared/phase-advance_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  advancePhase,
  goalArc,
  type PerPatternState,
  sessionsRequiredFor,
} from "./phase-advance.ts";

// daysPerWeek=4 → sessionsRequiredFor('accumulation', 4) = max(3, 4 × max(1, 4/2)) = 8.
// Tests use 8 as the canonical accumulation threshold; force-deload at 2× = 16.
//
// goalArc defaults to "strength" so the legacy ADR-0011 arc
// (accumulation→intensification→peaking→deload) is the baseline these tests
// assert. Volume-arc behaviour (ADR-0030) is pinned by explicit overrides below.
const baseState = (overrides: Partial<PerPatternState> = {}): PerPatternState => ({
  currentPhase: "accumulation",
  sessionsInPhase: 0,
  sessionsRequiredForPhase: 8,
  trend: "progressing",
  consecutiveForceDeloadsOnPattern: 0,
  lastPhaseTransitionAtSessionCount: 0,
  goalArc: "strength",
  ...overrides,
});

Deno.test("ADR-0011: first-time pattern (sessionsInPhase=1, under threshold) → no-op, no state change", () => {
  // Caller incremented sessionsInPhase from 0 to 1 after the first session.
  // Threshold is 8; sessionsInPhase=1 < threshold → no advance fires.
  const state = baseState({ sessionsInPhase: 1 });
  const outcome = advancePhase(state, /* currentSessionCount */ 1);

  assertEquals(outcome.fired, "no-op");
  assertEquals(outcome.newPhase, "accumulation");
  assertEquals(outcome.newSessionsInPhase, 1);
  assertEquals(outcome.newConsecutiveForceDeloads, 0);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 0);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0011: sessionsRequiredFor matches legacy PatternPhaseService.swift:78 verbatim — max(3, phaseWeeks × max(1, ⌊daysPerWeek/2⌋))", () => {
  // phaseWeeks: accumulation=4, intensification=4, peaking=3, deload=1
  // multiplier: max(1, ⌊daysPerWeek/2⌋)
  // result:     max(3, phaseWeeks × multiplier)

  // daysPerWeek=4 → multiplier = ⌊4/2⌋ = 2
  assertEquals(sessionsRequiredFor("accumulation", 4), 8); //    max(3, 4×2) = 8
  assertEquals(sessionsRequiredFor("intensification", 4), 8); // max(3, 4×2) = 8
  assertEquals(sessionsRequiredFor("peaking", 4), 6); //         max(3, 3×2) = 6
  assertEquals(sessionsRequiredFor("deload", 4), 3); //          max(3, 1×2) = max(3, 2) = 3 (floor wins)

  // daysPerWeek=1 → multiplier = max(1, ⌊1/2⌋) = max(1, 0) = 1
  assertEquals(sessionsRequiredFor("accumulation", 1), 4); //    max(3, 4×1) = 4
  assertEquals(sessionsRequiredFor("deload", 1), 3); //          max(3, 1×1) = 3 (floor wins)

  // daysPerWeek=6 → multiplier = ⌊6/2⌋ = 3
  assertEquals(sessionsRequiredFor("accumulation", 6), 12); //   max(3, 4×3) = 12
  assertEquals(sessionsRequiredFor("peaking", 6), 9); //         max(3, 3×3) = 9
});

Deno.test("ADR-0011: natural progressing-advance — accumulation→intensification at threshold; sessionsInPhase resets, counter resets, lastTransitionAt updates", () => {
  // Threshold met (sessionsInPhase = 8 = required), trend=progressing, no
  // 2× force-deload pressure (sessionsInPhase < 16). Per ADR-0011 §(a):
  //   advance to nextPhase (accumulation → intensification per phaseOrder)
  //   sessionsInPhase = 0
  //   lastPhaseTransitionAtSessionCount = currentSessionCount
  // Per ADR-0011 §(b): natural progressing-advance resets the counter to 0.
  // Counter pre-set to 2 to verify the reset is unconditional on this path.
  const state = baseState({
    sessionsInPhase: 8,
    trend: "progressing",
    consecutiveForceDeloadsOnPattern: 2,
    lastPhaseTransitionAtSessionCount: 4,
  });
  const outcome = advancePhase(state, /* sessionCount */ 12);

  assertEquals(outcome.fired, "natural-advance");
  assertEquals(outcome.newPhase, "intensification");
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 0); // reset
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 12);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0011 §(b): force-deload at 2× threshold (plateaued) — accumulation→deload (skips intensification/peaking); counter += 1", () => {
  // Per ADR-0011 §(b): under prolonged stuck-trend pressure (≥ 2× threshold),
  // the force-advance safety valve jumps the cycle directly to .deload to
  // break the plateau. Skips intensification/peaking — those phases ask for
  // heavier work, which is the wrong intervention for a stuck pattern.
  // Counter increments on this path; lastTransitionAt updates.
  const state = baseState({
    sessionsInPhase: 16, // = 2 × sessionsRequiredForPhase
    trend: "plateaued",
    consecutiveForceDeloadsOnPattern: 0,
    lastPhaseTransitionAtSessionCount: 4,
  });
  const outcome = advancePhase(state, /* sessionCount */ 20);

  assertEquals(outcome.fired, "force-deload");
  assertEquals(outcome.newPhase, "deload");
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 1);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 20);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0011 §(c): cyclic deload→accumulation at threshold fires deload-end Q5 transition-mode trigger (basic case, progressing trend)", () => {
  // Basic case: currentPhase=deload, sessionsInPhase=threshold (not 2×, so
  // §(b) trigger condition is NOT met and the C8 composition isn't in play).
  // Per ADR-0011 §(c): cyclic rule fires regardless of trend; the deload-
  // end transition fires the Q5 transition-mode trigger so the post-deload
  // 3-session plain-mean window catches rebound and prevents stale pre-
  // deload e1RM bleed into the new accumulation block.
  const deloadThreshold = 3;
  const state: PerPatternState = {
    currentPhase: "deload",
    sessionsInPhase: deloadThreshold,
    sessionsRequiredForPhase: deloadThreshold,
    trend: "progressing",
    consecutiveForceDeloadsOnPattern: 0,
    lastPhaseTransitionAtSessionCount: 5,
    goalArc: "strength", // arc-agnostic fixture (deload→accumulation cycle)
  };
  const outcome = advancePhase(state, /* sessionCount */ 8);

  assertEquals(outcome.fired, "deload-end-cycle");
  assertEquals(outcome.newPhase, "accumulation");
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 0); // preserved (was 0)
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 8);
  assertEquals(outcome.firesDeloadEndTransitionMode, true);
});

Deno.test("ADR-0011 §(c): cyclic deload→accumulation regardless of trend — plateaued in-deload still cycles (trend block does NOT apply to deload→accumulation)", () => {
  // Distinct from C9's progressing-trend case: at sessionsInPhase=threshold
  // in deload with trend=plateaued, the cyclic rule still fires. Per §(c),
  // "the trend == .progressing block does not apply to the deload→accumulation
  // transition" — coming out of deload the pattern is by definition refreshed.
  // Counter preserved (was 1, stays 1) per the no-counter-touch property.
  const deloadThreshold = 3;
  const state: PerPatternState = {
    currentPhase: "deload",
    sessionsInPhase: deloadThreshold,
    sessionsRequiredForPhase: deloadThreshold,
    trend: "plateaued",
    consecutiveForceDeloadsOnPattern: 1,
    lastPhaseTransitionAtSessionCount: 5,
    goalArc: "strength", // arc-agnostic fixture (deload→accumulation cycle)
  };
  const outcome = advancePhase(state, /* sessionCount */ 8);

  assertEquals(outcome.fired, "deload-end-cycle");
  assertEquals(outcome.newPhase, "accumulation");
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 1); // preserved
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 8);
  assertEquals(outcome.firesDeloadEndTransitionMode, true);
});

Deno.test("ADR-0011 §(a): conditional-not-destructive trend flip — sessionsInPhase=threshold+3 plateaued, then trend=progressing → natural-advance fires immediately", () => {
  // Per ADR-0011 §(a): the trend block is conditional, not destructive.
  // sessionsInPhase keeps accumulating while blocked; if trend flips back to
  // progressing while sessionsInPhase still meets/exceeds threshold, the
  // deferred natural-advance fires on the very next session-completion call.
  // This is the load-bearing semantic that distinguishes "blocked" from
  // "reset" — a plateau that resolves doesn't lose the user's accumulated
  // session-count toward advance.
  //
  // Fixture: 3 sessions of plateau-blocked accumulation past threshold (so
  // sessionsInPhase=8+3=11), then trend flips to progressing on this call.
  const state = baseState({
    sessionsInPhase: 11, // = sessionsRequiredForPhase (8) + 3
    trend: "progressing",
    consecutiveForceDeloadsOnPattern: 0,
  });
  const outcome = advancePhase(state, /* sessionCount */ 14);

  assertEquals(outcome.fired, "natural-advance");
  assertEquals(outcome.newPhase, "intensification");
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 0);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 14);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0011 §Consequences migration: legacy v1 terminal-deload pattern decoded — ratchets normally; next deload-threshold met → cycles to accumulation (no migration code path)", () => {
  // Legacy v1 PatternPhaseService.swift:126 ("Already at deload — no further
  // transition") treated deload as terminal. v2's cyclic rule replaces that.
  // Per ADR-0011 §Consequences: existing rows decode with currentPhase=
  // .deload + additive defaults (counter=0, lastPhaseTransitionAt=0); the v2
  // cyclic rule handles them transparently with NO migration code path.
  //
  // This test simulates a legacy decoded row across two consecutive session-
  // completion calls:
  //   1. sessionsInPhase=2 (under threshold) → no-op, ratchets normally
  //   2. sessionsInPhase=3 (= deload threshold) → deload-end-cycle to
  //      accumulation per §(c), regardless of trend
  const deloadThreshold = 3;
  const legacyDecodedBase: PerPatternState = {
    currentPhase: "deload",
    sessionsInPhase: 2, // ratcheting toward threshold
    sessionsRequiredForPhase: deloadThreshold,
    trend: "plateaued", // any trend; cyclic rule fires regardless
    consecutiveForceDeloadsOnPattern: 0, // additive default on decode
    lastPhaseTransitionAtSessionCount: 0, // legacy v1 didn't track this
    goalArc: "strength", // arc-agnostic fixture (deload transitions)
  };

  // Step 1 — under threshold, ratchets normally (no-op).
  const ratcheting = advancePhase(legacyDecodedBase, /* sessionCount */ 11);
  assertEquals(ratcheting.fired, "no-op");
  assertEquals(ratcheting.newPhase, "deload");
  assertEquals(ratcheting.newSessionsInPhase, 2);
  assertEquals(ratcheting.newLastPhaseTransitionAtSessionCount, 0);

  // Step 2 — caller incremented sessionsInPhase to threshold, cycles per §(c).
  const cycling = advancePhase(
    { ...legacyDecodedBase, sessionsInPhase: deloadThreshold },
    /* sessionCount */ 12,
  );
  assertEquals(cycling.fired, "deload-end-cycle");
  assertEquals(cycling.newPhase, "accumulation");
  assertEquals(cycling.newSessionsInPhase, 0);
  assertEquals(cycling.newConsecutiveForceDeloads, 0);
  assertEquals(cycling.newLastPhaseTransitionAtSessionCount, 12);
  assertEquals(cycling.firesDeloadEndTransitionMode, true);
});

Deno.test("ADR-0011 §(d): deload-end-cycle does NOT reset consecutiveForceDeloads counter (only natural progressing-advance resets — negative case to C5)", () => {
  // Negative-case companion to C5's positive assertion. Per ADR-0011 §(d):
  //   "The counter increments only on force-deloads (not on natural deload-
  //    end transitions), and resets to 0 on any natural progressing-advance."
  // This test pins the no-reset semantic so a future maintainer who changes
  // deload-end to also-reset (the symmetric-but-wrong intuition) breaks here.
  // Without C11 as a separate cycle, a refactor that conflates the two
  // counter-handling paths would not break C5 (which doesn't exercise
  // deload-end), and the regression would slide through.
  //
  // Fixture: counter=3 (chronically force-deloaded pattern surfacing the
  // §(d) digest threshold), going through deload-end. Counter must NOT
  // drop to 0 — the LLM digest must keep seeing the chronic-stuck signal.
  const deloadThreshold = 3;
  const state: PerPatternState = {
    currentPhase: "deload",
    sessionsInPhase: deloadThreshold,
    sessionsRequiredForPhase: deloadThreshold,
    trend: "progressing",
    consecutiveForceDeloadsOnPattern: 3,
    lastPhaseTransitionAtSessionCount: 10,
    goalArc: "strength", // arc-agnostic fixture (deload-end cycle)
  };
  const outcome = advancePhase(state, /* sessionCount */ 13);

  assertEquals(outcome.fired, "deload-end-cycle");
  assertEquals(outcome.newConsecutiveForceDeloads, 3); // NOT 0 (load-bearing)
});

Deno.test("ADR-0011 §(b)+(c): force-deload-trigger condition met while in deload — cyclic rule wins by composition; counter NOT incremented", () => {
  // Issue #79's C8 edge-case wording ("force-deload while already in deload
  // → no-op (NO counter increment)") describes a state UNREACHABLE under the
  // composition rule. Step 2 (cyclic deload-end) always fires first when
  // currentPhase=.deload AND sessionsInPhase >= threshold, so step 3 (§(b)
  // force-deload) cannot reach a deload pattern. The "no-op" prose targets
  // the user-visible invariant that the counter must not double-increment;
  // the cyclic rule satisfies that invariant naturally because deload-end-
  // cycle does not touch the counter (per §(d): "counter increments only on
  // force-deloads, not on natural deload-end transitions").
  //
  // This test pins the actually-reachable composed outcome:
  //   currentPhase=deload + sessionsInPhase=2×deload-threshold + plateaued
  //   → cyclic deload-end-cycle (per step 2) → counter preserved.
  //
  // Issue amendment proposed post-merge to reword the C8 edge-case prose.
  // See A7's cycle 10 / 13 / 17 / 18 for the same level-5-prose-vs-level-3-
  // ADR pattern. Recurrence noted as a candidate for design-principles.md.
  const deloadThreshold = 3; // = sessionsRequiredFor("deload", daysPerWeek=4)
  const state: PerPatternState = {
    currentPhase: "deload",
    sessionsInPhase: 2 * deloadThreshold, // §(b) trigger condition met
    sessionsRequiredForPhase: deloadThreshold,
    trend: "plateaued",
    consecutiveForceDeloadsOnPattern: 2, // pre-set non-zero to verify preservation
    lastPhaseTransitionAtSessionCount: 8,
    goalArc: "strength", // arc-agnostic fixture (§(b)+(c) composition)
  };
  const outcome = advancePhase(state, /* sessionCount */ 14);

  assertEquals(outcome.fired, "deload-end-cycle");
  assertEquals(outcome.newPhase, "accumulation"); // cyclic per §(c)
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 2); // preserved — the user-visible invariant
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 14);
  assertEquals(outcome.firesDeloadEndTransitionMode, true);
});

Deno.test("ADR-0011 §(b): force-deload at 2× threshold (declining) — same path as plateaued; counter += 1", () => {
  // Mirrors C6 with trend=declining. The §(b) safety valve fires on EITHER
  // plateaued OR declining at ≥ 2× threshold — both are "stuck" trends from
  // the advance-blocking perspective. Pinning this behaviour separately so
  // a future refactor that narrows the §(b) trigger to plateaued-only does
  // not silently leave declining patterns stuck forever (decline is the
  // more-urgent of the two trends per ADR-0011 §(a)).
  const state = baseState({
    sessionsInPhase: 16,
    trend: "declining",
    consecutiveForceDeloadsOnPattern: 0,
  });
  const outcome = advancePhase(state, /* sessionCount */ 20);

  assertEquals(outcome.fired, "force-deload");
  assertEquals(outcome.newPhase, "deload");
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 1);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 20);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0011 §(a): declining blocks natural advance — block extension to declining (regressing lifter must not be auto-advanced into a harder phase)", () => {
  // Threshold met but trend=declining blocks. Per ADR-0011 §(a) Considered
  // Options: declining is more urgent than plateau, not less — auto-
  // advancing a regressing lifter into intensification compounds the
  // regression. Same conditional-not-destructive accumulation behaviour.
  const state = baseState({
    sessionsInPhase: 8,
    trend: "declining",
  });
  const outcome = advancePhase(state, /* sessionCount */ 12);

  assertEquals(outcome.fired, "blocked");
  assertEquals(outcome.newPhase, "accumulation");
  assertEquals(outcome.newSessionsInPhase, 8);
  assertEquals(outcome.newConsecutiveForceDeloads, 0);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 0);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0011: plateau blocks natural advance — sessionsInPhase keeps accumulating (conditional, not destructive)", () => {
  // Threshold met (sessionsInPhase = 8 = required) but trend=plateaued blocks
  // the natural-advance path. Per ADR-0011 §(a): block is conditional;
  // sessionsInPhase passed through unchanged so the caller's accumulation
  // continues toward the 2× force-deload threshold on subsequent sessions.
  const state = baseState({
    sessionsInPhase: 8, // = sessionsRequiredForPhase
    trend: "plateaued",
  });
  const outcome = advancePhase(state, /* sessionCount */ 12);

  assertEquals(outcome.fired, "blocked");
  assertEquals(outcome.newPhase, "accumulation"); // unchanged
  assertEquals(outcome.newSessionsInPhase, 8); // unchanged
  assertEquals(outcome.newConsecutiveForceDeloads, 0);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 0); // unchanged
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

// ─────────────────────────────────────────────────────────────────────────
// ADR-0030: goal-aware phase cycle. Strength keeps peaking; everything else
// uses the volume arc (skip peaking). The classifier is asymmetric-error-safe:
// only an explicit strength signal yields "strength"; absent/empty → "volume".
// ─────────────────────────────────────────────────────────────────────────

Deno.test("ADR-0030 goalArc: explicit strength signals → strength (case-insensitive); everything else → volume", () => {
  // Strength signals.
  assertEquals(goalArc("Strength (max weight)"), "strength");
  assertEquals(goalArc("build STRENGTH"), "strength"); // case-insensitive
  assertEquals(goalArc("powerlifting meet prep"), "strength");
  assertEquals(goalArc("improve my 1RM"), "strength");
  assertEquals(goalArc("hit a new max weight squat"), "strength");

  // Non-strength → volume.
  assertEquals(goalArc("Hypertrophy (muscle size)"), "volume");
  assertEquals(goalArc("Muscular endurance"), "volume");
  assertEquals(goalArc("General fitness"), "volume");

  // Absent / empty / whitespace → volume (asymmetric-error-safe default).
  assertEquals(goalArc(""), "volume");
  assertEquals(goalArc("   "), "volume");
  assertEquals(goalArc(null), "volume");
  assertEquals(goalArc(undefined), "volume");
});

Deno.test("ADR-0030 strength arc UNCHANGED: intensification + progressing + threshold → peaking, natural-advance, counter reset", () => {
  const state = baseState({
    currentPhase: "intensification",
    sessionsInPhase: 8,
    trend: "progressing",
    consecutiveForceDeloadsOnPattern: 2,
    goalArc: "strength",
  });
  const outcome = advancePhase(state, /* sessionCount */ 20);

  assertEquals(outcome.fired, "natural-advance");
  assertEquals(outcome.newPhase, "peaking");
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 0); // natural-advance resets
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 20);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0030 volume arc SKIPS peaking: intensification + progressing + threshold → deload (not peaking), natural-advance", () => {
  const state = baseState({
    currentPhase: "intensification",
    sessionsInPhase: 8,
    trend: "progressing",
    goalArc: "volume",
  });
  const outcome = advancePhase(state, /* sessionCount */ 20);

  assertEquals(outcome.fired, "natural-advance");
  assertEquals(outcome.newPhase, "deload"); // skipped peaking
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newConsecutiveForceDeloads, 0);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 20);
  // Volume natural-advance into deload is NOT a deload-end cycle, so it does
  // NOT fire the transition-mode trigger (that fires only on deload→accumulation).
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0030 volume off-arc peaking: a peaking pattern under volume arc → deload (NOT accumulation via modulo accident)", () => {
  // Legacy data or a strength→hypertrophy goal switch can leave a pattern
  // sitting in `peaking` under a volume arc. On natural advance it must go to
  // deload (the slot it is owed), not jump to accumulation.
  const state = baseState({
    currentPhase: "peaking",
    sessionsInPhase: 6, // sessionsRequiredFor("peaking", 4) = 6
    sessionsRequiredForPhase: 6,
    trend: "progressing",
    goalArc: "volume",
  });
  const outcome = advancePhase(state, /* sessionCount */ 22);

  assertEquals(outcome.fired, "natural-advance");
  assertEquals(outcome.newPhase, "deload"); // NOT accumulation
  assertEquals(outcome.newSessionsInPhase, 0);
  assertEquals(outcome.newLastPhaseTransitionAtSessionCount, 22);
});

Deno.test("ADR-0030 accumulation→intensification identical for BOTH arcs", () => {
  const strength = advancePhase(
    baseState({ currentPhase: "accumulation", sessionsInPhase: 8, goalArc: "strength" }),
    12,
  );
  const volume = advancePhase(
    baseState({ currentPhase: "accumulation", sessionsInPhase: 8, goalArc: "volume" }),
    12,
  );
  assertEquals(strength.fired, "natural-advance");
  assertEquals(strength.newPhase, "intensification");
  assertEquals(volume.fired, "natural-advance");
  assertEquals(volume.newPhase, "intensification");
});

Deno.test("ADR-0030 force-deload UNCHANGED for volume arc: plateaued at 2× threshold → deload, force-deload, counter += 1", () => {
  const state = baseState({
    sessionsInPhase: 16, // 2× threshold
    trend: "plateaued",
    consecutiveForceDeloadsOnPattern: 0,
    goalArc: "volume",
  });
  const outcome = advancePhase(state, /* sessionCount */ 20);

  assertEquals(outcome.fired, "force-deload");
  assertEquals(outcome.newPhase, "deload");
  assertEquals(outcome.newConsecutiveForceDeloads, 1);
  assertEquals(outcome.firesDeloadEndTransitionMode, false);
});

Deno.test("ADR-0030 deload-end cyclic UNCHANGED for volume arc: deload at threshold → accumulation, deload-end-cycle, transition-mode fires", () => {
  const state = baseState({
    currentPhase: "deload",
    sessionsInPhase: 3,
    sessionsRequiredForPhase: 3,
    trend: "progressing",
    goalArc: "volume",
  });
  const outcome = advancePhase(state, /* sessionCount */ 25);

  assertEquals(outcome.fired, "deload-end-cycle");
  assertEquals(outcome.newPhase, "accumulation");
  assertEquals(outcome.firesDeloadEndTransitionMode, true);
});
