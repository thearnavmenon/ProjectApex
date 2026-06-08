// Project Apex — shared per-axis confidence-lifecycle foundation (#282, Part of #166).
//
// Per ADR-0020: the three axes (exercise / pattern / muscle) each own an
// INDEPENDENT advancement rule, but all route their proposed next-state through
// this one `monotonicAdvance` clamp so the forward-only / no-skip invariant is
// enforced uniformly. The per-axis gate thresholds live in ADR-0020's table,
// not here — this module is only the shared state machine + write-contract type.
//
// Pure: no I/O, no clock reads.

/**
 * The confidence states an Edge Function may WRITE. The Swift `AxisConfidence`
 * enum (ADR-0005) has a 4th case `seasoned` that is deliberately reserved and
 * never written (ADR-0020 §States) — excluding it from this write-contract type
 * makes an accidental `seasoned` write a compile error.
 */
export type ConfidenceWriteState = "bootstrapping" | "calibrating" | "established";

/**
 * Stage ordering for the forward-only ratchet. Index = maturity rank.
 * `seasoned` is intentionally absent (reserved, never written).
 */
export const CONFIDENCE_ORDER: readonly ConfidenceWriteState[] = [
  "bootstrapping",
  "calibrating",
  "established",
];

/**
 * Forward-only, no-skip clamp (ADR-0020 §monotonicAdvance). Given the current
 * confidence and the state a per-axis rule proposes, returns the next state:
 * - never regresses below `current` (forward-only ratchet — the ONLY regression
 *   policy; confidence never downgrades);
 * - advances at most ONE stage per call (no stage-skipping) — a rule proposing
 *   `established` from `bootstrapping` advances only to `calibrating`, reaching
 *   `established` on a subsequent apply.
 */
export function monotonicAdvance(
  current: ConfidenceWriteState,
  proposed: ConfidenceWriteState,
): ConfidenceWriteState {
  const ci = CONFIDENCE_ORDER.indexOf(current);
  const pi = CONFIDENCE_ORDER.indexOf(proposed);
  if (pi <= ci) return current; // no regression (and no-op when equal)
  return CONFIDENCE_ORDER[ci + 1]; // advance exactly one stage toward proposed
}
