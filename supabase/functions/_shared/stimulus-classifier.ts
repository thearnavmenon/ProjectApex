// Project Apex — Phase 2 stimulus-classifier.
//
// Per Q3 PRD-internal (lock-in 2026-05-07) and ADR-0005 §"two-dimensional
// recovery", a pure classifier mapping (intent, reps, rpeFelt) to the
// stimulus dimension(s) a set drives. Non-stimulus sets (warmup,
// technique) return null so the orchestrator (#A12) skips updating
// recovery timestamps (ADR-0005 §"low-stimulus exclusion via Optional
// return").
//
// AMRAP returns 'both' (not 'metabolic') per Q3 lock-in: AMRAP is by
// definition a max-effort final-set, the asymmetric-error logic of the
// top-9–10 RPE-bump applies — under-counting NM stimulus is silent →
// over-prescription. Issue #76 body's 'metabolic' cell is a transcription
// error against the grilling lock-in; flagged in PR description.
//
// Pure: no I/O, no clock reads.

import {
  BACKOFF_BOTH_REP_MAX,
  BACKOFF_NM_REP_MAX,
  STIMULUS_RPE_BUMP_REP_MAX,
  STIMULUS_RPE_BUMP_REP_MIN,
  STIMULUS_RPE_BUMP_TRIGGER,
} from "./constants.ts";

export type SetIntent = "warmup" | "top" | "backoff" | "technique" | "amrap";

export type StimulusDimension = "neuromuscular" | "metabolic" | "both";

export function classifyStimulus(
  intent: SetIntent,
  reps: number,
  rpeFelt: number | null,
): StimulusDimension | null {
  switch (intent) {
    case "warmup":
    case "technique":
      return null;
    case "amrap":
      return "both";
    case "top":
      if (reps <= BACKOFF_NM_REP_MAX) return "neuromuscular";
      if (reps <= BACKOFF_BOTH_REP_MAX) return "both";
      if (
        reps >= STIMULUS_RPE_BUMP_REP_MIN &&
        reps <= STIMULUS_RPE_BUMP_REP_MAX
      ) {
        // RPE-bump: RPE ≥ 9 upgrades metabolic → both (Q3 asymmetric-error
        // preference — under-counting NM stimulus is silent).
        if (rpeFelt !== null && rpeFelt >= STIMULUS_RPE_BUMP_TRIGGER) {
          return "both";
        }
        return "metabolic";
      }
      // reps > 10: outside ADR-0005's e1RM validity (3..10), but stimulus
      // classification still applies. Per Q3 / #76 item-11: metabolic;
      // PR description flags for reviewer.
      return "metabolic";
    case "backoff":
      if (reps <= BACKOFF_NM_REP_MAX) return "neuromuscular";
      if (reps <= BACKOFF_BOTH_REP_MAX) return "both";
      return "metabolic";
  }
}
