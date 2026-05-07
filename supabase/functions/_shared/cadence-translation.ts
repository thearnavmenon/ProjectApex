// Project Apex — Phase 2 cadence-aware-duration translator.
//
// Per ADR-0015 (Cadence-aware session-to-time translation pattern), this
// is the canonical primitive for translating "N sessions of training"
// into a wall-clock duration. Future rules adopting the shape MUST cite
// this ADR in their code comments (per ADR-0015 §Decision).
//
// Formula (verbatim from ADR-0015 §Decision):
//   durationDays = (cadence === null)
//       ? nilFallbackDays                        // conservative, calendar-day floor
//       : max(floorDays, N × cadenceDays);      // session-derived, with calendar floor
//
// Pure: no I/O, no clock reads. Caller composes with `Date` arithmetic.

/**
 * Cadence-aware translation per ADR-0015.
 *
 * @param cadenceDays - mean delta in days between consecutive recent
 *                     sessions (`PatternProfile.sessionsCadenceDays`);
 *                     null when fewer than 2 sessions are recorded.
 * @param n - the session-count semantic the rule is expressing.
 * @param floorDays - calendar-day minimum that prevents pathological
 *                   values at very high cadences.
 * @param nilFallbackDays - conservative fallback when no cadence is
 *                         available (long-absence-returner default).
 * @returns duration in days (Number, may be fractional).
 */
export function cadenceAwareDuration(
  cadenceDays: number | null,
  n: number,
  floorDays: number,
  nilFallbackDays: number,
): number {
  if (cadenceDays === null) {
    return nilFallbackDays;
  }
  return Math.max(floorDays, n * cadenceDays);
}
