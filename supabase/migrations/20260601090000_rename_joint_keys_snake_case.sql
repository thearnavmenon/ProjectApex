-- Reverse migration: docs/migrations/down/20260601090000_rename_joint_keys_snake_case.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- #151: rename the camelCase joint key 'lowerBack' to snake_case 'lower_back'
-- in trainee_models.model_json limitation subjects.
--
-- The Edge Function's PATTERN_TRAINS_JOINTS map (_shared/note-classifier.ts)
-- previously stored the joint string "lowerBack" (camelCase), while a joint
-- subject's value is the BodyJoint rawValue "lower_back" (snake_case) — locked
-- by note-classifier-prompt.txt and Swift's BodyJoint.lowerBack = "lower_back".
-- The auto-clear gate isSubjectTrained does trainedJoints.has(subject.value),
-- so a lower_back-scoped limitation never matched the camelCase-derived set and
-- never auto-cleared. EF code in this same PR fixes the map to snake_case; this
-- migration renames the key in any existing alpha JSONB rows.
--
-- 'lowerBack' is the only multi-word joint, so it is the only joint affected
-- (shoulder/elbow/wrist/hip/knee/ankle/neck have no casing distinction).
--
-- Joint-keyed locations migrated (joints are never pattern-keyed, so unlike
-- #148 only the two limitation arrays need touching):
--   1. model_json.activeLimitations[*].subject.value  when subject.kind='joint'
--   2. model_json.clearedLimitations[*].subject.value when subject.kind='joint'
--
-- Each location is migrated independently with an idempotent transformation
-- (no-op when the value isn't 'lowerBack') so the migration can re-run safely.
-- Forward-only per the migrations workflow.

-- Helper: rename the camelCase joint scalar 'lowerBack' to snake_case within a
-- jsonb scalar. Returns the input unchanged for any non-matching value.
CREATE OR REPLACE FUNCTION pg_temp.rename_joint_value(input jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE input #>> '{}'
    WHEN 'lowerBack' THEN '"lower_back"'::jsonb
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
          jsonb_set(entry, '{subject,value}', pg_temp.rename_joint_value(entry#>'{subject,value}'))
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
          jsonb_set(entry, '{subject,value}', pg_temp.rename_joint_value(entry#>'{subject,value}'))
        ELSE entry
      END
    ), '[]'::jsonb)
    FROM jsonb_array_elements(model_json->'clearedLimitations') AS e(entry)
  )
)
WHERE model_json ? 'clearedLimitations'
  AND jsonb_typeof(model_json->'clearedLimitations') = 'array';
