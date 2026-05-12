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
 * Resolve a movement pattern for an exercise ID. Returns `undefined` for
 * unknown IDs (e.g. legacy or non-canonical entries) so callers can decide
 * how to handle (skip, log, fall back). The orchestrator's pattern bootstrap
 * skips unknown IDs — they don't trigger a profile creation, matching
 * the asymmetric-error preference (under-bootstrap is silent;
 * over-bootstrap creates phantom patterns).
 */
export function lookupPattern(exerciseId: string): MovementPattern | undefined {
  return EXERCISE_PATTERN_MAP[exerciseId];
}
