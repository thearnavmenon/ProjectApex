// Project Apex — Phase 2 global phase-advance trigger.
//
// Per ADR-0012 (global phase advance trigger and the major-pattern
// enumeration, accepted 2026-05-07). Fires iff:
//   - ≥4 of 6 major patterns transitioned phase within last 6 user
//     sessions (currentSessionCount - lastPhaseTransitionAtSessionCount
//     <= 6)
//   - AND (lastGlobalPhaseAdvanceFiredAtSessionCount === null
//          OR sessionCount - that >= 6)  // cooldown
//   - AND sessionCount >= 6              // bootstrap guard
//
// Force-deload counts as a phase transition (per ADR-0011 §(b) — feature,
// not bug; see ADR-0012 §Consequences "Force-deload-as-transition is a
// feature").
//
// Pure: no I/O, no clock reads.

import {
  GLOBAL_PHASE_ADVANCE_BOOTSTRAP_GUARD,
  GLOBAL_PHASE_ADVANCE_COOLDOWN_SESSIONS,
  GLOBAL_PHASE_ADVANCE_MAJOR_PATTERN_THRESHOLD,
  GLOBAL_PHASE_ADVANCE_SESSION_WINDOW,
  MAJOR_PATTERNS,
} from "./constants.ts";

export interface PatternTransitionState {
  pattern: string;
  lastPhaseTransitionAtSessionCount: number;
}

/**
 * Global phase-advance trigger per ADR-0012.
 */
export function shouldFireGlobalPhaseAdvance(
  patternStates: PatternTransitionState[],
  currentSessionCount: number,
  lastGlobalPhaseAdvanceFiredAtSessionCount: number | null,
): boolean {
  // ADR-0012 §Cooldown: bootstrap guard. Prevents premature firing on a
  // brand-new user whose 4th major's accumulation block fills up before
  // they have 6 sessions of total training history.
  if (currentSessionCount < GLOBAL_PHASE_ADVANCE_BOOTSTRAP_GUARD) return false;

  // ADR-0012 §Cooldown: pure session-count, no cadence translation. Fires
  // iff lastFired === null OR delta >= 6. Boundary-inclusive on the fires
  // side: delta=6 fires (cooldown just expired), delta=5 blocks.
  if (lastGlobalPhaseAdvanceFiredAtSessionCount !== null) {
    const delta = currentSessionCount - lastGlobalPhaseAdvanceFiredAtSessionCount;
    if (delta < GLOBAL_PHASE_ADVANCE_COOLDOWN_SESSIONS) return false;
  }

  // ADR-0012 §"6 major patterns": lunge and isolation transitions are
  // accessory and do NOT count toward the ≥4-of-6 threshold. Filter to
  // MAJOR_PATTERNS only before applying the window check.
  const majorSet: Set<string> = new Set(MAJOR_PATTERNS);

  // ADR-0012 §"Window semantics": for each major pattern, check
  // currentSessionCount - lastPhaseTransitionAtSessionCount <= 6 (window).
  // Count how many satisfy. Fires iff count >= 4.
  const transitionedInWindow = patternStates.filter(
    (p) =>
      majorSet.has(p.pattern) &&
      currentSessionCount - p.lastPhaseTransitionAtSessionCount <=
        GLOBAL_PHASE_ADVANCE_SESSION_WINDOW,
  ).length;
  return transitionedInWindow >= GLOBAL_PHASE_ADVANCE_MAJOR_PATTERN_THRESHOLD;
}
