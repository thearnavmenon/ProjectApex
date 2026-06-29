// Project Apex — Phase 2 per-pattern phase-advance module.
//
// Per ADR-0011 (per-pattern phase advance — plateau-aware,
// force-advance safety valve, cyclic mesocycle, accepted
// 2026-05-07): advances `PatternProfile.currentPhase` on every
// session-completion that increments `sessionsInPhase`.
//
// Composition (ADR-0011 §Decision):
//   1. Caller increments `sessionsInPhase` before calling this
//      function.
//   2. If currentPhase == .deload AND sessionsInPhase >= threshold
//      → cyclic advance to .accumulation; fires deload-end Q5
//      transition-mode trigger; consecutiveForceDeloads NOT reset
//      (only natural progressing-advance resets it).
//   3. Else if sessionsInPhase >= 2× threshold AND trend ∈
//      {plateaued, declining} → force-deload (skips intensification
//      / peaking); consecutiveForceDeloads += 1.
//   4. Else if sessionsInPhase >= threshold AND trend == .progressing
//      → natural advance to nextPhase in cycle; counter reset.
//   5. Else → blocked (threshold met but trend blocks) or no-op
//      (under threshold). sessionsInPhase keeps accumulating per
//      ADR-0011 §(a) "block is conditional, not destructive."
//
// Pure: no I/O, no clock reads. Caller injects `currentSessionCount`
// for `lastPhaseTransitionAtSessionCount` updates.

import { FORCE_DELOAD_THRESHOLD_MULTIPLIER } from "./constants.ts";
import type { ProgressionTrend } from "./plateau-verdict.ts";

export type MesocyclePhase =
  | "accumulation"
  | "intensification"
  | "peaking"
  | "deload";

/**
 * Goal arc per ADR-0030 (goal-branch amendment to ADR-0011). The per-pattern
 * phase cycle is goal-aware: a `strength` arc keeps the peaking taper; a
 * `volume` arc skips `peaking` entirely so hypertrophy/endurance/general users
 * are never cycled into a powerlifting peak (low reps, RIR 1–2). This is a
 * computed *input* — it is NOT a persisted field on the wire (the goal lives in
 * `model_json.goal.statement`; the orchestrator classifies it once and injects
 * the resolved arc, keeping this module pure).
 */
export type GoalArc = "strength" | "volume";

export interface PerPatternState {
  currentPhase: MesocyclePhase;
  sessionsInPhase: number;
  sessionsRequiredForPhase: number;
  trend: ProgressionTrend;
  consecutiveForceDeloadsOnPattern: number;
  lastPhaseTransitionAtSessionCount: number;
  /** Resolved goal arc (ADR-0030). Computed input, not persisted. */
  goalArc: GoalArc;
}

export interface PhaseAdvanceOutcome {
  newPhase: MesocyclePhase;
  newSessionsInPhase: number;
  newConsecutiveForceDeloads: number;
  newLastPhaseTransitionAtSessionCount: number;
  fired: "natural-advance" | "force-deload" | "deload-end-cycle" | "blocked" | "no-op";
  /** True if this transition fires the deload-end Q5 transition-mode trigger (ADR-0011 §(c)). */
  firesDeloadEndTransitionMode: boolean;
}

/**
 * Option-B threshold per ADR-0011 §Consequences — preserved verbatim
 * from legacy `PatternPhaseService.swift:78`:
 *
 *   sessionsRequired = max(3, phaseWeeks × max(1, ⌊daysPerWeek / 2⌋))
 *
 * `Math.floor(daysPerWeek / 2)` mirrors Swift's integer-division semantics
 * on the legacy `daysPerWeek / 2` expression. The floor of 3 catches the
 * minimum-cadence edge case (daysPerWeek=1 → multiplier=1, deload=1 →
 * 3 sessions, not 1).
 */
export function sessionsRequiredFor(
  phase: MesocyclePhase,
  daysPerWeek: number,
): number {
  let phaseWeeks: number;
  switch (phase) {
    case "accumulation":
      phaseWeeks = 4;
      break;
    case "intensification":
      phaseWeeks = 4;
      break;
    case "peaking":
      phaseWeeks = 3;
      break;
    case "deload":
      phaseWeeks = 1;
      break;
  }
  const multiplier = Math.max(1, Math.floor(daysPerWeek / 2));
  return Math.max(3, phaseWeeks * multiplier);
}

/**
 * Goal-aware phase cycle per ADR-0011 §(c) as amended by ADR-0030.
 *   - strength arc (unchanged): accumulation → intensification → peaking → deload → accumulation
 *   - volume arc:               accumulation → intensification → deload → accumulation  (skips peaking)
 *
 * `intensification` is kept for volume — progressive overload by load is fine
 * for hypertrophy; only the strength *taper* (peaking) is wrong. The cycle is
 * indexed-and-modulo on advance, so deload wraps back to accumulation in both
 * arcs.
 */
const STRENGTH_ARC: readonly MesocyclePhase[] = [
  "accumulation",
  "intensification",
  "peaking",
  "deload",
];

const VOLUME_ARC: readonly MesocyclePhase[] = [
  "accumulation",
  "intensification",
  "deload",
];

const phaseOrderFor = (arc: GoalArc): readonly MesocyclePhase[] =>
  arc === "strength" ? STRENGTH_ARC : VOLUME_ARC;

const nextPhaseInCycle = (
  current: MesocyclePhase,
  arc: GoalArc,
): MesocyclePhase => {
  const order = phaseOrderFor(arc);
  const idx = order.indexOf(current);
  // Off-arc current phase (a volume-arc pattern sitting in `peaking` from
  // legacy data or a strength→hypertrophy goal switch): treat `peaking` as the
  // pre-deload slot and advance explicitly to `deload`. Do NOT lean on the
  // modulo accident (indexOf === -1 → order[0] → accumulation), which would
  // skip the deload the pattern is owed.
  if (idx === -1) return "deload";
  return order[(idx + 1) % order.length];
};

/**
 * Classify a freeform goal statement into a goal arc (ADR-0030). Returns
 * `"strength"` iff the statement carries an explicit strength signal;
 * everything else — including absent / empty / whitespace-only — resolves to
 * `"volume"`. The asymmetry is deliberate and error-safe: the bug being fixed
 * is non-strength users getting peaked, so default-no-peak fixes the majority
 * and never wrongly peaks a user.
 */
export function goalArc(statement: string | null | undefined): GoalArc {
  if (!statement || !statement.trim()) return "volume";
  const s = statement.toLowerCase();
  const strengthSignals = ["strength", "max weight", "powerlift", "1rm"];
  return strengthSignals.some((sig) => s.includes(sig)) ? "strength" : "volume";
}

/**
 * Per-pattern phase advance per ADR-0011.
 */
export function advancePhase(
  state: PerPatternState,
  currentSessionCount: number,
): PhaseAdvanceOutcome {
  const passthrough = {
    newPhase: state.currentPhase,
    newSessionsInPhase: state.sessionsInPhase,
    newConsecutiveForceDeloads: state.consecutiveForceDeloadsOnPattern,
    newLastPhaseTransitionAtSessionCount: state.lastPhaseTransitionAtSessionCount,
    firesDeloadEndTransitionMode: false,
  };

  const stuck = state.trend === "plateaued" || state.trend === "declining";
  const forceDeloadThreshold = FORCE_DELOAD_THRESHOLD_MULTIPLIER *
    state.sessionsRequiredForPhase;

  // ADR-0011 §(c): cyclic deload→accumulation. At sessionsInPhase >= threshold
  // in .deload, advance to .accumulation regardless of trend (coming out of
  // deload the pattern is by definition refreshed; the §(a) trend block does
  // not apply to the deload→accumulation transition). Fires the deload-end
  // Q5 transition-mode trigger (3-session plain-mean window during resumption
  // catches post-deload rebound and prevents stale pre-deload e1RM bleed).
  // Per §(d): the counter is NOT reset by deload-end (only natural
  // progressing-advance resets it) and NOT incremented (only force-deload
  // increments it).
  //
  // Composition note: this branch must come BEFORE the §(b) force-deload
  // branch. The ADR §(b) edge case "no-op while already in deload" describes
  // a state unreachable under this composition — when currentPhase=.deload
  // and sessionsInPhase >= threshold, this cyclic rule fires first, so §(b)
  // never reaches an in-deload pattern. The user-visible invariant ("counter
  // not double-incremented for in-deload patterns") is preserved by this
  // branch's no-counter-touch property. See C8 test (§(b)+(c) composition).
  if (
    state.currentPhase === "deload" &&
    state.sessionsInPhase >= state.sessionsRequiredForPhase
  ) {
    return {
      newPhase: "accumulation",
      newSessionsInPhase: 0,
      newConsecutiveForceDeloads: state.consecutiveForceDeloadsOnPattern,
      newLastPhaseTransitionAtSessionCount: currentSessionCount,
      fired: "deload-end-cycle",
      firesDeloadEndTransitionMode: true,
    };
  }

  // ADR-0011 §(b): force-advance safety valve. Under stuck trend at ≥ 2×
  // threshold, jump directly to .deload (skip intensification / peaking) to
  // break the plateau. Counter increments here; the natural progressing-
  // advance path (below) is the only path that resets it. Must come before
  // the §(a) blocked check because at ≥ 2× threshold both predicates match.
  if (state.sessionsInPhase >= forceDeloadThreshold && stuck) {
    return {
      newPhase: "deload",
      newSessionsInPhase: 0,
      newConsecutiveForceDeloads: state.consecutiveForceDeloadsOnPattern + 1,
      newLastPhaseTransitionAtSessionCount: currentSessionCount,
      fired: "force-deload",
      firesDeloadEndTransitionMode: false,
    };
  }

  // ADR-0011 §(a): plateau OR declining blocks natural advance. The block is
  // conditional, not destructive — sessionsInPhase keeps accumulating toward
  // the 2× force-deload threshold on subsequent calls. Declining is more
  // urgent than plateau (lifter is regressing, not just stuck) so auto-
  // advancing into a harder phase is the wrong intervention.
  if (state.sessionsInPhase >= state.sessionsRequiredForPhase && stuck) {
    return { ...passthrough, fired: "blocked" };
  }

  // ADR-0011 §(a): natural progressing-advance fires when sessionsInPhase has
  // met the threshold and trend == progressing. Per ADR-0011 §(b), this path
  // resets `consecutiveForceDeloadsOnPattern` to 0 — only this path resets
  // the counter (deload-end-cycle does not).
  if (
    state.sessionsInPhase >= state.sessionsRequiredForPhase &&
    state.trend === "progressing"
  ) {
    return {
      // ADR-0030: goal-aware next phase. Strength keeps the peaking taper;
      // volume skips it. The deload-end cyclic branch (above) and the
      // force-deload safety valve stay goal-agnostic — only the natural
      // progressing-advance is goal-branched.
      newPhase: nextPhaseInCycle(state.currentPhase, state.goalArc),
      newSessionsInPhase: 0,
      newConsecutiveForceDeloads: 0,
      newLastPhaseTransitionAtSessionCount: currentSessionCount,
      fired: "natural-advance",
      firesDeloadEndTransitionMode: false,
    };
  }

  return { ...passthrough, fired: "no-op" };
}
