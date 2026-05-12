-- Reverse migration: docs/migrations/down/20260512134826_add_workout_sessions_program_id_fk.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- Adds a FK constraint on workout_sessions.program_id with ON DELETE SET NULL.
--
-- Discovered post-B1 during a routine session audit: a workout_session row
-- referenced a program_id that didn't exist in `programs`. The column was
-- defined as plain uuid without a FK (per the original remote_schema baseline
-- at supabase/migrations/20260506091314_remote_schema.sql:248), so manual
-- operator deletes against `programs` left orphan references behind. The
-- iOS code path has no DELETE FROM programs site (verified via grep), so the
-- orphans came from out-of-band cleanup; the schema is what allows them.
--
-- Two changes:
--   1. NULL out any existing orphan program_ids — required because ADD
--      CONSTRAINT ... NOT VALID + VALIDATE would still reject the orphans,
--      and ADD CONSTRAINT without NOT VALID rejects them at constraint-add
--      time. Null'ing them is cosmetically lossless (the session row stays;
--      its dangling program reference becomes an explicit unknown).
--   2. ADD the FK with ON DELETE SET NULL so any future legitimate program
--      deletion gracefully nulls the back-reference rather than leaving
--      orphans (or cascading and losing the session row, which would be
--      worse — session history is more durable than program identity).
--
-- Cleanup-plan reference: see `docs/phase-2-cleanup-plan-2026-05-12.md` Tier 6
-- item #9. This migration discharges that backlog item.

-- 1. NULL out orphans.
UPDATE public.workout_sessions
SET program_id = NULL
WHERE program_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.programs p WHERE p.id = workout_sessions.program_id
  );

-- 2. Add the FK constraint with ON DELETE SET NULL.
-- Skip if the constraint already exists (idempotent re-runs).
DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'workout_sessions_program_id_fkey'
      AND conrelid = 'public.workout_sessions'::regclass
  ) THEN
    ALTER TABLE public.workout_sessions
      ADD CONSTRAINT workout_sessions_program_id_fkey
      FOREIGN KEY (program_id) REFERENCES public.programs(id) ON DELETE SET NULL;
  END IF;
END
$migration$;
