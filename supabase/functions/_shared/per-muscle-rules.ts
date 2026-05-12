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
  EXERCISE_PRIMARY_MUSCLE_MAP,
  type PrimaryMuscle,
} from "./exercise-library.ts";

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
