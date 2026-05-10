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
  | "horizontalPush"
  | "verticalPush"
  | "horizontalPull"
  | "verticalPull"
  | "squat"
  | "hipHinge"
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
  barbell_bench_press: "horizontalPush",
  dumbbell_bench_press: "horizontalPush",
  incline_barbell_press: "horizontalPush",
  incline_dumbbell_press: "horizontalPush",
  decline_bench_press: "horizontalPush",
  machine_chest_press: "horizontalPush",
  cable_chest_fly: "isolation",
  pec_deck_fly: "isolation",
  dumbbell_fly: "isolation",
  push_ups: "horizontalPush",

  // Back
  barbell_row: "horizontalPull",
  dumbbell_row: "horizontalPull",
  t_bar_row: "horizontalPull",
  cable_row: "horizontalPull",
  seated_cable_row: "horizontalPull",
  lat_pulldown_wide: "verticalPull",
  lat_pulldown_close: "verticalPull",
  pull_ups: "verticalPull",
  chin_ups: "verticalPull",
  face_pull: "horizontalPull",
  cable_rear_delt_fly: "isolation",
  cable_straight_arm_pulldown: "verticalPull",
  dumbbell_single_arm_row: "horizontalPull",
  assisted_pull_up: "verticalPull",

  // Shoulders
  overhead_press: "verticalPush",
  dumbbell_shoulder_press: "verticalPush",
  machine_shoulder_press: "verticalPush",
  lateral_raise: "isolation",
  cable_lateral_raise: "isolation",
  rear_delt_fly: "isolation",
  arnold_press: "verticalPush",
  upright_row: "verticalPull",

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
  conventional_deadlift: "hipHinge",
  romanian_deadlift: "hipHinge",
  dumbbell_romanian_deadlift: "hipHinge",
  lying_leg_curl: "isolation",
  seated_leg_curl: "isolation",
  stiff_leg_deadlift: "hipHinge",
  hip_thrust: "hipHinge",
  cable_pull_through: "hipHinge",
  glute_bridge: "hipHinge",
  sumo_deadlift: "hipHinge",

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
  dips: "verticalPush",
  close_grip_bench_press: "horizontalPush",
  dumbbell_overhead_tricep_extension: "isolation",
  cable_overhead_tricep_extension: "isolation",

  // Smith / cable variants for chest
  smith_machine_bench_press: "horizontalPush",
  smith_machine_incline_press: "horizontalPush",
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
