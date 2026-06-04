# Day-label convention is a stable per-user key, preserved across regen

**Status**: accepted, 2026-06-04

## Context

A program's training days carry a **day label** — the same concept named three
different things across the layers it passes through:

- `day_focus` — the free-text muscle-group string the macro-plan LLM emits per day in the skeleton (e.g. `"Upper Push"`).
- `dayLabel` — the Swift `TrainingDay.dayLabel`, derived from `day_focus` via `MacroPlanService.normalizeDayLabel` (snake_case, e.g. `Upper_Push`).
- `day_type` — the `workout_sessions.day_type` column persisted per logged session, equal to the `dayLabel` of the day that was trained.

The day label is not cosmetic. `ProgramViewModel.deepLiftHistory` looks up a
day's per-exercise history with `Filter(column: "day_type", op: .eq, value: day.dayLabel)`.
That is, **the day label is the join key between a planned day and the user's
historical sets for that kind of day.** Progression context (recent loads, e1RM
trend) flows to the session AI through this lookup.

Issue #172 exposed the consequence of treating the label as disposable. On
**program regeneration**, the macro-plan LLM was given no knowledge of the labels
the user already trained under. It invented a fresh convention (`Lower`,
`Upper_Push`, `Upper_Pull`, `Full_Body`) while `ProgramViewModel.regenerateProgram`
grafted the previously-completed days back in carrying their *original* labels
(`Push_A`, `Pull_A`, `Legs_A`). The result was a single `mesocycle_json` holding
two label conventions concatenated — for the alpha user, 45 of 60 days had labels
that matched no historical session. Because `deepLiftHistory` joins on the label,
every new-convention day matched zero history: the AI lost the user's lift history
for ~75% of the program and reset to "fresh user" progression. This is the actual
root cause behind the `0 set_logs across 0 exercises after regen` symptom reported
in #141 (which had hypothesised `program_id` scoping — the wrong cause).

The pre-existing macro-plan prompt already said "All 12 weeks MUST use the SAME
day_focus order" — but that only enforces *internal* consistency within one
generation. It said nothing about consistency *across* generations, and in fact
actively told the LLM to "derive the structure from first principles" and "DO NOT
use named splits like 'Push A'" — directly at odds with reusing the user's
established `Push_A`/`Pull_A` convention.

## Decision

**The day-label convention is a stable per-user key. Once a user has training
history under a set of day labels, program regeneration MUST preserve that
convention rather than mint a new one.**

Concretely:

1. The macro-plan request carries an optional `history.recent_day_labels` block —
   the user's distinct `day_type` values from their recent `workout_sessions`,
   fetched by `ProgramViewModel.generateMacroSkeleton` (the shared path
   `regenerateProgram` delegates to) and threaded through
   `MacroPlanService.generateSkeleton(historicalDayLabels:)`. The block is
   **omitted entirely** (synthesized `encodeIfPresent`) for a user with no
   history, so first-program generation is unchanged.
2. When `history.recent_day_labels` is present, the macro-plan system prompt
   instructs the LLM to **reuse those exact labels for all 12 weeks** — and this
   instruction **takes precedence** over the first-principles / no-named-splits
   guidance, while still honoring the hard `training_days_per_week` count.
3. When the block is absent, the LLM derives labels from first principles as
   before.

The fix lives in the shared `generateMacroSkeleton`, so `regenerateProgram` is
covered without changing its graft logic: once the newly generated weeks reuse
the historical labels, they match the grafted completed days and the
two-convention "Frankenstein" mesocycle can no longer form.

## Consequences

- Lift history stays attached to each planned day across regenerations.
  `deepLiftHistory`'s `day_type = dayLabel` join keeps resolving after a regen.
- The three names for the day label (`day_focus` → `dayLabel` → `day_type`) are
  one concept across layers; see CONTEXT.md. Code that mints or transforms a day
  label must keep the normalized form stable (`normalizeDayLabel` is idempotent
  on already-normalized labels, so the LLM emitting the historical strings
  verbatim survives normalization unchanged).
- This is an LLM-prompt-enforced invariant, not a hard schema constraint: the
  model is *instructed* to reuse labels. The deterministic guard is the test that
  the labels reach the prompt (`MacroPlanServiceHistoricalLabelsTests`); whether
  the LLM obeys is a prompt-quality concern, not unit-testable.
- A second caller of `generateSkeleton` exists — `OnboardingView` (first-program
  generation). It was intentionally left passing the default empty
  `historicalDayLabels`: onboarding is a brand-new user with no sessions, so the
  behavior is identical. If onboarding is ever made re-runnable for a returning
  user, it should fetch and pass historical labels too.

## Supersedes / supersedes-by

Supersedes the pre-#172 behavior where program regeneration let the macro-plan
LLM choose a fresh day-label convention with no knowledge of the user's history.
Not yet superseded.
