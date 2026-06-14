# Cadence-aware session-to-time translation pattern

**Status**: accepted, 2026-05-07

## Context

Project Apex models **user-experienced training time, not calendar time**. Adaptation, recovery, staleness, and pattern-disruption all key off training events rather than wall-clock days (per ADR-0002's queue-event-windowed programme model). When a derived rule needs to express "after N sessions of training" but the storage shape is forced to be a `Date` (because the consumer is wall-clock-aware — e.g., a `Date` comparison against `now` in `inTransitionMode(asOf:)`), a translation step is required.

The pattern recurs across multiple decisions:

1. **`PatternProfile.transitionModeUntil`** (Phase 2 / Q5 grilling): set to `now + max(14d, 3 × cadence)` when triggered, with `nil`-cadence fallback to `now + 21d` (covering the long-absence-returner case where assuming a fixed cadence would undershoot).
2. **`disruptedPatterns` derivation** (per ADR-0005): a pattern is disrupted when `daysSinceLastSession > 2 × sessionsCadenceDays`.
3. **Future "long-absence return" or "stale pattern" detections** are likely candidates for the same shape.

The translation has consistent failure modes when poorly implemented:

- A fixed time threshold (e.g., "stale = 14 days, full stop") penalizes high-frequency users — at 4×/week, a missed week is 4 missed sessions; at 1×/week, it's 1 missed session. Treating these the same is wrong.
- A fixed session-count threshold without a calendar-day floor produces pathological values at very high cadence — `3 × 1-day cadence = 3 days` is too short to mean "3 sessions of stabilization" in any useful sense.
- A naive `nil`-cadence fallback to a fixed cadence assumption (e.g., "default to 3.5 days/session") undershoots the realistic nil case — the long-absence-returner whose prior cadence was sparse.

This ADR documents the translation pattern itself so future rules adopt the consistent shape, the pitfalls are surfaced once rather than rediscovered, and the architectural commitment (event-coded > calendar-coded) is explicit.

## Decision

When a rule needs to express "N sessions of training" as a wall-clock duration, use:

```
durationDays = (cadence == nil)
    ? nilCadenceFallbackDays                          // conservative, calendar-day floor
    : max(floorDays, N × cadenceDays)                 // session-derived, with calendar floor
```

Where:
- `cadence: Double?` is `PatternProfile.sessionsCadenceDays` (mean delta in days between consecutive recent sessions; nil when fewer than 2 sessions are recorded for the pattern).
- `N` is the session-count semantic the rule is trying to express.
- `floorDays` is a calendar-day minimum that prevents pathological values at very high cadences. Typically chosen so that `floorDays / max_realistic_cadence ≥ N` at the high-frequency end.
- `nilCadenceFallbackDays` is a conservative fallback when no cadence is available. The realistic nil case is a long-absence-returner whose previous cadence was sparse; default to longer than the typical floor (e.g., 21d when the floor is 14d) so the rule covers ~3 sessions even at a 1×/week assumed resume.

### Why event-coded, not calendar-coded

The system models adaptation as a function of training events. Recovery decay (per ADR-0010) is wall-clock-driven for sound physiological reasons (the body does recover in calendar time), but the *triggers* and *windows* that gate adaptation logic are session-driven because they ask "given this user's training, where do they sit on the adaptation curve?" Two users training at the same calendar interval but different session frequencies sit at different points on that curve; calendar-based gates would over-react to one and under-react to the other.

The queue-event-windowed programme model (ADR-0002) is the foundational commitment. This translation pattern operationalizes it in fields where the consumer's storage shape is forced to be `Date`.

### Common pitfalls

1. **Naive `nil`-cadence fallback to a fixed cadence assumption**: the realistic nil case is a long-absence-returner whose previous cadence was sparse. Assuming "3.5 days/session" means the rule fires after `3.5 × N` days, which undershoots the N-session intent. Fallback should be conservative (longer) and calendar-day-coded directly.

2. **Using calendar time for "long absence" or "stale pattern"**: penalizes high-frequency users for training more. Cadence-aware translation distinguishes the 4×/week-missing-a-week case from the 1×/week-missing-a-week case.

3. **Missing the calendar-day floor**: at very high cadence (e.g., cadence = 1 day), `3 × cadence = 3 days` is too short to mean "3 sessions worth of stabilization" — the user's body hasn't recovered, the EWMA hasn't accumulated meaningful new data. The floor catches this.

### Current usages

| Usage | Formula | Where |
|-------|---------|-------|
| Transition-mode expiry (DURATION) | `now + max(14d, 3 × cadence)`, nil → `now + 21d` | Q5 / Phase 2 PRD-internal, code comments cite this ADR |
| `disruptedPatterns` derivation | `daysSinceLastSession > 2 × sessionsCadenceDays` | ADR-0005 (pre-existing; this ADR documents the pattern that ADR-0005 instantiated) |
| Long-absence transition **trigger** | `gapDays ≥ 28` (flat calendar days, **not** cadence-aware) | `_shared/long-absence.ts`; deliberate exception — see Amendment 2026-06-14 |

Future rules adopting the shape MUST cite this ADR in their code comments and Considered Options sections.

## Considered Options

- **Calendar-time-only thresholds** ("stale pattern = 14 days, full stop"): rejected. Penalizes high-frequency users; mismatches ADR-0002's queue-event programme model.

- **Session-count-only thresholds without time floor**: rejected. Pathological at high cadence — `3 × 1-day cadence = 3 days` is too short to mean "3 sessions of stabilization" for any practical purpose.

- **Per-rule ad-hoc translation without a shared pattern**: rejected (this ADR exists). Future maintainers tuning one rule would not know adjacent rules use the same translation; inconsistency invites bugs and tuning drift.

- **Replace `Date`-storage fields with session-count storage** (e.g., `transitionModeUntilSessionCount: Int?`): rejected for v2. The Codable migration cost across `RecoveryProfile` and `PatternProfile` is non-trivial; the consumer of these fields (the LLM digest) reads `Date` cleanly. Future v3 may revisit.

## Consequences

- Future rules adopting "N sessions of training" semantics translate via this pattern. The formula is consistent: `max(floorDays, N × cadence)` with conservative nil-cadence fallback.

- Code comments at each usage site cite this ADR. The translation rationale (event-coded > calendar-coded; nil-fallback for long-absence-returners; floor for high-cadence pathology) doesn't repeat at each site — future readers land on the ADR for context.

- Tuning a specific instance (e.g., changing Q5's `3 × cadence` to `4 × cadence`) is local — doesn't require ADR amendment. Tuning the *pattern itself* (e.g., changing the nil-cadence fallback rule, or adding a multiplicative ceiling) requires ADR amendment because it affects all current and future instances.

## Amendment (2026-06-14) — long-absence trigger is calendar-flat (a deliberate exception)

The long-absence re-anchor (see [ADR-0005](0005-persistent-structured-trainee-model.md) amendment of the same date) introduces a **TRIGGER** that fires at a flat `gapDays ≥ 28`, which is *not* cadence-aware. This is a knowing exception to this ADR's session-relativity thesis (§"the triggers and windows that gate adaptation logic are session-driven"), made for two reasons:

1. **Cross-surface consistency.** The client already gates a user-facing "return phase" cue on a flat `daysSinceLastSession ≥ 28` (`requiresReturnPhaseOverride`). Making the server's estimate-collapse trigger cadence-aware (e.g. `max(14d, 2 × cadence)`) would fire as early as 15 days for some users, so the coach could receive two contradictory return signals for the same gap. One flat definition keeps the surfaces aligned. (The owner ratified flat-28 over the cadence-aware alternative during design.)
2. **The cadence-aware part is preserved where it belongs — the WINDOW.** Only the *detection* is calendar-flat. The transition-mode **DURATION** the trigger opens (`now + max(14d, 3 × cadence)`, nil → `now + 21d`) is unchanged and remains cadence-aware per this ADR. So the system still asks "how many sessions of fresh data re-establish capability?" in event time; it just decides "has a real layoff happened?" in calendar time.

The `disruptedPatterns` 2×-cadence derivation (still session-relative) is unchanged and coexists: it cues the coach; the flat-28 trigger drives the heavier estimate collapse.

- Composition with ADR-0008's late-arrival watermark is implicit: `cadence` is computed from the trainee model's `recentSessionDates`, which excludes refused-late-arrival sessions. Translation rules thus reflect the trainee model's view of the user, not the raw `set_logs` view. This is correct — the model's view is the authoritative one.

- Composition with ADR-0011's force-deload semantics is also implicit: a force-deload event is a phase transition, advances `lastPhaseTransitionAtSessionCount`, but doesn't directly update `recentSessionDates` (which records actual training sessions, not phase events). Cadence calculations remain stable across force-deload events.
