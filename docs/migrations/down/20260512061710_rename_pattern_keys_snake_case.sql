-- Reverse migration for: supabase/migrations/20260512061710_rename_pattern_keys_snake_case.sql
-- Documentation only — manual operator use (`psql -f`); not auto-applied
-- by `supabase db push`.
--
-- Inverts the snake_case → camelCase rename across the same 8 pattern-keyed
-- locations. Use only when rolling back the #148 EF deploy.

CREATE OR REPLACE FUNCTION pg_temp.unrename_pattern_value(input jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE input #>> '{}'
    WHEN 'horizontal_push' THEN '"horizontalPush"'::jsonb
    WHEN 'horizontal_pull' THEN '"horizontalPull"'::jsonb
    WHEN 'vertical_push'   THEN '"verticalPush"'::jsonb
    WHEN 'vertical_pull'   THEN '"verticalPull"'::jsonb
    WHEN 'hip_hinge'       THEN '"hipHinge"'::jsonb
    ELSE input
  END
$$;

CREATE OR REPLACE FUNCTION pg_temp.unrename_pattern_keys(input jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    jsonb_object_agg(
      CASE k
        WHEN 'horizontal_push' THEN 'horizontalPush'
        WHEN 'horizontal_pull' THEN 'horizontalPull'
        WHEN 'vertical_push'   THEN 'verticalPush'
        WHEN 'vertical_pull'   THEN 'verticalPull'
        WHEN 'hip_hinge'       THEN 'hipHinge'
        ELSE k
      END,
      v
    ),
    '{}'::jsonb
  )
  FROM jsonb_each(input) AS e(k, v)
$$;

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{patterns}',
  (
    SELECT COALESCE(
      jsonb_object_agg(
        CASE k
          WHEN 'horizontal_push' THEN 'horizontalPush'
          WHEN 'horizontal_pull' THEN 'horizontalPull'
          WHEN 'vertical_push'   THEN 'verticalPush'
          WHEN 'vertical_pull'   THEN 'verticalPull'
          WHEN 'hip_hinge'       THEN 'hipHinge'
          ELSE k
        END,
        CASE WHEN v ? 'pattern'
          THEN jsonb_set(v, '{pattern}', pg_temp.unrename_pattern_value(v->'pattern'))
          ELSE v
        END
      ),
      '{}'::jsonb
    )
    FROM jsonb_each(model_json->'patterns') AS e(k, v)
  )
)
WHERE model_json ? 'patterns' AND jsonb_typeof(model_json->'patterns') = 'object';

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{prescriptionAccuracy}',
  pg_temp.unrename_pattern_keys(model_json->'prescriptionAccuracy')
)
WHERE model_json ? 'prescriptionAccuracy' AND jsonb_typeof(model_json->'prescriptionAccuracy') = 'object';

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{fatigueInteractions}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry ? 'fromPattern' OR entry ? 'toPattern' THEN
          entry
            || jsonb_build_object('fromPattern', pg_temp.unrename_pattern_value(entry->'fromPattern'))
            || jsonb_build_object('toPattern',   pg_temp.unrename_pattern_value(entry->'toPattern'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'fatigueInteractions') AS e(entry)
  )
)
WHERE model_json ? 'fatigueInteractions' AND jsonb_typeof(model_json->'fatigueInteractions') = 'array';

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{lastSessionPatternPerformance}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE WHEN entry ? 'pattern'
        THEN jsonb_set(entry, '{pattern}', pg_temp.unrename_pattern_value(entry->'pattern'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'lastSessionPatternPerformance') AS e(entry)
  )
)
WHERE model_json ? 'lastSessionPatternPerformance' AND jsonb_typeof(model_json->'lastSessionPatternPerformance') = 'array';

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{activeLimitations}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry #>> '{subject,kind}' = 'pattern' THEN
          jsonb_set(entry, '{subject,value}', pg_temp.unrename_pattern_value(entry#>'{subject,value}'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'activeLimitations') AS e(entry)
  )
)
WHERE model_json ? 'activeLimitations' AND jsonb_typeof(model_json->'activeLimitations') = 'array';

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{clearedLimitations}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry #>> '{subject,kind}' = 'pattern' THEN
          jsonb_set(entry, '{subject,value}', pg_temp.unrename_pattern_value(entry#>'{subject,value}'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'clearedLimitations') AS e(entry)
  )
)
WHERE model_json ? 'clearedLimitations' AND jsonb_typeof(model_json->'clearedLimitations') = 'array';
