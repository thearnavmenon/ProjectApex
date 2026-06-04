-- Reverse migration: docs/migrations/down/20260604061428_add_deactivate_and_insert_program_rpc.sql
-- (documentation only; not auto-applied by `supabase db push`)
--
-- #189: the iOS regen-persist sequence was a non-transactional client-side
-- PATCH-then-POST — deactivatePrograms() (set every program is_active=false)
-- followed by insert() of the new active program. If the PATCH succeeded but
-- the POST failed (network blip, validation, FK), the user was left with zero
-- active programs and fetchActiveProgram() returned nil: a hidden state-loss
-- path (the historical run of inactive programs in the alpha user's DB is the
-- footprint of this bug firing).
--
-- This adds a single server-side function that performs the deactivate + the
-- new-program write in ONE transaction (a plpgsql function body is one
-- transaction), so a partial failure can no longer strand the user with no
-- active program. The write is an UPSERT on the client-generated primary key
-- (programs.id = the local Mesocycle.id, per #181), which makes a client retry
-- idempotent: re-running the call converges on exactly one active program
-- regardless of how far a previous attempt got.
--
-- The function returns the persisted program id (needed for #181 stale-id
-- reconciliation between the local mesocycle and the programs row).
--
-- SECURITY INVOKER (the default — stated explicitly here): the function runs as
-- the calling user, so the existing "programs: owner access" RLS policy
-- (user_id = auth.uid()) applies to both the UPDATE and the INSERT/UPSERT
-- exactly as it does for the direct PATCH/POST this replaces. No privilege
-- escalation; an authenticated user can still only touch their own rows.

CREATE OR REPLACE FUNCTION public.deactivate_and_insert_program(
    p_user_id uuid,
    p_program_id uuid,
    p_mesocycle_json jsonb,
    p_weeks integer
) RETURNS TABLE (program_id uuid)
    LANGUAGE plpgsql
    SECURITY INVOKER
    SET search_path = ''
    AS $$
DECLARE
    v_program_id uuid;
BEGIN
    -- 1. Deactivate the user's currently-active program(s).
    UPDATE public.programs
       SET is_active = false
     WHERE user_id = p_user_id
       AND is_active = true;

    -- 2. Upsert the new program as active. ON CONFLICT (id) makes a retry
    --    idempotent — if a prior attempt already inserted this id, re-running
    --    just re-activates and refreshes it instead of erroring on the PK.
    INSERT INTO public.programs (id, user_id, mesocycle_json, weeks, is_active)
    VALUES (p_program_id, p_user_id, p_mesocycle_json, p_weeks, true)
    ON CONFLICT (id) DO UPDATE
        SET user_id        = excluded.user_id,
            mesocycle_json = excluded.mesocycle_json,
            weeks          = excluded.weeks,
            is_active      = true
    RETURNING id INTO v_program_id;

    -- 3. Return the persisted id as a single-row result set (RETURNS TABLE).
    RETURN QUERY SELECT v_program_id;
END;
$$;

ALTER FUNCTION public.deactivate_and_insert_program(uuid, uuid, jsonb, integer) OWNER TO postgres;

GRANT ALL ON FUNCTION public.deactivate_and_insert_program(uuid, uuid, jsonb, integer) TO anon;
GRANT ALL ON FUNCTION public.deactivate_and_insert_program(uuid, uuid, jsonb, integer) TO authenticated;
GRANT ALL ON FUNCTION public.deactivate_and_insert_program(uuid, uuid, jsonb, integer) TO service_role;
