-- Reverse migration: docs/migrations/down/20260512055424_drop_orphan_top_level_recovery.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- #146: drop orphan top-level `model_json.recovery` field on trainee_models.
--
-- Per ADR-0005, recovery is two-dimensional NM + metabolic per movement
-- pattern (stored at `model_json.patterns[<key>].recovery`). The Edge
-- Function previously wrote a top-level `model_json.recovery` alongside —
-- a schema drift the Swift PatternProfile decoder never read. The EF code
-- in this same PR migrates stimulus-classifier and readiness-curve rules
-- to per-pattern recovery and stops writing the top-level field; this
-- migration strips the orphan from existing alpha rows so the JSONB
-- column reflects only the canonical shape.
--
-- The `-` operator on jsonb is idempotent: rows without the `recovery`
-- key are unaffected, so the migration is order-safe relative to the
-- Edge Function deploy. Forward-only per the migrations workflow.

UPDATE public.trainee_models
SET model_json = model_json - 'recovery'
WHERE model_json ? 'recovery';
