-- Reverse migration for: supabase/migrations/20260604061428_add_deactivate_and_insert_program_rpc.sql
-- (documentation only; NOT auto-applied by `supabase db push`. Run manually with
--  `psql -f` against the target database if the forward migration must be rolled back.)
--
-- #189: drops the atomic deactivate-and-insert RPC. The iOS client falls back to
-- the prior non-transactional deactivatePrograms()-then-insert() path if this
-- function is absent only when paired with a client build that still uses it —
-- the forward migration is additive (a new function), so dropping it has no
-- effect on existing rows or other functions.

DROP FUNCTION IF EXISTS public.deactivate_and_insert_program(uuid, uuid, jsonb, integer);
