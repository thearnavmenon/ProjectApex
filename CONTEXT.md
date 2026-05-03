# Project Apex — Domain Glossary

The ubiquitous language for Project Apex. When writing code, issues, PRDs, tests, or commit messages, use these terms exactly. Don't drift to synonyms listed under `_Avoid_`.

If a concept needs more than two sentences to define, it isn't a term — it's a concept. The ADR is the source of truth; this file links to it.

## Language

### Programme structure

**Queue**:
The programme as an ordered list of session slots, advanced by training events not by calendar time. See ADR-0002.
_Avoid_: schedule, calendar, plan

**Mesocycle skeleton**:
The gym-agnostic ordered sequence of session slots grouped into phases; lives in `programs.mesocycle_json`. See ADR-0002, ADR-0005.
_Avoid_: programme plan, mesocycle (without "skeleton")

**Mesocycle phase**:
One of Accumulation, Intensification, Peaking, or Deload — phase position is per-pattern, not global.
_Avoid_: programme phase, training block

**Pattern phase**:
The current phase position for a single movement pattern within the mesocycle phase progression. Stored on `PatternProfile.currentPhase`.
_Avoid_: phase (when ambiguous)

### Trainee model

**Trainee model**:
The persistent structured behavioural model per user — capability, recovery, goal, projections — updated server-side after each session. See ADR-0005, ADR-0006.
_Avoid_: user profile, user state, user data

**Calibration review**:
The one-time UI screen fired when ≥4 of 6 major patterns reach `.established` per-axis confidence; sets floor + stretch projections. See ADR-0005.
_Avoid_: assessment, test block, week 1 test

**Floor projection**:
The capability-based realistic target — immovable on goal renegotiation. See ADR-0005.
_Avoid_: target, conservative goal

**Stretch projection**:
The user-adjustable-upward target — re-derived silently on goal renegotiation. See ADR-0005.
_Avoid_: ambitious target, max goal

### Movement & sets

**Movement pattern**:
A type of motion. Eight cases per the typed `MovementPattern` enum (Slice 1): `horizontalPush`, `verticalPush`, `horizontalPull`, `verticalPull`, `squat`, `hipHinge`, `lunge`, `isolation`. Strictly motion taxonomy — independent from muscle classification.
_Avoid_: muscle group, exercise category

**Muscle group** (trainee-model aggregation key):
One of six body-part groups (back, chest, biceps, shoulders, triceps, legs) — locked at six. The trainee model's `muscles: [MuscleGroup: MuscleProfile]` keys on this. Calves and core are not first-class muscle groups in v2.
_Avoid_: movement pattern, body part (in code), primary muscle (different concept — see below)

**Primary muscle** (ExerciseLibrary classification, Slice 1):
Finer-grained muscle classification carried on `ExerciseDefinition.primaryMuscle`. Nine cases: back, chest, biceps, shoulders, triceps, **quads, hamstrings, glutes, calves**. Used by AI prescription reasoning so the model can distinguish leg subgroups for muscle-balance coaching. Maps to `MuscleGroup` via `PrimaryMuscle.muscleGroup` (leg subgroups → `.legs`). Core is excluded — the 4 historical core exercises were removed from the library in Slice 1.
_Avoid_: muscle group (different concept — primary muscle is finer-grained)

**Set intent**:
The required field on every set — `warmup`, `top`, `backoff`, `technique`, or `amrap`. No silent defaults at any layer. See ADR-0005.
_Avoid_: set type, set kind

**Top set**:
A set with `intent == .top` AND reps in 3..10 — the sole contributor to e1RM estimation.
_Avoid_: heavy set, max set, working set

### Capability metrics

**e1RM**:
Epley estimated 1-rep max — `weight × (1 + reps / 30)`, computed only on top sets within the 3..10-rep validity range.
_Avoid_: 1RM, one-rep-max

**EWMA**:
Exponentially weighted moving average over the last 5 valid top sets, α = 0.333 — the standard mode for e1RM estimation. See ADR-0005.
_Avoid_: rolling average, moving average (without qualifier)

**Transition mode**:
A per-pattern flag that collapses the e1RM update window from N=5 EWMA to N=3 plain-mean over recent sessions. Triggered by calibration recency, deload-end, phase transition, or long-absence return. **Unrelated to mesocycle phase transition.** See ADR-0005.
_Avoid_: phase transition

### Coaching signals

**Stimulus dimension**:
A set's training stimulus classification — `neuromuscular`, `metabolic`, or `both`. Warmup and technique sets classify as `nil`. Drives two-dimensional recovery. See ADR-0005.
_Avoid_: training stimulus, fatigue type

**Active limitation**:
A currently flagged injury / pain state per pattern, muscle, or joint — AI-inferred caps at `.mild` until user-confirmed.
_Avoid_: injury, pain (too general)

**Cleared limitation**:
An archived limitation resolved through clean training — retention capped at 50 entries / 12 months.
_Avoid_: resolved injury, healed limitation

**Form degradation flag**:
An SE-widening signal on an exercise when notes mention form decay. Independent from active limitation; a single note can contribute to both.
_Avoid_: technique flag, form note

**Fatigue interaction**:
A cross-pattern carryover signal — surfaces in prompts only at confidence ≥ 0.7 with ≥15 paired observations.
_Avoid_: crossover fatigue, pattern interaction

**Prescription accuracy**:
The AI's own bias and RMSE per pattern × intent — meta-coaching about the AI's miscalibration. Distinct from a single intent mismatch at log time.
_Avoid_: AI accuracy, calibration

### Multi-gym

**Cross-gym transfer**:
Capability follows the user across gyms; per-session generation is gym-aware. See ADR-0002, ADR-0005.
_Avoid_: gym switch, multi-gym sync, cross-exercise transfer (different concept)

### Build process (Mattpocock skills vocabulary)

**HITL**:
Human-in-the-loop — issue tag for items requiring human input (visual feedback, design judgment, product decisions).
_Avoid_: human-required, manual

**AFK**:
Away-from-keyboard — issue tag for items an agent can run autonomously without human context.
_Avoid_: automated, agent-only

**Tracer-bullet vertical slice**:
The unit of work for `to-issues` — a thin end-to-end cut through all integration layers (data → logic → UI), independently mergeable and testable.
_Avoid_: feature, ticket, story, horizontal slice

## Relationships

- A **Trainee model** belongs to one user; a **Mesocycle skeleton** belongs to one programme; one user has one trainee model and one or more (paused) mesocycle skeletons.
- The **Queue** is a view over the active **Mesocycle skeleton**.
- **Top set**s feed **EWMA**; **EWMA** computes **e1RM**; **transition mode** changes the EWMA window shape.
- A **Set intent** value gates whether a set contributes to **EWMA** (only `top`), volume aggregation, and RPE calibration.
- **Stimulus dimension** classifies sets and feeds two-dimensional recovery on **PatternProfile**.
- A **Form degradation flag** widens **e1RM** SE; an **active limitation** gates exercises and prescription.
- **Calibration review** sets **floor projection** and **stretch projection** using current **EWMA** capability.
- **Movement pattern** and **muscle group** are independent taxonomies — a set is associated with both via its exercise.

## Example dialogue

> **Engineer**: "What does it mean for the trainee model to be 'in transition mode' for bench?"
> **Domain**: "**Transition mode** is a flag on the bench's `PatternProfile` that collapses the **EWMA** window from 5 top sets to the 3 most recent sessions, switching from exponential weighting to plain mean. Triggered by calibration recency, deload-end, **pattern phase** transition, or long-absence return — and importantly, it's *not* the same thing as a mesocycle phase transition. See ADR-0005."

> **Engineer**: "Should this be a `ready-for-agent` issue or `ready-for-human`?"
> **Domain**: "If the work is a **tracer-bullet vertical slice** with no visual or design-judgment component — schema, server-side rules, deterministic logic — it's **AFK** and gets `ready-for-agent`. If it needs visual feedback or product judgment, it's **HITL** and gets `ready-for-human`."

## Flagged ambiguities

- **"Phase"** is overloaded. Always qualify: **mesocycle phase** (Accumulation / Intensification / Peaking / Deload) is unrelated to **transition mode** (an EWMA window-mode flag).
- **"Transfer"** is overloaded. **Cross-gym transfer** = capability follows user across gyms. **Cross-exercise transfer** = capability extrapolation between related exercises (e.g., bench → OHP). Different mechanisms; surface both terms when both apply.
- **"Top set"** is not "the heaviest set in a session" — it requires `intent == .top` AND reps in 3..10. A heaviest set with reps > 10 is not a top set and does not contribute to e1RM.
- **"Limitation"** vs **"form degradation flag"**: independent signals about different things (joint health vs technique quality). A single note can contribute to both.
