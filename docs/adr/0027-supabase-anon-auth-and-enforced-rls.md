# Supabase anonymous auth + enforced RLS as the identity and access foundation

**Status**: accepted, 2026-06-12

**Relates to**: [ADR-0016](0016-client-cannot-bypass-rls.md) (client cannot bypass RLS — this ADR completes the story by actually turning RLS on), [ADR-0018](0018-atomic-program-persistence-via-security-invoker-rpc.md) (SECURITY INVOKER RPC — its "RLS governs both operations" claim assumed enforcement that this ADR enables).

## Context

### The audit finding (#369)

A security audit of the alpha Supabase setup found four compounding problems:

1. **RLS was off on the five core tables.** `workout_sessions`, `programs`, `trainee_models`, `users`, and `set_logs` all had `ENABLE ROW LEVEL SECURITY` missing. The owner policies that had been authored on `programs` and `set_logs` existed as SQL objects but were completely inert — the database ignored them because RLS was not enabled on those tables.

2. **The iOS client was `anon` with no real identity.** `SupabaseClient` never called `auth.signIn` of any kind. `resolvedUserId` was either read from the keychain (a locally-generated UUID written at first launch) or, during onboarding, taken from the body of the Edge Function response. The client connected as the `anon` role with `auth.uid()` always returning `NULL`. With RLS off, writes from any client reached any row.

3. **`gym_profiles` had an "anon full access" policy.** `gym_profiles` *did* have RLS enabled, but its sole policy was `USING(true)` — every row was readable and writable by any connection, including unauthenticated ones. This was the inverse of the intended posture.

4. **Both Edge Functions were an IDOR.** The `update-trainee-model` and `update-trainee-goal` functions connected via `SUPABASE_DB_URL` (the `postgres` role, which has `BYPASSRLS`), so RLS could not protect the EF write path even in principle. But the functions also trusted the `user_id` field in the request body without verifying the caller's identity — an arbitrary caller could supply any UUID and operate on another user's data.

### Why this mattered for ADR-0016 and ADR-0018

ADR-0016 ("client cannot bypass RLS") was authored to prohibit a client-side service-role key and to codify that "all client database access … is subject to RLS." That invariant was false in practice: RLS was off on the core tables, so there was nothing to bypass or to be subject to. ADR-0016 documented an intention, not a reality.

ADR-0018 ("atomic program persistence via SECURITY INVOKER RPC") stated that the `SECURITY INVOKER` property means "the existing 'programs: owner access' policy … governs both the UPDATE and the INSERT/UPSERT exactly as it did the direct PATCH/POST." That claim was also false: `programs` had RLS off at the time, so the policy governed nothing.

Both ADRs remain accurate about everything they *do* govern (the service-role prohibition; the atomicity rationale; the idempotency design). Their "RLS is enforcing" assumption held only after this ADR actually enabled RLS on the core tables. A supersession note is added to both.

### Alpha posture constraint

Project Apex is in alpha with a single-cohort of known users and no user-facing account system. Creating a full credentialed auth flow (email/password, OAuth) was not acceptable: it breaks the frictionless no-account posture and requires onboarding UX changes that are out of scope.

## Decision

Three changes shipped together as the auth/RLS workstream (#369), across six slices:

### 1. Supabase anonymous sign-in as the identity source (slices 1–3: PRs #372, #373, #382)

Every fresh install now calls `auth.signInAnonymously()` at launch. Supabase's anonymous sign-in provider issues a real JWT with a stable `sub` (= `auth.uid()`). This gives every device a real, persistent identity without any sign-in UI or account creation step — the no-account alpha posture is preserved.

`resolvedUserId` throughout the app is now `auth.uid()` sourced from the live session, not a locally-generated UUID from the keychain. Onboarding writes `users.id = auth.uid()` (not a placeholder). The bundled anon key (`SUPABASE_ANON_KEY`, a non-secret publishable key) ships in the app binary and is the only credential the client holds; it is safe under RLS because all policies key on `auth.uid()`, and an anon-role connection with no session has `uid() = NULL` which matches no rows.

The Anonymous provider was enabled on the live Supabase project and verified end-to-end.

### 2. Enforced RLS with owner policies on all six tables (slice 5: PR #386, migration `20260612020101_enable_rls_owner_policies.sql`)

The migration:

- Enables RLS (`ALTER TABLE … ENABLE ROW LEVEL SECURITY`) on the five previously unprotected tables: `workout_sessions`, `programs`, `trainee_models`, `users`, `set_logs`.
- Installs `FOR ALL … USING(user_id = auth.uid()) WITH CHECK(user_id = auth.uid())` owner policies on `workout_sessions`, `programs`, `trainee_models`, and `gym_profiles` — both the read predicate (USING) and the write predicate (WITH CHECK), so a client can neither query nor insert rows it does not own.
- The `users` table is keyed on its primary key (`id`), not a separate `user_id` column; its policy is `USING(id = auth.uid()) WITH CHECK(id = auth.uid())`.
- `set_logs` has no direct owner column; ownership is via `session_id → workout_sessions.user_id`. Its policy is a subquery: `USING(session_id IN (SELECT id FROM workout_sessions WHERE user_id = auth.uid()))` with a matching `WITH CHECK`.
- Replaces the `gym_profiles` "anon full access" `USING(true)` policy with the same owner pattern.
- Replaces the pre-existing USING-only `programs` and `set_logs` policies (which had no `WITH CHECK` and therefore could not constrain writes) with the full USING+WITH CHECK form.

After the migration, per-user isolation is enforced in one declarative place that every reader of the schema can audit. An `anon` connection with `auth.uid() = NULL` matches no rows on any table.

### 3. Edge Function JWT ownership check as the EF access gate (slice 4: PR #385, `supabase/functions/_shared/jwt-owner.ts`)

The Edge Functions connect as `postgres` (`SUPABASE_DB_URL`), which is `BYPASSRLS`. RLS cannot protect the EF write path. The JWT check is therefore the EF's access gate.

`checkOwnership(req, bodyUserId)` in `jwt-owner.ts` decodes (does not re-verify — the Supabase platform has already verified the JWT signature for functions with verify-jwt ON) the `Bearer` token from the `Authorization` header to extract the `sub` claim. It then asserts `sub == bodyUserId`. A mismatch yields 403; a missing or malformed token yields 401. Both functions were updated to call `checkOwnership` before any database write. This closes the IDOR.

### Accepted: alpha data-wipe

Rows written before the workstream shipped carry the old locally-generated placeholder UUIDs as their `user_id` values. These rows are still in the database but are invisible to real sessions (their `user_id != auth.uid()`). Backfilling — matching placeholder UUIDs to real `auth.uid()` values — is not feasible at alpha cohort scale without an operator-side mapping, which does not exist. The data-wipe was accepted explicitly.

## Alternatives considered

**Credentialed authentication (email/password or OAuth)**. Rejected: breaks the no-account alpha posture; requires additional onboarding UX; deferrable to public launch.

**Backfilling existing rows to real `auth.uid()` values**. Rejected: requires a UUID mapping between locally-generated IDs and real Supabase auth UIDs; that mapping was never stored; an operator-level migration with no reliable source key is not feasible at alpha scale.

**Relying on RLS for the Edge Function path**. Impossible by construction: the Edge Functions use `SUPABASE_DB_URL` (the `postgres` role), which has `BYPASSRLS`. No RLS policy can constrain a `postgres`-role connection. The JWT check is therefore a structural necessity, not a belt-and-suspenders addition.

**No anonymous auth — keep the keychain UUID, just enable RLS**. Rejected: `auth.uid()` would still be `NULL` (no auth session), so all owner policies would match no rows and the client would be unable to read or write its own data. RLS enforcement requires a real session.

## Consequences

- **Per-user isolation is now enforced.** Every client DB read and write goes through an `auth.uid()`-keyed policy. A client can only see and only write its own rows.
- **Fresh installs ship the bundled anon key and auto sign in.** The anon key is a non-secret publishable credential; it is safe to bundle. The anonymous sign-in happens silently at launch; there is no account-creation UI.
- **Placeholder-keyed rows are invisible.** Existing alpha data written before the workstream is unreachable to real sessions. This is the accepted data-wipe.
- **Edge Function path is protected by the JWT check, not by RLS.** RLS and the JWT check are complementary: RLS protects the client path; the JWT check protects the EF path. Neither alone covers both paths.
- **Rate-limited anon signups.** Supabase rate-limits anonymous sign-in by IP. At alpha scale this is not a concern; before public launch, a CAPTCHA or anonymous-to-credentialed migration flow should be considered.
- **Pre-public-launch follow-up: rotate the anon key and add CAPTCHA.** The bundled anon key should be rotated when the app transitions out of alpha. Anonymous users should be offered an upgrade path to a credentialed account to survive re-installs. These are deferred; they do not affect the current security posture, which is correct for alpha.

## Shipped as

- PR #372 — slice 1: anonymous sign-in session (`auth.signInAnonymously()`, session persistence)
- PR #373 — slice 2: bundle anon key + launch gate; closes #329
- PR #382 — slice 3: repoint `resolvedUserId` → `auth.uid()`; onboarding writes `users.id = auth.uid()`
- PR #385 — slice 4: Edge Function JWT `sub == body.user_id` ownership check (closes the IDOR)
- PR #386 — slice 5: RLS migration `20260612020101_enable_rls_owner_policies.sql` (the gate-flip)
- PR #387 — smoke-test fix that unblocked the deploy
- Foundation: PR #368 (bundled Anthropic key + setup gate)

## Supersedes / supersedes-by

Supersedes the pre-#369 posture: RLS off on core tables; client identity from a keychain-generated UUID; Edge Functions trusting the request body `user_id` without JWT verification; `gym_profiles` "anon full access" policy. Partially supersedes the "RLS is enforcing" assumption in [ADR-0016](0016-client-cannot-bypass-rls.md) and [ADR-0018](0018-atomic-program-persistence-via-security-invoker-rpc.md) — see supersession notes on those ADRs. Not yet superseded.
