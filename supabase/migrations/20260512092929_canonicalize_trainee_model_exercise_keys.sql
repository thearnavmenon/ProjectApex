-- Reverse migration: docs/migrations/down/20260512092929_canonicalize_trainee_model_exercise_keys.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- Canonicalise legacy-aliased exercise_id keys in trainee_models.model_json.exercises.
--
-- The Edge Function previously bootstrapped `model_json.exercises` keyed by
-- whatever `set_logs.exercise_id` strings flowed in — including legacy aliases
-- like `lat_pulldown_wide_grip` (canonical: `lat_pulldown_wide`) and
-- `dumbbell_flat_press` (canonical: `dumbbell_bench_press`). When iOS later
-- logs the same exercise under its canonical ID, a second profile is created
-- and the AI sees two unrelated entries instead of one consolidated history.
--
-- Companion to the EF-side fix in `_shared/exercise-library.ts` (this PR):
-- `canonicalizeExerciseId()` is now called at the input boundary, so future
-- session-applies will not re-introduce legacy keys. This migration repairs
-- existing rows so the alpha user's training history surfaces under canonical
-- keys today rather than waiting for organic recoalescence.
--
-- Per-pair behaviour:
--   - Rename-only (legacy exists, canonical does NOT): move the value, rewriting
--     its inner `exerciseId` field to match the new key.
--   - Merge (both exist): combine via `pg_temp.merge_exercise_profiles`, then
--     drop the legacy key. Asymmetric defaults — sum sessionCount, concat
--     topSets/sessionSnapshots, max e1rmPeak, OR formDegradationFlag, take
--     e1rmCurrent/e1rmMedian from the entry with higher sessionCount, take
--     max confidence on the ordered enum.
--
-- Idempotent: re-running is a no-op once all keys are canonical.

-- ─── Helpers (pg_temp, dropped at session end) ────────────────────────────

CREATE OR REPLACE FUNCTION pg_temp.confidence_idx(c text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    array_position(ARRAY['bootstrapping','calibrating','established','seasoned'], c),
    1  -- default to bootstrapping (lowest)
  )
$$;

CREATE OR REPLACE FUNCTION pg_temp.merge_exercise_profiles(legacy jsonb, canonical jsonb, canonical_id text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'exerciseId',                       canonical_id,
    'topSets',                          COALESCE(legacy->'topSets','[]'::jsonb) || COALESCE(canonical->'topSets','[]'::jsonb),
    'sessionSnapshots',                 COALESCE(legacy->'sessionSnapshots','[]'::jsonb) || COALESCE(canonical->'sessionSnapshots','[]'::jsonb),
    'sessionCount',                     COALESCE((legacy->>'sessionCount')::int, 0) + COALESCE((canonical->>'sessionCount')::int, 0),
    'e1rmCurrent',                      CASE
                                          WHEN COALESCE((legacy->>'sessionCount')::int, 0) >= COALESCE((canonical->>'sessionCount')::int, 0)
                                          THEN COALESCE(legacy->'e1rmCurrent', canonical->'e1rmCurrent')
                                          ELSE COALESCE(canonical->'e1rmCurrent', legacy->'e1rmCurrent')
                                        END,
    'e1rmMedian',                       CASE
                                          WHEN COALESCE((legacy->>'sessionCount')::int, 0) >= COALESCE((canonical->>'sessionCount')::int, 0)
                                          THEN COALESCE(legacy->'e1rmMedian', canonical->'e1rmMedian')
                                          ELSE COALESCE(canonical->'e1rmMedian', legacy->'e1rmMedian')
                                        END,
    'e1rmPeak',                         to_jsonb(GREATEST(
                                          COALESCE((legacy->>'e1rmPeak')::float, 0),
                                          COALESCE((canonical->>'e1rmPeak')::float, 0)
                                        )),
    'formDegradationFlag',              to_jsonb(
                                          COALESCE((legacy->>'formDegradationFlag')::boolean, false)
                                          OR COALESCE((canonical->>'formDegradationFlag')::boolean, false)
                                        ),
    'formDegradationCleanSessions',     to_jsonb(GREATEST(
                                          COALESCE((legacy->>'formDegradationCleanSessions')::int, 0),
                                          COALESCE((canonical->>'formDegradationCleanSessions')::int, 0)
                                        )),
    'confidence',                       to_jsonb(
                                          (ARRAY['bootstrapping','calibrating','established','seasoned'])[
                                            GREATEST(
                                              pg_temp.confidence_idx(legacy->>'confidence'),
                                              pg_temp.confidence_idx(canonical->>'confidence')
                                            )
                                          ]
                                        )
  )
$$;

-- ─── Per-pair canonicalisation ────────────────────────────────────────────
--
-- Alias map mirrors `_shared/exercise-library.ts:EXERCISE_NORMALIZATION_MAP`.
-- Each pair fires two UPDATE statements: one for the rename-only case,
-- one for the merge case. Each is idempotent (WHERE-clauses gate on
-- whether the legacy key still exists).

DO $migration$
DECLARE
  alias_map jsonb := '{
    "bench_press": "barbell_bench_press",
    "flat_bench_press": "barbell_bench_press",
    "bb_bench_press": "barbell_bench_press",
    "db_bench_press": "dumbbell_bench_press",
    "incline_press": "incline_dumbbell_press",
    "incline_db_press": "incline_dumbbell_press",
    "bent_over_row": "barbell_row",
    "bent_over_barbell_row": "barbell_row",
    "bb_row": "barbell_row",
    "barbell_bent_over_row": "barbell_row",
    "db_row": "dumbbell_row",
    "one_arm_dumbbell_row": "dumbbell_row",
    "lat_pull_down": "lat_pulldown_wide",
    "lat_pulldown_overhand": "lat_pulldown_wide",
    "pull_up": "pull_ups",
    "pullup": "pull_ups",
    "pull-up": "pull_ups",
    "chin_up": "chin_ups",
    "chinup": "chin_ups",
    "back_squat": "barbell_back_squat",
    "squat": "barbell_back_squat",
    "barbell_squat": "barbell_back_squat",
    "low_bar_squat": "barbell_back_squat",
    "deadlift": "conventional_deadlift",
    "barbell_deadlift": "conventional_deadlift",
    "rdl": "romanian_deadlift",
    "barbell_rdl": "romanian_deadlift",
    "barbell_romanian_deadlift": "romanian_deadlift",
    "stiff_legged_deadlift": "stiff_leg_deadlift",
    "sldl": "stiff_leg_deadlift",
    "ohp": "overhead_press",
    "barbell_ohp": "overhead_press",
    "barbell_overhead_press": "overhead_press",
    "military_press": "overhead_press",
    "db_shoulder_press": "dumbbell_shoulder_press",
    "seated_dumbbell_press": "dumbbell_shoulder_press",
    "bicep_curl": "dumbbell_curl",
    "biceps_curl": "dumbbell_curl",
    "db_curl": "dumbbell_curl",
    "barbell_bicep_curl": "barbell_curl",
    "ez_curl": "ez_bar_curl",
    "tricep_pushdown": "cable_tricep_pushdown",
    "triceps_pushdown": "cable_tricep_pushdown",
    "rope_pushdown": "cable_tricep_pushdown",
    "overhead_extension": "overhead_tricep_extension",
    "db_overhead_extension": "overhead_tricep_extension",
    "lying_tricep_extension": "skull_crushers",
    "cable_pulldown_neutral_grip": "lat_pulldown_close",
    "lat_pulldown_wide_grip": "lat_pulldown_wide",
    "dumbbell_flat_press": "dumbbell_bench_press",
    "dumbbell_incline_press": "incline_dumbbell_press",
    "dumbbell_bicep_curl": "dumbbell_curl",
    "dumbbell_lateral_raise": "lateral_raise",
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
    "rear_delt_raise": "rear_delt_fly"
  }'::jsonb;
  pair RECORD;
BEGIN
  FOR pair IN SELECT key AS legacy, value AS canonical FROM jsonb_each_text(alias_map) LOOP

    -- Case 1: rename-only. Legacy key exists, canonical doesn't.
    -- Move the value over and rewrite its inner exerciseId.
    UPDATE public.trainee_models
    SET model_json = jsonb_set(
      model_json,
      '{exercises}',
      ((model_json->'exercises') - pair.legacy)
        || jsonb_build_object(
          pair.canonical,
          jsonb_set(
            model_json->'exercises'->pair.legacy,
            '{exerciseId}',
            to_jsonb(pair.canonical)
          )
        )
    )
    WHERE model_json ? 'exercises'
      AND jsonb_typeof(model_json->'exercises') = 'object'
      AND model_json->'exercises' ? pair.legacy
      AND NOT (model_json->'exercises' ? pair.canonical);

    -- Case 2: merge. Both keys exist — field-merge legacy into canonical,
    -- then drop legacy.
    UPDATE public.trainee_models
    SET model_json = jsonb_set(
      model_json,
      '{exercises}',
      ((model_json->'exercises') - pair.legacy)
        || jsonb_build_object(
          pair.canonical,
          pg_temp.merge_exercise_profiles(
            model_json->'exercises'->pair.legacy,
            model_json->'exercises'->pair.canonical,
            pair.canonical
          )
        )
    )
    WHERE model_json ? 'exercises'
      AND jsonb_typeof(model_json->'exercises') = 'object'
      AND model_json->'exercises' ? pair.legacy
      AND model_json->'exercises' ? pair.canonical;

  END LOOP;
END
$migration$;
