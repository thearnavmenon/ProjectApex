-- Reverse migration: docs/migrations/down/20260617000000_add_training_day_id_to_workout_sessions.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- #443 (Q2) — durable day identity for workout_sessions.
--
-- (program_id, week_number, day_type) is NOT unique — normalizeDayLabel does not
-- disambiguate two days that share a label — so resume/repair cannot reliably
-- re-match a session to its TrainingDay. This column gives every session a
-- durable, server-visible TrainingDay.id stamped at session start.
--
-- Nullable with no default and no backfill: existing rows keep NULL (legacy),
-- and the repair path falls back to its prior behaviour for those rows.

ALTER TABLE workout_sessions ADD COLUMN training_day_id uuid;
