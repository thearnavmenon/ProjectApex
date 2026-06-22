-- Reverse migration: docs/migrations/down/20260622000000_add_completion_flags_to_set_logs.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- #43 — persist set_logs.completion_flags for cross-session AI reasoning.
--
-- Slice 6 (#10) shipped SetCompletionFlag (pain / form_breakdown) client-side
-- only — captured on the rep/RPE sheet, carried on the in-memory SetLog, and
-- threaded into the within-session AI prompt — but never persisted. Without a
-- column the flags evaporate at session end, so cross-session reasoning
-- ("flagged pain on bench last week -> ease off this week") is impossible.
--
-- TEXT[] NOT NULL DEFAULT '{}': the empty array IS the real semantic
-- ("no flags raised"), not a backfill placeholder, so existing rows are correct
-- as-is and no Phase-2 default-drop is needed. Values are constrained to
-- {pain, form_breakdown} at the Edge Function boundary (validateRequest),
-- mirroring how set_logs.intent is validated, rather than via a DB CHECK.

ALTER TABLE public.set_logs
  ADD COLUMN IF NOT EXISTS completion_flags TEXT[] NOT NULL DEFAULT '{}';
