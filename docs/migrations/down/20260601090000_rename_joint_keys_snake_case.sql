-- REVERSE of supabase/migrations/20260601090000_rename_joint_keys_snake_case.sql
-- (documentation only; not auto-applied by `supabase db push` — run manually
--  via `psql -f` if the forward #151 migration must be rolled back.)
--
-- Renames the snake_case joint key 'lower_back' back to camelCase 'lowerBack'
-- in trainee_models.model_json limitation subjects where subject.kind='joint'.
-- Only restore this alongside reverting the EF code change in the same PR —
-- otherwise the auto-clear gate (which now expects snake_case) breaks again.
--
-- Idempotent (no-op when the value isn't 'lower_back'). Scoped to joint
-- subjects only, so it will not touch the canonical 'lower_back' used by the
-- note-classifier tissue-fallthrough path (that value is produced fresh, not
-- stored as a joint subject this migration manages).

CREATE OR REPLACE FUNCTION pg_temp.revert_joint_value(input jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE input #>> '{}'
    WHEN 'lower_back' THEN '"lowerBack"'::jsonb
    ELSE input
  END
$$;

-- 1. activeLimitations[*].subject.value when subject.kind='joint'.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{activeLimitations}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry #>> '{subject,kind}' = 'joint' THEN
          jsonb_set(entry, '{subject,value}', pg_temp.revert_joint_value(entry#>'{subject,value}'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'activeLimitations') AS e(entry)
  )
)
WHERE model_json ? 'activeLimitations'
  AND jsonb_typeof(model_json->'activeLimitations') = 'array';

-- 2. clearedLimitations[*].subject.value when subject.kind='joint'.
UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{clearedLimitations}',
  (
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN entry #>> '{subject,kind}' = 'joint' THEN
          jsonb_set(entry, '{subject,value}', pg_temp.revert_joint_value(entry#>'{subject,value}'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'clearedLimitations') AS e(entry)
  )
)
WHERE model_json ? 'clearedLimitations'
  AND jsonb_typeof(model_json->'clearedLimitations') = 'array';
