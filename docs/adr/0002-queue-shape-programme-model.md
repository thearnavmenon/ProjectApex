# Queue-shape programme model: drop calendar dates

**Status**: accepted, 2026-05-01

## Context

The original v1.0 PRD framed the programme as a calendar-anchored 12-week mesocycle with sessions assigned to specific dates. By the time v2 design started, the shipped behaviour had already drifted: FB-011 made progression training-time-anchored (no calendar advancement), FB-009 allowed free day selection (any generated session can start regardless of date), and `GymStreakService` counted training events with a 1-day-gap absorber rather than calendar streaks. Three independent features were quietly converging on the same model — the calendar metaphor was decorative, not load-bearing.

## Decision

The programme is a **queue of sessions in a fixed phase-aware order**, advanced by training events (completion or skip), not by calendar time. Specifically:

1. The `MesocycleSkeleton` is a sequence of typed slots (Push A, Pull A, Legs A, …) grouped into phases (Accumulation, Intensification, Peaking, Deload). No dates.
2. Length is measured in **sessions, not weeks**. A trainee on holiday for two weeks doesn't "lose" two weeks of programme — they pick up the queue where they left off.
3. **Rest days are not modelled.** "Rest day" is a calendar concept with no place in a queue model. Time between sessions is unstructured and rendered as the absence of a session, not as a planned event.
4. Programme length is flexible — the macro skeleton can extend or compress at reassessment based on observed progress, rather than terminating at a fixed 12-week boundary.
5. **The programme is calendar-free; the Today UI uses local-clock day-boundaries for state transitions only.** This demarcation matters: the *programme* (skeleton, queue, advancement) never references calendar dates. The *Today UI surface* uses local-clock 4am day-flips for the post-session → pre-session state transition (per ADR-0003), because "today" is a local-clock concept for the user. The two layers are decoupled — calendar lives only in the user-facing state transition, not in any programme data.

## Considered Options

- **(A) Calendar-shaped programme, original v1.0 spec.** Sessions assigned to dates; calendar grid as primary surface. Rejected: doesn't match the user's actual training pattern (variable cadence, travel, life context), and FB-011 had already reverted the advancement logic away from this model.
- **(B) Hybrid: calendar grid for display + training-time advancement for state.** Visually calendar-shaped, semantically queue-shaped. Rejected: lying about what the data represents leads to UX inconsistency (e.g., what does "Tuesday" show on a queue-progressing programme where Tuesday hasn't been trained?).
- **(C) Pure queue (chosen).** Calendar metaphor dropped from both data model and UI. Programme tab becomes a phase-segmented vertical list of sessions in queue order; Today shows "Up next" rather than "Today's session."

Within the chosen (C) pure-queue model, three sub-variants were also weighed:

- **(C-i) Length: fixed 12 weeks vs flexible.** Chose flexible — the macro skeleton can extend if progress is slow, compress if fast. Reassessed every 6 sessions (light) and at phase transitions (heavy).
- **(C-ii) Length unit: weeks vs sessions.** Chose sessions. "12 weeks" implies calendar progression; "48 sessions" describes the actual programme content.
- **(C-iii) Rest days: explicit entity vs derived from absence vs not modelled at all.** Chose not modelled. Derivation worked but produced empty calendar cells with no semantic content; the queue model has no place for "non-training days" because the unit of work is the session, not the day.

## Consequences

- The `Week` model in code keeps `dayOfWeek: Int` only as a programmed-week ordinal (1 through `daysPerWeek`), not a Mon–Sun mapping. Future readers should not treat it as a calendar mapping.
- `VolumeValidationService` (and its successor in the trainee model) windows over **last 7 training events**, not last 7 calendar days.
- Reminders / nudges (N1 staleness, N2 day-of) use queue-aware language ("Push A is up next — when you're ready"), never schedule-shaming ("you missed Tuesday").
- `disruptedPatterns` detection (long-absence flag) uses days-since-last-session, but the *programme* never advances on calendar tick — only the user's *re-entry* coaching does.
- Multi-gym programme architecture (per ADR-0005, persistent trainee model) inherits this shape — the queue is user-scoped, gym-aware Stage 2 generation produces gym-specific prescriptions per session.
