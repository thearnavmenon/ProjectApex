-- Reverse migration: docs/migrations/down/20260612020101_enable_rls_owner_policies.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- Auth/RLS workstream slice 5 (#369, ADR-0027) — the gate-flip.
--
-- Enables Row Level Security on the five core owner-scoped tables that were
-- still RLS-off (workout_sessions, programs, trainee_models, users, set_logs),
-- and installs FOR ALL owner policies with BOTH USING and WITH CHECK so a client
-- can neither read nor INSERT rows it does not own. Replaces the pre-existing
-- USING-only "owner access" policies on programs and set_logs (which had no
-- WITH CHECK, so they could not constrain writes). Also replaces the
-- gym_profiles "anon full access" USING(true) policy with a real owner policy.
--
-- No GRANT changes: with auth.uid()-keyed policies the anon role (NULL uid)
-- matches no rows, so the existing anon grants are inert under RLS. Edge
-- Functions connect as postgres (BYPASSRLS) and enforce ownership via the
-- slice-4 JWT check, so they are unaffected.
--
-- Idempotent: ENABLE ROW LEVEL SECURITY is a no-op if already on, and every
-- CREATE POLICY is preceded by DROP POLICY IF EXISTS.


-- 1. Enable RLS on the five tables currently missing it.

ALTER TABLE "public"."workout_sessions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."programs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."trainee_models" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."set_logs" ENABLE ROW LEVEL SECURITY;


-- 2. Owner-scoped FOR ALL policies (USING + WITH CHECK).

DROP POLICY IF EXISTS "workout_sessions: owner access" ON "public"."workout_sessions";
CREATE POLICY "workout_sessions: owner access" ON "public"."workout_sessions" FOR ALL USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

-- programs had a pre-existing USING-only "programs: owner access" policy; replace it.
DROP POLICY IF EXISTS "programs: owner access" ON "public"."programs";
CREATE POLICY "programs: owner access" ON "public"."programs" FOR ALL USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

DROP POLICY IF EXISTS "trainee_models: owner access" ON "public"."trainee_models";
CREATE POLICY "trainee_models: owner access" ON "public"."trainee_models" FOR ALL USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

-- users is keyed on its PK (no user_id column; id IS the user id).
DROP POLICY IF EXISTS "users: owner access" ON "public"."users";
CREATE POLICY "users: owner access" ON "public"."users" FOR ALL USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));

-- set_logs has no user_id; ownership is via session_id -> workout_sessions.user_id.
-- Replace the pre-existing USING-only "set_logs: owner access" subquery policy,
-- keeping the subquery shape and adding the matching WITH CHECK.
DROP POLICY IF EXISTS "set_logs: owner access" ON "public"."set_logs";
CREATE POLICY "set_logs: owner access" ON "public"."set_logs" FOR ALL USING (("session_id" IN ( SELECT "workout_sessions"."id"
   FROM "public"."workout_sessions"
  WHERE ("workout_sessions"."user_id" = "auth"."uid"())))) WITH CHECK (("session_id" IN ( SELECT "workout_sessions"."id"
   FROM "public"."workout_sessions"
  WHERE ("workout_sessions"."user_id" = "auth"."uid"()))));


-- 3. Fix gym_profiles: replace the "anon full access" USING(true) policy with a
--    real owner policy. (gym_profiles already has RLS enabled in the baseline.)

DROP POLICY IF EXISTS "anon full access" ON "public"."gym_profiles";
CREATE POLICY "owner access" ON "public"."gym_profiles" FOR ALL USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));
