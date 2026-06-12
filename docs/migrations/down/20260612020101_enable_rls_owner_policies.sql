-- Reverse of 20260612020101_enable_rls_owner_policies.sql
--
-- supabase db push is forward-only; this file is for manual operator use
-- (psql -f) when rolling back the RLS gate-flip from auth slice 5 (#369).
-- Documentation only; not auto-applied.
--
-- Restores the exact pre-migration state:
--   * DISABLE RLS on the five tables the forward migration enabled it on
--     (workout_sessions, programs, trainee_models, users, set_logs).
--   * DROP the new FOR ALL owner policies.
--   * Restore the original USING-only "owner access" policies on programs and
--     set_logs (the forward migration replaced these with FOR ALL variants).
--   * Restore the original gym_profiles "anon full access" USING(true) policy
--     (gym_profiles keeps RLS enabled — the baseline had it on).
--
-- WARNING: re-disabling RLS re-exposes every row to the anon grants. Only run
-- this if you are deliberately rolling back per-user data isolation.


-- 1. Drop the new FOR ALL owner policies.

DROP POLICY IF EXISTS "workout_sessions: owner access" ON "public"."workout_sessions";
DROP POLICY IF EXISTS "programs: owner access" ON "public"."programs";
DROP POLICY IF EXISTS "trainee_models: owner access" ON "public"."trainee_models";
DROP POLICY IF EXISTS "users: owner access" ON "public"."users";
DROP POLICY IF EXISTS "set_logs: owner access" ON "public"."set_logs";
DROP POLICY IF EXISTS "owner access" ON "public"."gym_profiles";


-- 2. Disable RLS on the five tables the forward migration enabled it on.
--    (gym_profiles is intentionally left RLS-enabled — that matches the baseline.)

ALTER TABLE "public"."workout_sessions" DISABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."programs" DISABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."trainee_models" DISABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."users" DISABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."set_logs" DISABLE ROW LEVEL SECURITY;


-- 3. Restore the original USING-only "owner access" policies on programs and
--    set_logs (the forward migration replaced these). These are inert while RLS
--    is disabled above, but restoring them returns the schema to its exact
--    pre-migration shape.

CREATE POLICY "programs: owner access" ON "public"."programs" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "set_logs: owner access" ON "public"."set_logs" USING (("session_id" IN ( SELECT "workout_sessions"."id"
   FROM "public"."workout_sessions"
  WHERE ("workout_sessions"."user_id" = "auth"."uid"()))));


-- 4. Restore the original gym_profiles "anon full access" USING(true) policy.

CREATE POLICY "anon full access" ON "public"."gym_profiles" USING (true) WITH CHECK (true);
