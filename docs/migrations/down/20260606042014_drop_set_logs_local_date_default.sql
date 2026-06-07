-- Reverse of 20260606042014_drop_set_logs_local_date_default.sql
--
-- supabase db push is forward-only; this file is for manual operator use
-- (psql -f) when rolling back the DEFAULT drop on set_logs.local_date.
--
-- Restores the backfill-only sentinel DEFAULT '1970-01-01' that the forward
-- migration dropped. The column was — and remains — NOT NULL; only the DEFAULT
-- is being reinstated.

ALTER TABLE "public"."set_logs" ALTER COLUMN "local_date" SET DEFAULT '1970-01-01'::text;
