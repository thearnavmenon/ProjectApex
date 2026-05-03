# Persistent structured trainee model

**Status**: accepted, 2026-05-01

## Context

Pre-v2, the AI inferred user state from raw `set_logs` on every session: e1RM trends came from `StagnationService` (Epley over a 3-session window), volume gaps from `VolumeValidationService` (sets-per-week vs target, calendar-week-shaped), per-pattern phases from `PatternPhaseService`. Episodic notes lived in pgvector via `MemoryService` and were retrieved by semantic similarity at inference time. Coaching cues felt generic because the AI was rebuilding its understanding of the user from raw logs every session — there was no aggregated, structured behavioural memory across sessions. RAG handled episodic recall but couldn't aggregate ("the user has had 5 left-shoulder mentions in 10 sessions" is not a query RAG answers natively).

This ADR is tightly coupled to ADR-0006 (server-side update logic): the trainee model's update rules run server-side via Edge Function. It also references ADR-0002 (queue-shape progression for window definitions) and is referenced by ADR-0004 (gym profile feeds session-generation context).

## Decision

Build a **persistent, structured trainee model** — a typed object per user, persisted in Supabase, updated after every completed session, consulted before every prescription. It supersedes scattered services and centralises behavioural state.

**Relationship to `MesocycleSkeleton`**: the queue itself (the ordered list of session slots from ADR-0002) is **not** a field on `TraineeModel`. The skeleton lives on the existing `programs` table (`programs.mesocycle_json` JSONB), is per-programme-per-user, and represents the structural plan. `TraineeModel` represents the *behavioural model of the user* — capability, recovery, goal, projections — and is consulted alongside the skeleton during session generation. The two are kept separate because they have different update cadences (skeleton mutates on regenerate / phase boundary; trainee model mutates after every session) and different ownership (skeleton is the AI's plan; trainee model is the user's learned profile). `TraineeModel` may carry an `activeProgramId: UUID` reference for join purposes, but the skeleton is read from `programs` at consumption time, not duplicated.

Top-level shape of `TraineeModel` (stored fields):

- `goal: GoalState` — plain-language goal + focus areas; no numerical targets at onboarding.
- `projections: ProjectionState?` — floor (capability-based, immovable) + stretch (user-adjustable upward only); set at calibration review (fires when ≥4 of 6 major patterns reach `.established` per-axis confidence — typically ~6–8 sessions of normal training, but the threshold is the rule, not the heuristic), re-derived silently on goal renegotiation.
- `patterns: [MovementPattern: PatternProfile]` — phase, RPE-offset, recovery (two-dimensional NM + metabolic), per-axis confidence, transition-mode flag.
- `muscles: [MuscleGroup: MuscleProfile]` — volume tolerance, observed sweet spot (current-context estimate, varies with phase), volume deficit (queue-event-windowed per ADR-0002), focus weight from goal.
- `exercises: [String: ExerciseProfile]` — per-exercise capability (EWMA over last 5 valid top sets, validity 3–10 reps), median capability alongside peak, learning-phase flag (`sessionCount < 10`), form-degradation flag (RAG-fed).
- `activeLimitations: [ActiveLimitation]` + `clearedLimitations` — injury / pain state per pattern / muscle / joint; AI-inferred limitations require ≥2 corroborating evidence and cap at `.mild` until user-confirmed.
- `fatigueInteractions: [FatigueInteraction]` — cross-pattern carryover patterns; surface in prompts only at confidence ≥ 0.7 with ≥15 paired observations.
- `prescriptionAccuracy: [MovementPattern: [SetIntent: PrescriptionAccuracy]]` — meta-coaching: the AI's own bias and RMSE per pattern × intent.
- `prescriptionIntentMismatches: [PrescriptionIntentMismatch]` — diagnostic log (inspection-only, capped at 50; not used for rate analytics).
- `transfers: [TransferKey: ExerciseTransfer]` — per-user-learned cross-exercise transfer coefficients with R²; gated on ≥5 paired observations.
- `bodyweight: BodyweightHistory` — passive logging.
- `lifeContextEvents: [LifeContextEvent]` — disruption history, persist-only in v2 (consumption deferred).

Computed properties (derived at read time, not stored):

- `isReadyForCalibrationReview: Bool` — true iff ≥4 of 6 major patterns are at `.established` AND calibration review has not yet fired.
- `disruptedPatterns: [MovementPattern]` — derived from per-pattern `sessionsCadenceDays` and `daysSinceLastSession`; a pattern is disrupted when current absence exceeds 2× typical cadence. Consumed by B5 (programme-reacts-to-life-context) coaching prompts.
- `shouldFireGlobalPhaseAdvance: Bool` — derived from per-pattern `lastPhaseTransitionAtSessionCount`; fires when ≥4 major patterns transitioned within a 6-session window.

RAG (`MemoryService`) is reframed as a **sensor that feeds structured fields** — not demoted, not parallel. A periodic cadence (after every session that adds a new note) runs a single multi-classification LLM call producing both per-exercise form-degradation counts and per-joint limitation evidence; both feed the trainee model as structured updates.

`SetIntent` (`.warmup | .top | .backoff | .technique | .amrap`) is a required field on every set with no silent defaults at any layer. AI prescriptions without intent fail validation and re-prompt. Freestyle user-logged sets present an explicit picker. Intent gates which sets contribute to e1RM (only `.top`, validity 3–10 reps), volume aggregation (warmup/technique zero-weighted), and RPE calibration (top + amrap full, backoff half, others excluded).

## Considered Options

Three top-level alternatives:

- **Continue with raw-logs-each-session.** Rejected: this is the current behaviour and produces generic coaching cues — every session re-derives user state from scratch, never building persistent behavioural memory.
- **Pure RAG, no structured model.** Rejected: RAG retrieves semantically similar episodic notes but can't aggregate ("how has shoulder felt over the last 6 sessions" isn't a similarity-search query). Aggregation is what makes structured.
- **Structured trainee model alongside RAG, with RAG-feeds-structured (chosen).** Best of both — episodic recall via RAG, aggregated behavioural memory via structured fields, with explicit pipeline where periodic RAG summarisation populates structured updates.

Sub-variants within the structured model (this is where the real grilling happened):

- **Confidence: global enum vs per-axis.** Chose per-axis. Global confidence (`.bootstrapping | .calibrating | .established | .seasoned`) was a lie when half the patterns had no data; each `PatternProfile` / `MuscleProfile` / `ExerciseProfile` carries its own.
- **e1RM update: Bayesian vs rolling-window vs EWMA.** Chose EWMA (α = 0.333, N = 5, validity 3–10 reps). Bayesian was hand-waved; plain rolling-window weights all observations equally regardless of recency; EWMA is the honest middle. With a transition-mode collapse (when `inTransitionMode` from calibration-recency / phase-transition / long-absence triggers, window collapses to 3 most recent **sessions** — heaviest top set per session, plain mean, sample variance with Bessel correction — to avoid measuring intra-session consistency rather than recent capability across sessions).
- **e1RM window: top sets vs sessions.** Chose top-set-counted (last 5 valid top sets, possibly multiple per session in 5×5 programmes). Cadence derives from unique session days within the window.
- **Capability: peak only vs median + peak.** Chose both. Default prescription targets median (typical-day capability); peak is stretch reference for unusually-good days only. Real coaches prescribe to typical, not peak.
- **Recovery: single-dimensional vs two-dimensional.** Chose two-dimensional (NM + metabolic). Single dimension was wrong for hybrid hypertrophy/strength trainees where heavy 1–3RM and high-rep moderate work tax different systems with different decay curves. Stimulus dimension is classified per set via joint intensity-and-reps consideration with low-stimulus sets (warmup, technique) explicitly excluded via `Optional` return.
- **Capability granularity: pattern-level only vs exercise-level.** Chose exercise as source of truth, pattern as aggregator. Cross-exercise transfer (C3) needs exercise-level granularity to reason "bench got stronger, OHP/dips should bump."
- **Transfer matrix: static literature defaults vs learned per-user.** Chose learned per-user, gated on ≥5 paired observations. Static defaults dressed up guesses as values; refusing to propagate until paired observations exist is honest. Cold-start cost: first ~30 sessions per pair give no transfer benefit.
- **Linearity assumption for transfers.** Chose log residuals + Spearman-correlation flag at ≥10 observations + additional SE widening proportional to residual stddev when flagged. Doesn't fit a non-linear model (overkill for v2); detects when linearity is wrong and widens uncertainty accordingly.
- **`StimulusResponseProfile` (.volumeBiased / .balanced / .intensityBiased): include vs drop.** Dropped. Single global label was a fortune-cookie; per-muscle would require multi-phase data with meaningful variation that v2 single-user won't generate quickly enough to be useful.
- **Fatigue interaction confidence: count-only vs count × consistency.** Chose count × consistency. `consistencyFactor = max(0, min(1, 1 - stddev/|mean|))` over last 10 observations, with a 0.001 mean-guard for delta-percent values. Hard cap of 0.5 below 15 observations; surfacing threshold 0.7. Practical effect: fatigue interactions don't surface in prompts for the first ~30 sessions per pair.
- **Goal: numerical targets at onboarding vs plain-language → calibration-review projections.** Chose plain-language at onboarding, projections at calibration review. Day-1 numerical targets were pseudo-precision — the AI doesn't have data to project honestly on session 1.
- **Calibration: named "test block" vs continuous.** Chose continuous. No "Assessment Block" / "Week 1 Test" surface; first ~6–8 sessions are normal training, calibration review fires once when per-axis confidences mature.
- **Reassessment cadence: fixed (every 6 / every 12) vs phase-tied.** Chose phase-tied. Light reassessment per-pattern at phase midpoints/transitions (silent, model-internal); heavy reassessment when ≥4 of 6 major patterns transition phase within a 6-session window (UI screen + goal renegotiation).
- **Set intent silent defaults vs explicit-everywhere.** Chose explicit-everywhere. AI prescriptions without intent fail validation; freestyle sets prompt at log time; migration happens in three phases with code validation shipping before DB migration so no write-window gap exists.
- **AI-inferred limitations: corroboration thresholds.** Chose ≥2 corroborating evidence required, cap at `.mild` severity until user-confirmed via UI.
- **Form-degradation classifier: separate vs integrated with limitation classifier.** Chose integrated single LLM call with structured multi-part output. Form-degradation and limitations are independent signals — a note can contribute to both.
- **Day boundaries for cadence: device-local vs UTC vs pre-bucketed local.** Chose pre-bucketed `localDate` string at write time. Immune to subsequent timezone changes (user travels Sydney → Tokyo without breaking cadence calculations).
- **Disruption history (`lifeContextEvents`): act now vs persist-only vs defer.** Chose persist-only — cheap detection seeds v2.5 work for free without committing to a consumption design now.

## Consequences

### Service supersession

- `StagnationService` is superseded — its Epley-based logic moves into the trainee-model update routine, output lives on `MuscleProfile.stagnationStatus` and `PatternProfile.trend`.
- `VolumeValidationService` is superseded with semantics fix — output lives on `MuscleProfile.volumeDeficit`, windowed over last 7 training events (not calendar weeks per ADR-0002).
- `PatternPhaseService` is partially folded in — phase storage moves to `PatternProfile.currentPhase` + `sessionsInPhase`, advance logic gains plateau-awareness (clearly plateaued patterns no longer auto-advance).
- `MemoryService` (RAG) is reframed as a sensor — kept and extended with `summariseRecentNotes()` cadence that classifies form-degradation + limitations into structured trainee-model fields. Not demoted; the RAG embedding pipeline still runs for episodic semantic search at set-by-set inference time.

### Implementation consequences

- `WorkoutContext` payload becomes a `TraineeModelDigest` — a request-time projection of relevant trainee-model fields, narrower than the full model (token economics).
- Update rules run server-side via Supabase Edge Function (per ADR-0006); idempotency at DB layer; client posts session-completion events via the existing `WriteAheadQueue` rails.
- The `MovementPattern` enum is cleaned to motion patterns only — calves and core are removed (calves contribute to `legs` muscle-group volume aggregation; core is not modelled as a first-class trainee axis in v2).
- `MuscleGroup` is locked at six (back / chest / biceps / shoulders / triceps / legs) — drives both the trainee model's per-muscle storage and the Progress tab's narrative cards.
- The trainee model is the AI's *behavioural memory*; the `MesocycleSkeleton` (ADR-0002) is the AI's *plan*. Session generation reads both: skeleton for what's queued next, trainee model for who the user is. Keeping them separate means each can evolve independently — the skeleton can be regenerated without losing trainee-model state, and the trainee model accumulates across multiple regenerated programmes.
