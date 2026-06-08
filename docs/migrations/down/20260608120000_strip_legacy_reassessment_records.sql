-- Reverse migration for: supabase/migrations/20260608120000_strip_legacy_reassessment_records.sql
-- Documentation only — manual operator use (`psql -f`); not auto-applied
-- by `supabase db push`.
--
-- Restores a synthetic top-level `reassessmentRecords` key (empty array) on
-- every trainee_models row that lacks it. The field was a write-orphan — no
-- production path ever populated it — so the only value any legacy row could
-- have carried was the empty array `[]` (the Swift default before the field
-- was removed in #224). The reverse therefore restores the SHAPE as `[]`,
-- without claiming to restore data (there was none to restore).
--
-- Use only when rolling back to a client/state that expects the key to exist.
-- The current Swift decoder ignores `reassessmentRecords` whether present or
-- absent, so a rollback should not be necessary in practice.

UPDATE public.trainee_models
SET model_json = jsonb_set(
  model_json,
  '{reassessmentRecords}',
  '[]'::jsonb,
  true
)
WHERE NOT (model_json ? 'reassessmentRecords');
