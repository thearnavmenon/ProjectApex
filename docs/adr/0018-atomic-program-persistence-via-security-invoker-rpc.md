# Atomic program persistence via a SECURITY INVOKER RPC

**Status**: accepted, 2026-06-04

> **Partial supersession note (2026-06-12):** This ADR stated that the `SECURITY INVOKER` RPC means "the existing 'programs: owner access' policy … governs both the UPDATE and the INSERT/UPSERT." That claim assumed RLS was enabled on `programs` — it was not. [ADR-0027](0027-supabase-anon-auth-and-enforced-rls.md) (accepted 2026-06-12) enabled RLS on `programs` (and the other core tables), so the statement is now true. The atomicity rationale, idempotency design, and `SECURITY INVOKER` choice documented here are unaffected.

## Context

Persisting a (re)generated program to Supabase was a two-step, non-transactional
client-side sequence in `ProgramViewModel.persistProgram`:

```swift
try await client.deactivatePrograms(userId:)     // PATCH every program → is_active=false
try await client.insert(row, table: "programs")   // POST the new active program
```

The two calls are independent network round-trips with no shared transaction. If
the PATCH succeeded but the POST failed (network blip, validation, FK, app
backgrounded mid-sequence), the user was left with **all programs `is_active=false`
and no new active program**. `fetchActiveProgram()` then returns `nil` and the
user appears, server-side, to have no program at all. The historical run of
inactive-only program rows in the alpha user's DB is the footprint of this
partial-failure path firing (#189).

Issue #189 listed three candidate fixes: (1) reverse the order (insert first,
deactivate after — leaves a transient two-active-programs window resolved
client-side by `created_at`), (2) a server-side transactional RPC, (3) an atomic
upsert. The reverse-order option still has a non-atomic window and needs an
upsert anyway for retry idempotency. The decision was the RPC.

This sits under ADR-0016 (client cannot bypass RLS): the operation must remain
subject to Row Level Security, so the RPC is **not** a service-role escalation —
it is a `SECURITY INVOKER` function that runs as the calling user.

## Decision

**Multi-step program persistence is performed by a single server-side
`SECURITY INVOKER` RPC, `public.deactivate_and_insert_program`, that does the
deactivate and the new-program write in one transaction and returns the persisted
program id.**

Migration `supabase/migrations/20260604061428_add_deactivate_and_insert_program_rpc.sql`:

```sql
public.deactivate_and_insert_program(p_user_id uuid, p_program_id uuid,
                                     p_mesocycle_json jsonb, p_weeks integer)
  RETURNS TABLE (program_id uuid)
  LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
```

Key properties:

- **Atomic.** A plpgsql function body executes in one transaction, so the
  `UPDATE … SET is_active=false` and the new-program write either both commit or
  neither does. The zero-active-program window is structurally impossible.
- **Idempotent on retry.** The write is `INSERT … ON CONFLICT (id) DO UPDATE … SET
  is_active=true` on the **client-generated** primary key (`programs.id` =
  local `Mesocycle.id`, per ADR/issue #181/#183). A retry — even after a prior
  attempt partially or fully succeeded — converges on exactly one active program.
- **RLS-preserving.** `SECURITY INVOKER` means the function runs as the caller, so
  the existing `"programs: owner access"` policy (`user_id = auth.uid()`) governs
  both the UPDATE and the INSERT/UPSERT exactly as it did the direct PATCH/POST.
  No privilege change; an authenticated user can still only touch their own rows.
  Consistent with ADR-0016.
- **Returns the id** for #181 stale-id reconciliation between the local mesocycle
  and the `programs` row.

`SupabaseClient.deactivateAndInsertProgram(_:userId:)` calls it via the existing
`rpc()` helper; `persistProgram` makes that one call.

### Why plpgsql, not a single multi-CTE statement

A tempting one-statement form —
`WITH deactivated AS (UPDATE …), upserted AS (INSERT … ON CONFLICT DO UPDATE …) SELECT …` —
is **wrong** on the retry case: when the program id already exists and is active,
the `deactivated` UPDATE and the `upserted` ON CONFLICT DO UPDATE both modify the
same row in a single statement, which PostgreSQL forbids ("tuple already modified
by an operation triggered by the current command"). plpgsql's sequential
UPDATE-then-INSERT runs them as separate statements, so the INSERT sees the
UPDATE's effect — correct and retry-safe.

### When to reach for an RPC vs. a client-side sequence vs. an Edge Function

- **Single-row, single-statement** writes stay on the client (anon-key,
  RLS-subject) — the existing `insert`/`update`/`deactivatePrograms` primitives.
- **Multi-step writes that must be atomic** and that the *user is allowed to
  perform under RLS* use a `SECURITY INVOKER` RPC like this one.
- **Operations that require privileges the user does not have under RLS** belong
  in an Edge Function with `SUPABASE_SERVICE_ROLE_KEY` server-side (ADR-0016,
  `docs/agents/edge-functions.md`) — never a client-side service-role path.

## Consequences

- The partial-failure state-loss path in regen-persist is eliminated.
- A new server-side surface (a callable RPC) now exists. It deploys via
  `supabase db push` on merge to `main` (the "Deploy to linked Supabase" job),
  with a documentation-only reverse migration at
  `docs/migrations/down/20260604061428_add_deactivate_and_insert_program_rpc.sql`.
- `SupabaseClient.deactivatePrograms(userId:)` is no longer called in production
  (its only caller now uses the RPC). It was retained — it has direct test
  coverage and is a reasonable standalone primitive — rather than deleted, to
  keep this change surgical.
- The iOS behavior change ships via an app build, **decoupled** from the migration
  deploy: after the deploy the function simply exists until a client build calls
  it, so the migration is safe to land ahead of the client.

## Supersedes / supersedes-by

Supersedes the pre-#189 non-transactional client-side `deactivatePrograms()`-then-
`insert()` program-persist sequence. Partially superseded by [ADR-0027](0027-supabase-anon-auth-and-enforced-rls.md): the "programs owner policy governs both operations" claim is now correct (RLS enabled on `programs`); the atomicity and idempotency design stands.
