-- Migration: 0006_create_session_notes_table.sql
-- F1 from 2026-05-06 migration recovery — create session_notes table
--
-- ████████████████████████████████████████████████████████████████████████
-- WHY THIS MIGRATION EXISTS
--
-- A read-only audit of production schema on 2026-05-06 (triggered by
-- the failed deploy attempt of migration 0004) found that
-- public.session_notes did not exist on production. The Swift
-- WorkoutSessionManager.addVoiceNote(...) path has been writing
-- voice/text notes to the table since the feature shipped:
--
--   try? await writeAheadQueue.enqueue(notePayload, table: "session_notes")
--
-- The `try?` swallows the resulting REST-API "table does not exist"
-- error, so every voice note logged in production has silently failed.
-- No telemetry surfaced this — the only symptom was absence of rows in
-- a table the client codebase referenced.
--
-- This migration creates the table with the schema that matches the
-- Swift SessionNote / SessionNotePayload models exactly. There is no
-- backfill — past notes were never persisted anywhere recoverable.
-- New writes start populating after apply.
--
-- See:
--   * ProjectApex/Models/WorkoutSession.swift:206  — SessionNote model
--   * ProjectApex/Features/Workout/WorkoutSessionManager.swift:1805 —
--     SessionNotePayload (the encoder shape)
--   * ProjectApex/Features/Workout/WorkoutSessionManager.swift:485  —
--     write site
--   * PR #47 (the original Slice 6) and the 2026-05-06 deploy attempt
--     that surfaced the audit
--
-- Out of scope (separate slices):
--   * RLS policies — Phase 5 will land RLS for every table at once;
--     matching the rest of the schema, this table is unprotected for now
--   * Backfill of historical notes — impossible; they were never persisted
--   * Surfacing the silent enqueue failures (#41 covers telemetry generally;
--     a focused write-failure surface is its own slice)
-- ████████████████████████████████████████████████████████████████████████
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS make
-- every statement re-runnable.

CREATE TABLE IF NOT EXISTS public.session_notes (
    id              UUID        PRIMARY KEY,
    session_id      UUID        NOT NULL REFERENCES public.workout_sessions(id) ON DELETE CASCADE,
    exercise_id     TEXT        NULL,
    raw_transcript  TEXT        NOT NULL,
    tags            TEXT[]      NOT NULL DEFAULT '{}',
    logged_at       TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_session_notes_session_id
    ON public.session_notes(session_id);

COMMENT ON TABLE public.session_notes IS
    'Voice/text notes logged during a workout session. Mirrors the Swift '
    'SessionNote / SessionNotePayload models exactly. Write-only from iOS — '
    'the client never reads back from this table; the embedding pipeline '
    '(memory_embeddings) consumes notes for RAG separately. Created in F1 '
    'of the 2026-05-06 migration recovery; see migration header for context.';

COMMENT ON COLUMN public.session_notes.exercise_id IS
    'Nullable: the exercise the note relates to, if known. Some notes are '
    'global to the session (no exercise context).';

COMMENT ON COLUMN public.session_notes.tags IS
    'Client-derived tags from detectNoteTags(transcript:) in '
    'WorkoutSessionManager.swift. As of this migration, the bounded set of '
    'emitted values is: ''injury_concern'', ''fatigue'', ''energy''. '
    'Adding a new tag requires a Swift code change to detectNoteTags. '
    'The column is typed as TEXT[] (not an enum) so future tag values '
    'land without a schema migration.';
