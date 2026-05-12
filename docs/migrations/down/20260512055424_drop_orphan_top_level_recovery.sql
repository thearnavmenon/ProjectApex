-- Reverse migration for: supabase/migrations/20260512055424_drop_orphan_top_level_recovery.sql
-- Documentation only — manual operator use (`psql -f`); not auto-applied
-- by `supabase db push`.
--
-- Restores a synthetic top-level `recovery` field on every trainee_models
-- row using ADR-0005 defaults (null timestamps + 1.0 readinesses). The
-- pre-#146 EF code wrote real values into this field via the global
-- stimulus-classifier + readiness-curve pipelines, but those pipelines
-- moved to per-pattern recovery in the same PR — there is no way to
-- reconstruct the prior per-row values from per-pattern state at rollback
-- time. The reverse therefore restores the SHAPE (so pre-#146 EF code
-- that reads `model_json.recovery` won't crash on missing-key) without
-- claiming to restore the data.
--
-- Use only when rolling back the #146 EF deploy.

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{recovery}',
  '{"lastNeuromuscularStimulusAt": null, "lastMetabolicStimulusAt": null, "neuromuscularReadiness": 1.0, "metabolicReadiness": 1.0}'::jsonb,
  true
)
WHERE NOT (model_json ? 'recovery');
