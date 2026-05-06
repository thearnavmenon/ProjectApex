-- Migration: 0004_add_intent_to_set_logs_with_default_and_backfill.sql
-- Phase 1 / Slice 6 — set-intent column add + heuristic backfill
-- Issue: #10  ·  ADR-0005  ·  PR: #47
--
-- ████████████████████████████████████████████████████████████████████████
-- DEPLOYMENT GATE — do NOT apply until ALL of the following steps complete
-- in order:
--
-- STEP 1. Phase 0 code (SetPrescription.intent validation, freestyle picker,
--   Edge Function payload validator) is merged to main and shipped to
--   TestFlight.
--
-- STEP 2. Each alpha user has confirmed via DM the EXACT question:
--
--   > Have you logged at least one set in the new build (Slice 6 / Phase 0)?
--
--   "Have you updated" is NOT sufficient — the build can be installed but
--   never exercised. Capture each confirmation in the Slice 6 PR thread
--   before proceeding to step 3. At alpha scale (n ≤ 5) this manual gate is
--   the agreed workaround for the absence of `app_build` telemetry; see
--   issue #41 for the beta-scale replacement.
--
-- STEP 3. Race-window mitigation — DM the alpha cohort to pause logging for
--   the apply window, BEFORE running the SQL below. A Phase-0 write that
--   lands during the apply receives the column DEFAULT 'top' as it inserts.
--   The heuristic backfill below is a one-shot pass at apply time — it does
--   not revisit rows on subsequent inserts, so any DEFAULT-tagged row that
--   slips in during the window stays mislabelled. Cheap to prevent at
--   n ≤ 5; expensive to detect after the fact.
--
--   Pre-written DM text — copy verbatim, fill in the two [HH:MM] times
--   (give yourself a 30-minute buffer; the actual SQL runs in seconds but
--   the human round-trip on acknowledgments takes longer):
--
--   > Apex maintenance: I'm running the set-intent DB migration in ~10 min
--   > and need ~30 min of clear writes — please don't log any sets between
--   > [HH:MM] and [HH:MM] [TZ] (about 30 min). Reason: any sets logged
--   > during the apply window may receive default 'top' labels instead of
--   > the heuristic-derived label. I'll DM you when it's done. Thanks!
--
--   Wait for ALL alpha users to acknowledge before proceeding to step 4.
--
-- STEP 4. Apply this migration via Supabase SQL editor or psql against the
--   production project URL. Top-level `migrations/` is not picked up by
--   `supabase db push` (see project memory note; path-drift fix is its own
--   separate slice).
--
-- STEP 5. After the SQL completes, DM the alpha cohort that the maintenance
--   window is over and logging can resume. (Out of the gate but in the
--   deploy sequence — see the Slice 6 PR description for the full
--   per-phase ordering.)
--
-- ████████████████████████████████████████████████████████████████████████
--
-- Phase 1 of the three-phase set-intent migration:
--   Phase 0 (Swift, already shipped): SetPrescription.validate() requires
--     intent; rep/RPE picker requires explicit interaction; Edge Function
--     payload validator rejects set_logs without intent. No DB schema
--     change. No silent default at any layer.
--   Phase 1 (this file): adds `intent TEXT NOT NULL DEFAULT 'top'` to
--     set_logs as a backfill safety-net, then heuristically labels
--     historical rows from weight/rep pattern.
--   Phase 2 (next migration: 0005): drops the DEFAULT so post-cutoff
--     writes must populate intent explicitly. Defence-in-depth — the
--     Phase 0 client-side validation already enforces, this adds DB-
--     level enforcement.
--
-- Heuristic backfill (per ADR-0005 / issue #10):
--   For each (session_id, exercise_id) group:
--     * Highest weight_kg → 'top'. Tie-break: highest reps_completed wins
--       (closest to AMRAP shape — but stays 'top' since the heuristic
--       cannot distinguish AMRAP from a heavy top set), then lowest
--       set_number (earliest performed) for stability.
--     * Other sets ≥ 50% of top weight → 'backoff'.
--     * Other sets < 50% of top weight → 'warmup'.
--     * Bodyweight groups (top_weight = 0): rn=1 set stays 'top'; all
--       others 'warmup' (the 0.50 * 0 boundary cannot match anything,
--       defensible default for legacy bodyweight rows).
--
--   AMRAP and technique are NOT recoverable from logged data alone —
--   pre-cutoff rows that were AMRAP get labelled 'top'; pre-cutoff
--   technique rows get labelled by weight pattern. Analytics consumers
--   that break out per-intent must filter via
--   MigrationDates.v2SetIntentBackfill in Swift to exclude pre-cutoff
--   rows from per-intent breakdowns.
--
-- Idempotency: ADD COLUMN IF NOT EXISTS makes the schema change
-- re-runnable. The UPDATE pass filters `intent = 'top'` so it only
-- touches rows still at the column DEFAULT — heuristic labels written
-- by a prior apply are never overwritten on re-run.

-- ─── 1. Schema change ───────────────────────────────────────────────────────
ALTER TABLE public.set_logs
  ADD COLUMN IF NOT EXISTS intent TEXT NOT NULL DEFAULT 'top';

COMMENT ON COLUMN public.set_logs.intent IS
  'SetIntent (warmup/top/backoff/technique/amrap) per ADR-0005. The DEFAULT '
  '''top'' is a Phase-1 backfill safety net only and is dropped in Phase 2 '
  '(0005_drop_intent_default_from_set_logs.sql) so post-cutoff writes must '
  'populate intent explicitly. Pre-cutoff rows (see '
  'MigrationDates.v2SetIntentBackfill in Swift) carry approximate labels '
  'from the heuristic backfill in 0004: top = highest weight per '
  '(session, exercise); backoff ≥ 50%% of top weight; warmup < 50%%. '
  'AMRAP and technique are NOT recoverable from logged data alone and '
  'remain labelled by weight pattern for pre-cutoff rows; analytics that '
  'break out per-intent must filter pre-cutoff via '
  'MigrationDates.v2SetIntentBackfill.';

-- Pass 1 removed.
--
-- Original intent: pull intent values from set_logs.ai_prescribed JSONB
-- where Phase 0 Swift had stashed them.
--
-- Why removed: the assumption was wrong. set_logs.ai_prescribed never
-- existed on the production schema, and Phase 0's SetLogPayload encoder
-- did not serialize the field even when the in-memory SetLog carried it.
-- Pass 1 was therefore either a no-op (column-exists case) or a hard
-- error (column-doesn't-exist case, which is what production is).
--
-- The heuristic backfill below (window function over weight/session/
-- exercise) does all the actual work and operates only on columns that
-- demonstrably exist on production.
--
-- See PR #47 (the original Slice 6 PR) and this fix-up PR's body for
-- the failed deploy attempt context (2026-05-06) and audit findings.

-- ─── 2. Heuristic backfill ──────────────────────────────────────────────────
--
--   Window over (session_id, exercise_id), pick the highest weight as 'top',
--   and partition the rest by 50%-of-top into 'backoff' / 'warmup'.
--   Only touches rows still at the column DEFAULT.
WITH ranked AS (
    SELECT
        id,
        weight_kg,
        MAX(weight_kg) OVER (PARTITION BY session_id, exercise_id) AS top_weight,
        ROW_NUMBER() OVER (
            PARTITION BY session_id, exercise_id
            ORDER BY weight_kg DESC, reps_completed DESC, set_number ASC
        ) AS rn
    FROM public.set_logs
    WHERE intent = 'top'
),
labelled AS (
    SELECT
        id,
        CASE
            WHEN rn = 1                         THEN 'top'
            WHEN top_weight = 0                 THEN 'warmup'
            WHEN weight_kg >= 0.50 * top_weight THEN 'backoff'
            ELSE                                     'warmup'
        END AS new_intent
    FROM ranked
)
UPDATE public.set_logs sl
SET intent = labelled.new_intent
FROM labelled
WHERE sl.id = labelled.id
  AND sl.intent = 'top'
  AND labelled.new_intent <> 'top';
