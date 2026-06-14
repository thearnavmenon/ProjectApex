// Project Apex — long-absence re-anchor trigger predicate.
//
// When a lifter takes a long break their strength decays, but the
// event-windowed EWMA treats the first workout back as if it happened right
// after the last one — so the stale, inflated estimate persists. This module
// detects the absence so the orchestrator can flip the estimate/flag into
// transition mode and RE-ANCHOR (measure-don't-guess) off the post-return
// sessions.
//
// The TRIGGER is FLAT >= LONG_ABSENCE_DAYS (28) calendar days since the prior
// logged session — matching the client's `requiresReturnPhaseOverride` cue
// (`daysSinceLastSession >= 28`) in SessionPlanService.swift. It is NOT
// cadence-aware (the cadence-aware part lives in the transition-mode DURATION
// of `computeTransitionModeUntil`, which is unchanged).
//
// Pure: no clock reads. Both endpoints are injected by the caller.

import { LONG_ABSENCE_DAYS } from "./constants.ts";

// Re-export so consumers of the trigger predicate get the threshold from the
// same module; constants.ts remains the canonical home (constants_test.ts
// pins the value there).
export { LONG_ABSENCE_DAYS };

const MS_PER_DAY = 86_400_000;

/**
 * Calendar-day gap between the prior logged session and the incoming one.
 *
 * @param priorLoggedAt - the most-recent prior session's loggedAt, or null
 *                        when there is no prior session (first-ever).
 * @param incomingLoggedAt - the incoming session's loggedAt.
 * @returns null when `priorLoggedAt` is null; otherwise the gap in days,
 *          clamped to 0 (negative gaps — incoming before prior — are clock
 *          skew and never indicate an absence).
 */
export function gapDays(
  priorLoggedAt: Date | null,
  incomingLoggedAt: Date,
): number | null {
  if (priorLoggedAt === null) return null;
  const deltaMs = incomingLoggedAt.getTime() - priorLoggedAt.getTime();
  return Math.max(0, deltaMs / MS_PER_DAY);
}

/**
 * Long-absence trigger: fires when a measurable gap is >= LONG_ABSENCE_DAYS.
 * A null gap (no prior session) never fires.
 */
export function isLongAbsence(gapDays: number | null): boolean {
  return gapDays !== null && gapDays >= LONG_ABSENCE_DAYS;
}

/**
 * Drop everything before the most-recent long-absence gap, returning only the
 * post-return suffix — the same "re-anchor on the freshest training block"
 * principle the estimate-layer trim (ewma-engine `preGapCutoff`) uses, applied
 * to a session series for the calibration-projection consumer.
 *
 * `items` MUST be sorted ascending by loggedAt. A gap is an adjacent pair
 * separated by >= `thresholdDays`; when several exist, the cut is at the MOST
 * RECENT one. Returns the input unchanged when no qualifying gap exists.
 *
 * Pure: no clock reads.
 */
export function postReturnSessions<T extends { loggedAt: Date }>(
  items: T[],
  thresholdDays: number = LONG_ABSENCE_DAYS,
): T[] {
  let cut = 0;
  for (let i = 1; i < items.length; i++) {
    const gap = (items[i].loggedAt.getTime() - items[i - 1].loggedAt.getTime()) /
      MS_PER_DAY;
    if (gap >= thresholdDays) cut = i;
  }
  return items.slice(cut);
}
