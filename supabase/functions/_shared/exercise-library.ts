// Project Apex — Edge Function exercise→pattern library.
//
// MINIMUM-VIABLE PORT of `ProjectApex/Models/ExerciseLibrary.swift`. Only the
// subset the orchestrator needs — `(exercise_id → MovementPattern)` — is
// mirrored here. The full Swift library carries name + primaryMuscle +
// synergists + equipmentType + bodyweightOnly per entry; none of those are
// needed server-side for pattern profile bootstrap (#110 / A15).
//
// Why a port rather than a schema column:
//   - `set_logs` has no `pattern` column; production rows can't carry it
//     until a forward-only schema migration ships AND historical rows are
//     backfilled. The G1 single-user historical-replay context (#85)
//     specifically needs server-side derivation against rows already in
//     the dump.
//   - Hybrid (schema column + library fallback) stays as a future option
//     once the schema migration ships; nothing about this port precludes
//     it. See #110's design-call discussion.
//
// Drift policy: the canonical truth is the Swift library. New exercises
// are added in Swift first, then mirrored here. The drift test in
// exercise-library_test.ts asserts the entry count matches a hand-pinned
// constant; bumping the count without updating both fails the test loudly.

/**
 * Movement pattern enum — mirrors `ProjectApex/Models/MovementPattern.swift`.
 * 8 values per ADR-0005's pattern taxonomy.
 */
export type MovementPattern =
  | "horizontal_push"
  | "vertical_push"
  | "horizontal_pull"
  | "vertical_pull"
  | "squat"
  | "hip_hinge"
  | "lunge"
  | "isolation";

/**
 * Map from `exercise_id` (snake_case canonical IDs from `set_logs.exercise_id`)
 * to `MovementPattern`. Pinned at 71 entries as of 2026-05-10. Bumping this
 * map MUST also bump `EXERCISE_LIBRARY_ENTRY_COUNT` and the corresponding
 * Swift library entries.
 */
export const EXERCISE_PATTERN_MAP: Record<string, MovementPattern> = {
  // Chest
  barbell_bench_press: "horizontal_push",
  dumbbell_bench_press: "horizontal_push",
  incline_barbell_press: "horizontal_push",
  incline_dumbbell_press: "horizontal_push",
  decline_bench_press: "horizontal_push",
  machine_chest_press: "horizontal_push",
  cable_chest_fly: "isolation",
  pec_deck_fly: "isolation",
  dumbbell_fly: "isolation",
  push_ups: "horizontal_push",

  // Back
  barbell_row: "horizontal_pull",
  dumbbell_row: "horizontal_pull",
  t_bar_row: "horizontal_pull",
  cable_row: "horizontal_pull",
  seated_cable_row: "horizontal_pull",
  lat_pulldown_wide: "vertical_pull",
  lat_pulldown_close: "vertical_pull",
  pull_ups: "vertical_pull",
  chin_ups: "vertical_pull",
  face_pull: "horizontal_pull",
  cable_rear_delt_fly: "isolation",
  cable_straight_arm_pulldown: "vertical_pull",
  dumbbell_single_arm_row: "horizontal_pull",
  assisted_pull_up: "vertical_pull",

  // Shoulders
  overhead_press: "vertical_push",
  dumbbell_shoulder_press: "vertical_push",
  machine_shoulder_press: "vertical_push",
  lateral_raise: "isolation",
  cable_lateral_raise: "isolation",
  rear_delt_fly: "isolation",
  arnold_press: "vertical_push",
  upright_row: "vertical_pull",

  // Quads
  barbell_back_squat: "squat",
  front_squat: "squat",
  leg_press: "squat",
  hack_squat_machine: "squat",
  goblet_squat: "squat",
  leg_extension: "isolation",
  bulgarian_split_squat: "lunge",
  walking_lunge: "lunge",
  smith_machine_squat: "squat",

  // Hamstrings / Glutes / Hips
  conventional_deadlift: "hip_hinge",
  romanian_deadlift: "hip_hinge",
  dumbbell_romanian_deadlift: "hip_hinge",
  lying_leg_curl: "isolation",
  seated_leg_curl: "isolation",
  stiff_leg_deadlift: "hip_hinge",
  hip_thrust: "hip_hinge",
  cable_pull_through: "hip_hinge",
  glute_bridge: "hip_hinge",
  sumo_deadlift: "hip_hinge",

  // Biceps
  barbell_curl: "isolation",
  ez_bar_curl: "isolation",
  dumbbell_curl: "isolation",
  preacher_curl: "isolation",
  hammer_curl: "isolation",
  cable_curl: "isolation",
  cable_hammer_curl: "isolation",

  // Triceps
  cable_tricep_pushdown: "isolation",
  overhead_tricep_extension: "isolation",
  skull_crushers: "isolation",
  dips: "vertical_push",
  close_grip_bench_press: "horizontal_push",
  dumbbell_overhead_tricep_extension: "isolation",
  cable_overhead_tricep_extension: "isolation",

  // Smith / cable variants for chest
  smith_machine_bench_press: "horizontal_push",
  smith_machine_incline_press: "horizontal_push",
  cable_crossover_chest_fly: "isolation",

  // Calves
  standing_calf_raise: "isolation",
  seated_calf_raise: "isolation",
  smith_machine_calf_raise: "isolation",
};

/**
 * Pinned entry count — drift detector for the Swift mirror.
 * Bumping the map size MUST bump this constant (and add a new Swift entry).
 */
export const EXERCISE_LIBRARY_ENTRY_COUNT = 71;

/**
 * Maps legacy / variant exercise_id strings to their canonical equivalents.
 * Mirror of `ExerciseLibrary.normalizationMap` in
 * `ProjectApex/Models/ExerciseLibrary.swift`. Keep in sync — any addition
 * in Swift must be ported here, and the drift test below enforces the entry
 * count.
 *
 * Resolution rules:
 *   - Keys here must NOT be canonical IDs (i.e. must NOT appear as keys in
 *     EXERCISE_PATTERN_MAP). The unit test below enforces this.
 *   - Values must all be canonical IDs (must appear in EXERCISE_PATTERN_MAP).
 *
 * Used at the EF input boundary in `update-trainee-model/index.ts` so
 * `model_json.exercises` is keyed by canonical IDs regardless of what
 * historical or in-flight `set_logs.exercise_id` strings the iOS / LLM
 * stack produces (preventing the drift surfaced post-B1).
 */
export const EXERCISE_NORMALIZATION_MAP: Record<string, string> = {
  // Bench press variants
  "bench_press": "barbell_bench_press",
  "flat_bench_press": "barbell_bench_press",
  "bb_bench_press": "barbell_bench_press",
  "db_bench_press": "dumbbell_bench_press",
  "incline_press": "incline_dumbbell_press",
  "incline_db_press": "incline_dumbbell_press",

  // Row variants
  "bent_over_row": "barbell_row",
  "bent_over_barbell_row": "barbell_row",
  "bb_row": "barbell_row",
  "barbell_bent_over_row": "barbell_row",
  "db_row": "dumbbell_row",
  "one_arm_dumbbell_row": "dumbbell_row",

  // Lat pulldown variants — only mapping clearly unambiguous spellings.
  // "lat_pulldown" (no suffix) is intentionally NOT mapped because it's
  // ambiguous between lat_pulldown_wide and lat_pulldown_close.
  "lat_pull_down": "lat_pulldown_wide",
  "lat_pulldown_overhand": "lat_pulldown_wide",

  // Pull-up / chin-up variants
  "pull_up": "pull_ups",
  "pullup": "pull_ups",
  "pull-up": "pull_ups",
  "chin_up": "chin_ups",
  "chinup": "chin_ups",

  // Squat variants
  "back_squat": "barbell_back_squat",
  "squat": "barbell_back_squat",
  "barbell_squat": "barbell_back_squat",
  "low_bar_squat": "barbell_back_squat",

  // Deadlift variants
  "deadlift": "conventional_deadlift",
  "barbell_deadlift": "conventional_deadlift",
  "rdl": "romanian_deadlift",
  "barbell_rdl": "romanian_deadlift",
  "barbell_romanian_deadlift": "romanian_deadlift",
  "stiff_legged_deadlift": "stiff_leg_deadlift",
  "sldl": "stiff_leg_deadlift",

  // OHP variants
  "ohp": "overhead_press",
  "barbell_ohp": "overhead_press",
  "barbell_overhead_press": "overhead_press",
  "military_press": "overhead_press",
  "db_shoulder_press": "dumbbell_shoulder_press",
  "seated_dumbbell_press": "dumbbell_shoulder_press",

  // Curl variants
  "bicep_curl": "dumbbell_curl",
  "biceps_curl": "dumbbell_curl",
  "db_curl": "dumbbell_curl",
  "barbell_bicep_curl": "barbell_curl",
  "ez_curl": "ez_bar_curl",

  // Tricep variants
  "tricep_pushdown": "cable_tricep_pushdown",
  "triceps_pushdown": "cable_tricep_pushdown",
  "rope_pushdown": "cable_tricep_pushdown",
  "overhead_extension": "overhead_tricep_extension",
  "db_overhead_extension": "overhead_tricep_extension",
  "lying_tricep_extension": "skull_crushers",

  // Lat pulldown — grip-specific variants seen in live data
  "cable_pulldown_neutral_grip": "lat_pulldown_close",
  "lat_pulldown_wide_grip": "lat_pulldown_wide",

  // Dumbbell press variants seen in live data
  "dumbbell_flat_press": "dumbbell_bench_press",
  "dumbbell_incline_press": "incline_dumbbell_press",

  // Curl/raise variants seen in live data
  "dumbbell_bicep_curl": "dumbbell_curl",
  "dumbbell_lateral_raise": "lateral_raise",

  // Misc
  "split_squat": "bulgarian_split_squat",
  "lunge": "walking_lunge",
  "leg_curl": "lying_leg_curl",
  "hamstring_curl": "lying_leg_curl",
  "calf_raise": "standing_calf_raise",
  "barbell_hip_thrust": "hip_thrust",
  "glute_hip_thrust": "hip_thrust",
  "lateral_raises": "lateral_raise",
  "side_lateral_raise": "lateral_raise",
  "reverse_fly": "rear_delt_fly",
  "rear_delt_raise": "rear_delt_fly",
};

/**
 * Pinned entry count — drift detector for the Swift normalizationMap mirror.
 */
export const EXERCISE_NORMALIZATION_ENTRY_COUNT = 64;

/**
 * Returns the canonical exercise_id for `exerciseId`.
 *
 * Resolution order:
 *   1. If `exerciseId` is already a canonical ID (present in EXERCISE_PATTERN_MAP),
 *      return it unchanged.
 *   2. If `exerciseId` is a known legacy alias, return its canonical mapping.
 *   3. Otherwise return `exerciseId` unchanged — callers handle unknown IDs
 *      (typically skip with no profile bootstrap; see lookupPattern's
 *      asymmetric-error preference for under-bootstrap).
 *
 * Mirror of `ExerciseLibrary.lookup(_:)`'s canonical-resolution behavior in
 * Swift — but returns the canonical ID string, not an ExerciseDefinition,
 * so the EF can use it as a key in `model_json.exercises`.
 */
export function canonicalizeExerciseId(exerciseId: string): string {
  if (exerciseId in EXERCISE_PATTERN_MAP) return exerciseId;
  if (exerciseId in EXERCISE_NORMALIZATION_MAP) {
    return EXERCISE_NORMALIZATION_MAP[exerciseId];
  }
  return exerciseId;
}

/**
 * Resolve a movement pattern for an exercise ID. Canonicalises legacy
 * aliases before lookup, so a row logged as `lat_pulldown_wide_grip` resolves
 * the same pattern as the canonical `lat_pulldown_wide`. Returns `undefined`
 * for unknown IDs (e.g. genuinely unfamiliar entries) so callers can decide
 * how to handle (skip, log, fall back). The orchestrator's pattern bootstrap
 * skips unknown IDs — they don't trigger a profile creation, matching
 * the asymmetric-error preference (under-bootstrap is silent;
 * over-bootstrap creates phantom patterns).
 */
export function lookupPattern(exerciseId: string): MovementPattern | undefined {
  return EXERCISE_PATTERN_MAP[canonicalizeExerciseId(exerciseId)];
}
