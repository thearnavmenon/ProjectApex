# Phase 2 Cleanup Plan — 2026-05-12

## Context

On 2026-05-12 a routine "check my training cycle state before I regenerate my program" inquiry surfaced **four independent gaps** in the Phase 2 trainee-model pipeline, each individually sufficient to keep `trainee_models` empty in production despite all Phase 2 code being merged to `main`:

| # | Gap | Status | Fix |
|---|---|---|---|
| #135 | iOS producer never wired: `TraineeModelService` never instantiated, `enqueueUpdate` had zero callers, `WorkoutSessionManager.finishSession` never enqueued | ✅ Fixed | [PR #137](https://github.com/thearnavmenon/ProjectApex/pull/137) merged commit `3f66e4d` |
| #138 | Edge Function deployed as Phase 1 stub (v1, 2026-05-05) returning `{"trainee_model":{}}`; 1946 lines of Phase 2 logic never deployed | ✅ Fixed | `supabase functions deploy update-trainee-model --project-ref hqjgrlzvrttnyfjqjewe` → v2 ACTIVE since 2026-05-12 03:42:02 UTC |
| #139 | Phase 2 schema migration `20260507210000_phase_2_schema.sql` committed to repo 2026-05-07 but `supabase db push --linked` never run; missing column `trainee_models.last_applied_logged_at` broke deployed v2 on every call | ✅ Fixed | `supabase db push --linked` applied 2026-05-12 |
| #136 | Suspected silent-catch on program inserts; investigated → no live bug, persist path works as designed; the historical orphan `a9a15cd8-...` referenced by 26 sessions is a pre-historical artifact | ✅ Closed as no-bug | [PR #140](https://github.com/thearnavmenon/ProjectApex/pull/140) merged commit `945299d` left diagnostic logger in place |

Plus the alpha user's 19 historical sessions were backfilled into `trainee_models` end-to-end (243 set_logs, 5 patterns populated, 21 exercises with e1RM, watermark at `2026-05-04 11:24:20+00`).

The pipeline is now functional end-to-end. This doc sequences the remaining cleanup.

---

## Tier 1 — Prevent recurrence

The three deployment gaps (#135 / #138 / #139) shared one root cause: **GitHub merge does not auto-run `supabase functions deploy` or `supabase db push`.** Both are manual admin steps. Without addressing this, the next Phase 2 PR can recreate the same shape of bug.

### 1. File: "CI: auto-deploy Edge Functions + migrations on merge to main"

Workflow shape:
- On push to `main` touching `supabase/functions/<name>/**` → run `supabase functions deploy <name>`
- On push to `main` touching `supabase/migrations/**` → run `supabase db push --linked`
- Both gated on the existing `Edge Function Tests (Deno)` + Swift test suites passing

Secrets needed: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, project ref `hqjgrlzvrttnyfjqjewe`.

Pre-flight risk: migrations are forward-only and `supabase db push` does not auto-rollback on failure. Mitigations: (a) `--dry-run` step first, fail the job on diff anomalies; (b) require PR approval for any change touching `supabase/migrations/**`. Note: existing CLAUDE.md migrations workflow already requires the reverse migration to be authored at `docs/migrations/down/<name>.sql` — keep enforcing.

Not yet filed. **Action: file this issue before any other Phase 2 PR ships.**

---

## Tier 2 — Honest accounting

### 2. Correct `docs/phase-2-integration-audit-2026-05-10.md`

The audit's framing "Phase 2 wires end-to-end on the production HTTP path" was true only for *URL routing* — iOS reaches the function. It was false for *production behaviour* — the function endpoint ran the Phase 1 stub, not Phase 2 code, and the schema needed to run Phase 2 wasn't deployed. The audit doc is the canonical reference for "what state is Phase 2 in"; until corrected, it reads as if everything was working.

Action: add a 2026-05-12 addendum noting the three deployment gaps (#135, #138, #139) and their resolution. Keep the original prose for archaeology but mark the relevant lines as superseded.

### 3. Correct `docs/phase-2-verification-gate-report.md`

The G1 PASS-CONDITIONAL verdict's headline claim — "Phase 2 production HTTP path wired + smoke-tested end-to-end" — was technically true only of the iOS→URL wiring. The smoke test did not exercise the Phase 2 rule pipeline because the deployed function wasn't running it. The verdict needs an addendum.

Action: same as Tier 2 #2 — append the 2026-05-12 correction, keep original.

---

## Tier 3 — Real bugs found

### 4. [#141 — deepLiftHistory returns 0 set_logs after regen](https://github.com/thearnavmenon/ProjectApex/issues/141)

Surfaced during the 2026-05-12 regen instrumentation: a fresh program produces a fresh `programs.id`; the `deepLiftHistory` fetch is presumably scoped by `program_id` and finds zero set_logs even though the user has 243 historical sets under prior programs. ProgressViewModel scopes by `user_id` and works correctly. Cross-program continuity defeats the purpose of having historical data; this defeats it.

Action: fix the fetch's WHERE clause. Likely a one-line change once located. Filed as #141.

---

## Tier 4 — Validate the fixes from this session work in the wild

### 5. End-to-end smoke from real iOS app

The 19-session backfill exercised the Edge Function via a CLI script with a service-role key. That validates the function works for *that auth context*. It does **not** validate that the iOS producer (PR #137) successfully enqueues + WAQ-flushes + Edge-Function-applies on a real completed session.

Action: after the next live workout completion, query:

```sql
SELECT
  ws.id AS session_id,
  ws.completed,
  tmas.applied_at,
  (tmas.applied_at IS NOT NULL) AS appeared_in_applied_sessions
FROM public.workout_sessions ws
LEFT JOIN public.trainee_model_applied_sessions tmas
  ON tmas.session_id = ws.id AND tmas.user_id = ws.user_id
WHERE ws.user_id = '6ce6c575-ee68-4ec9-9541-26354e7fdd1f'
  AND ws.session_date >= '2026-05-13'
ORDER BY ws.session_date DESC;
```

If `appeared_in_applied_sessions` is `true` within ~5 minutes of session completion, the producer wiring works in production. If `false`, the WAQ retry / Edge Function pipeline has a remaining gap and this becomes the next investigation.

### 6. Investigate `confidence: null` on all 5 patterns

After backfill, `trainee_models.model_json.patterns[*].confidence` is `null` for every pattern despite 19 sessions of data. Possible causes:
- Confidence field is populated by a rule module not in the current backfill data path (e.g., needs cross-session aggregates that 19 sessions doesn't trigger).
- Or it's actually a fifth gap — another half-wired field.

15-minute check: read the confidence-population path in `supabase/functions/update-trainee-model/index.ts`, find the trigger condition, see if our user's data should have hit it. If yes → file as a bug. If no → expected behaviour, document the threshold.

This matters because the digest is about to become a load-bearing input for B1–B4 cutover prompts, and confidence-gated logic (e.g., per ADR-0005's `.established`/`.calibrating` semantics) needs reliable confidence values.

---

## Tier 5 — Unblocked follow-ups

These were blocked on Phase 2 actually working. Now they can move.

### 7. Unpause [#132 — equipment-constraint validation port](https://github.com/thearnavmenon/ProjectApex/issues/132)

Originally paused mid-session pending the per-week refactor architecture decision. That decision: locked Option 4 (per-week refactor deferred indefinitely; current per-day path stays). Equipment validation can be ported to `SessionPlanService` as originally scoped — small port, ~half-day, no architectural risk.

Action: resume the issue. Implementation follows the legacy `ProgramGenerationService.validateEquipmentConstraints` shape (post-LLM check, one corrective re-prompt, typed error surface on persistent violation).

### 8. Resume B1 (#86), then B2/B3/B4 in sequence

The four cutover slices were paused 2026-05-10 pending data accrual. The accrual gate is now meaningful again — the alpha user has 19 backfilled sessions and the digest has real `per_pattern_summary.trend` values. Per the [Phase 2 memory entry](MEMORY.md), the gate query before resuming B1 is:

```sql
SELECT user_id, key AS pattern, value->>'trend' AS trend
FROM public.trainee_models, jsonb_each(model_json->'patterns')
WHERE value->>'trend' != 'progressing';
```

For our alpha user this currently returns ≥2 rows (`verticalPull → declining`, `isolation → declining`), satisfying the gate. **B1 can proceed.**

Sequencing: B1 → B2 → B3 → B4, each its own PR. B4 (full digest collapse + WorkoutContext restructure) sequences last.

---

## Tier 6 — Optional hygiene

Each of these is "would be nice" but does not block anything. Defer indefinitely or batch later.

### 9. FK constraint on `workout_sessions.program_id`

Add `ALTER TABLE workout_sessions ADD CONSTRAINT workout_sessions_program_id_fkey FOREIGN KEY (program_id) REFERENCES programs(id) ON DELETE SET NULL;` — closes the data-integrity gap that #136 was filed against. Forward-only; the existing 26 orphan references would need to be nulled first or the ALTER will fail validation. Pure cosmetic since no consumer breaks on the dangling reference today.

### 10. Step B of the original #136 plan — WAQ-ify program inserts

Replace the three `Task.detached { try { client.insert(...) } catch {} }` sites in `ProgramViewModel` with `writeAheadQueue.enqueue(row, table: "programs")`. Mirrors the #135 pattern. Doesn't fix any current bug; future transient failures would retry instead of getting logged-and-forgotten. Defer until there's a reason.

### 11. Memory cleanup

The [`project_phase_2_half_deployed.md`](/Users/arnav/.claude/projects/-Users-arnav-Desktop-ProjectApex/memory/project_phase_2_half_deployed.md) entry was updated mid-session to reflect the corrected state. After B1–B4 land and the trainee model has been driving prompts for a few weeks, this memory entry can be deleted entirely — its purpose was "navigate the half-deployed state during cutover."

The [`project_phase_2_grilling_prd_internal_lockins.md`](/Users/arnav/.claude/projects/-Users-arnav-Desktop-ProjectApex/memory/project_phase_2_grilling_prd_internal_lockins.md) entry should be reviewed for whether it's still relevant after B1+ ships.

---

## Out of scope for this cleanup — separate tracks

These came up during the session but aren't deployment-pipeline cleanup. Listed for completeness:

- **Program generation granularity** — Option 4 (skeleton + per-week + per-set) locked as architecture; refactor deferred indefinitely (the per-day path delivers acceptable results at n=1 alpha and the digest signal would need much more data to meaningfully change per-week selection vs. per-day). Captured in [`project_program_generation_granularity.md`](/Users/arnav/.claude/projects/-Users-arnav-Desktop-ProjectApex/memory/project_program_generation_granularity.md).
- **Leg programming for the next program** — Option A (leg compound opener every session) recommended. Alpha user's currently-active program `87f3a441-...` should be inspected for whether legs are scheduled; if not, regenerate with that constraint. User-action, not code-action.
- **Per-set prompt iteration** — separate from B1–B4 cutover, the per-set prompt's deload heuristic + progressive overload mechanics + calibration anchors have known weaknesses (see #135 investigation comment). Defer to after B1 lands; the digest will plug in there naturally.

---

## Recommended order of attack

Working top-down, the highest-value sequencing is:

1. **#1 (file CI auto-deploy issue)** — prevents the next gap of the same shape. Do this first.
2. **#7 (unpause #132)** — small, safe, ships actual user value (equipment safety on per-day generation). Half-day.
3. **#5 (live-session smoke check)** — after the next workout, one SQL query. Confirms the producer wiring works in the wild.
4. **#6 (`confidence: null` investigation)** — 15 minutes. Either rules out a fifth gap or files it.
5. **#4 (deepLiftHistory fix per #141)** — likely a one-line WHERE clause fix.
6. **#8 (resume B1, then B2/B3/B4)** — multi-PR cutover work. Largest scope but everything else has cleared the runway.
7. **#2 + #3 (audit doc + G1 report corrections)** — can interleave anywhere. Honest accounting, no code risk.
8. **Tier 6** — only if/when motivated.

Steps 1–5 are roughly a day's work. Step 6 is multi-PR over a couple of weeks. Steps 7–8 are background.
