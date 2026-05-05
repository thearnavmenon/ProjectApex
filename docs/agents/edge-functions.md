# Edge Functions: secrets, access, rotation

How Edge Function secrets are stored, who holds the keys that bypass RLS, and when and how those keys rotate. Slice 9b and downstream Edge Function work follow this doc; material deviations get a new ADR.

Scale baseline: solo developer, alpha cohort of 3–5 friends (P-B), pre-multi-user. Policies are sized for that scale and explicitly *not* enterprise-grade.

## Decisions

### 1. Secret storage — Supabase Edge Function env vars

Edge Function secrets live in Supabase-managed env vars, set via the Supabase CLI (`supabase secrets set FOO=bar`) and read inside the function via `Deno.env.get("FOO")`. Encrypted at rest by Supabase, scoped to the Edge Function runtime, rotated with one CLI command, no external vendor.

**Rationale.** The secrets the Edge Function needs (eventually `ANTHROPIC_API_KEY`, plus whatever else lands in the Deno runtime) are consumed by the Edge Function itself — put them where the Edge Function reads them. Supabase Vault is the right answer when the *stored procedure* needs a secret (the procedure is currently pure compute, no external calls). External managers (Doppler, 1Password CLI, AWS Secrets Manager) are overkill at this scale and add a cold-start fetch hop. Vault and external managers are not foreclosed: when a future slice needs Postgres-side secrets, that specific secret moves to Vault and the two mechanisms coexist.

**Addenda.**

- `SUPABASE_SERVICE_ROLE_KEY` is **platform-injected** in deployed Edge Functions — do not `supabase secrets set` it. For local `supabase functions serve` development, set it explicitly in `supabase/.env` (or whichever local env file the CLI picks up); the value matches whatever the production service-role key currently is.
- Audit trail: the Supabase dashboard logs secret mutations with timestamp and actor. Coarse (no per-read logging) but adequate at solo scale — there *is* a trail of "when was this key last set."
- `ANTHROPIC_API_KEY` may be set to an empty placeholder during Slice 9b, since 9b's stub does not call Anthropic. The access pattern (`Deno.env.get`) is what 9b commits to; the value lands when the function actually invokes Anthropic.

### 2. Service-role access — solo developer only

The Supabase service-role key is held by the solo developer only. Storage: a password manager entry titled **`ProjectApex — Supabase service-role key`** (1Password / Bitwarden / equivalent). No CI/CD secret. No shared copies. Manual `supabase functions deploy` from the developer's laptop until a future slice explicitly justifies CI deploys.

**Rationale.** The service-role key bypasses RLS — it is the master key that overrides every protection Phase 5's RLS migrations install. At solo + 3–5 friends, deploys are infrequent enough that manual is not a bottleneck. Adding a GitHub Actions secret would expand the attack surface (compromised workflow, malicious dependency, leaked PAT) for a convenience that isn't paying for itself yet. Bus-factor recovery rides on the password manager's own 2FA + recovery codes.

**Addenda.**

- The Supabase CLI uses your separate `supabase login` token for deploys — manual deploys do not require the service-role key on disk at deploy time. The key is only on disk in `supabase/.env` for local `supabase functions serve`.
- Adding CI deploys later is an explicit decision, not a default-on choice. When that slice lands: store the key as a GitHub Actions secret with environment-scoped protection rules, then rotate immediately so the CI copy is born in CI.
- One-time pre-Slice-9b hygiene rotation (see §Rotation playbooks → Service-role) ensures the key in the password manager has clean provenance before the first real deploy.

### 3. Rotation policy — time-based for Anthropic, event-based for service-role

| Secret | Cadence | Triggers | Rollback |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | Every 90 days | Confirmed compromise; plausible exposure; end of alpha | Provision new → `supabase secrets set` → smoke test → revoke old after 24h. Both keys live for the 24h overlap. Reversion = revert env var. |
| Supabase service-role | On-incident only | Confirmed compromise; access-list change (CI added, partner added/removed); end of alpha; one-time pre-Slice-9b hygiene rotation | None. Dashboard rotation invalidates the old key immediately — forward-fix only. Do not rotate near deploy windows or end-of-day. |
| Local `supabase/.env` service-role copy | Inherits upstream | Inherits upstream | Re-read from password manager. |

**Rationale.** 90-day cadence on Anthropic catches the dominant API-key failure mode: silent leaks (force-pushed-but-still-in-pack-files, .env synced to cloud, etc.) where you don't realise the leak happened. Service-role has no overlap window in Supabase's model, so calendar-based rotation introduces breakage risk without compensating value — event-based only, with a high bar for what counts as an event. The paired routine: when rotating Anthropic on the 90-day cadence, also do a 5-minute access-list review (does anyone other than the developer hold service-role today?). Bundles two chores into one.

**Addenda — triggers.**

- **"End of alpha" is concrete**, not vibes-based: the trigger fires the moment the **first non-friend user onboards** — i.e., the first user who is not personally known to the developer. Operational test: would you invite them to dinner? If yes, they're a friend; if no, end-of-alpha has fired and every secret that was live during the friend-only alpha rotates, regardless of suspicion.
- **Plausible exposure** = the key may have transited a clipboard manager, screenshot, screen-share, unsandboxed dev tool, a chat / email thread you did not author, or **an LLM chat (Claude, ChatGPT, Copilot inline, etc.)**. Pasting a key into an LLM context — even for "just debugging this one error" — is exposure regardless of the provider's stated retention policy: prompts may be cached, indexed, used for training under some plans, or surfaced in operator dashboards. Treat any key that has been in an LLM chat as exposed. Lower bar than "confirmed compromise"; higher bar than "I had a bad feeling."
- **Access-list change** for service-role includes both additions (CI added, bus-factor partner added) and removals (partner offboarded, CI deploys retired). New copies start fresh; offboarded copies die with the old key.

**Addenda — non-triggers.** These are explicitly *not* incident-worthy:

- Discovering historical evidence of a key that has **since been rotated**. The leak is dead with the key. A screenshot from 4 months ago of a key rotated 2 months ago is a non-event — do not double-rotate out of anxiety.
- Routine deploys, schema migrations, or new Edge Function additions that consume existing secrets.
- A friend asking "what's your stack" — describing that you use Supabase service-role is not a leak.
- Dependency security advisories (Deno std lib CVEs, Supabase JS client advisories, transitive npm/Deno package CVEs) that do **not** concern credential exposure. A standard RCE, DoS, or prototype-pollution advisory in a transitively-pulled package is a *patch* event, not a *rotation* event. The advisory must explicitly call out credential exfiltration, token leakage, or environment-variable disclosure to qualify as plausible exposure — otherwise upgrade the package and move on.

## Local dev workflow

How to run, deploy, observe, and roll back the Edge Function. Added in Slice 9b (#9). Sister section to §Rotation playbooks: same "executable without rederivation" promise.

**Prerequisites.**

- Supabase CLI: `brew install supabase/tap/supabase` (macOS canonical).
- Authenticated: `supabase login` (one-time, browser-based).
- Linked: `supabase link --project-ref <ref>` (one-time per checkout — get `<ref>` from Dashboard → Project Settings → General → Reference ID; **do not** confuse with `project_id` in `supabase/config.toml`, which is a local-only identifier).
- Local secrets: `supabase/.env` exists with at minimum `SUPABASE_SERVICE_ROLE_KEY=<value>` for `supabase functions serve` to mirror the platform-injected production env (see §Decisions §1 addenda). The file is gitignored at the repo root — never commit it. Created during the §Pre-Slice-9b hygiene rotation.

**Run a function locally.**

1. `supabase start` — boots the local stack (Postgres, Auth, Edge runtime) on the ports declared in `supabase/config.toml`. First run pulls Docker images.
2. `supabase functions serve update-trainee-model --env-file ./supabase/.env` — starts the local Edge runtime for the named function; re-reads source on each request.
3. Function URL: `http://127.0.0.1:54321/functions/v1/update-trainee-model`.

**Smoke test locally.** Get the local anon key from `supabase status`, then:

```bash
curl -i -X POST http://127.0.0.1:54321/functions/v1/update-trainee-model \
  -H "Authorization: Bearer <local-anon-key>" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"00000000-0000-0000-0000-000000000001","session_id":"00000000-0000-0000-0000-000000000002","session_payload":{}}'
```

Expected: `HTTP/1.1 200 OK` and body `{"trainee_model":{}}`.

**Deploy to production.** `supabase functions deploy update-trainee-model`. The CLI uses your `supabase login` token; the service-role key is platform-injected and is not required on disk at deploy time (§Decisions §2 addenda). Default JWT verification stays on — do **not** pass `--no-verify-jwt` for this function (it's invoked from the authenticated client via the WAQ per ADR-0006 §3).

**Smoke test production.** Same curl as local, but against `https://<project-ref>.supabase.co/functions/v1/update-trainee-model` and with the project's anon key (Dashboard → Project Settings → API → `anon` `public`). The Phase 1 stub does not check user identity, so any valid project JWT passes verification.

**View logs.** Two routes; the dashboard is authoritative.

- Dashboard: Edge Functions → `update-trainee-model` → Logs tab. Works regardless of CLI version.
- CLI: `supabase functions logs update-trainee-model`. Verify the exact subcommand and any tail/follow flag against `supabase functions --help` on first use — the CLI surface has shifted across versions.

**Rollback.** No `supabase functions rollback` primitive. The deploy model is forward-only, mirroring the service-role rotation policy (§Decisions §3). To revert a bad deploy:

1. `git revert <bad-commit>` (or `git checkout <last-known-good>` for the function file only).
2. `supabase functions deploy update-trainee-model` again — the just-restored source replaces the broken version.

During the outage window, the WAQ rails (ADR-0006 §3) keep client-side session-completion events in the queue; clients converge once a working version is live. No user-visible error for routine outages.

### Gotchas

<!-- gotchas land here after the rotation drill (Slice 9b acceptance #8) and after the first real deploy. Empty by design — populated empirically, not speculatively. -->

## Rotation playbooks

Executable without rederivation. If you are reading this with no prior context, the steps below are sufficient.

### Anthropic API key

**Prerequisite:** a recurring 90-day calendar reminder titled **"Rotate Anthropic API key"** must exist. If not already set, create it now — the cadence is worthless without a forcing function.

**Concurrent-keys precondition:** the 24-hour overlap window in step 5 below requires Anthropic Console to permit at least two active API keys simultaneously (one new, one old, during the overlap). **Verified satisfied** at console.anthropic.com → Settings → API Keys — Console supports ≥2 concurrent keys, which is the minimum the playbook needs. Exact per-account upper bound not recorded; if a future rotation ever hits a cap, record the observed limit here so subsequent rotations don't bump into it again.

1. console.anthropic.com → API Keys → create new key (label it with today's date, e.g., `apex-edge-2026-08-01`).
2. `supabase secrets set ANTHROPIC_API_KEY=<new value>` (production project).
3. Smoke test the new key directly against Anthropic before trusting it in the function path:

   ```bash
   curl https://api.anthropic.com/v1/messages \
     -H "x-api-key: <new value>" \
     -H "anthropic-version: 2023-06-01" \
     -H "content-type: application/json" \
     -d '{"model":"claude-haiku-4-5-20251001","max_tokens":4,"messages":[{"role":"user","content":"ping"}]}'
   ```

   Confirm HTTP 200 and a non-empty `content` array. Once the Edge Function actually invokes Anthropic (post-Slice-9b integration), additionally hit the function path and confirm 200 + non-empty response — but the curl check above is the minimum and runs identically pre- and post-integration.
4. Set a 24-hour calendar reminder titled **"Revoke old Anthropic key — apex-edge-<previous date>"**.
5. After 24 hours: console.anthropic.com → revoke old key.
6. **If the 24-hour reminder is dismissed, snoozed, or missed**, and you are uncertain whether the old key was revoked: revoke now (in the console) and rotate the *current* key again from step 1. Never leave an unrevoked old key live past the overlap window.

Reversion (if step 3 smoke-test fails): `supabase secrets set ANTHROPIC_API_KEY=<old value>` — the old key is still active during the 24-hour overlap. Investigate the failure before re-attempting rotation.

### Supabase service-role key

No overlap window. Run only during a daylight window where you can debug breakage. Do not run on a Friday afternoon.

**Fan-out checklist** — before rotating, confirm every place the key currently lives so the post-rotation update has no gaps. Items marked `*` may not yet exist pre-Slice-9b; first appearance is during 9b's local-dev setup. **Pre-9b, only the password manager entry is a live location.**

- [ ] Password manager entry **`ProjectApex — Supabase service-role key`**
- [ ] Local `supabase/.env`* (for `supabase functions serve`)
- [ ] (Future, currently N/A) GitHub Actions secret — only relevant after CI deploys are added
- [ ] (Future, currently N/A) any bus-factor partner's password manager — only relevant if Decision #2 is revisited

**Rotation steps:** verify cheap before verify expensive — local first, then production. If local breaks, production is untouched.

1. Supabase Dashboard → Settings → API → rotate `service_role` key.
2. Update the password manager entry **`ProjectApex — Supabase service-role key`** with the new value.
3. Update local `supabase/.env` with the new value.
4. Verify local: restart `supabase functions serve` and hit the endpoint locally; confirm 200.
5. Verify production: `supabase functions deploy <name>` and confirm a deploy and a 200 from a smoke-test invocation. (Production Edge Functions pick up the new platform-injected value automatically — no `supabase secrets set` needed for the service-role key itself.)
6. If anything fails: forward-fix only. There is no reversion path.

### Pre-Slice-9b hygiene rotation

Run once, before Slice 9b's first real deploy, to guarantee clean provenance for the service-role key in the password manager (the auto-generated key from project creation may have transited setup notes, screenshots, or clipboard managers). Use the Supabase service-role playbook above; the fan-out checklist at that point is just the password manager + local `.env`. If `supabase/.env` does not yet exist, create it as part of step 3 — Slice 9b will need it for `supabase functions serve` regardless.

## Out of scope

This doc covers secret storage, access list, and rotation for the Edge Function deployment context. Out of scope:

- Edge Function deployment itself (Slice 9b — issue #9).
- Anthropic API integration / digest assembly logic (downstream of 9b).
- RLS policy design (Phase 5).
- Multi-device or optimistic-concurrency migration paths (deferred to v3+ per ADR-0006).
