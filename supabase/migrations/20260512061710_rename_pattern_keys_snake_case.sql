-- Reverse migration: docs/migrations/down/20260512061710_rename_pattern_keys_snake_case.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- #148: rename camelCase MovementPattern keys to snake_case across all
-- pattern-keyed locations in trainee_models.model_json.
--
-- The Edge Function previously emitted camelCase pattern keys
-- (horizontalPush, horizontalPull, hipHinge, verticalPush, verticalPull)
-- via _shared/exercise-library.ts's MovementPattern type. Swift's
-- MovementPattern.rawValue uses snake_case (horizontal_push, etc.) per
-- the cross-platform fixture contract locked by ADR-0006. decodeEnumKeyedDict
-- silently skipped mismatched keys → 5 of 8 patterns dropped on iOS
-- decode. EF code in this same PR migrates to snake_case; this migration
-- renames the keys in existing alpha JSONB rows.
--
-- Pattern-keyed locations migrated:
--   1. model_json.patterns                       (outer dict keys)
--   2. model_json.patterns.<k>.pattern           (per-PatternProfile field added in #146)
--   3. model_json.prescriptionAccuracy           (outer dict keys per ADR-0014)
--   4. model_json.fatigueInteractions[*].fromPattern (string value)
--   5. model_json.fatigueInteractions[*].toPattern   (string value)
--   6. model_json.lastSessionPatternPerformance[*].pattern (string value)
--   7. model_json.activeLimitations[*].subject.value when subject.kind='pattern'
--   8. model_json.clearedLimitations[*].subject.value when subject.kind='pattern'
--
-- Each location is migrated independently with an idempotent transformation
-- (no-op when source key/value isn't camelCase) so the migration can re-run
-- safely if interrupted. Forward-only per the migrations workflow.

-- Helper function: rename camelCase MovementPattern strings to snake_case
-- within a jsonb scalar. Returns the input unchanged for non-matching values.
CREATE OR REPLACE FUNCTION pg_temp.rename_pattern_value(input jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE input #>> '{}'
    WHEN 'horizontalPush' THEN '"horizontal_push"'::jsonb
    WHEN 'horizontalPull' THEN '"horizontal_pull"'::jsonb
    WHEN 'verticalPush'   THEN '"vertical_push"'::jsonb
    WHEN 'verticalPull'   THEN '"vertical_pull"'::jsonb
    WHEN 'hipHinge'       THEN '"hip_hinge"'::jsonb
    ELSE input
  END
$$;

-- Helper function: rename camelCase MovementPattern keys within a JSON
-- object. Builds a new object reusing snake_case keys for the 5 camelCase
-- variants; all other keys pass through unchanged.
CREATE OR REPLACE FUNCTION pg_temp.rename_pattern_keys(input jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    jsonb_object_agg(
      CASE k
        WHEN 'horizontalPush' THEN 'horizontal_push'
        WHEN 'horizontalPull' THEN 'horizontal_pull'
        WHEN 'verticalPush'   THEN 'vertical_push'
        WHEN 'verticalPull'   THEN 'vertical_pull'
        WHEN 'hipHinge'       THEN 'hip_hinge'
        ELSE k
      END,
      v
    ),
    '{}'::jsonb
  )
  FROM jsonb_each(input) AS e(k, v)
$$;

-- 1 + 2. model_json.patterns outer keys + per-PatternProfile `pattern` field.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{patterns}',
  (
    SELECT COALESCE(
      jsonb_object_agg(
        CASE k
          WHEN 'horizontalPush' THEN 'horizontal_push'
          WHEN 'horizontalPull' THEN 'horizontal_pull'
          WHEN 'verticalPush'   THEN 'vertical_push'
          WHEN 'verticalPull'   THEN 'vertical_pull'
          WHEN 'hipHinge'       THEN 'hip_hinge'
          ELSE k
        END,
        CASE WHEN v ? 'pattern'
          THEN jsonb_set(v, '{pattern}', pg_temp.rename_pattern_value(v->'pattern'))
          ELSE v
        END
      ),
      '{}'::jsonb
    )
    FROM jsonb_each(model_json->'patterns') AS e(k, v)
  )
)
WHERE model_json ? 'patterns'
  AND jsonb_typeof(model_json->'patterns') = 'object';

-- 3. model_json.prescriptionAccuracy outer keys.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{prescriptionAccuracy}',
  pg_temp.rename_pattern_keys(model_json->'prescriptionAccuracy')
)
WHERE model_json ? 'prescriptionAccuracy'
  AND jsonb_typeof(model_json->'prescriptionAccuracy') = 'object';

-- 4 + 5. fatigueInteractions[*].fromPattern + .toPattern values.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{fatigueInteractions}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry ? 'fromPattern' OR entry ? 'toPattern' THEN
          entry
            || jsonb_build_object('fromPattern', pg_temp.rename_pattern_value(entry->'fromPattern'))
            || jsonb_build_object('toPattern',   pg_temp.rename_pattern_value(entry->'toPattern'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'fatigueInteractions') AS e(entry)
  )
)
WHERE model_json ? 'fatigueInteractions'
  AND jsonb_typeof(model_json->'fatigueInteractions') = 'array';

-- 6. lastSessionPatternPerformance[*].pattern values.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{lastSessionPatternPerformance}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE WHEN entry ? 'pattern'
        THEN jsonb_set(entry, '{pattern}', pg_temp.rename_pattern_value(entry->'pattern'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'lastSessionPatternPerformance') AS e(entry)
  )
)
WHERE model_json ? 'lastSessionPatternPerformance'
  AND jsonb_typeof(model_json->'lastSessionPatternPerformance') = 'array';

-- 7. activeLimitations[*].subject.value when subject.kind='pattern'.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{activeLimitations}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry #>> '{subject,kind}' = 'pattern' THEN
          jsonb_set(entry, '{subject,value}', pg_temp.rename_pattern_value(entry#>'{subject,value}'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'activeLimitations') AS e(entry)
  )
)
WHERE model_json ? 'activeLimitations'
  AND jsonb_typeof(model_json->'activeLimitations') = 'array';

-- 8. clearedLimitations[*].subject.value when subject.kind='pattern'.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{clearedLimitations}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry #>> '{subject,kind}' = 'pattern' THEN
          jsonb_set(entry, '{subject,value}', pg_temp.rename_pattern_value(entry#>'{subject,value}'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'clearedLimitations') AS e(entry)
  )
)
WHERE model_json ? 'clearedLimitations'
  AND jsonb_typeof(model_json->'clearedLimitations') = 'array';
