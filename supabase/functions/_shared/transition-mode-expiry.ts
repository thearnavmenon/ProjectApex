// Project Apex — Phase 2 transition-mode expiry composer.
//
// Per Q5 PRD-internal lock-in: when an ADR-0005 trigger fires
// (calibration recency, deload-end, phase transition, long-absence
// return), the trainee model's `transitionModeUntil` is set to:
//
//   transitionModeUntil = now + cadenceAwareDuration(cadence, 3, 14d, 21d)
//
// composed via the ADR-0015 cadence-aware-duration primitive
// (`./cadence-translation.ts`). Composition with an existing
// `currentUntil` is max-of-untils on overlap (extend, don't reset),
// fresh-from-now after expiry.
//
// The 14-day floor rationale is independent-session-equivalents at high
// cadence (statistical noise reduction needs more sessions when sessions
// are less independent), NOT fatigue accumulation. The 21-day nil
// fallback covers ~3 sessions at an assumed 1×/week resume cadence for
// the long-absence-returner case.
//
// Pure: no I/O, no clock reads. `now` is injected by the caller.

import { cadenceAwareDuration } from "./cadence-translation.ts";
import {
  TRANSITION_MODE_CADENCE_MULTIPLIER,
  TRANSITION_MODE_FLOOR_DAYS,
  TRANSITION_MODE_NIL_CADENCE_FALLBACK_DAYS,
} from "./constants.ts";

const MS_PER_DAY = 24 * 60 * 60 * 1000;

const addDays = (base: Date, days: number): Date =>
  new Date(base.getTime() + days * MS_PER_DAY);

/**
 * Compose transition-mode expiry per Q5 PRD-internal + ADR-0015.
 *
 * @param now - injected wall-clock (caller-supplied; this module reads no clock).
 * @param cadenceDays - mean delta between recent sessions, or null when fewer
 *                     than 2 sessions are recorded (long-absence-returner case).
 * @param currentUntil - the existing `transitionModeUntil`, or null on first
 *                      transition-mode entry.
 */
export function computeTransitionModeUntil(
  now: Date,
  cadenceDays: number | null,
  currentUntil: Date | null,
): Date {
  const days = cadenceAwareDuration(
    cadenceDays,
    TRANSITION_MODE_CADENCE_MULTIPLIER,
    TRANSITION_MODE_FLOOR_DAYS,
    TRANSITION_MODE_NIL_CADENCE_FALLBACK_DAYS,
  );
  const computed = addDays(now, days);
  // Max-of-untils on overlap (extend, don't shrink). currentUntil only
  // participates when it's still in the future; an expired currentUntil
  // is treated as fresh-from-now (no carry-over).
  if (currentUntil !== null && currentUntil.getTime() > now.getTime()) {
    return currentUntil.getTime() > computed.getTime() ? currentUntil : computed;
  }
  return computed;
}
