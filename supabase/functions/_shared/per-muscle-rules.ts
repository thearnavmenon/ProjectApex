// Project Apex — per-muscle rule helpers (#156, MuscleProfile producer).
//
// Pure helpers consumed by `applyPerMuscleRules` in update-trainee-model/index.ts
// (the orchestrator coordinator). Per ADR-0005 §"Two-level muscle taxonomy"
// and ADR-0009 §"Aggregation to MuscleProfile.stagnationStatus".
//
// Q1 threshold-semantic lock (2026-05-13): MEV interpretation, per-7-events
// targets scaled at 4×/week alpha-cohort cadence. Bootstrap-only — EWMA-update
// of tolerance is deferred to a follow-up issue. Cadence-scaling per user's
// actual sessionsPerWeek is also deferred (alpha cohort ≈ 4×/week makes this
// adequate).

import {
  canonicalizeExerciseId,
  EXERCISE_PATTERN_MAP,
  EXERCISE_PRIMARY_MUSCLE_MAP,
  type MovementPattern,
  type PrimaryMuscle,
} from "./exercise-library.ts";
import type { ConfidenceWriteState } from "./confidence-lifecycle.ts";

/** ADR-0005 ProgressionTrend enum — must mirror Swift rawValues. */
export type ProgressionTrend = "progressing" | "plateaued" | "declining";

/** ADR-0005 AxisConfidence enum — must mirror Swift rawValues. */
export type AxisConfidence = "bootstrapping" | "calibrating" | "established";

/**
 * MuscleGroup — locked-six aggregation key for the trainee model's per-muscle
 * storage per ADR-0005 §"Two-level muscle taxonomy". Distinct from the finer
 * `PrimaryMuscle` (9-enum) which is the ExerciseLibrary's classification field.
 * Leg subgroups (quads/hamstrings/glutes/calves) collapse to "legs"; upper-
 * body muscles map 1:1.
 */
export type MuscleGroup =
  | "back"
  | "chest"
  | "biceps"
  | "shoulders"
  | "triceps"
  | "legs";

/**
 * Runtime set of the locked-six `MuscleGroup` values — single source of truth
 * mirroring the type above (the type alone is compile-time only). Used to
 * validate client-supplied muscle strings at trust boundaries so non-canonical
 * tokens (e.g. "posterior_deltoid") cannot leak into model state (#167).
 */
export const MUSCLE_GROUPS: ReadonlySet<MuscleGroup> = new Set<MuscleGroup>([
  "back",
  "chest",
  "biceps",
  "shoulders",
  "triceps",
  "legs",
]);

/**
 * Q1-locked per-muscle volume targets (MEV midpoints, per-7-events at
 * 4×/week cadence). volumeTolerance is bootstrapped from this table per
 * 2026-05-13 prep-prompt lock. Follow-up: EWMA-update of tolerance from
 * observed RPE/recovery signals; cadence-scaling for users away from
 * 4×/week.
 */
export const MUSCLE_VOLUME_TARGETS: Record<MuscleGroup, number> = {
  back: 21,
  chest: 18,
  shoulders: 18,
  biceps: 16,
  triceps: 12,
  legs: 18,
};

/**
 * Bootstrap shape of a `MuscleProfile` JSONB entry. Mirrors
 * `ProjectApex/Models/TraineeModelProfiles.swift::MuscleProfile`. Keys are
 * camelCase to match the Swift decoder's default CodingKeys (no rename).
 *
 * Per the #146 pattern: `muscleGroup` is emitted as a field so Swift's inner
 * decoder can read it (the dict key alone is invisible to `decodeEnumKeyedDict`).
 */
export interface BootstrapMuscleProfile {
  muscleGroup: MuscleGroup;
  volumeTolerance: number;
  observedSweetSpot: number | null;
  volumeDeficit: number;
  focusWeight: number;
  stagnationStatus: "progressing" | "plateaued" | "declining";
  confidence: "bootstrapping" | "calibrating" | "established";
}

/**
 * Create a fresh `MuscleProfile` with ADR-0005 defaults + 2026-05-13-locked
 * decision values:
 * - Q1: `volumeTolerance` from MEV midpoint table.
 * - Q3: `observedSweetSpot` null (EF emits null, Swift decodes to nil).
 * - Q4: `focusWeight` defaults to 0; coordinator overrides post-bootstrap
 *   when the muscle is in `goal.focusAreas`.
 * - Q5: `confidence` = .bootstrapping; lifecycle transitions deferred.
 * - ADR-0009 empty-participation default: `stagnationStatus` = .progressing.
 *
 * `volumeDeficit` defaults to 0; the orchestrator runs the volume-aggregation
 * + deficit-computation rules immediately after bootstrap, which overwrite it.
 */
export function bootstrapMuscleProfile(
  muscleGroup: MuscleGroup,
): BootstrapMuscleProfile {
  return {
    muscleGroup,
    volumeTolerance: MUSCLE_VOLUME_TARGETS[muscleGroup],
    observedSweetSpot: null,
    volumeDeficit: 0,
    focusWeight: 0,
    stagnationStatus: "progressing",
    confidence: "bootstrapping",
  };
}

/**
 * Per ADR-0005 §"Two-level muscle taxonomy": leg subgroups (quads,
 * hamstrings, glutes, calves) collapse to MuscleGroup.legs; upper-body
 * muscles map 1:1.
 */
export function primaryMuscleToGroup(pm: PrimaryMuscle): MuscleGroup {
  switch (pm) {
    case "back":
    case "chest":
    case "biceps":
    case "shoulders":
    case "triceps":
      return pm;
    case "quads":
    case "hamstrings":
    case "glutes":
    case "calves":
      return "legs";
  }
}

/**
 * SetIntent values that contribute to volume aggregation per ADR-0005's set-
 * intent semantics: warmup and technique are zero-weighted (warmup builds to
 * top-set load without contributing to hypertrophy volume; technique sets are
 * low-load skill rehearsal). Top + backoff + amrap contribute fully.
 */
const VOLUME_CONTRIBUTING_INTENTS: ReadonlySet<string> = new Set([
  "top",
  "backoff",
  "amrap",
]);

/**
 * One bucket of per-muscle session volume — appended on each apply that
 * trains the muscle. Bounded externally to the last 7 entries per ADR-0002's
 * queue-event-windowed semantic. Mirrors `weeklyVolumeLoadHistory` on
 * PatternProfile JSONB (an EF-only field; Swift's MuscleProfile decoder
 * does not consume it, so the locked Swift shape is preserved).
 */
export interface WeeklyVolumeBucket {
  loggedAtIso: string;
  sets: number;
}

/**
 * The maximum number of session buckets retained per muscle. Per ADR-0002:
 * "VolumeValidationService (and its successor in the trainee model) windows
 * over last 7 training events, not calendar weeks."
 */
export const MUSCLE_VOLUME_WINDOW = 7;

/**
 * `volumeDeficit = max(0, volumeTolerance − Σ sets in last `MUSCLE_VOLUME_WINDOW`
 * buckets)`. Per Q1 lock (2026-05-13, MEV interpretation): a positive deficit
 * means the user is below the growth threshold for this muscle; B2 (#87)
 * consumes the digest-projected value to drive volume-correction coaching.
 *
 * Cold-start (empty history) surfaces the full tolerance. Downstream
 * consumers temper via `MuscleProfile.confidence` (Q5 lock: all #156
 * profiles ship at .bootstrapping; lifecycle is a follow-up).
 */
export function computeVolumeDeficit(
  history: WeeklyVolumeBucket[],
  volumeTolerance: number,
): number {
  const recent = history.slice(-MUSCLE_VOLUME_WINDOW);
  const sum = recent.reduce((acc, bucket) => acc + bucket.sets, 0);
  return Math.max(0, volumeTolerance - sum);
}

/**
 * Per-set volume aggregation. Returns a partial Record keyed by
 * `MuscleGroup` with each muscle's count of volume-contributing sets from
 * `setLogs`. Attribution flows `exercise_id → PrimaryMuscle → MuscleGroup` via
 * `EXERCISE_PRIMARY_MUSCLE_MAP` after canonicalising legacy aliases.
 *
 * Sets that fail to attribute (unknown exercise IDs, missing intent) are
 * silently dropped per the asymmetric-error preference (under-attribute is
 * silent; over-attribute would falsely inflate volume signals and trigger
 * spurious AI volume-correction prompts).
 */
export function aggregateMuscleSetCounts(
  setLogs: Array<Record<string, unknown>>,
): Partial<Record<MuscleGroup, number>> {
  const counts: Partial<Record<MuscleGroup, number>> = {};
  for (const entry of setLogs) {
    const exerciseId = entry.exercise_id;
    const intent = entry.intent;
    if (typeof exerciseId !== "string" || typeof intent !== "string") continue;
    if (!VOLUME_CONTRIBUTING_INTENTS.has(intent)) continue;
    const primary = EXERCISE_PRIMARY_MUSCLE_MAP[canonicalizeExerciseId(exerciseId)];
    if (primary === undefined) continue;
    const group = primaryMuscleToGroup(primary);
    counts[group] = (counts[group] ?? 0) + 1;
  }
  return counts;
}

/**
 * Static derivation of which MovementPatterns participate in each
 * MuscleGroup's stagnation aggregation, per ADR-0009 §"Aggregation to
 * MuscleProfile.stagnationStatus": `∃ exercise e such that
 * primaryMuscle(e).muscleGroup == M ∧ e.movementPattern == P`. Derived from
 * the two exercise maps at module load.
 */
const MUSCLE_PARTICIPATING_PATTERNS: Record<MuscleGroup, Set<MovementPattern>> =
  (() => {
    const result: Record<MuscleGroup, Set<MovementPattern>> = {
      back: new Set(),
      chest: new Set(),
      biceps: new Set(),
      shoulders: new Set(),
      triceps: new Set(),
      legs: new Set(),
    };
    for (const exerciseId of Object.keys(EXERCISE_PATTERN_MAP)) {
      const pattern = EXERCISE_PATTERN_MAP[exerciseId];
      const primary = EXERCISE_PRIMARY_MUSCLE_MAP[exerciseId];
      if (primary === undefined) continue;
      const group = primaryMuscleToGroup(primary);
      result[group].add(pattern);
    }
    return result;
  })();

/**
 * Aggregate `MuscleProfile.stagnationStatus` from per-pattern trends per
 * ADR-0009 §"Aggregation to MuscleProfile.stagnationStatus" (amended
 * 2026-05-07). Worst-across-patterns precedence `declining > plateaued >
 * progressing`. Patterns at `.bootstrapping` confidence are excluded from
 * participation (their trends aren't evaluable). Empty effective
 * participation returns `.progressing` — the no-signal default; cold-start
 * is carried separately by `MuscleProfile.confidence`.
 */
/**
 * Per Q4 lock (2026-05-13): binary `focusWeight` derived from
 * `GoalState.focusAreas` enum-membership. Returns 1.0 when the muscle is
 * in the user's focus areas, 0.0 otherwise. Continuous-weight follow-up is
 * scoped post-#156.
 */
export function computeFocusWeight(
  muscleGroup: MuscleGroup,
  focusAreas: readonly string[],
): number {
  return focusAreas.includes(muscleGroup) ? 1.0 : 0.0;
}

export function aggregateStagnationStatus(
  muscleGroup: MuscleGroup,
  patternProfiles: Record<
    string,
    { trend: ProgressionTrend; confidence: AxisConfidence }
  >,
): ProgressionTrend {
  const participating = MUSCLE_PARTICIPATING_PATTERNS[muscleGroup];
  let sawPlateau = false;
  for (const pattern of participating) {
    const profile = patternProfiles[pattern];
    if (profile === undefined) continue;
    if (profile.confidence === "bootstrapping") continue;
    if (profile.trend === "declining") return "declining"; // short-circuit; worst case
    if (profile.trend === "plateaued") sawPlateau = true;
  }
  return sawPlateau ? "plateaued" : "progressing";
}

/**
 * Propose a muscle's confidence by AGGREGATING from its participating
 * movement patterns' confidence (ADR-0020 §"Per-axis gate table"; #286).
 * Reuses the same `MUSCLE_PARTICIPATING_PATTERNS` walk as
 * `aggregateStagnationStatus`, and the same convention of skipping patterns
 * with no profile (never trained). Muscle confidence is parasitic on its
 * patterns and never exceeds the evidence beneath it.
 *
 * - `.established` when at least `ceil(2/3)` of the muscle's participating
 *   patterns that have a profile are `.established`. The 2/3 supermajority
 *   mirrors the calibration-review ≥4/6 (=2/3) major-pattern bar; `ceil`
 *   keeps small participating sets under-claiming.
 * - `.calibrating` when ≥1 participating pattern has left `.bootstrapping`.
 * - `.bootstrapping` otherwise — including the empty-effective-set case
 *   (no participating pattern has a profile yet), which is guarded
 *   explicitly to avoid the `ceil(0) >= 0` vacuous-truth trap.
 *
 * Counts the FULL participating set (incl. isolation / accessory patterns),
 * NOT just the 6 major patterns — muscles like biceps participate in zero
 * major patterns, so a major-only rule would make them un-establishable.
 *
 * Returns the PROPOSED state (pre-clamp); the caller applies `monotonicAdvance`.
 */
export function proposeMuscleConfidence(
  muscleGroup: MuscleGroup,
  patternProfiles: Record<string, { confidence: AxisConfidence }>,
): ConfidenceWriteState {
  const participating = MUSCLE_PARTICIPATING_PATTERNS[muscleGroup];
  let withProfile = 0;
  let established = 0;
  let pastBootstrap = 0;
  for (const pattern of participating) {
    const profile = patternProfiles[pattern];
    if (profile === undefined) continue; // never trained → not in the effective set
    withProfile++;
    if (profile.confidence === "established") established++;
    if (profile.confidence !== "bootstrapping") pastBootstrap++;
  }
  if (withProfile === 0) return "bootstrapping"; // empty-effective-set guard
  if (established >= Math.ceil(withProfile * (2 / 3))) return "established";
  if (pastBootstrap >= 1) return "calibrating";
  return "bootstrapping";
}
