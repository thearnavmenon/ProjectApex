-- Migration: 0007_add_profile_columns_to_users.sql
-- F2 from 2026-05-06 migration recovery — add profile columns to users
--
-- ████████████████████████████████████████████████████████████████████████
-- WHY THIS MIGRATION EXISTS
--
-- The 2026-05-06 production schema audit (triggered by 0004's failed
-- deploy attempt) found that public.users on production had only three
-- columns: id, display_name, created_at. The Swift onboarding flow's
-- UserInsertRow encoder writes six fields:
--
--   id, display_name, bodyweight_kg, height_cm, age, training_age
--
-- The four profile fields landed against unknown columns and the
-- INSERT either failed wholesale or had those fields silently dropped
-- by PostgREST. The call site uses `try?` so any error was invisible:
--
--   try? await deps.supabaseClient.insert(userRow, table: "users")
--
-- Net effect: every user that completed onboarding got their bodyweight,
-- height, age, and training age preserved only in UserDefaults locally,
-- never on the server. This migration adds the four columns so future
-- onboarding writes succeed end-to-end.
--
-- See:
--   * ProjectApex/Features/Onboarding/OnboardingView.swift:972  —
--     UserInsertRow Codable shape (the encoder's CodingKeys are the
--     authoritative source for column names)
--   * ProjectApex/Features/Onboarding/OnboardingView.swift:934  —
--     write call site (the silent-failure path)
--   * ProjectApex/AICoach/AIInferenceService.swift:79          —
--     UserProfileContext (the inference-side struct that consumes
--     these values from UserDefaults)
--   * PR #47 (the original Slice 6) and the 2026-05-06 deploy attempt
--     that surfaced the audit
--
-- Existing-row handling: production has 2 rows in public.users at apply
-- time. They retain id / display_name / created_at; the four new
-- columns are NULL. No backfill — the original profile values were
-- captured only in UserDefaults, which is not accessible from the
-- server. The user can re-enter values via the Settings UI; today
-- Settings only writes UserDefaults, so server sync is a separate
-- follow-up (filed alongside this migration).
--
-- Out of scope (separate slices):
--   * Settings → server write path. Settings currently writes
--     UserDefaults only. Wiring it to also push to the server is its
--     own slice — needs decisions on sync cadence, conflict resolution,
--     and error UI. Filed as a follow-up issue at PR-open time.
--   * Telemetry / unburying the silent insert failures (#41 covers
--     telemetry generally).
--   * RLS policies (Phase 5 across the schema).
-- ████████████████████████████████████████████████████████████████████████
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes each statement re-runnable.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS bodyweight_kg NUMERIC,
  ADD COLUMN IF NOT EXISTS height_cm     NUMERIC,
  ADD COLUMN IF NOT EXISTS age           INTEGER,
  ADD COLUMN IF NOT EXISTS training_age  TEXT;

COMMENT ON COLUMN public.users.bodyweight_kg IS
    'User-reported bodyweight in kilograms. Captured at onboarding and '
    'editable from Settings (Settings UI currently writes UserDefaults '
    'only — server sync is a separate follow-up). NUMERIC chosen to '
    'match equipment_catalog kg-typed columns; arbitrary precision '
    'avoids floating-point edge cases on inputs like ''82.5''.';

COMMENT ON COLUMN public.users.height_cm IS
    'User-reported height in centimetres. NUMERIC for parity with '
    'bodyweight_kg.';

COMMENT ON COLUMN public.users.age IS
    'User-reported age in years. Range validation lives at the input '
    'layer (iOS); the DB does not enforce a CHECK constraint.';

COMMENT ON COLUMN public.users.training_age IS
    'User-reported training experience label. As of this migration, the '
    'bounded set of values produced by the Swift TrainingAge enum is '
    '(byte-exact rawValues from OnboardingView.swift:43): '
    '''Beginner (< 1 yr)'', ''Intermediate (1–3 yrs)'', '
    '''Advanced (3+ yrs)''. Note the en-dash (–, U+2013) between ''1'' '
    'and ''3'' in the intermediate label — not a hyphen. Adding a new '
    'value or changing an existing rawValue requires a Swift code '
    'change. Stored as TEXT (no CHECK, no ENUM) so future labels land '
    'without a schema migration.';
