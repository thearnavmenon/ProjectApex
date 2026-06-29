# Per-pattern phase advance: plateau-aware composition, force-advance safety valve, cyclic mesocycle

**Status**: accepted, 2026-05-07

> **Amended by [ADR-0030](0030-committed-deterministic-program-generation.md) (#559, 2026-06-29):** the phase cycle is now **goal-aware**. A `strength` goal keeps the arc pinned here (`accumulation → intensification → peaking → deload`); every other goal (hypertrophy, endurance, general, absent) uses a **volume arc** that skips `peaking` (`accumulation → intensification → deload`) so non-strength users are never cycled into a strength taper. The deload-end cyclic rule §(c) and the force-deload safety valve §(b) are unchanged — only the natural progressing-advance §(a) is goal-branched. The goal arc is a computed input classified from `model_json.goal.statement`, not a persisted field.

## Context

ADR-0005 specifies that phase storage moves from the legacy `PatternPhaseService` to `PatternProfile.currentPhase` + `sessionsInPhase`, and that "advance logic gains plateau-awareness." It does not pin (a) the composition rule for plateau-aware blocking, (b) what happens when an advance is blocked indefinitely, or (c) whether the deload phase remains terminal as in legacy `PatternPhaseService.swift` line 126 ("Already at deload — no further transition") or rolls forward into a new mesocycle.

ADR-0009 just pinned the hybrid plateau verdict semantics on `PatternProfile.trend`. The composition between (1) the legacy Option-B advance threshold (`max(3, phaseWeeks × max(1, daysPerWeek/2))`), (2) the trend verdict, and (3) the cyclic-vs-terminal phase model is not addressed in any prior ADR.

This ADR pins the composition. Tightly coupled to ADR-0005 (the advance trigger), ADR-0009 (the trend verdict), and the legacy `PatternPhaseService` Option-B threshold (preserved as the per-phase session-count requirement).

## Decision

### (a) Plateau and declining trends both block advance

On every session-completion that increments `sessionsInPhase`:

```
if sessionsInPhase >= sessionsRequiredForPhase:
    if trend == .progressing:
        advance to nextPhase
        sessionsInPhase = 0
        lastPhaseTransitionAtSessionCount = sessionCount
    else:  // trend ∈ {.plateaued, .declining}
        do nothing — sessionsInPhase keeps accumulating
```

Both `.plateaued` and `.declining` block advance. The extension to `.declining` is deliberate:

- The legacy decline rule's `<5d-gap` requirement (now superseded by ADR-0009's hybrid decline definition) made decline structurally rare for low-frequency users — "decline rarely fires" is partly an artifact of the trigger geometry, not a statement about how often regression actually happens.
- When decline fires, it represents overreaching, illness, life stress, or programming-volume mismatch. Asking a regressing lifter to lift heavier (intensification phase) is worse than asking a plateaued lifter to lift heavier — the regressing lifter has demonstrated they can't even hold current loads.
- Plateau means "stimulus isn't producing adaptation, but the lifter is at least holding the line." Decline means "stimulus is exceeding the lifter's capacity to recover, and the line is breaking." Decline is more urgent than plateau, not less.

The block is *conditional, not destructive*: `sessionsInPhase` continues to accumulate. If `trend` flips from `.plateaued` (or `.declining`) to `.progressing` while `sessionsInPhase >= sessionsRequiredForPhase`, the next session-completion fires the deferred advance.

### (b) Force-advance safety valve to deload

Without a release valve, a stuck pattern stays in its current phase forever. The rule:

```
if trend ∈ {.plateaued, .declining} AND sessionsInPhase >= 2 × sessionsRequiredForPhase:
    force-advance directly to .deload
    sessionsInPhase = 0
    lastPhaseTransitionAtSessionCount = sessionCount
    consecutiveForceDeloadsOnPattern += 1
```

The force-advance jumps the phase order — accumulation → deload, skipping intensification and peaking. The 2× threshold is patient: at 4-day cadence with a 4-week accumulation phase, force-deload fires after ~16 sessions (~8 calendar weeks) of stuckness. Real coaches intervene at 4–6 weeks, but for an automated system erring patient is correct — under-trigger force-advance is preferable to over-trigger on noisy verdicts.

The natural progressing-advance path resets the counter to 0:

```
if trend == .progressing AND sessionsInPhase >= sessionsRequiredForPhase:
    advance to nextPhase
    consecutiveForceDeloadsOnPattern = 0
```

### (c) Cyclic mesocycle: deload cycles to accumulation

Phase ordering becomes:

```
phaseOrder = [.accumulation, .intensification, .peaking, .deload, ...repeat]
```

After `sessionsInPhase >= sessionsRequiredForPhase` in `.deload`, advance to `.accumulation` (regardless of `trend` — coming out of deload the pattern is by definition refreshed; the `trend == .progressing` block does not apply to the deload→accumulation transition).

The legacy "deload is terminal" was a v1 simplification because v1 programmes were finite. v2 with continuous coaching cycles. Rejecting the alternative deload → peaking path: peaking-after-deload would have a fresh, undertrained-but-rested lifter doing low-rep heavy work, which neither rebuilds volume tolerance nor produces meaningful adaptation.

The deload→accumulation transition explicitly fires the **deload-end trigger** from the Q5 transition-mode formula. The 3-session plain-mean window during resumption catches the post-deload rebound and prevents stale pre-deload e1RM data from bleeding into the new accumulation block.

### (d) Watch-item: consecutive force-deloads as meta-coaching surface

If a pattern force-deloads, returns to accumulation, and immediately plateaus or declines to 2× threshold a second time — that's not plateau, it's a programme-design problem. The same accumulation block that produced the plateau will likely produce another.

v2 does not implement automated remediation, but the meta-coaching surface tracks `consecutiveForceDeloadsOnPattern: Int` per `PatternProfile`. When this counter reaches 2, the digest surfaces the signal to the LLM, which has the context to suggest exercise rotation or programme rebuild via natural-language coaching. Future versions may add automated exercise-rotation logic; v2 leaves it to the AI to surface.

The counter increments only on force-deloads (not on natural deload-end transitions), and resets to 0 on any natural progressing-advance.

### Edge cases

- **Trend flips mid-phase from `.plateaued`/`.declining` to `.progressing` after `sessionsInPhase >= threshold`**: advance fires next session-completion. Block was conditional, not destructive.
- **Pattern hits force-advance while already in `.deload`**: no-op. The pattern is already taking the recommended intervention; `consecutiveForceDeloadsOnPattern` does NOT increment.
- **Pattern hits force-advance while `transitionModeUntil` is already set**: both compose. Phase advances; transition mode stays active per Q5's max-of-untils rule.
- **First-time pattern (`sessionsInPhase == 0`, `currentPhase == .accumulation`)**: starts at accumulation, no special handling.
- **Pattern was at terminal `.deload` under legacy v1 semantics, decoded into v2 trainee model**: `currentPhase = .deload`, `sessionsInPhase` ratchets normally; next deload-threshold met → advance to `.accumulation` per cyclic rule. Migration is additive.

## Considered Options

- **Block on plateau only, leave declining unblocked.** The original Q6 recommendation. Rejected on the grounds in (a): trigger geometry made decline rare under legacy rules; under ADR-0009's hybrid verdict, decline can fire on low-frequency patterns where it couldn't before; auto-advancing a regressing lifter into a harder phase is worse than auto-advancing a plateaued lifter; the cost of also blocking on decline is negligible because decline is still rare.

- **Force-advance to next phase in cycle (accumulation → intensification) rather than direct-to-deload.** Rejected: asking a plateaued or declining user to lift heavier when their volume-load and e1RM are flat or dropping is the wrong intervention. The whole point of force-advance is to break the plateau, and intensification doesn't break plateau — deload does.

- **Deload remains terminal (legacy v1 model).** Rejected: paints us into a corner under the (b) safety valve, and is contrary to standard periodization theory where macrocycles are cyclic. v1 had finite programmes; v2 has continuous coaching.

- **Deload → peaking (rather than → accumulation).** Rejected: peaking-after-deload is unnatural and doesn't rebuild volume tolerance.

- **Force-advance threshold at 1.5× rather than 2×.** Rejected: 1.5× lands at ~12 sessions / ~6 calendar weeks for a 4-day-cadence accumulation block, which is closer to real-coach intervention timing but more sensitive to noisy plateau verdicts. Patient is the correct error direction for an automated system.

- **No counter; just suggest force-deload again if the pattern stuck-plateaus a second time.** Rejected: without the counter, the LLM digest can't differentiate a first-time stuck pattern from a chronically stuck one. The counter is one Int field per pattern; the meta-coaching value justifies the cost.

## Consequences

- The Edge Function gains the composition rule on per-session apply. The `PatternProfile.currentPhase`, `sessionsInPhase`, and `lastPhaseTransitionAtSessionCount` fields are already present; the rule is pure logic on top.

- `PatternProfile` gains a `consecutiveForceDeloadsOnPattern: Int` field (default 0). Codable migration is additive — existing rows decode with the default. No backfill required.

- Legacy `PatternPhaseService.swift` is deleted in Phase 2; its Option-B threshold formula (`max(3, phaseWeeks × max(1, daysPerWeek/2))`) is preserved verbatim in the Edge Function rule logic as the `sessionsRequiredForPhase` derivation.

- The cyclic phase rule means a programme can run indefinitely. The mesocycle "ends" only when the user explicitly switches programmes or goals; otherwise patterns cycle through accumulation → intensification → peaking → deload → accumulation without bound.

- The TraineeModelDigest exposes `consecutiveForceDeloadsOnPattern` per pattern. The system prompts gain a guidance rule: when this counter reaches 2 on a pattern, the LLM suggests exercise rotation or programme rebuild via natural-language coaching cue.

- Composition with Q5: the deload→accumulation transition fires the `deload-end` trigger; `transitionModeUntil` gets set per the Q5 formula. This is implementation contract, not separate behavior.

- The block-on-declining extension means the AI receives `trend = .declining` patterns that don't auto-advance. The system prompts gain interpretation guidance: declining + blocked-from-advance is the "user is regressing, recommend recovery interventions" signal — distinct from plateaued + blocked, which is "user is stuck, recommend stimulus variation."

- No CONTEXT.md changes — the new terms (`force-advance`, `consecutive force-deload`) are PRD-internal vocabulary, not ubiquitous-language candidates yet. Promote if they recur in user-facing copy.
