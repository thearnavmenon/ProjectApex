# Phase 2 verification gate (G1 / #85) — report

**Verdict:** **PASS-CONDITIONAL** — Phase 2 wiring is end-to-end correct against the synthetic fixture; replay-vs-legacy comparisons + manual sign-off items are reframed as v2.x watch-items contingent on alpha cohort growing beyond n=1.
**Run date:** 2026-05-10
**Scope:** alpha-cohort sanity check (n=1) — synthetic-fixture smoke + Phase 3 wiring slices
**Issue:** [#85](https://github.com/thearnavmenon/ProjectApex/issues/85)

## Why the redefinition

The literal G1 issue body envisioned ≥2 weeks of silent-population data accruing across an alpha cohort, then comparing the trainee model's per-apply outputs against three legacy services (StagnationService, VolumeValidationService, PatternPhaseService) with ≥85% agreement plus five manual coaching-judgment audits. With n=1 alpha (the project author) and Phase 2 having only just merged in the integration audit window, the literal pass condition is structurally unreachable: per-apply temporal agreement-rate has no statistical population, force-deload triggers haven't fired against real data, and the C-arc demand-side surface for free-form notes is being superseded by trigger-driven structured prompts.

A first end-to-end replay attempt on 2026-05-10 surfaced a different problem: seven Phase 2 rule modules existed as locally-tested pure functions but had no orchestrator caller. The HTTP path silently no-op'd. That finding moved G1's blocking condition from "compare against legacy services" to "wire the rules we already shipped." Phases 0–3 of [`docs/phase-2-integration-audit-2026-05-10.md`](phase-2-integration-audit-2026-05-10.md) closed all seven gaps:

| Slice | PR | What it wired |
|---|---|---|
| A14 | [#111](https://github.com/thearnavmenon/ProjectApex/pull/111) | `handleRequest` → `applySession`; bootstrap UPSERT; JSONB encoding fix |
| A15 | [#115](https://github.com/thearnavmenon/ProjectApex/pull/115) | Pattern profile bootstrap from `session_payload`; `_shared/exercise-library.ts` port |
| A16 | [#114](https://github.com/thearnavmenon/ProjectApex/pull/114) | End-to-end smoke test infrastructure + CI job |
| A17 | [#117](https://github.com/thearnavmenon/ProjectApex/pull/117) | `ewma-engine` → `ExerciseProfile.e1rmCurrent` |
| A18 | [#119](https://github.com/thearnavmenon/ProjectApex/pull/119) | `stimulus-classifier` → `RecoveryProfile.last*StimulusAt` |
| A19 | [#121](https://github.com/thearnavmenon/ProjectApex/pull/121) | `recovery-curve` → `RecoveryProfile.*Readiness` |
| A20 | [#123](https://github.com/thearnavmenon/ProjectApex/pull/123) | `plateau-verdict` → `PatternProfile.trend` |
| A21 | [#125](https://github.com/thearnavmenon/ProjectApex/pull/125) | `prescription-accuracy` + gap-bucket → `prescriptionAccuracy[pattern][intent]` |
| A22 | [#127](https://github.com/thearnavmenon/ProjectApex/pull/127) | `transfer-regression` → `transferRegressions[from][to]` |
| A23 | [#129](https://github.com/thearnavmenon/ProjectApex/pull/129) | `fatigue-interaction` → `fatigueInteractions[]` + `lastSessionPatternPerformance[]` |

Each slice extended the smoke fixture's growing-oracle assertion set so the synthetic session now produces visible state changes across every wired module. CI (`Edge Function Tests (Deno)`) runs the orchestrator + smoke suites on every PR — the smoke test is the standing alpha-cohort oracle.

## What this gate is actually validating

**End-to-end correctness of the Phase 2 production HTTP path** under a synthetic fixture covering 3 movement patterns × multiple intents. The smoke test (`supabase/functions/update-trainee-model/smoke_test.ts`) POSTs the fixture over HTTP, reads `trainee_models.model_json` back via SQL, and asserts:

- `applied_sessions` PK row inserted (idempotency boundary committed)
- `trainee_models.session_count`, `last_applied_logged_at`, `model_json` populated
- `model_json.patterns` bootstrapped for each trained pattern (currentPhase, sessionsInPhase, recentSessionDates, weeklyVolumeLoadHistory)
- `model_json.exercises[id].e1rmCurrent` populated per Epley × EWMA
- `model_json.recovery.last*StimulusAt` + `*Readiness` populated per ADR-0010 curve
- `PatternProfile.trend` explicitly written by plateau-verdict
- `model_json.prescriptionAccuracy` exists (empty until production iOS client supplies `ai_prescribed`)
- `model_json.transferRegressions` populated with 6 directional pairs (3 exercises × 2)
- `model_json.fatigueInteractions` empty on first session; `lastSessionPatternPerformance` populated for next-session pairing
- Idempotent retry path: second POST with same `(user_id, session_id)` returns cached snapshot via PK conflict; `session_count`, watermark, and `model_json` unchanged

This is the alpha-cohort sanity check. It catches every wiring regression the integration audit named, plus any future regression on the same surface.

## Three automated comparisons — deferred to v2.x

The literal G1 comparisons require simultaneous legacy + trainee state, which only exists at alpha-cohort scale (n>1). Reframed as v2.x watch-items:

### Comparison 1 — Stagnation verdict (per-pattern)
**Deferred.** Re-run the legacy `StagnationService.computeSignals` (per-exercise, aggregated to per-pattern via worst-of) against `PatternProfile.trend` from the trainee model when alpha cohort has ≥30 sessions per pattern across ≥2 users. Single-user replay produced an all-`.progressing` baseline (no plateau or decline observed) — the agreement rate would be vacuously 100%. **Revisit trigger:** alpha grows to n>1 OR a single user accumulates ≥30 sessions with at least one pattern reaching `.plateaued` or `.declining`.

### Comparison 2 — Volume deficit (per-muscle binary)
**Deferred.** Trainee `MuscleProfile.volumeDeficit` and legacy `VolumeValidationService.currentWeekDeficits` measure the same direction under different windowing (queue-event-windowed per ADR-0002 vs calendar-week). Binary classification agreement is the comparison surface, but n=1 with all-accumulation training produces no contested cases. **Revisit trigger:** same as Comparison 1.

### Comparison 3 — Pattern phase (per-pattern, end-state)
**Deferred.** Trainee `PatternProfile.currentPhase` vs legacy `PatternPhaseService.computeInitialPhases`. Force-deload-as-transition (ADR-0011) is feature, not bug — flagged disagreements there require human review. n=1 replay produced no completed phase cycle, so agreement is vacuous. **Revisit trigger:** alpha grows OR single user reaches a completed deload cycle.

## Five coaching-judgment items — deferred or smoke-covered

### Item 1 — Recovery readiness 24/48/72h
**Smoke-covered (formula-only) + deferred for full review.** `recovery-curve_test.ts` pins the curve formula: 24h post-NM ≈ 0.7853 (orchestrator test `A19 / #120`), 48h ≈ 0.8950, 72h ≈ 0.9407 (formula derivations, all within ±0.05 of the ADR-0010 table). What's deferred: the smoke fixture only exercises t=0 (residual floor 0.3); full multi-day replay against alpha cohort data is the v2.x deepen. **Revisit trigger:** alpha cohort produces ≥10 multi-day sessions with cross-day NM-classified stimulus.

### Item 2 — Force-deload trigger audit
**Composition-now-possible (A20 wired); deferred for data.** Plateau-verdict (A20) now writes `PatternProfile.trend`. Force-deload's predicate (`trend ∈ {plateaued, declining}` AND `sessionsInPhase ≥ 2 × threshold`) is therefore live. n=1 replay produces no plateau or decline (single-session windows < 3-session base). **Revisit trigger:** any alpha-cohort session-apply emits `phase-advance` with `consecutiveForceDeloadsOnPattern` incrementing.

### Item 3 — Classifier output spot-check
**Deferred — demand-side superseded.** A13's free-form note path is rarely used in production. The Stage 2 classifier infrastructure transfers cleanly to the trigger-driven structured-prompt feature (C-arc watch-item). Q9 language-scoping subset becomes auxiliary. **Revisit trigger:** trigger-driven structured-prompt feature lands and ≥20 invocations accrue, OR free-form note volume hits ≥20 against the existing path.

### Item 4 — Phase-cycling validation (deload→accumulation)
**Composition-now-possible (A20 wired); deferred for data.** Same chain as Item 2 — plateau-verdict drives the trend predicate that feeds force-deload that produces the cyclic deload→accumulation transition. **Revisit trigger:** any pattern reaches `.deload` AND completes the deload phase (sessionsInPhase ≥ deload threshold).

### Item 5 — Gap-bucket bucketing audit
**Smoke-covered (formula) + orchestrator-tested (semantics).** The `gapBucket` rule is pure and unit-tested (`prescription-accuracy_test.ts`). `prescription-accuracy.ts` `gapBucket` edge-case routes first-ever sessions to `over72h` per the locked semantic. The A21 orchestrator test `A21 / #124` asserts a first-ever-pattern session lands in `over72h` bucket end-to-end. **Revisit trigger:** alpha cohort produces ≥10 multi-day same-pattern sessions across the three bucket boundaries.

## Failing items + resolution paths

None. All 7 unwired-module gaps from the integration audit closed via PRs #111–#129. No rule-module amendments required during the wiring work.

## v2.x watch-items raised by this gate

1. **Per-apply temporal agreement-rate.** The literal #85 reading evaluates per-session-apply agreement over a population. End-state-only replay is the v1 substitute; the temporal-resolution gate revisits at n>1.
2. **Three legacy-vs-trainee agreement-rate comparisons** (Comparisons 1, 2, 3 above) — same trigger.
3. **Recovery readiness multi-day curve audit** (Item 1) — same trigger.
4. **Force-deload trigger audit + phase-cycling validation** (Items 2 + 4) — fire when trend ≠ progressing or any deload completes.
5. **Classifier output review against trigger-driven structured prompts** (Item 3) — fires when C-arc lands.
6. **Gap-bucket cross-boundary audit** (Item 5) — fires at multi-day session density.
7. **iOS WAQ adapter wiring audit.** The integration audit only inspected the Edge Function side. Whether the iOS client actually POSTs to `update-trainee-model` in production (vs. running everything client-side-cold) is a v2.x watch-item — adjacent to but not blocking G1.
8. **Other Edge Functions stub-grep.** `grep -nE "Phase 1 stub|TODO" supabase/functions/*/index.ts` may reveal similar `handleRequest` stubs in functions G1 didn't touch.
9. **JSONB write-pattern grep.** `grep -nE "::jsonb" supabase/functions/` finds other double-encoding sites latent in non-G1 paths.
10. **Schema-vs-Codable diff.** Diff `model_json` Swift Codable shape against the orchestrator's writes — fields populated on neither side are unwired.

The replay scaffold (`scripts/phase2-verification-gate/`) is preserved as a reference artifact for v2.x verification cycles. Local-machine fixtures (`fixtures/historical-replay.sql`, `fixtures/legacy-pattern-phase-states.json`) **must be deleted** after this PR merges per the gate README's cleanup obligation — they contain the user's full training history.

## Final verdict

**PASS-CONDITIONAL.** Phase 2 production HTTP path is wired, smoke-tested in CI, and produces visible state changes across all 7 rule modules from the integration audit. 2B can proceed. All deferred items are tracked as v2.x watch-items above with explicit revisit triggers.

Per Q12 PRD-internal, this verdict gates 2B-merge-allow. The deferrals are scope-realistic for n=1 alpha; they are not silent gaps.

## Verdict acceptance — 2026-06-01 (post-B4 + post-cleanup boundary)

The PASS-CONDITIONAL verdict above is **accepted as terminal**, exiting via the OR branch of the standing project memory's delete-when clause ("user decides Phase 2 is done at current state"). No stronger verdict was pursued; the AND branch (G1 re-runs land non-PASS-CONDITIONAL) was not mechanically reachable at n=1 without resurrecting deleted legacy services.

**Reasoning:**

- The three legacy comparators referenced in §3 (StagnationService, VolumeValidationService, PatternPhaseService) were permanently deleted by B1/B2/B3 (PRs [#160](https://github.com/thearnavmenon/ProjectApex/pull/160), [#170](https://github.com/thearnavmenon/ProjectApex/pull/170), [#174](https://github.com/thearnavmenon/ProjectApex/pull/174)). Re-running Comparisons 1–3 as originally written is no longer possible without structural code resurrection.
- The n=1 alpha cohort has not grown since 2026-05-10. The v2.x revisit triggers in §80–91 (n>1 alpha, force-deload firing, completed deload cycle, multi-day NM cross-day stimulus, etc.) have not fired.
- Cleanup PR [#194](https://github.com/thearnavmenon/ProjectApex/pull/194) (2026-06-01) completed the `transferRegressions` legacy-fallback removal and orphan-SQL apply; no Phase 2 cleanup work remains.
- The smoke test ([`supabase/functions/update-trainee-model/smoke_test.ts`](../supabase/functions/update-trainee-model/smoke_test.ts), CI-run via `Edge Function Tests (Deno)` on every PR) remains the standing alpha-cohort oracle.
- v2.x watch-items 1–10 above remain the authoritative deferral record. This footer does not retire them; only their revisit triggers firing does.

The project memory `project_phase_2_half_deployed.md` is deleted concurrently with this footer landing; this section is its durable replacement as the verdict-acceptance recording.
