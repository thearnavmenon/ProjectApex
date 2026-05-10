# Phase 2 integration audit — 2026-05-10

## Why this doc exists

G1's first end-to-end replay attempt against single-user historical data on
2026-05-10 surfaced three load-bearing wiring gaps in the Phase 2 production
HTTP path that had been latent across the entire 2A slice arc (#72–#84).
A14 (#109, merged) closed those three. But the closing audit revealed a
deeper systemic issue: the slice-by-slice testing strategy produced
locally-correct rule modules that were globally unwired into the
orchestrator. This doc catalogues the full integration gap and proposes
the slice plan to close it.

This is **not** a retro of the 2A arc. The rule modules ship as designed.
The gap is at the composition layer — between the modules and the
orchestrator, and between the orchestrator and the production HTTP path.

## Audit findings

### Server-side rule modules — wiring inventory

The Edge Function at `supabase/functions/update-trainee-model/` imports
14 modules from `_shared/`. Of those 14:

- **3 are infrastructure** — `constants.ts`, `observability.ts`,
  `llm-retry.ts`. Not rule modules; correctly wired.
- **1 is helper-only** — `cadence-translation.ts`. Used internally by
  `transition-mode-expiry`. Correctly wired through that path.
- **3 rule modules are wired** into the orchestrator's session-apply
  pipeline — `phase-advance`, `transition-mode-expiry`,
  `global-phase-advance`.
- **1 module is wired into Stage 2** — `note-classifier` (per ADR-0013's
  separate-after-Stage-1 contract).
- **7 rule modules are completely unwired.** Their compute functions
  exist with passing unit tests, but the orchestrator never imports or
  calls them. The model_json fields these modules are supposed to
  populate stay at default values across all session-applies.

| Module | Slice | ADR | Status | Field(s) populated |
|---|---|---|---|---|
| `phase-advance` | A8 (#79) | ADR-0011 | ✅ wired | `PatternProfile.currentPhase`, `sessionsInPhase`, `consecutiveForceDeloadsOnPattern`, `lastPhaseTransitionAtSessionCount` |
| `transition-mode-expiry` | A6 (#77) | Q5 | ✅ wired | `PatternProfile.transitionModeUntil` |
| `global-phase-advance` | A8 (#79) | ADR-0012 | ✅ wired | `lastGlobalPhaseAdvanceFiredAtSessionCount` |
| `note-classifier` | A13 (#84) | ADR-0013, Q9 | ✅ wired (Stage 2) | `formDegradationFlag`, `activeLimitations`, `clearedLimitations` |
| `ewma-engine` | A6 (#77) | ADR-0005, ADR-0009 | ❌ unwired | `PatternProfile.e1RMEwma` (would feed plateau-verdict + prescription-accuracy) |
| `stimulus-classifier` | A5 (#76) | Q3 | ❌ unwired | `RecoveryProfile.lastNeuromuscularStimulusAt`, `lastMetabolicStimulusAt` |
| `recovery-curve` | A5 (#76) | ADR-0010 | ❌ unwired | `RecoveryProfile.neuromuscularReadiness`, `metabolicReadiness` |
| `plateau-verdict` | A7 (#78) | ADR-0009 | ❌ unwired (only `ProgressionTrend` type imported) | `PatternProfile.trend`, `MuscleProfile.stagnationStatus` |
| `prescription-accuracy` | A9 (#80) | ADR-0014 | ❌ unwired | `prescriptionAccuracy[pattern][intent]` cells + gap-bucket |
| `transfer-regression` | A10 (#81) | Q10 | ❌ unwired | `transferRegressions[(from, to)]` |
| `fatigue-interaction` | A11 (#82) | ADR-0005 | ❌ unwired | `fatigueInteractions[(patternA, patternB)]` |

The 7 unwired modules represent the bulk of Phase 2's coaching value.
Without them, the AI digest sees a `TraineeModelDigest` where
`stagnationStatus`, `recoveryReadiness`, `prescriptionAccuracy`,
`transferRegressions`, and `fatigueInteractions` all stay at default /
empty values for all alpha cohort users.

### Composition-layer gap (gap 4 from G1 audit, filed as #110/A15)

The orchestrator's `applyPerPatternRules` ([index.ts:286-358](../supabase/functions/update-trainee-model/index.ts#L286-L358))
iterates `Object.entries(patterns)` only — it updates pattern profiles
that already exist but never bootstraps a new one. With no production
bootstrap path, fresh users get empty `model_json.patterns` indefinitely.
A14 fixed the trainee_models row bootstrap (UPSERT) but not the per-pattern
bootstrap.

Filed as #110 (A15) with three viable shapes (schema column / EF library /
hybrid) and a recommendation toward (B) EF library port for G1's
single-user-historical-replay context.

### Test coverage gaps

The orchestrator's 26 tests (post-A14) cover:
- Late-arrival watermark refusal paths
- PK-conflict cached-snapshot returns
- Atomic rollback on rule throw
- Stage 2 fires-once-on-first-apply contract
- Phase advance composition (force-deload, cyclic deload→accumulation,
  global-advance)
- A14's row-bootstrap UPSERT + JSONB shape

What no existing test covers:
- **End-to-end HTTP smoke** — fresh user, POST a synthetic session via
  HTTP, assert trainee_models row materializes correctly with all
  expected fields populated. The closest test (`orchestrator_test.ts`'s
  ADR-0006 test) calls `applySession` directly with a pre-INSERTed row.
- **Multi-rule composition** — every rule module's tests exercise its
  own outputs. No test asserts that running an apply against a
  representative session_payload populates the EWMA field AND the
  recovery readiness AND the trend verdict AND the prescription
  accuracy together. Each module asserts in isolation.
- **JSONB write-path round-trip** — a test that asserts model_json's
  shape after a real mutation (not just the watermark-refusal path).
  A14 added one such test for the row-bootstrap case; broader coverage
  needed.

This is the **systemic gap** behind the integration debt: tests cover
modules in isolation with their preconditions hand-fed; the production
path doesn't satisfy those preconditions; each layer hides the next.

### iOS client checkpoint

`TraineeModelUpdateJob.swift` declares `functionName = "update-trainee-model"`.
Service layer (`TraineeModelService`, `SupabaseClient.callFunction`) is
in place. Whether the WAQ adapter actually fires per-completed-session
in production needs verification but is treated here as a checkpoint,
not a known gap. If the iOS client wasn't actually POSTing to the EF
in production, the unwired-orchestrator gap (#109's gap 1) would have
been silently masked anyway — server-side state stayed at Phase 1
defaults regardless.

A v2.x watch-item: confirm the iOS WAQ adapter's per-session trigger
fires in alpha against a staging deploy of the wired EF.

### Schema additive fields — assumed-populated by orchestrator

Phase 2 schema migration (#73, A2) added these fields to `trainee_models`'s
codable shape inside `model_json`:

- `consecutiveForceDeloadsOnPattern: Int` — populated by phase-advance ✅
- `lastGlobalPhaseAdvanceFiredAtSessionCount: Int?` — populated by
  global-phase-advance ✅
- `formDegradationCleanSessions: Int` — populated by Stage 2 classifier ✅
- `lastClassifiedNoteCreatedAt: Date?` — populated by Stage 2 classifier
  watermark ✅
- `prescriptionAccuracy.biasByGapBucket` etc. — would be populated by
  prescription-accuracy module ❌ (unwired)

And `trainee_models` table column:
- `last_applied_logged_at TIMESTAMPTZ` — populated by orchestrator ✅
  (post-A14)

## Revised slice plan — Phase 2 completion

### Phase 0 (this doc)
Audit doc as durable inventory. PR opens, lands as documentation.

### Phase 1 — End-to-end smoke test infrastructure
**Slice A16 (new issue to file): smoke test infra + first assertion set.**

One Deno integration test exercising the full HTTP → orchestrator → DB path:
- Synthetic fixture: one user (no trainee_models row), one programme,
  one session_payload covering 3 patterns × ~10 sets across multiple
  intents and exercises
- Test action: POST to local EF, then read back the trainee_models row
- Initial assertion set: trainee_models row materializes,
  `jsonb_typeof(model_json) = 'object'`, `session_count = 1`,
  `last_applied_logged_at` advances, dedupe row exists.
- Wires into CI via existing GitHub Actions or equivalent

**Why first**: every subsequent slice extends the assertion set. A
module wired in slice A17 must add an assertion that its field is
populated — the smoke test becomes a growing oracle for "did the
integration debt regrow."

**Out of scope for A16**: pattern profile assertions (those land with
A15), per-rule-module assertions (those land with each A17–A23 slice).

### Phase 2 — A15 (#110): Pattern profile bootstrap
Per option (B) from the design call: port `(exercise_id → MovementPattern)`
subset to `_shared/exercise-library.ts`. Orchestrator derives trained
patterns from session_payload before applyPerPatternRules and seeds
initial PatternProfile per ADR-0011 defaults. Smoke test extended with
"pattern profiles exist for all trained patterns post-apply" assertion.

### Phase 3 — Wire unwired rule modules in dependency order

| Slice | Module | ADR | Order rationale |
|---|---|---|---|
| A17 | ewma-engine | ADR-0005, ADR-0009 | First — produces e1RM EWMA consumed by plateau-verdict + prescription-accuracy. No upstream deps among unwired modules. |
| A18 | stimulus-classifier | Q3 | Second — populates `RecoveryProfile.last*StimulusAt` per set. Recovery-curve consumes these timestamps. No deps among unwired modules other than reading set-level intent/reps/RPE. |
| A19 | recovery-curve | ADR-0010 | Third — reads stimulus timestamps written in A18; produces readiness scalars. Depends on A18. |
| A20 | plateau-verdict | ADR-0009 | Fourth — uses ewma (A17) plus volume-load track. Aggregates to muscle level. Depends on A17. |
| A21 | prescription-accuracy | ADR-0014 | Fifth — gap-bucket reads recovery timestamps (A18) for bucketing; otherwise aggregates per-set rep-error. Depends on A18 (for buckets). |
| A22 | transfer-regression | Q10 | Sixth — pair-wise log-log fit; standalone (no deps among unwired modules). Could land earlier if no other slice blocks. |
| A23 | fatigue-interaction | ADR-0005 | Seventh — per-pattern session-pair interactions; reads recent session performance. Largely standalone. Could land earlier. |

Each slice's PR adds:
1. Orchestrator wiring (compose into per-pattern loop or per-set loop
   as appropriate).
2. Unit tests for the new compose path (existing module-level tests
   stay).
3. New smoke-test assertions confirming the field populates with
   realistic values for the synthetic fixture.

### Phase 4 — G1 redefinition + close #85

With the smoke test in place and all 7 modules wired, G1's single-user
historical replay becomes a one-shot artifact rather than a recurring
gate. Convert to a lighter "alpha-cohort sanity check" with:
- Items 1 + 5 (recovery readiness + gap-bucket) reviewer sign-off
  against the replay output
- Comparisons 1, 2, 3 run with end-state agreement rates documented
- Final verdict landed in `docs/phase-2-verification-gate-report.md`
- Issue #85 closes via the report's PR

The single-user replay setup on `gate/phase-2-verification` (replay.ts,
extract-legacy-outputs.py, fixtures structure, README) is preserved as
a reference artifact — useful for v2.x verification cycles when alpha
cohort grows.

## Total scope estimate

- Phase 0: 1–2 hrs (this doc + PR)
- Phase 1: 4–8 hrs (smoke infra + first assertions)
- Phase 2: 4–8 hrs (A15 — pattern bootstrap + library port)
- Phase 3: ~4–8 hrs per slice × 7 = 32–64 hrs
- Phase 4: 4–8 hrs (G1 redefinition + report draft + close)

**Total: ~50–90 hours, ~10 PRs over 1.5–2.5 focused weeks.**

## Slice dependency graph

```
                       Phase 0 (this doc)
                             │
                             ▼
              Phase 1 (A16: smoke infra)
                             │
                             ▼
                Phase 2 (A15: bootstrap)
                  ┌──────────┼──────────┐
                  ▼                     ▼
        Phase 3 (A17: ewma)   Phase 3 (A18: stimulus)
                  │                     │
                  ▼                     ▼
        Phase 3 (A20: plateau) Phase 3 (A19: recovery)
                                        │
                  Phase 3 (A21: prescription-accuracy)
                                        │
                  Phase 3 (A22: transfer-regression)
                                        │
                  Phase 3 (A23: fatigue-interaction)
                                        │
                                        ▼
                        Phase 4 (G1 redefinition + close #85)
```

A22 and A23 have no upstream deps among unwired modules and can ship
in parallel with the rest of Phase 3 if convenient. The chain
A17 → A20 (ewma → plateau) and A18 → A19 → A21 (stimulus → recovery →
prescription-accuracy with gap-bucket) is sequential.

## Cross-references

- #85 (G1 verification gate — paused on `gate/phase-2-verification`)
- #109 (A14 — production HTTP path wiring; merged 2026-05-09)
- #110 (A15 — pattern profile bootstrap; the next blocker for G1 resume)
- ADR-0005 (TraineeModel shape — what model_json should look like)
- ADR-0009 (hybrid plateau verdict)
- ADR-0010 (recovery curves)
- ADR-0011 (per-pattern phase advance)
- ADR-0012 (global phase advance)
- ADR-0013 (Stage 2 classifier separation)
- ADR-0014 (prescription accuracy + gap-bucket)
- Q3 (stimulus classifier table)
- Q10 (transfer regression R² gate)
- `gate/phase-2-verification` branch — G1 single-user replay setup
  (preserved; resumes after Phase 3 completes)
