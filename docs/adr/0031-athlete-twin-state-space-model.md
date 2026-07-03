# Athlete-Twin v1: per-pattern state-space model, shadow mode, and the Phase-1 evidence gate verdict

**Status**: accepted (Phase 1, shadow only), 2026-07-03. The twin ships as a **shadow dual-write** — it touches no live decision. The Phase-1 forecasting gate from `docs/brain-overhaul-plan-2026-07.md` was run against the cohort's full real history and the verdict is recorded below: the twin beats the incumbent EWMA on the specified observable, **but a trivial rep-habit null beats both**, and the band-calibration gate failed — so this ADR explicitly does **not** authorize Phases 2–5 to proceed on forecasting-edge grounds. Advancing the overhaul requires either the gate redesign or the data-collection path named under Consequences.

**Relationship to other ADRs**: implements Phase 1 of the brain-overhaul plan's proposed architecture. Does not supersede anything yet — ADR-0005's EWMA (per ADR-0009/0010/0011/0020 mechanisms) remains the live engine; the plan's proposal that the twin absorb them is contingent on gates this ADR reports as not passed. ADR-0030's committed-deterministic discipline applies unchanged (the twin is seeded-free, wall-clock-free, replayable).

## Context

The brain-overhaul plan proposes replacing the per-exercise EWMA + threshold-ladder stack with a per-pattern generative model of the athlete (Banister-family fitness–fatigue dynamics, personal rep-response, UKF inference), from which plans, plateau calls, and confidence fall out as posterior statements. Phase 1's job was to earn that complexity with evidence, cheaply: build the twin in shadow mode plus a replay/backtest harness, and answer — *does the twin out-predict the incumbent EWMA at forecasting next-session top-set reps-at-load, on our own users' logged history?*

The cohort reality: 6 users in prod, of whom **two** have any logged sets — one with 32 sessions / 348 sets over 11 weeks (2026-03-17 → 2026-06-04), one with 6 sessions / 30 sets. "Hierarchical pooling across the cohort" therefore degenerates to shared literature priors; there is no cross-user pooling signal at n≈1.5 users of history.

## Decision

### v1 model (what shipped, in `supabase/functions/_shared/twin/`)

Per movement pattern, a UKF over state `[C, T, G, log ρ, b_e…]`:

- `C` — log e1RM of the pattern's **anchor exercise** (first/best exercise seen), true-capability scale (reported RIR included).
- `T` — capability trend per day (local-linear-trend replacement for the plan's fitness reservoir `F`).
- `G` — **one** fatigue term (τ = ADR-0010's 30 h), impulse-loaded by effective sets.
- `log ρ` — personal rep-response slope (prior = Epley's 30).
- `b_e` — one learned log-offset per additional exercise in the pattern (patterns mix heterogeneous exercises; a pattern-level `C` is unobservable without them). State grows as exercises appear.

Observations: every working set with weight > 0 and an effort report — `reps + RIR ≈ personal-Epley(C + b_e − G − intra-session fatigue)`; RPE→RIR fallback at higher noise; AMRAP counts as RIR 0; no-signal sets are skipped and counted, never guessed. Forecasts of *performed* reps are **censored** at the athlete's demonstrated rep-habit ceiling (max of last 8 top-set rep counts + 1) minus their habitual stopping-RIR — the cohort data showed performed top-set reps are pinned to the program's rep target regardless of remaining capability.

Numerics: cubature-style sigma points (all weights positive → covariance PSD by construction), scalar sequential updates, jittered Cholesky with incident telemetry, and property tests against an **independently written** reference implementation (exact linear KF equivalence; Gauss–Hermite posterior agreement on the real observation model; PSD under seeded random op sequences; byte-identical determinism). No `Date.now()`, no `Math.random()` anywhere — the filter's clock is the data's timestamps.

**Named v1 cuts from the full plan**: the fitness reservoir `F` (absorbed into `T`; unidentifiable at 1–2 sessions/week/pattern), the two-τ NM/metabolic fatigue split (`G` collapsed to one term — at the observed median 4–5-day inter-session gaps, τ=30 h fatigue decays to ≤4% between sessions and even the single term is barely observable), the per-session day-readiness factor and cross-pattern transfer (v1 filters are independent per pattern), and learned per-user observation noise (fixed constants + NIS diagnostics instead).

### Shadow dual-write

A new Stage-1 pipeline stage (after recovery readiness) writes the serialized posterior to `patterns.<key>.twin` inside the same transaction. Hard containment: per-pattern try/catch inside `applyTwinShadow` plus an orchestrator-level catch — a twin defect cannot roll back an apply; legacy fields are never written by the stage. Divergence between the twin's anchor e1RM and the legacy EWMA is **logged** (`twin_shadow.applied` / `twin_shadow.failed` observability channels), never acted on. The two e1RM scales differ by construction (RIR-inclusive vs performed-rep); the divergence log's *stability* is the signal, not its size. Nothing client-side reads the block (Swift decoders ignore unknown keys).

Live-payload caveat: `session_payload.set_logs` carries `rpe_felt` but not `rir_estimated`, so live shadow updates run on RPE-derived RIR (coarser) until the client payload adds RIR — a small client follow-up if the twin path continues.

### Replay/backtest harness (`_shared/twin/backtest/`)

Replays each user's full history through: the **prod-faithful incumbent** (per-exercise EWMA exactly as `applyPerExerciseRules` drives it, including its real 0 kg-bodyweight-set poisoning; plus a "dressed" variant with an expanding-window error sd, and a 0 kg-clean variant), a **load-blind rep-habit null** (running mean/sd of the pattern's past top-set reps), and the twin. Scores MAE, CRPS (closed-form Gaussian; numerically-integrated censored-Gaussian for the twin), empirical 90%-band coverage, paired seeded-bootstrap CIs, a load-change stratification, a load-forecast addendum, and per-user×pattern identifiability. Runs twice and asserts byte-identical reports. A synthetic-cohort golden pins the harness under CI; the real export never enters the repo.

## The Phase-1 gate verdict (real cohort, 34 sessions, 35 scored transitions, 2026-07-03)

| forecaster | MAE (reps) | CRPS | 90%-band coverage |
|---|---|---|---|
| incumbent EWMA (as shipped) | 5.77 | 4.31 (dressed) | 0.571 (dressed) |
| **twin v1** | **2.50** | **2.00** | **0.600** |
| rep-habit null (load-blind) | **0.89** | **0.70** | **0.943** |

1. **Twin vs EWMA — passed.** ΔMAE +3.27 reps, 95% CI [2.10, 4.53]; twin closer on 28/35 transitions; positive in every pattern (per-pattern CIs cross zero on the two smallest strata only).
2. **Band calibration — failed.** 0.600 vs the 0.85–0.95 gate. The misses are structural, not noise-scale: over-forecasts where the athlete racked at the program's rep target with capability to spare, and under-forecasts where they ground out the target after a load jump.
3. **Determinism — passed.** Same inputs → byte-identical report; no wall-clock reads; zero covariance-health incidents across the full replay.
4. **Shadow containment — holds by construction and test.**

**The finding that reframes the gate:** the observable itself is degenerate under rep-target training. Athletes (or their program) pick loads so that top-set reps land at ~the target; performed reps then carry almost no forecastable capability signal. The load-blind habit null wins **every stratum, including transitions where the load changed ≥5%** (MAE 0.83 vs twin 2.57 — the load changes are themselves calibrated to hold reps constant). On the prescription-shaped addendum (predict next session's top-set **load**), last-load carry-forward (3.67 kg MAE) beats both the EWMA-inversion (3.71) and the twin-inversion (4.71) overall. No capability model can win these observables on this cohort's data, because the capability signal lives in the slow, deliberate, low-entropy load progression that trivial persistence already nails.

**Identifiability (as predicted, a first-class result):** on the one well-sampled user, exercise offsets learned everywhere (17/17 below 0.7× prior sd) and ρ moved 4–8 prior-σ — but to 4.4–11 against Epley's 30, i.e. ρ learned the *behavioral* load-rep curve (habitual "RPE 9" reporting + target-driven stopping), not physiology; `exp(C)` therefore is **not** a physiological e1RM and must not seed load prescription without recalibration. Trend `T` was decisively detected on 2 of 6 trained patterns (horizontal_pull ≈ +1.3%/day early-novice gain; vertical_push). Fatigue `G` and its constants are unidentifiable at this cadence, exactly as the plan feared. The 6-session user's parameters all sit at the prior — the twin is honestly "literature constants wearing a Kalman hat" for cold users. NIS of 2–11 (worst on the grab-bag isolation pattern) says observation noise is still underestimated for heterogeneous patterns.

**Scope note:** everything above is a claim about *predictive* likelihood on logged history. Nothing here validates or refutes whether twin-guided *prescriptions* would produce better outcomes — that counterfactual is not in the data (and Phase 0's prescription ledger is the instrument that would eventually make prescription accuracy measurable).

## Consequences

- **The overhaul does not advance to Phases 2–5 on this evidence.** The plan's premise — "the twin out-predicts the incumbent, therefore it earns its complexity" — is technically met against the EWMA but hollow against the honest null. Two paths forward (owner decision):
  1. **Redesign the gate around an observable with signal.** Candidates: prediction quality on *deliberately varied* loads (which is exactly what Pillar 3's pre-registered experiment sets would generate — AMRAP/test sets break the rep-target censoring), or ledger-based prescription accuracy once Phase 0 ships.
  2. **Collect before concluding.** The shadow dual-write now accrues twin posteriors and divergence logs on every live apply at zero product risk; re-run this gate when the cohort has materially more history (and more than ~1.5 users of it).
- The shadow stage stays in (cheap, contained, reversible by deleting one pipeline stage + the `twin` blocks); the backtest harness is the standing instrument for any future gate run.
- The EWMA and every ADR-0009/0010/0011/0020 mechanism remain the live brain, unretired.
- Fixed v1 constants that a future phase must revisit rather than trust: intra-session fatigue 0.025 log-units/set, dose impulse 0.006/effective-set, observation sds (1.3/1.8/1.3 reps), novice-sized trend prior (±15%/month), rep-habit window 8. All are flagged inline in `model.ts`.
- Known live-vs-backtest asymmetry: live shadow sees RPE only (no RIR in the payload), so live posteriors will be noisier than the backtest's until the client adds `rir_estimated` to `TraineeModelSetLogPayload`.
