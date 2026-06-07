-- Reverse migration: docs/migrations/down/20260606042014_drop_set_logs_local_date_default.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- #67: drop the backfill-only sentinel DEFAULT '1970-01-01' on set_logs.local_date.
--
-- Defence-in-depth. The DEFAULT originated in the baseline dump
-- (supabase/migrations/20260506091314_remote_schema.sql:169) as a backfill
-- safety net. All three (and only three) set_logs insert paths now populate
-- local_date explicitly via the non-optional SetLog.formatLocalDate
-- (WorkoutSession.swift:209), which never yields the sentinel. Dropping the
-- DEFAULT means any future omission surfaces as a loud 23502 NOT NULL violation
-- rather than silently writing the 1970 sentinel — which is the point.
--
-- The column stays NOT NULL. Existing sentinel rows are untouched (backfill is
-- out of scope, tracked in #63).

ALTER TABLE "public"."set_logs" ALTER COLUMN "local_date" DROP DEFAULT;
