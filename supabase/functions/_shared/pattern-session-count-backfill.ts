// Project Apex — PatternProfile sessionCount-backfill helper (#284, Part of #166).
//
// The per-pattern `sessionCount` field is introduced by ADR-0020 to drive the
// pattern confidence lifecycle. Patterns that existed before this slice carry
// no `sessionCount`, so the bootstrap path (which only runs for newly-trained
// patterns) never sets it. This pure function seeds missing `sessionCount` from
// `recentSessionDates.length` so existing patterns get credit for prior sessions
// rather than restarting the confidence climb from zero.
//
// Design (mirrors #173 backfillPatternConfidence):
// - Producer-side, not SQL: survives future field additions; catches the shape
//   for any affected user on their next apply.
// - Idempotent: only writes when `sessionCount` is undefined; once written, the
//   guard never re-fires.
// - Conservative seed: `recentSessionDates.length` is a FLOOR on the true count
//   (it is "approximate for pre-existing patterns; exact going forward"). It can
//   never over-count, which is the asymmetric-safe direction (ADR-0020).
// - Audit: returns the count of patterns actually written.

/**
 * Walks model_json.patterns entries. For each entry missing `sessionCount`,
 * seeds it from the length of `recentSessionDates` (0 if absent).
 *
 * @param patterns - The patterns dict from model_json (shallow-copied; the
 *   original is not mutated).
 * @returns The updated patterns dict and `backfilledCount` (patterns written).
 */
export function backfillPatternSessionCount(
  patterns: Record<string, Record<string, unknown>>,
): {
  patterns: Record<string, Record<string, unknown>>;
  backfilledCount: number;
} {
  const updated: Record<string, Record<string, unknown>> = {};
  let backfilledCount = 0;

  for (const [key, profile] of Object.entries(patterns)) {
    if (profile.sessionCount === undefined) {
      const recent = profile.recentSessionDates;
      const floor = Array.isArray(recent) ? recent.length : 0;
      updated[key] = { ...profile, sessionCount: floor };
      backfilledCount++;
    } else {
      updated[key] = profile;
    }
  }

  return { patterns: updated, backfilledCount };
}
