# Account linking via Sign in with Apple (anonymous → permanent, uid-preserving)

**Status**: accepted, 2026-07-03

**Relates to**: [ADR-0027](0027-supabase-anon-auth-and-enforced-rls.md) (amends — ships the anonymous→credentialed upgrade path ADR-0027 explicitly deferred; every invariant there is preserved unchanged).

## Context

ADR-0027 made the anonymous GoTrue session the app's identity: every install mints a real `auth.uid()` at launch, all six core tables carry `auth.uid()`-keyed RLS owner policies, and the Edge Functions gate on the JWT `sub`. It also named its own gap: the identity is bound to **one device install**. The session tokens are Keychain-persisted with `ThisDeviceOnly` accessibility, so a lost, reset, or upgraded phone — even a normal iPhone backup/restore — orphans the user's entire training history. ADR-0027's consequences section deferred the fix: *"Anonymous users should be offered an upgrade path to a credentialed account to survive re-installs."*

This was the app's top table-stakes gap. The product decisions (locked before implementation): **Sign in with Apple only** (no email/password/Google in v1) and **required at onboarding** (anonymous sign-in still runs silently at launch to mint the uid and JWT; the Apple step anchors that uid).

### The non-negotiable correctness property

After Apple authentication, the resulting session's `user.id` **must equal** the pre-existing anonymous `auth.uid()`. Same uid ⇒ every RLS policy and the EF `sub`-ownership check keep matching the user's existing rows ⇒ zero data migration, zero orphaning. A uid mismatch on link is a hard failure.

### The verified linking mechanism (Step-0 spike, 2026-07-03)

The naive REST recipe — pass the anonymous user's `Authorization: Bearer` on `POST /auth/v1/token?grant_type=id_token` — **does not link**. GoTrue ignores a bare Bearer on that grant and signs in / creates a **separate** user (the uid-changing trap). Verified from the supabase/auth source (`internal/api/token_oidc.go`, `IdTokenGrant`): the handler only reads the Authorization header when the request body carries **`"link_identity": true`**; with that flag it calls `linkIdentityToUser`, which attaches the Apple identity to the calling user, **preserves `user.id`**, and flips `is_anonymous` to `false`.

Facts that anchor the decision, each verified against the live project or the source:

- The feature shipped in supabase/auth **v2.179.0** (PR supabase/auth#2108, 2025-08-28). The live project runs **v2.192.0** (probed via `GET /auth/v1/health`).
- Live probe: `link_identity: true` with **no** Bearer → `"Linking requires a valid user access token in Authorization"` — the deployed binary executes the linking branch.
- Live probe: `link_identity: true` **with** an anon Bearer → fails only at `provider_disabled` — the sole remaining gate is enabling the Apple provider (owner config; see Consequences).
- The native id_token linking path is **not** gated by the dashboard "manual linking" toggle (that toggle only guards the OAuth-redirect `/user/identities` routes, which probe 404 `manual_linking_disabled` on this project — irrelevant here).
- Nonce contract: Apple's `ASAuthorization` request carries `SHA256(rawNonce)`; the GoTrue exchange carries the **raw** nonce, which the server hashes to compare with the id_token's `nonce` claim (source-confirmed).
- Returning user: if the Apple identity already belongs to another uid, the link attempt returns **422 `identity_already_exists`** — an explicit, discriminable fork, not an ambiguous success.

## Decision

1. **`SupabaseAuth.signInWithApple(idToken:rawNonce:)`** (the hand-rolled GoTrue client, per ADR-0027's no-SPM posture) implements the exchange:
   - *Link path* (a current session exists): id_token grant + anon Bearer + `link_identity: true`. On 2xx the response uid must equal the current uid — a mismatch throws `appleLinkUidMismatch` and the mismatched session is **never adopted** (the uid-parity invariant, enforced in code and tests).
   - *Returning-user path*: on 422 `identity_already_exists`, fall back to a plain id_token sign-in, which adopts the existing Apple-bound uid. The session swap is persisted including `.supabaseAuthUserId`, so `UserIdentityResolver` re-resolves to the recovered uid.
   - *No-session path*: a launch whose anonymous sign-in failed can still sign in with Apple directly (recovery is never blocked by the anon path being down).
   - Degradation contract preserved: any failure leaves the anonymous session and Keychain untouched; token values are never logged.

2. **Required onboarding step** (`.appleSignIn`, between the intro cards and the profile questions): the system `SignInWithAppleButton`, no skip. After the exchange, routing is deterministic: a link continues onboarding; a swap enters the app directly **iff** the recovered uid has an active program (RLS-scoped existence check), hydrating the gym profile and `users`-row biometrics from the server — the program itself loads through the existing `ProgramViewModel` network path. A swap without a program re-onboards under the recovered uid.

3. **Backfill gate for existing installs**: an install already past onboarding with no Apple-anchored identity is prompted on launch (server-truth check via `GET /auth/v1/user` → `identities` / `is_anonymous`; fail-open — no session or a failed check skips the gate that launch). The prompt is skippable ("Not now" re-arms next launch); linking preserves the install's current uid, which is what makes the *current* alpha users' data durable, not just future users'.

4. **No schema, RLS, or Edge Function change.** uid preservation is the entire trick: every `auth.uid()`-keyed policy and the EF `sub == body.user_id` gate keep working untouched. GoTrue owns `auth.identities`; the Apple-provided email is adopted onto `auth.users` server-side by `linkIdentityToUser`. Nothing Apple-related is stored on `public.users` — no migration.

## Alternatives considered

**Email/password accounts.** Rejected: breaks the near-zero-friction posture; adds credential UX, reset flows, and a password to forget. One tap on the sheet is the entire cost of SiWA.

**OAuth-redirect identity linking (`GET /user/identities/authorize`).** Rejected: requires the dashboard manual-linking toggle (off, and beta), a browser round-trip, and does not use the native Apple sheet. The native id_token variant *is* the `link_identity` flag on the token grant.

**Email-attach conversion (`PUT /auth/v1/user` with the Apple relay email).** The designated last-resort fallback; not needed — the deployed GoTrue supports native id_token linking. Would have changed the UX (verification email round-trip) and was gated behind an explicit stop-and-report.

**Keychain accessibility migration (drop `ThisDeviceOnly`).** Rejected: letting tokens ride device backups is a weaker security posture and still doesn't survive a lost phone without a backup. With the Apple ID as the recovery anchor, `ThisDeviceOnly` is now *correct*: on a new device, re-auth reconstructs a session for the same uid; the Keychain never needs to migrate.

## Consequences

- **Recovery works end-to-end**: fresh install → silent anonymous launch → Sign in with Apple → 422 fork → same uid recovered → RLS-scoped data intact, onboarding skipped. Acceptance criteria 1–5 of the campaign (#595) are covered by unit tests; the live round-trip is owner-gated (below).
- **OWNER-BLOCKED live verification**: the Apple provider is not yet enabled (probed `external.apple: false`). Prerequisites (tracked on #595): Apple Developer portal capability + Services ID/key; Supabase Apple provider enablement with the app's bundle id in Client IDs; device provisioning profile. Until then the Apple exchange fails at `provider_disabled` and the app degrades to the anon path — launch is never bricked. An `APEX_INTEGRATION_TESTS=1`-gated live probe ships with Slice A; full uid-parity is then confirmed on-device.
- **Orphaned anon rows on the returning-user path**: the abandoned throwaway anon uid's (empty) rows stay in the database, invisible to real sessions — the same accepted posture as ADR-0027's data-wipe.
- **Two-device edge**: if an install's Apple ID already anchors a different uid, the swap recovers that uid and this device's local caches are cleared to reload under it; the device's previous anon-uid server rows become unreachable. Accepted and documented at alpha scale.
- **"Reset all data" semantics shift honestly**: the reset dialog already says *"on this device"* — after a reset, re-onboarding with the same Apple ID recovers the old uid and its server history via the 422 fork. A true server-side erase is account deletion, explicitly out of scope for v1.
- **Captcha note for the future**: the id_token grant passes through GoTrue's `verifyCaptcha`. If Auth captcha is ever enabled (an ADR-0027 pre-launch follow-up), the exchange body must also carry `gotrue_meta_security.captcha_token`.

## Shipped as

- PR #602 — Slice A: `signInWithApple` linking core + uid-parity invariant + tests (closes #596)
- PR #603 — Slice B: required onboarding step + returning-user routing + entitlement (closes #597)
- PR #604 — Slice C: backfill link gate for existing installs (closes #598)
- Umbrella: #595 (owner prerequisites + Step-0 probe evidence)

## Supersedes / supersedes-by

Amends [ADR-0027](0027-supabase-anon-auth-and-enforced-rls.md): the deferred "upgrade path to a credentialed account" follow-up is shipped; ADR-0027's identity, RLS, and EF-gate decisions are all unchanged and remain authoritative. Not superseded.
