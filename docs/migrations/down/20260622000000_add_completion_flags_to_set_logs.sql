-- Reverse migration for supabase/migrations/20260622000000_add_completion_flags_to_set_logs.sql
-- Documentation only; NOT auto-applied by `supabase db push`. Run manually
-- (`psql -f`) if the forward migration must be rolled back.
--
-- #43 — drop the cross-session completion-flags column.

ALTER TABLE public.set_logs DROP COLUMN IF EXISTS completion_flags;
