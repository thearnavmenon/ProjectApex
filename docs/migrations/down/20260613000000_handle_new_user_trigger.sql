-- Reverse of 20260613000000_handle_new_user_trigger.sql
--
-- `supabase db push` is forward-only; this file is for manual operator use
-- (psql -f) when rolling back the handle_new_user trigger (#369).
-- Documentation only; not auto-applied.
--
-- Removes the trigger and its backing function. Any public.users rows that the
-- trigger auto-provisioned before this rollback are left in place — they are
-- harmless (onboarding's upsert would have created them anyway).

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

DROP FUNCTION IF EXISTS public.handle_new_user();
