# Global phase advance trigger and the major-pattern enumeration

**Status**: accepted, 2026-05-07

## Context

ADR-0005 specifies three rules that all use a "≥4 of 6 major patterns" threshold:

1. **Calibration review** — fires when ≥4 of 6 major patterns reach `.established` per-axis confidence; sets floor + stretch projections; UI screen.
2. **Global phase advance event** — fires when ≥4 of 6 major patterns transitioned phase within a 6-session window; heavy reassessment UI + goal renegotiation.
3. **Per-pattern advance** (ADR-0011) — uses the per-pattern Option-B threshold (`max(3, phaseWeeks × max(1, daysPerWeek/2))`), not the ≥4-of-6 global rule.

These rules are routinely conflated in casual discussion. ADR-0005 names calibration review and global advance separately but does not pin the 6-pattern enumeration, the window semantics for global advance, or the cooldown rule. ADR-0011 just pinned per-pattern advance and added force-deload-as-transition semantics.

This ADR pins the shared 6-pattern enumeration (used by both calibration review and global advance), the window semantics for global advance, the cooldown rule preventing re-fire spam, and the disambiguation between the three rules.

Tightly coupled to ADR-0005 (calibration review and global-advance concept), ADR-0011 (per-pattern advance and force-deload semantics that count toward this rule's transition tally), and CONTEXT.md (the disambiguation entry that captures the three-rule landscape for future readers).

## Decision

### The three rules — disambiguated

| Rule | Trigger | Frequency | Effect |
|------|---------|-----------|--------|
| Calibration review (ADR-0005) | ≥4 of 6 major patterns reach `.established` per-axis confidence | One-time per user | Sets floor + stretch projections; UI screen |
| Global phase advance event (this ADR) | ≥4 of 6 major patterns had a phase transition within last 6 user sessions | Recurring with cooldown | Heavy reassessment UI + goal renegotiation; re-derives stretch projections (floor untouched) |
| Per-pattern advance (ADR-0011) | `sessionsInPhase >= sessionsRequiredForPhase AND trend == .progressing` | Per-pattern, every session-completion | Advances `currentPhase` to next phase in cycle |

### The 6 major patterns — shared enumeration

```swift
let majorPatterns: Set<MovementPattern> = [
    .horizontalPush, .verticalPush, .horizontalPull, .verticalPull, .squat, .hipHinge
]
// Excluded: .lunge, .isolation
```

This enumeration is shared by **both** the calibration review (ADR-0005) and the global phase advance event (this ADR). Future tuning that touches the enumeration affects both rules.

The set is the canonical movement-based programming framework that modern periodization (Boyle, Helms, Schoenfeld, Israetel, RP) inherits in some form: two upper-push axes, two upper-pull axes, knee-dominant lower (squat), hip-dominant lower (hipHinge).

**hipHinge belongs as peer with squat.** Squat is meaningfully quad-dominant; hinge is posterior-chain-dominant. The hamstrings, glutes, and erectors are major adaptation axes that squat under-stimulates regardless of stance or depth. The "deadlift programming is user-dependent" objection cuts the wrong way — users who avoid deadlifts substitute RDL, hip thrust, or trap-bar variants, all of which are hipHinge pattern. The pattern stays primary even when the specific exercise rotates. Excluding hipHinge would create an enumeration that breaks for any user running hamstring- or glute-focused programming.

**Lunge and isolation are excluded.** Lunge is a unilateral accessory pattern with inconsistent programming volumes across users; counting it would skew the trigger toward users who happen to like single-leg work. Isolation is by definition accessory; counting biceps-curl phase transitions toward macro readiness would dilute the signal.

The enumeration has an implicit asymmetry — 4 upper-body axes, 2 lower-body axes. This is a known characteristic, not a flaw. It reflects how programming actually distributes volume: there are more upper-body muscle groups, programming respects that, the enumeration follows. The ≥4-of-6 threshold is generous enough to absorb the asymmetry in practice.

### Window semantics: last-6-total-user-sessions

The "6-session window" means the user's last 6 completed sessions, any pattern. The rule asks: *"given the last six things this user did, how many of their major patterns are concurrently progressing?"* — that's session-count-coded by construction.

Implementation: for each major pattern, check `currentSessionCount - patternProfile.lastPhaseTransitionAtSessionCount <= 6`. Count how many of the 6 satisfy. If ≥4, the threshold is met (subject to cooldown).

### Cooldown: pure session-count, no cadence translation

```
fire iff:
    ≥4 of 6 major patterns transitioned within last 6 sessions
    AND (lastGlobalPhaseAdvanceFiredAtSessionCount == nil
         OR sessionCount - lastGlobalPhaseAdvanceFiredAtSessionCount >= 6)
    AND sessionCount >= 6  // bootstrap guard
```

A high-frequency user (4×/week) is eligible for global advance roughly every 1.5 weeks; a low-frequency user (1×/week) is eligible every 6 weeks. This scaling is correct — a high-frequency user generating more transitions in less wall-clock time should be eligible more often, because their training data accumulates more often. A calendar-time cooldown would penalize high-frequency users for training more, which is backwards for a system whose entire programme model is queue-event-windowed (per ADR-0002).

### Effect of firing

- Set `lastGlobalPhaseAdvanceFiredAtSessionCount` on `TraineeModel`.
- Surface heavy-reassessment UI on next app launch / post-session summary.
- Re-derive stretch projections silently from current EWMA capability per ADR-0005 (floor immovable).
- Mesocycle skeleton may regenerate **only** if the user accepts a goal renegotiation in the heavy-reassessment flow; otherwise stays as-is.
- The LLM digest exposes `lastGlobalPhaseAdvanceFiredAtSessionCount`. The session-plan prompt detects "fired this session" via `sessionCount - that == 0` and surfaces heavy-reassessment language naturally.

### Edge cases

- **User has fewer than 6 total sessions**: the `sessionCount >= 6` bootstrap guard prevents premature firing on a brand-new user whose 4th major pattern's accumulation block fills up before they have 6 sessions of total training history.
- **Pattern has never trained** (`lastPhaseTransitionAtSessionCount` at initial value 0): doesn't satisfy `currentSessionCount - 0 <= 6` for users past session 6, naturally excluded from the count.
- **Force-deload counts as a phase transition** (per ADR-0011): yes, deliberately. See Consequences below.

## Considered Options

- **5 major patterns (drop hipHinge)**: rejected. hipHinge is a primary muscle-group driver (hamstrings + glutes + lower back); excluding it would miss a major adaptation axis. The user-dependence objection cuts the wrong way — hip-dominant work substitutes within the pattern.

- **8 patterns, lower threshold (≥5 of 8)**: rejected. Dilutes the signal — counting lunge transitions toward macro readiness doesn't reflect macro progress. Lunge is unilateral accessory; isolation is by definition accessory.

- **Per-pattern windowing**: rejected. Different semantic than the rule wants ("readiness within this pattern's recent training" vs "user-level recent training trajectory"). More state. The total-user-sessions formulation uses only existing fields.

- **Calendar-time cooldown** (e.g. "fire at most once per 4 weeks"): rejected. Penalizes high-frequency users for training more; mismatches the queue-event-windowed programme model from ADR-0002.

- **Force-deload doesn't count as a phase transition**: rejected. See Consequences — force-deload-as-transition produces a useful emergent behavior worth preserving.

- **Adding a 7th pattern to balance upper/lower**: rejected. The asymmetry (4 upper, 2 lower) reflects how programming actually distributes volume; adding a 7th pattern to "balance" it would dilute the threshold or force an artificial pattern division.

## Consequences

- The Edge Function gains the global-advance check after the per-pattern advance logic on each session apply. The fields it reads (`lastPhaseTransitionAtSessionCount` per pattern, `sessionCount`, `lastGlobalPhaseAdvanceFiredAtSessionCount`) are all already present or trivially additive.

- `TraineeModel` gains `lastGlobalPhaseAdvanceFiredAtSessionCount: Int?` field (default nil for new users, never-fired). Codable migration is additive — existing rows decode with the default.

- **Force-deload-as-transition is a feature, not a bug.** If 4 of the user's major patterns force-deload within 6 sessions, global phase advance fires on the pattern of failure. This is the strongest *"your programming is broken, you need a rebuild"* signal the system can generate — exactly when heavy reassessment is most warranted. Future readers might worry about a "noisy" fire when patterns are clustering force-deloads, and the right answer is: that is the rule working correctly. A user whose plumbing is leaking everywhere needs the heavy reassessment UI to surface, not get suppressed by some "force-deloads don't count" exception.

- The 6-pattern enumeration is the canonical major-pattern set across the codebase for these specific rules. The legacy `MovementPattern` enum has 8 cases (locked by Slice 1); this ADR picks 6 of them as "major" for the calibration-review and global-advance triggers. Exercise classification, prescription targeting, and other systems still use the full 8-case enum.

- The shared enumeration between calibration review and global phase advance means future tuning that touches the enumeration affects both rules. Maintainers looking at one should see "this also governs the other" — pinned once here at the top of this ADR.

- CONTEXT.md gains a `Global phase advance event` term alongside the existing `Calibration review` term, with the disambiguation explicit.
