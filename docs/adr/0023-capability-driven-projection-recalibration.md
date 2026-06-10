# Capability-driven projection re-calibration (the floor becomes monotonic non-decreasing)

**Status**: accepted, 2026-06-10

**Relates to**: [ADR-0021](0021-calibration-review-projection-derivation-and-editing.md) (calibration-review projection derivation) and [ADR-0005](0005-persistent-structured-trainee-model.md) (§"projections"). This ADR **refines** the "floor is immovable" decision in both: the floor becomes **monotonic non-decreasing**, re-anchored only on demonstrated, band-clearing capability. It does not supersede ADR-0021; the initial derivation, the upward-only stretch edit, and the asymmetric-error thesis all stand.

## Context

ADR-0021 set per-pattern `floor`/`stretch` targets once at calibration review and froze the floor forever ("existing floors are never re-derived"). #304/ADR-0022 then showed that *goal renegotiation* re-running the stretch formula is nearly inert (the formula reads only `floor` + `trend`, never the goal text), and deferred to #305 the real product question: **should renegotiation move targets meaningfully?**

#305 was grilled (three rounds, each design question verified by two independent reviewer agents). The outcome reshaped the issue:

- **Goal-aware margin (option B)** — `focusAreas` raising the stretch margin — stays **deferred**. The *size* of a focus bump is an inherently cross-athlete constant with no honest source on an alpha cohort; inventing it is the day-1 pseudo-precision ADR-0005 §goal rejected. (The codebase already declined this once: `computeFocusWeight` is a deliberate binary 1.0/0.0.)
- The honest, buildable-now answer uses the athlete's **own demonstrated capability**, and it is **not** a goal event — a goal-text edit has no causal link to capability growth. The frozen floor is the real staleness: an athlete who has been lifting two plates above their floor for months still carries a floor describing who they were at calibration. That floor no longer means "recent demonstrated capability" — a milder version of the very dishonesty the round-down median was designed to prevent.

So #305 becomes **capability-driven re-calibration**: when demonstrated capability has clearly outgrown the band, re-derive the projection from current capability and surface it.

## Decision

### What "immovable" was actually protecting

ADR-0021's thesis is "the floor can't be **lowered or faked**." That is a *directional* guarantee. An **upward, server-derived, capability-anchored** step-up is neither a lowering nor a fake — it is the floor doing its job (tracking demonstrated capability) after the athlete has unambiguously moved past it. So the load-bearing invariant is refined from "never moves" to:

> **The floor is monotonic non-decreasing. It never overstates (round-down median), never retreats, and is never client-supplied — but it ratchets up when the athlete has durably outgrown it.**

### Trigger (server, `update-trainee-model` session-apply, per established major)

Re-calibrate pattern `p` when its recent-window **median** capability has climbed a **full band-width past stretch**:

```
currentCapability(p) ≥ p.stretch + (p.stretch − p.floor)
```

- **Self-relative** — the threshold is the athlete's own band, never an absolute kg or cohort constant.
- **Median, not peak.** The trigger uses the same recent-window median every other projection number uses (`currentCapability`). A peakier signal would be jumpy and a foreign body; `e1rmPeak` is a dead field anyway. Consequence: re-calibration fires *after* sustained progress, not on a one-day PR — which is why the surfaced copy frames it as "you've **consistently** climbed past your target," not "you just smashed it."
- **Stateless de-bounce.** The median window already absorbs a single good session, so no streak counter is needed. (A grilling-time "declining-trend flip-flop" concern was verified a false alarm — see Idempotency.)

### Re-derivation

For each outgrown pattern, from current capability:
- `newFloor = max(oldFloor, round-down-2.5(current))` — monotonic; still round-down median, so it never overstates. (The `max` is load-bearing, not defensive: a post-PR window dip can momentarily push `round-down(current)` below the old floor.)
- `newStretch = max(storedStretch, deriveStretch(newFloor, trend))` — upward-only; never lowers a stretch the athlete deliberately raised (#269).
- `progress` recomputed against the new band.

**Idempotency is structural, not bolted-on.** Because `newFloor = round-down(current)`, we have `current < newFloor + increment ≤ deriveStretch(newFloor) ≤ newStretch`. So a re-calibrated pattern can never read "achieved" against its new band on the next apply — the trigger cannot re-fire until a fresh full band-width of growth. No cooldown field.

### Surface (re-armed calibration banner, event-keyed)

Re-calibration is **surfaced, not silent** — a silent floor bump would reset a just-succeeded athlete from "achieved" to "on_track" and silently raise the stretch (an athlete-visible jump). The existing one-time calibration banner/screen (#269) is **re-armed** for the repeating event via a **watermark**, not the one-time boolean:

- The EF stamps `projections.lastRecalibratedAtSessionCount` (+ `lastRecalibratedPatterns`, the patterns that moved).
- The ack advances `acknowledgedRecalibrationSessionCount`.
- The banner re-arms iff `watermark > ack`. Append/advance semantics — survives a server sync and can't be reverted by an unrelated full-object write (the failure mode a single boolean would have).
- Copy is celebratory and names only the outgrown patterns ("You've leveled up" / "you've consistently climbed past your `<pattern>` target — here's a higher one"); the re-calibrated rows show a **"Levelled up" badge** instead of the just-reset progress label, so hitting the old target reads as a win.

## Consequences

- The floor is no longer strictly immovable — it is **monotonic non-decreasing on demonstrated capability**. The asymmetric-error thesis is preserved (never overstates, never lowers, never faked); only the upward direction is unfrozen.
- Per-pattern (not a global ≥4/6 gate — that gate was one-time *readiness*; growth is per-pattern). The existing `reviewActive` latch remains the precondition (re-calibration only touches patterns that already hold a projection).
- **No SQL migration** (projections is existing JSONB). iOS gains tolerant-decoded fields, the watermark ack, celebratory copy, and the badge.
- Built as 3 slices: #307 (EF mechanism + watermark), #308 (surface: decode + re-arm + copy + badge + ack), #305-docs (this ADR + CONTEXT/DIARY/BACKLOG).
- **Deferred (still):** goal-aware margin / option B (#305's original framing) — revisit once cohort data can calibrate a focus bump honestly.
- **Found en route (separate fix):** the legacy `calibrationReviewAcknowledged` camel/snake key mismatch (#309) — the #269 server ack doesn't survive a sync; #305's new field uses camelCase to avoid the trap.
