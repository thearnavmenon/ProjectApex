// Project Apex — PatternProfile confidence-backfill helper (#173).
//
// Pre-existing patterns (those that existed in model_json.patterns before
// PR #149/#146 landed the bootstrap producer) carry `confidence: null`
// because the bootstrap path only runs for newly-discovered patterns
// (`if (!(pattern in merged))`). This pure function repairs that shape
// by initializing null-confidence entries to "bootstrapping".
//
// Design decisions (locked per prep-prompt):
// - Producer-side fix, not SQL backfill: survives future field additions
//   and catches the same shape for any affected user.
// - Idempotent by construction: writing "bootstrapping" when confidence
//   is already "bootstrapping" or beyond is a no-op in practice (the
//   guard checks === null, not a falsy check).
// - Scope: confidence field only. Other potentially-missing fields
//   (rpeOffset, recovery, weeklyVolumeLoadHistory) are out of scope
//   for this issue — #173 explicitly limits to confidence.
// - Audit: returns a count of patterns actually written so the caller
//   can conditionally add "pattern-confidence-backfill" to rulesFired.

/**
 * Walks model_json.patterns entries. For each entry where `confidence`
 * is exactly `null`, sets it to `"bootstrapping"`.
 *
 * @param patterns - The patterns dict from model_json (mutated in place
 *   on a shallow copy; original is not mutated).
 * @returns An object with the updated patterns dict and `backfilledCount`
 *   (number of patterns whose confidence was written).
 */
export function backfillPatternConfidence(
  patterns: Record<string, Record<string, unknown>>,
): {
  patterns: Record<string, Record<string, unknown>>;
  backfilledCount: number;
} {
  const updated: Record<string, Record<string, unknown>> = {};
  let backfilledCount = 0;

  for (const [key, profile] of Object.entries(patterns)) {
    if (profile.confidence === null) {
      updated[key] = { ...profile, confidence: "bootstrapping" };
      backfilledCount++;
    } else {
      updated[key] = profile;
    }
  }

  return { patterns: updated, backfilledCount };
}
