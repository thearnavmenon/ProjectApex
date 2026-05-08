// Project Apex — Phase 2 prescription-accuracy aggregator.
//
// Per ADR-0014 (rep-error metric, 30-obs sliding window, deload
// exclusion, gap-bucket stratification, accepted 2026-05-07).
// Aligns with ADR-0010 (gap-bucket boundaries pin to NM tau=30h)
// and ADR-0011 (deload exclusion composes with cyclic phase model).
//
// Pure throughout except `appendObservation` which mutates the
// accumulator by design (sliding-window eviction).

import {
  GAP_BUCKET_BOUNDARY_HIGH_HOURS,
  GAP_BUCKET_BOUNDARY_LOW_HOURS,
  PRESCRIPTION_ACCURACY_BIAS_SURFACE_THRESHOLD,
  PRESCRIPTION_ACCURACY_DIGEST_MIN_SAMPLES,
  PRESCRIPTION_ACCURACY_GAP_BUCKET_DIVERGENCE_THRESHOLD,
  PRESCRIPTION_ACCURACY_GAP_BUCKET_MIN_SAMPLES,
  PRESCRIPTION_ACCURACY_RMSE_SURFACE_THRESHOLD,
  PRESCRIPTION_ACCURACY_WINDOW_SIZE,
} from "./constants.ts";

export type InterSessionGapBucket =
  | "under48h"
  | "between48And72h"
  | "over72h";

export type SetIntent =
  | "top"
  | "backoff"
  | "amrap"
  | "warmup"
  | "technique";

export interface PerCellAccumulator {
  pattern: string;
  intent: string;
  /** Rep-error values; sliding window of last PRESCRIPTION_ACCURACY_WINDOW_SIZE. */
  observations: number[];
  observationsByGapBucket: Record<InterSessionGapBucket, number[]>;
  /**
   * Parallel to `observations`: the gap-bucket each observation lives in.
   * Tracked so eviction can sync the per-bucket sub-array (per ADR-0014
   * §"Sliding window": "Per-bucket sub-arrays maintain the same eviction
   * order... Maintain by reference (each observation knows its bucket at
   * append time)"). Small interface extension over the issue body's
   * 4-field shape — surfaced in the slice PR.
   */
  observationBuckets: InterSessionGapBucket[];
}

export interface DigestableAccuracy {
  pattern: string;
  intent: string;
  bias: number;
  rmse: number;
  sampleCount: number;
  biasByGapBucket: Record<InterSessionGapBucket, number>;
  rmseByGapBucket: Record<InterSessionGapBucket, number>;
  sampleCountByGapBucket: Record<InterSessionGapBucket, number>;
}

export interface SetObservation {
  pattern: string;
  prescribedIntent: string;
  loggedIntent: string;
  prescribedReps: number;
  repsCompleted: number;
  userCorrectedWeight: boolean;
  completionFlags: string[];
  patternPhaseAtPrescription:
    | "accumulation"
    | "intensification"
    | "peaking"
    | "deload";
  loggedAt: Date;
  /** Most recent prior session loggedAt of the SAME pattern, null if first ever. */
  priorSessionLoggedAt: Date | null;
}

/**
 * Surfacing rule per ADR-0014 §"Digest exposure filter":
 *   sampleCount >= PRESCRIPTION_ACCURACY_DIGEST_MIN_SAMPLES (5)
 *   AND ( |bias| > PRESCRIPTION_ACCURACY_BIAS_SURFACE_THRESHOLD (0.05)
 *         OR rmse > PRESCRIPTION_ACCURACY_RMSE_SURFACE_THRESHOLD (0.10)
 *         OR (gap-bucket divergence...) ).
 */
export function shouldSurfaceInDigest(d: DigestableAccuracy): boolean {
  if (d.sampleCount < PRESCRIPTION_ACCURACY_DIGEST_MIN_SAMPLES) return false;
  if (Math.abs(d.bias) > PRESCRIPTION_ACCURACY_BIAS_SURFACE_THRESHOLD) {
    return true;
  }
  if (d.rmse > PRESCRIPTION_ACCURACY_RMSE_SURFACE_THRESHOLD) return true;

  // ADR-0010 stacking signal: divergence between short-gap (fatigued) and
  // long-gap (fresh) bias indicates the AI isn't accounting for inter-
  // session fatigue. Surfacing strict at > 0.05 per ADR-0014. Both
  // buckets must have sampleCount ≥ 3 to suppress the rule on noise from
  // sparsely-populated buckets.
  const bothBucketsMet =
    d.sampleCountByGapBucket.under48h >=
      PRESCRIPTION_ACCURACY_GAP_BUCKET_MIN_SAMPLES &&
    d.sampleCountByGapBucket.over72h >=
      PRESCRIPTION_ACCURACY_GAP_BUCKET_MIN_SAMPLES;
  if (bothBucketsMet) {
    const divergence = Math.abs(
      d.biasByGapBucket.under48h - d.biasByGapBucket.over72h,
    );
    if (divergence > PRESCRIPTION_ACCURACY_GAP_BUCKET_DIVERGENCE_THRESHOLD) {
      return true;
    }
  }
  return false;
}

/**
 * Gap-bucket assignment per ADR-0014 §"Gap-bucket stratification".
 * Boundaries align with ADR-0010 NM tau (30h):
 *   under48h:        NM readiness ~0.30–0.84 (still meaningfully fatigued)
 *   between48And72h: NM readiness ~0.84–0.94 (mostly recovered)
 *   over72h:         NM readiness ~0.94+   (fully fresh)
 */
const MS_PER_HOUR = 1000 * 60 * 60;

export function gapBucket(observation: SetObservation): InterSessionGapBucket {
  // ADR-0014 §Edge cases: first-ever pattern (no prior session) routes to
  // over72h. No stacking signal possible without a prior session — biased
  // to the long-gap bucket where stacking-divergence isn't computable.
  if (observation.priorSessionLoggedAt === null) return "over72h";

  const gapHours =
    (observation.loggedAt.getTime() -
      observation.priorSessionLoggedAt.getTime()) / MS_PER_HOUR;

  // Clock skew: negative gap (priorSessionLoggedAt in the future) clamps
  // to 0 → under48h per #80 locked semantic + asymmetric-error preference
  // (over-counts stacking on bad obs → loud, self-corrects in 30-obs
  // window; routing to over72h would silently mask actual fatigue
  // stacking). Explicit branch makes the clamp visible and gives a future
  // observability hook (clock_skew event) a place to land — ADR-0014
  // doesn't currently specify a channel; tracked as a v2.x watch-item.
  if (gapHours < 0) return "under48h";

  // Watertight partition (locked per ADR-0014 enum docstring):
  //   under48h        = gap <  48
  //   between48And72h = 48 ≤ gap ≤ 72   (inclusive both endpoints)
  //   over72h         = gap >  72       (strict)
  if (gapHours < GAP_BUCKET_BOUNDARY_LOW_HOURS) return "under48h";
  if (gapHours > GAP_BUCKET_BOUNDARY_HIGH_HOURS) return "over72h";
  return "between48And72h";
}

const ZERO_BUCKETS: Record<InterSessionGapBucket, number> = {
  under48h: 0,
  between48And72h: 0,
  over72h: 0,
};

/**
 * Rep-error per ADR-0014 §"Error metric": `(reps_completed - reps_prescribed)
 * / reps_prescribed`. Positive bias = user exceeded reps = AI under-
 * prescribed; negative = user fell short = AI over-prescribed.
 */
export function repError(observation: SetObservation): number {
  return (observation.repsCompleted - observation.prescribedReps) /
    observation.prescribedReps;
}

/**
 * Append a single observation's rep-error to the cell. Mutating-style.
 * Caller is responsible for `shouldContribute` filtering before calling.
 *
 * Sliding window: when the cell exceeds PRESCRIPTION_ACCURACY_WINDOW_SIZE
 * (30 per ADR-0014), the oldest observation is evicted from BOTH the
 * main array and its bucket sub-array (per the §"Sliding window" sync
 * requirement).
 */
export function appendObservation(
  cell: PerCellAccumulator,
  observation: SetObservation,
): void {
  const err = repError(observation);
  const bucket = gapBucket(observation);
  cell.observations.push(err);
  cell.observationBuckets.push(bucket);
  cell.observationsByGapBucket[bucket].push(err);

  while (cell.observations.length > PRESCRIPTION_ACCURACY_WINDOW_SIZE) {
    cell.observations.shift();
    const evictedBucket = cell.observationBuckets.shift()!;
    cell.observationsByGapBucket[evictedBucket].shift();
  }
}

const meanOf = (xs: number[]): number =>
  xs.length === 0 ? 0 : xs.reduce((a, b) => a + b, 0) / xs.length;

const rmseOf = (xs: number[]): number =>
  xs.length === 0 ? 0 : Math.sqrt(xs.reduce((a, b) => a + b * b, 0) / xs.length);

/**
 * Compute the digest-shaped output from a cell. Always returns; the
 * surfacing decision is separate (see shouldSurfaceInDigest).
 */
export function digestableAccuracy(
  cell: PerCellAccumulator,
): DigestableAccuracy {
  const buckets: InterSessionGapBucket[] = [
    "under48h",
    "between48And72h",
    "over72h",
  ];
  const biasByGapBucket = { ...ZERO_BUCKETS };
  const rmseByGapBucket = { ...ZERO_BUCKETS };
  const sampleCountByGapBucket = { ...ZERO_BUCKETS };
  for (const b of buckets) {
    const xs = cell.observationsByGapBucket[b];
    biasByGapBucket[b] = meanOf(xs);
    rmseByGapBucket[b] = rmseOf(xs);
    sampleCountByGapBucket[b] = xs.length;
  }
  return {
    pattern: cell.pattern,
    intent: cell.intent,
    bias: meanOf(cell.observations),
    rmse: rmseOf(cell.observations),
    sampleCount: cell.observations.length,
    biasByGapBucket,
    rmseByGapBucket,
    sampleCountByGapBucket,
  };
}

const WORKING_SET_INTENTS: ReadonlySet<string> = new Set([
  "top",
  "backoff",
  "amrap",
]);

/**
 * Per ADR-0014 §"Set-inclusion criteria — six required":
 *   1. intent match (loggedIntent === prescribedIntent)
 *   2. working set (intent in {top, backoff, amrap})
 *   3. completed (repsCompleted >= 1)
 *   4. not user-corrected weight
 *   5. no pain completion flag
 *   6. pattern not in .deload phase at prescription time
 */
export function shouldContribute(observation: SetObservation): boolean {
  // Criterion 1: intent match — deviated sets route to
  // prescriptionIntentMismatches log only, different signal.
  if (observation.loggedIntent !== observation.prescribedIntent) return false;

  // Criterion 2: working set only. Warmup / technique are structurally
  // undertargeted; including them would dilute the bias signal.
  if (!WORKING_SET_INTENTS.has(observation.prescribedIntent)) return false;

  // Criterion 3: completed (reps_completed >= 1). Abandoned sets carry
  // no rep-error signal — the degenerate -1.0 would dominate the bias.
  if (observation.repsCompleted < 1) return false;

  // Criterion 4: not user-corrected weight. User overrode the prescription
  // — the set isn't an observation of AI calibration any more.
  if (observation.userCorrectedWeight) return false;

  // Criterion 5: no pain completion flag. Pain-driven undershoots would
  // poison the bias estimate; pain is reactive-intervention territory,
  // surfacing through a different channel. Other flags (form_breakdown,
  // etc.) do NOT exclude — they're still calibration observations.
  if (observation.completionFlags.includes("pain")) return false;

  // Criterion 6: pattern not in .deload phase at prescription time. During
  // deload the AI is intentionally under-prescribing per ADR-0011's cyclic
  // phase model; accumulating deload sets would systematically positive-
  // bias the cell, mistranslating into "increase load" which is the wrong
  // intervention. Composes with ADR-0011 — every deload cycle pauses
  // accumulation; resumes when the pattern cycles back to accumulation.
  // Peaking is NOT excluded (its noise is documented but observations are
  // still informative — see ADR-0014 §"Peaking-phase caveat").
  if (observation.patternPhaseAtPrescription === "deload") return false;

  return true;
}
