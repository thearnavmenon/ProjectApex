-- Reverse migration: docs/migrations/down/20260608120000_strip_legacy_reassessment_records.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- P5-D07: strip the legacy top-level `model_json.reassessmentRecords` key
-- from existing trainee_models rows.
--
-- `reassessmentRecords` was declared on `TraineeModel` at Phase 1 inception
-- (commit cf8b48f, 2026-05-04) but never written by any production path — a
-- write-orphan. It was removed from the Swift struct and `CodingKeys` in #224
-- (commit 56d90bd, 2026-06-01); the decoder now silently ignores the legacy
-- key on any row that still carries it. This migration strips the dead key
-- from existing alpha-cohort rows so the JSONB column reflects only the
-- canonical shape.
--
-- The `-` operator on jsonb is idempotent: rows without the key are
-- unaffected, and the `WHERE ... ?` existence guard makes the migration safe
-- to re-run. No production code reads or writes the key, so this is
-- order-independent relative to any deploy. Forward-only per the migrations
-- workflow.

UPDATE public.trainee_models
SET model_json = model_json - 'reassessmentRecords'
WHERE model_json ? 'reassessmentRecords';
