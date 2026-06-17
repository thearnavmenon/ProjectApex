-- Reverse migration for supabase/migrations/20260617000000_add_training_day_id_to_workout_sessions.sql
-- Documentation only; NOT auto-applied by `supabase db push`. Run manually
-- (`psql -f`) if the forward migration must be rolled back.
--
-- #443 (Q2) — drop the durable day-identity column.

ALTER TABLE workout_sessions DROP COLUMN IF EXISTS training_day_id;
