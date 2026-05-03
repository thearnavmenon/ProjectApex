-- Migration: 0001_create_trainee_models_and_equipment_catalog.sql
-- Phase 1 / Slice 3 — trainee_models, trainee_model_applied_sessions, equipment_catalog
--
-- Applies cleanly to a fresh dev database or one with existing rows in
-- unrelated tables.  Re-running is safe: CREATE TABLE IF NOT EXISTS and
-- CREATE INDEX IF NOT EXISTS make every statement idempotent.
--
-- Out of scope (separate slices):
--   - equipment_catalog seed data  (#7)
--   - set_logs.intent / local_date columns
--   - RLS policies (Phase 5)
--   - Edge Function deployment

-- ---------------------------------------------------------------------------
-- trainee_models
-- Canonical server-side home for the persistent structured trainee model.
-- user_id is both PK and FK — one row per user, updated after every session.
-- Per ADR-0005 / ADR-0006: no global confidence_level column.  Per-axis
-- confidence lives inside model_json on each PatternProfile / MuscleProfile /
-- ExerciseProfile.  Calibration-review readiness is computed at read time
-- from those per-axis values, not stored as a top-level column.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trainee_models (
    user_id       UUID        PRIMARY KEY REFERENCES public.users(id),
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    session_count INTEGER     DEFAULT 0,
    model_json    JSONB       NOT NULL
);

COMMENT ON TABLE public.trainee_models IS
    'No confidence_level column: per-axis confidence lives inside model_json '
    'on each PatternProfile / MuscleProfile / ExerciseProfile (ADR-0005 / ADR-0006). '
    'Calibration-review readiness is derived at read time, not stored here.';

-- ---------------------------------------------------------------------------
-- trainee_model_applied_sessions
-- DB-layer idempotency log for trainee-model session updates (ADR-0006).
-- The composite PK (user_id, session_id) is the idempotency mechanism:
-- INSERT … ON CONFLICT DO NOTHING short-circuits duplicate submissions from
-- WAQ replay, network retries, and crash recovery.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trainee_model_applied_sessions (
    user_id    UUID        NOT NULL,
    session_id UUID        NOT NULL,
    applied_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, session_id)
);

-- ---------------------------------------------------------------------------
-- equipment_catalog
-- Globally scoped, AI-grown equipment catalog (ADR-0004 / option C5).
-- No user_id FK — this table is global, not per-user.
-- Per-gym overrides (e.g. this gym's max is 35 kg, not the catalog default)
-- live on gym_profiles.equipment, not here.
-- Seed data ships in a separate slice (#7).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.equipment_catalog (
    id                    TEXT        PRIMARY KEY,
    display_name          TEXT        NOT NULL,
    category              TEXT        NOT NULL,
    default_max_kg        NUMERIC,
    default_increment_kg  NUMERIC,
    primary_muscle_groups TEXT[]      NOT NULL,
    exercise_tags         TEXT[]      NOT NULL,
    created_at            TIMESTAMPTZ DEFAULT NOW()
);
