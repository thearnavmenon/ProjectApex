# Hybrid plateau verdict semantics on the trainee model

**Status**: accepted, 2026-05-07; amended 2026-05-07 (muscle-level aggregation rule)

## Context

ADR-0005 specifies that `StagnationService` is superseded by `MuscleProfile.stagnationStatus` and `PatternProfile.trend` on the trainee model — both typed `ProgressionTrend` (`progressing | plateaued | declining`). The ADR does not pin the *rule* that produces the verdict; the existing `StagnationService` rule (e1RM-only, fixed 3-session window, 2% spread, avgRPE<8 plateau conjunction, ≥5% drop with <5d-gap heuristic for declining) was written in a strength-shaped model and inherits cleanly only if Project Apex commits to strength-only positioning.

ADR-0005 explicitly justifies two-dimensional recovery and the muscle-profile volume fields with **"hybrid hypertrophy/strength trainees where heavy 1–3RM and high-rep moderate work tax different systems."** The system prompts open with "elite AI strength and hypertrophy coach." The trainee-model architecture is unambiguously hybrid-shaped. Lifting the legacy strength-only verdict into hybrid territory is therefore a coherence question: the verdict surface should match the architecture's positioning.

Three concrete failure modes of the legacy e1RM-only rule under hybrid positioning:

1. **Volume-shifted progression invisibly flagged as plateau**: a user grinding through more working sets at the same top-set weight is making real hypertrophy progress, but the e1RM track shows flat. The verdict fires `plateaued` and the AI prescribes change-the-weight when the right move is more volume.
2. **3-session window too short for low-frequency patterns**: at 1×/week pattern frequency (common for accessory work), 3 sessions is 3 weeks of data — within normal between-session variance for a noise-driven 2% e1RM swing.
3. **<5d-gap declining heuristic blind to low-frequency overreaching**: the demographic that overreaches on once-weekly accessory work has no recovery buffer to catch them, but the legacy rule silently exempts them by requiring the inter-session gap to be tight.

This ADR pins the verdict semantics rather than leaving them at the ADR-0005 concept level. Tightly coupled to ADR-0005 (the architectural commitment), ADR-0002 (queue-event windowing for the volume track), and ADR-0008 (chronological session ordering — the verdict consumes the trainee model's stream).

## Decision

The trainee model populates `MuscleProfile.stagnationStatus` and `PatternProfile.trend` from a **hybrid two-track verdict** combining e1RM EWMA flatness with volume-load flatness. Each track has its own window and threshold; the verdict aggregates with OR for `progressing` and AND for `plateaued`.

### Tracks

**e1RM track** (per-pattern, per-exercise — aggregates up to muscle):
- Signal: EWMA of top-set e1RM over the validity window from ADR-0005 (last 5 valid top sets, validity 3..10 reps).
- Window: **frequency-scaled** — 3 sessions when the pattern's `sessionsCadenceDays` ≤ 3.5 (≥2×/week); 4 sessions when `sessionsCadenceDays` > 3.5 (≤1×/week).
- Plateau threshold: e1RM spread ≤ **2.5%** across the window (sharpened from the legacy 2% to reduce false-positives on noise-driven swings).
- Plateau effort gate: avgRPE < 8.0 across the window. When avgRPE is nil (manual logs), require window + 1 sessions before firing — mirrors legacy `StagnationService`'s manual-log defence.

**Volume-load track** (per-muscle, per-pattern):
- Signal: weekly volume-load (Σ `weight × reps × sets` for non-warmup sets, top + backoff + amrap), aggregated over the last 7 training events (per ADR-0002 queue-event windowing).
- Plateau threshold: weekly volume-load spread ≤ 5% across a trailing 4-window comparison.
- Plateau effort gate: avgRPE < 8.0 across the window. A drop in volume-load with avgRPE ≥ 8.0 is "user is grinding through the same load" — fatigue/programming signal, not plateau.

**Decline rules** (replaces legacy <5d-gap heuristic):
- e1RM track: e1RM dropped ≥ 5% from start to end of the window AND avgRPE ≥ 7 (drops on low-RPE sessions are coasting, not decline).
- Volume-load track: weekly volume-load exceeds 115% of the trailing-4-week average (overreaching detector) OR drops ≥ 10% in the most recent window relative to the prior window.
- OR aggregation: either track firing yields `declining`.

### Verdict aggregation

| e1RM track  | Volume track | Verdict       |
|-------------|--------------|---------------|
| improving   | any          | `progressing` |
| any         | improving    | `progressing` |
| flat        | flat         | `plateaued`   |
| declining   | any          | `declining`   |
| any         | declining    | `declining`   |

Where "improving" means neither plateau nor declining on that track. Plateau requires both tracks flat — not e1RM-only flat — because volume-shifted progression (e1RM stuck, working sets climbing) is real progress that the verdict must not bury.

### Aggregation to `MuscleProfile.stagnationStatus` (amended 2026-05-07)

The original ADR text described the e1RM track as "per-pattern, per-exercise — aggregates up to muscle" without pinning the aggregation rule. This amendment fills that hole.

**Rule:** for each `MuscleGroup M`, `MuscleProfile.stagnationStatus` is the **worst** trend across the participating patterns, where worst order is `declining > plateaued > progressing`.

**Participation precondition:** a pattern `P` participates in muscle `M`'s aggregation iff:
- `∃` exercise `e` such that `ExerciseLibrary.primaryMuscle(e).muscleGroup == M` and `e.movementPattern == P`, AND
- `PatternProfile[P].confidence > .bootstrapping` (the pattern has accumulated enough data for its trend to be evaluable).

**Empty-participation case** (zero patterns above bootstrapping confidence map to `M`):
- `stagnationStatus = .progressing` — `ProgressionTrend` has no `.bootstrapping` case; `.progressing` is the no-signal default.
- The cold-start signal is carried by `MuscleProfile.confidence`, which stays at `.bootstrapping` independently. LLM digest consumers MUST read both fields — when `confidence == .bootstrapping`, the `stagnationStatus` value carries no actionable signal regardless of its trend value.

**Why worst-across-patterns** (asymmetric-error preference per `docs/design-principles.md`):
- Loud failure mode: muscle reads `.declining` because one pattern is declining → triggers exercise-rotation / programme-rebuild coaching cues; the user can override or RPE will quickly disconfirm if the muscle is actually fine.
- Silent failure mode: muscle reads `.progressing` while one pattern is regressing → no coaching intervention; the regressing pattern accumulates damage.
- Pick the loud one.

**Considered alternatives:**
- **Majority-vote with worst tiebreak** — smoother, more representative of average pattern state, but a 3-progressing/3-plateaued tie aggregates to plateaued (or progressing under a different tiebreak); the tiebreak rule is itself a decision and either direction has the asymmetric-error problem unsolved.
- **Re-apply the hybrid verdict at muscle level** (compute muscle-level e1RM track aggregating exercises whose `primaryMuscle.muscleGroup == M`, plus the already-per-muscle volume-load track, then run the OR/AND aggregation table at muscle level) — architecturally cleaner; reuses verdict logic. Rejected for v2 because muscle-level e1RM aggregation requires a sub-decision (max-of-exercises vs mean vs primary-exercise dominance) that ducks the same grilling. Documented as the v2.x upgrade path below.

**Concentration of aggregation risk on `legs` and `back`:**

The "one bad pattern poisons the muscle signal" risk is concentrated on muscle groups with multiple participating patterns:
- `legs`: 3 primary patterns (squat, hipHinge, lunge)
- `back`: 2 primary patterns (horizontalPull, verticalPull)
- `chest`, `shoulders`, `biceps`, `triceps`: 1 or 0 primary patterns (single-pattern muscles aggregate trivially)

Squat plateaus are particularly common (squat is the most-trained lower-body lift in alpha-cohort training programmes); under worst-across-patterns, a single squat plateau forces `legs.stagnationStatus = .plateaued` even when hipHinge and lunge are progressing. **This is the right direction by asymmetric-error reasoning, but it's also the most likely place where alpha-cohort behaviour pushes toward the v2.x upgrade.**

**Watch trigger** (catalogued in `docs/v2.x-watch-items.md`): if leg-muscle `stagnationStatus` reads `.plateaued` more than ~30% of the time across the alpha cohort's session-applies, that's the signal to re-apply ADR-0009's hybrid verdict at muscle level (the v2.x upgrade path) rather than aggregating from per-pattern verdicts. Until that trigger fires, worst-across-patterns is the right v2 rule.

**v2.x upgrade path:**

If alpha cohort surfaces the legs-aggregation problem, v2.x re-applies this ADR's verdict table at the muscle level. The required sub-decisions for that upgrade:
1. Muscle-level e1RM aggregation rule (max-of-exercises vs mean vs primary-exercise dominance per muscle).
2. Whether to keep per-pattern `PatternProfile.trend` as a separate signal alongside the muscle-level verdict, or derive it from the muscle-level result.
3. Whether the volume-load track stays per-muscle (already its v2 shape) or stratifies further.

The v2.x upgrade is forward-only per ADR-0006 — no auto-recompute of historical aggregations.

## Considered Options

- **Preserve e1RM-only verdict from legacy `StagnationService`, lifted server-side.** Rejected: incoherent with hybrid positioning; misses volume-shifted progression; false-positives on low-frequency patterns where 3 sessions = 3 weeks of data; <5d-gap heuristic silently exempts low-frequency overreachers.

- **Drop e1RM track entirely; use volume-load only.** Rejected: strength-leaning users (powerlifting-adjacent programming, 5×5/Wendler) whose top-set e1RM is the primary progression signal would have plateau detection blind to their actual training quality.

- **Three-track verdict adding RPE-trend as a third axis.** Rejected for v2: RPE measurement noise is high (users underreport/overreport inconsistently); a third aggregation axis multiplies the false-positive surface; fatigue interactions and prescription-accuracy fields already capture RPE-derived insight without firing into the plateau verdict.

- **Pure rule-based verdict (no AI judgment).** Chosen — alignment with ADR-0005's "rules computed server-side, deterministic" stance. AI consumes the verdict as a structured signal in the digest; AI does not run the verdict computation.

- **Frequency-scaled window only (no e1RM threshold sharpen).** Rejected as insufficient — the noise floor on day-to-day e1RM is empirically 3–5% for untrained-to-intermediate lifters; 2% threshold even with a 4-session window false-positives on bad-sleep doublings. The 2.5% number is a defensible compromise that preserves real-plateau sensitivity while suppressing the most common noise floor.

## Consequences

- The Edge Function gains the hybrid verdict rule. Implementation lives in the same stored procedure as the trainee-model update routine. The rule reads from the existing `set_logs` history (filtered by `intent` and validity) and the existing `PatternProfile.sessionsCadenceDays`; no new schema.

- `StagnationService` (Swift) is deleted in Phase 2 — its e1RM-only rule, 2% threshold, and <5d-gap heuristic have no successor on the client. The verdict comes from the trainee-model snapshot in the digest.

- The system prompts (`SystemPrompt_Inference.txt`, `SystemPrompt_SessionPlan.txt`) gain a `MuscleProfile.stagnationStatus` / `PatternProfile.trend` digest field, replacing the scattered `stagnation_signals` array currently encoded.

- Frequency-scaled window requires the rule to read `PatternProfile.sessionsCadenceDays`. That field is already populated as a derived property on the existing type; the rule consumes a cadence threshold (≤3.5 days/session ⇒ 3-session window; >3.5 days ⇒ 4-session window). No new state.

- The 2.5% spread threshold and the 115%-of-trailing-4-week overreach detector are tunable parameters. v2.5 may revisit based on alpha cohort data; the rule itself is forward-only per ADR-0006, so re-tuning applies to subsequent updates without auto-recompute.

- Plateau-awareness on phase-advance (per ADR-0005's "advance logic gains plateau-awareness") composes with this verdict: a pattern with `trend = .plateaued` does not auto-advance even when the Option-B session-count threshold from the legacy `PatternPhaseService` is met. The composition rule is governed separately by the phase-advance design (Phase 2 grilling open question).

- Volume-load track requires a derived `weeklyVolumeLoad: Double` computation over 7-training-event windows. Composes with the `VolumeValidationService` supersession (per ADR-0005) — both volume-deficit and volume-load-trend pull from the same windowed primitive.
