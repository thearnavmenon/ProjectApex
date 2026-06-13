-- Reverse migration: docs/migrations/down/20260613000000_handle_new_user_trigger.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- Auth/RLS workstream (#369) — new-user bootstrap trigger.
--
-- Problem: every public table that FK-references users(id) fails an INSERT if the
-- current auth.uid() has no public.users row. The iOS client creates that row
-- during onboarding, but any owned write that lands BEFORE onboarding completes
-- (e.g. a write-ahead-queue flush of a workout_session stamped with the real uid)
-- produces a FK-violation 23503. And if GoTrue sign-in succeeds on a re-install
-- but onboarding is skipped (developer reset, test account) the row is never
-- created at all. This is the durable, server-side half of the owner-mismatch fix.
--
-- Fix: an AFTER INSERT trigger on auth.users that immediately provisions a minimal
-- public.users row (id only; all profile columns are nullable per the schema).
-- ON CONFLICT (id) DO NOTHING makes it idempotent — a concurrent onboarding upsert
-- still wins and keeps its profile data.
--
-- SECURITY DEFINER (function explicitly OWNED BY the postgres superuser, below)
-- is required because the trigger fires in GoTrue's auth-schema context as
-- supabase_auth_admin, which does not have INSERT on public.users by default.
-- `SET search_path = ''` (every object fully schema-qualified) matches the repo's
-- existing SECURITY DEFINER pattern (deactivate_and_insert_program, #133) and is
-- the stricter Supabase recommendation against search_path injection. Because the
-- owner (postgres) is BYPASSRLS, the bare-id INSERT is not subject to the users
-- RLS WITH CHECK (id = auth.uid()) — correct, since the trigger runs synchronously
-- inside the auth.users INSERT before any client JWT exists. The explicit
-- `ALTER FUNCTION ... OWNER TO postgres` makes that BYPASSRLS dependency
-- non-implicit: the whole "this can't break sign-ups" guarantee rests on it.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.users (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

-- Idempotent: drop before (re)create so repeated migration runs are safe.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
