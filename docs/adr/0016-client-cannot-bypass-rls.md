# Client cannot bypass RLS

**Status**: accepted, 2026-06-01

> **Partial supersession note (2026-06-12):** This ADR stated that "all client database access … is subject to RLS." That invariant was not in force at the time of writing — RLS was off on the five core tables (`workout_sessions`, `programs`, `trainee_models`, `users`, `set_logs`), so there was nothing to be subject to. [ADR-0027](0027-supabase-anon-auth-and-enforced-rls.md) (accepted 2026-06-12) actually enabled RLS on those tables and established the anonymous-auth identity that makes `auth.uid()` non-NULL. The client-side service-role prohibition documented here is unaffected; only the "RLS is already enforcing" assumption was premature.

## Context

Until PR #206 (issue #191), the iOS client carried a code path for the Supabase **service-role key** — a credential that bypasses Row Level Security and grants unrestricted read/write across every table. The path was an artifact of MVP-era developer ergonomics: it let the app stand in for back-end work that had not yet been migrated to Edge Functions. The risks are well known:

- A leaked client binary leaks the service-role key. Anyone who extracts it can read or mutate any row, ignoring RLS.
- Any client code path that uses the service-role key tacitly opts the user out of every RLS policy authored for that table, defeating the policy's intent.
- The presence of two clients (anon-key client subject to RLS, service-role client bypassing it) makes the security posture of any given operation locally-determined and non-obvious to readers — a reviewer must trace which client is in use before reasoning about access.

PR #206 deleted the client-side service-role path entirely across five layers (`SupabaseClient` field + accessor, `AppDependencies` wiring, `DeveloperSettingsView` UI, `KeychainKey` enum case, and the dead-data keychain entry on already-installed devices). The cross-cutting grep confirmed that all remaining `service.role` hits in the repository are either (a) Edge Function code that legitimately uses `SUPABASE_SERVICE_ROLE_KEY` server-side, or (b) historical references in `docs/`.

This ADR codifies the now-implicit invariant — "iOS client cannot bypass RLS" — so that future contributors don't reintroduce a client-side service-role path under the same MVP-ergonomics pressure that originally produced it.

## Decision

**The iOS client MUST NOT possess, read, or transmit the Supabase service-role key.** All client database access goes through the anon-key client and is subject to RLS. Operations that require service-role privileges live in Edge Functions, which read `SUPABASE_SERVICE_ROLE_KEY` server-side per `docs/agents/edge-functions.md`.

Concretely, this prohibits:

1. Storing the service-role key in the keychain, `UserDefaults`, environment, build settings, or any other client-readable surface.
2. Constructing a Supabase client in app code with anything other than the anon key.
3. Adding a Developer Settings UI affordance to paste, view, or persist a service-role key.
4. Adding a code path that conditionally swaps in the service-role key (e.g., for "developer mode," "debug builds," or "alpha cohort").
5. Logging, telemetry, or crash-reporting paths that could egress a service-role key.

The exception is Edge Functions and other server-side surfaces (CI scripts, one-off operator commands run from a trusted host) — those legitimately use the service-role key per `docs/agents/edge-functions.md`.

### Why client-side service-role access is never acceptable

The service-role key is, by design, an RLS bypass. The justification for RLS — that policy logic should live in one declarative place that every reader of the schema can audit, rather than scattered across procedural call sites — is undermined the moment any client can opt out of it. There is no shape of "but only for this one operation" that survives the threat model: a binary that ever contained the key, ever decrypted it, or ever issued a request bearing it has leaked it. Mitigations like "obfuscate at build time" or "fetch on demand from a gated endpoint" do not change the leak surface; they only change the recovery cost for an attacker.

If an operation cannot be expressed under RLS, the right move is to (a) write an Edge Function that performs the operation server-side and applies its own authorization, or (b) revise the RLS policy to cover the case. The wrong move is to give the client the bypass key.

### Why this ADR exists separately from `docs/agents/edge-functions.md`

`docs/agents/edge-functions.md` is the authoritative reference for *Edge Function secret storage* — where `SUPABASE_SERVICE_ROLE_KEY` lives, who can read it, how it rotates. It documents the server side of the boundary. This ADR documents the *client-side prohibition* — the invariant that the boundary exists at all. Splitting the documents reflects the split in the responsibility: the EF doc tells operators how to handle the secret on the trusted side; this ADR tells contributors why the secret cannot cross to the untrusted side.

## Consequences

- Any future PR that reintroduces a `serviceKey` field, keychain entry, or client constructor variant taking a service-role key is in violation of this ADR and should be rejected at review.
- New operations that need service-role privileges add an Edge Function rather than reaching for the bypass. This raises the floor on what "shipping a feature" costs; it is the floor we are committing to.
- Cross-cutting greps for `service.role`, `serviceKey`, `SUPABASE_SERVICE_ROLE_KEY` in iOS code (`*.swift` under `ProjectApex/`) should return zero hits. Hits in `supabase/functions/` and `docs/` are expected.

## Supersedes / supersedes-by

Supersedes the MVP-era practice (pre-PR #206) of carrying a client-side service-role path in `SupabaseClient`, `AppDependencies`, and `DeveloperSettingsView`. Partially superseded by [ADR-0027](0027-supabase-anon-auth-and-enforced-rls.md): the "RLS is enforcing" assumption is now correct (RLS enabled on core tables); the service-role prohibition itself stands.
