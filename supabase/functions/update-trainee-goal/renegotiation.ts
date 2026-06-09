// Project Apex — goal-renegotiation stretch re-derivation (#304, ADR-0022).
//
// Pure helpers for the "silent" renegotiation lifecycle (ADR-0005 §projections,
// "re-derived silently on goal renegotiation"). When the athlete changes their
// goal — statement or focus areas — each existing per-pattern projection's
// STRETCH is re-derived from the (immovable) floor and the pattern's current
// trend, clamped UPWARD-ONLY so a target the athlete deliberately raised (#269)
// is never lowered. Floor is untouched; progress is intentionally left for the
// next session-apply to refresh (mirrors the #296 manual-edit path).
//
// By design this is nearly inert: the ADR-0021 stretch formula reads only
// floor + trend, so re-derivation moves a number only when the trend has
// shifted since the original derivation. That matches ADR-0005's "silently".
// The goal-aware version — where the new goal itself moves targets — is its own
// deferred design (#305), not this slice.
//
// Pure: no I/O, no clock reads.

import {
  deriveStretch,
  type PatternProjection,
} from "../_shared/calibration-projection.ts";
import type { ProgressionTrend } from "../_shared/plateau-verdict.ts";

/** The goal fields a renegotiation compares (statement + focus areas). */
export interface RenegotiableGoal {
  statement: string;
  focusAreas: string[];
}

const VALID_TRENDS: ReadonlySet<string> = new Set([
  "progressing",
  "plateaued",
  "declining",
]);

/**
 * True iff `next` is a genuine renegotiation of `prior` — the statement or the
 * (order-insensitive) set of focus areas changed.
 *
 * A null/undefined prior (onboarding's first-ever goal-set: no goal stored yet)
 * is NOT a renegotiation. An empty-statement prior is the `GoalState.placeholder`
 * sentinel (#146 defensive decode) and is likewise treated as "no real prior
 * goal", so hydrating a real goal over a placeholder never counts.
 */
export function isRenegotiation(
  prior: RenegotiableGoal | null | undefined,
  next: RenegotiableGoal,
): boolean {
  if (!prior || prior.statement === "") return false;
  if (prior.statement !== next.statement) return true;
  const a = [...prior.focusAreas].sort();
  const b = [...next.focusAreas].sort();
  if (a.length !== b.length) return true;
  return a.some((v, i) => v !== b[i]);
}

/**
 * Re-derive each projection's stretch on renegotiation. Upward-only:
 * `stretch := max(stored, deriveStretch(floor, currentTrend))`. Floor and
 * progress are returned unchanged (the immovable floor can't be faked; progress
 * self-heals on the next session-apply). A pattern with no — or a malformed —
 * trend entry defaults to "progressing", mirroring the calibration-derivation
 * arm's `?? "progressing"`. Returns a new array; entries that don't move are
 * returned by reference.
 */
export function rederiveStretchOnRenegotiation(
  projections: PatternProjection[],
  trendByPattern: Record<string, string | undefined>,
): PatternProjection[] {
  return projections.map((p) => {
    const raw = trendByPattern[p.pattern];
    const trend: ProgressionTrend = raw !== undefined && VALID_TRENDS.has(raw)
      ? raw as ProgressionTrend
      : "progressing";
    const rederived = deriveStretch(p.floor, trend);
    const stretch = Math.max(p.stretch, rederived); // upward-only clamp
    return stretch === p.stretch ? p : { ...p, stretch };
  });
}
