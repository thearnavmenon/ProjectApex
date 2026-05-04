-- Migration: 0002_add_local_date_to_set_logs.sql
-- Phase 1 / Slice 5 — pre-bucketed local-date on set_logs (issue #4, ADR-0005)
--
-- Adds the local_date TEXT column to set_logs.  Pre-bucketed at write time
-- (yyyy-MM-dd, formatted in the user's then-local timezone by the Swift
-- TopSetSnapshot.make(setLog:loggedInTimezone:) factory), so cadence and
-- disruption derivations remain stable across subsequent timezone changes
-- (e.g. user travels Sydney → Tokyo without breaking cadence calculations).
-- See ADR-0005 — "Day boundaries for cadence: device-local vs UTC vs
-- pre-bucketed local. Chose pre-bucketed `localDate` string at write time."
--
-- Backfill default '1970-01-01' exists ONLY to satisfy NOT NULL during the
-- column add against existing rows.  New writes always populate explicitly
-- via the Swift factory; no production code path relies on the default for
-- a newly-created row.
--
-- Sentinel rows ('1970-01-01') are NOT consumed raw at read time.  The
-- read-time derivation pattern lives in Swift at MigrationDates.v2LocalDateField
-- (see ProjectApex/Models/MigrationDates.swift): consumers branch on
-- "set logged before vs after the cutoff" and derive localDate on-the-fly
-- from `logged_at` + active timezone for pre-cutoff rows.  When this
-- migration is applied to a production database, update v2LocalDateField
-- in MigrationDates.swift to the actual deploy timestamp so future readers
-- can distinguish pre-cutoff (sentinel-tagged) from post-cutoff (factory-
-- written) rows.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-running safe.

ALTER TABLE public.set_logs
  ADD COLUMN IF NOT EXISTS local_date TEXT NOT NULL DEFAULT '1970-01-01';

COMMENT ON COLUMN public.set_logs.local_date IS
  'Pre-bucketed local-date string (yyyy-MM-dd) per ADR-0005. Captured at '
  'write time in the logging user''s then-local timezone via the Swift '
  'TopSetSnapshot factory; immune to subsequent timezone changes. Default '
  '''1970-01-01'' is a backfill-only sentinel — new writes populate '
  'explicitly.';
