-- Migration: add_primary_muscle_column.sql
-- ProjectApex — set_logs schema update
--
-- Adds the primary_muscle TEXT column to set_logs.
-- This column stores the coarse muscle group for each set (e.g. "chest", "back")
-- and is populated by the Swift app via ExerciseLibrary.primaryMuscle(for:).
--
-- Run this migration in the Supabase SQL editor BEFORE deploying the app update
-- that writes primary_muscle. The column is nullable so all existing rows remain
-- valid — the backfill_primary_muscle.mjs script handles populating old rows.
--
-- Usage: paste into Supabase SQL editor and run, or use supabase db push.

-- Add the column (idempotent: safe to run multiple times)
ALTER TABLE public.set_logs
  ADD COLUMN IF NOT EXISTS primary_muscle TEXT;

-- Partial index for analytics queries filtered by muscle group.
-- e.g. "total sets per muscle group this week"
-- WHERE clause limits the index to rows that actually have the column populated,
-- keeping index size small during the rollout period.
CREATE INDEX IF NOT EXISTS set_logs_primary_muscle_idx
  ON public.set_logs (primary_muscle)
  WHERE primary_muscle IS NOT NULL;

-- Comment for documentation
COMMENT ON COLUMN public.set_logs.primary_muscle IS
  'Coarse muscle group for this set: chest | back | shoulders | quads | hamstrings | glutes | biceps | triceps | calves | core. Populated from ExerciseLibrary canonical lookup at write time. NULL for rows pre-dating this column or with non-canonical exercise_ids.';
