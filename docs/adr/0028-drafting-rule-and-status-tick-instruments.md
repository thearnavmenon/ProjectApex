# The drafting-rule system and the committed-vs-provisional axis

**Status**: accepted, 2026-06-14

**Relates to**: `docs/design/splash-today.md` §The drawing (Today's full-bleed hairlines + margin ticks + evidence lockup), `docs/design/train.md` §3 (the program-root day-spine, the generation-horizon datum, the to-be-placed hatch, the discrete commitment gradient) and §14.3, `docs/design/progress.md` §3 (the drafting register / spine), and `DESIGN.md` §Data visualization (the `projection` dash + `hairline` + ink/pencil families). Builds on [ADR-0024](0024-pure-swift-design-system-foundation.md) (the token foundation + shared geometry home), [ADR-0025](0025-snapshot-visual-regression-harness.md) (the gated image harness these instruments register against), and the shipped capability band ([#345](https://github.com/thearnavmenon/ProjectApex/issues/345)) — the reference axis. Decided for [#411](https://github.com/thearnavmenon/ProjectApex/issues/411). **Does not supersede** ADR-0024/0025/0026 — it extends the instrument vocabulary they established.

## Context

Three Phase-3 screens drew the same new epistemic line independently. Today (`splash-today.md`) draws full-bleed structural hairlines with 4pt margin ticks and the evidence lockup. Train (`train.md` §3) has one genuinely novel problem — *diminishing knowledge across a planning horizon*: Option-4 generation (skeleton far out, prescriptions near) means a calendar that renders "Week 4 · Squat 120×5" four weeks early **fabricates precision the model has not computed**. Progress (`progress.md` §3) carries a two-tone "drafting register" margin annotation. All three are facets of one axis — **what the model has committed/placed vs. what is still provisional** — and the capability band (#345) already ships that axis as its measured/estimated edges (solid vs. dashed). Without a shared instrument, each screen would re-encode ink-vs-pencil ad hoc, and the band's confidence vocabulary would fork.

A second, near-identical axis exists: **day status** (done / future-generated / skeleton), drawn as the filled/hollow/undrawn tick vocabulary (`live-loop.md` §3, `post-workout.md` §9, `train.md` §3) — the StatusTick instrument ([#410](https://github.com/thearnavmenon/ProjectApex/issues/410)). The two are orthogonal and must not be conflated: a day can be *committed* (the model placed it) yet *not done* (a future hollow tick).

A latent bug compounded this: the Progress root spine (`ProgressRootLedger`, #354/[#408](https://github.com/thearnavmenon/ProjectApex/issues/408)) re-derived its floor x **inline** from a hardcoded representative band, so a row whose band width differed under the 48pt minimum-width expansion landed its floor tick *off* the spine — the fusion was approximated, not guaranteed.

## Decision

A **drafting-rule system** — a dormant shared visual system (the #345/#346 pattern), unwired into any live screen — in `ProjectApex/DesignSystem/Instruments/DraftingRule.swift`, plus a shared floor-datum helper and the #408 retro-fix.

### The two-axis model

- **The drafting-rule axis = commitment / knowledge** (committed-vs-provisional). This ADR's subject.
- **The StatusTick axis = day status** (done / future / skeleton, #410). A separate instrument; orthogonal.

These two never collapse into one mark. The drafting rule answers "has the model placed this?"; the tick answers "did it happen?".

### The governing rule (committed-vs-provisional)

A mark is **ink with numbers iff the model has committed/measured** the thing; **pencil shape-only iff provisional/projected**; and the committed↔provisional boundary is always **DRAWN** — a rule + a hatch — **never left to ink-vs-pencil alone**. The reason is load-bearing: `ink-muted` already means *time/metadata* everywhere in the app, so a lone pencil row reads as "secondary detail," not "the model hasn't computed this." The datum line disambiguates. This is encoded as `CommitmentState` (`.committed` / `.provisional`), bridged from the band's confidence axis by `CommitmentState.forConfidence` (measured → committed, estimated → provisional) so the two axes can never disagree.

### Components

- **`DraftingRule`** — a full-bleed 1px structural hairline (`draftingRuleWidth`) with an optional 4pt left-margin tick (`marginTickLength`); `style: .solid | .dashed`. The dashed style reuses `DesignGeometry.projectionDash` (4-2) — the one confidence-dash vocabulary.
- **`DraftingRegister`** — a two-tone tracked-caps margin annotation via `InkPencil.run` (digits `ink`/tnum, words `ink-muted`); **absent at zero** (`isAbsent` → `EmptyView`) — an empty slot, never a fabricated "0".
- **`GenerationHorizonBreak`** — the drawn horizon datum: a solid `DraftingRule` across the spine + a `DraftingRegister` legend ("PLACED ABOVE · SHAPE BELOW").
- **`ToBePlacedHatch`** (+ `HatchShape`) — the skeleton-zone fill.
- **`CommitmentTier`** — the discrete gradient.

### Ratified decisions

- **The to-be-placed hatch is a sparse diagonal hairline hatch in `ink-muted`** — deliberately distinct from the band's dashed *edges* (which run vertical and carry the estimated-band vocabulary) so the two confidence marks never collide on one drawing. Same "the model is guessing here" read, drawn as an area fill rather than an edge so it tiles the whole unplaced zone.
- **The commitment gradient is DISCRETE tiers, not a continuous fade.** A day's distance-from-now buckets into `.thisWeek` (full detail) / `.compressed` / `.glyphPerDay` via `CommitmentTier.forDistance(days:)`, a total function over `Int`.

### Disclosed decisions (resolved here, recorded for the trail)

- **Context-scoped dashed colour.** `DESIGN.md`'s `projection` prose said dashes are "accent-ink," but the shipped band draws its dashed *edges* in `hairline`/`bandEdge`. Resolution: the dash colour is **context-scoped** — a projected chart *series* is accent-ink (it is the accent line, dashed); a projected band/datum *edge* is hairline (it is the structural edge, dashed). The `DESIGN.md` prose was corrected to match the shipped code; **the band's code was not changed**.
- **Rest is derived from day gaps**, not a stored "rest" state — a rest day is a first-class node on the spine (`train.md` §3), not a separate status to place.
- **One shared tick family** across the loop, post-workout, and Train — the StatusTick instrument (#410), not a per-screen reinvention.

### Shared floor datum + the #408 retro-fix

Extracted **`BandDatum.floorX(width:)`** — the single source of truth for *where the floor sits* across the instruments that share one vertical datum: the band's left edge, the Progress spine, and Train's horizon. `ProgressRootLedger`'s spine now consumes `BandDatum.floorX` instead of re-deriving a representative `BandLayout` inline, so every row's floor tick fuses onto one datum (**closes #408**). The rendered output is preserved — the helper returns the same value the old inline derivation produced at any realistic strip width.

### New geometry constants (in `DesignGeometry`, ADR-0024's shared home)

| Constant | Value | Meaning |
|---|---|---|
| `draftingRuleWidth` | 1 | structural hairline weight |
| `marginTickLength` | 4 | left-margin tick downstroke |
| `hatchSpacing` | 8 | sparse-hatch line spacing (perpendicular) |
| `hatchLineWidth` | 0.5 | hatch hairline weight (< the 1px rule) |
| `hatchAngleDegrees` | 45 | hatch diagonal cant |
| `commitmentThisWeekMaxDay` | 7 | ≤ → `.thisWeek` tier |
| `commitmentCompressedMaxDay` | 14 | ≤ (and beyond this-week) → `.compressed`; beyond → `.glyphPerDay` |

No new **colour** token — the system draws entirely from `hairline`, `ink`, `ink-muted`, and the existing `projectionDash`.

### The no-slope carve-out

The discrete-tier gradient is honest. The `ui-overhaul-spec.md` §8.2 ban on opacity/slope gradients targets **confidence signals on the e1RM chart**, where a gradient would imply a continuous measured signal (the named "Hevy slope" failure). The commitment gradient is **calendar-furniture compression** — a different object. Rendering it as *discrete steps* (not a continuous fade) makes it structurally impossible to misread as a confidence-on-a-chart gradient. Flagged here so a later reviewer does not mistake it for a §8.2 violation.

## Consequences

- The three screens (Today hairlines, Train horizon, Progress register) draw from one instrument; the band's confidence vocabulary does not fork.
- `BandDatum.floorX` is now the one floor-x source; #408's approximated fusion is exact. A guard test asserts band == spine == horizon at multiple widths.
- The primitives are **dormant** — unwired into any live screen. The only shipped-code behaviour change is `ProgressRootLedger`'s spine math swapping to the shared datum (behaviour-preserving, and the file is itself routed only by the dormant 3-tab shell).
- The image snapshots are wired into the ADR-0025 harness but **reference-pending** — recorded by the CI Xcode-26.3 record job, never locally (recording on a skewed toolchain poisons later slices).
- The StatusTick axis (#410) stays a separate instrument; this ADR fixes the two-axis boundary so a future implementer does not merge them.

## Alternatives rejected

- **A continuous opacity/compression fade for the commitment gradient** — reads as a confidence-on-a-chart gradient, the exact §8.2 failure; discrete tiers are unambiguous.
- **Reusing the band's vertical dashed edges for the skeleton zone** — they would collide with the horizon datum's own marks on the same drawing; a diagonal `ink-muted` hatch is visually distinct.
- **Material alone (ink vs. pencil) for the horizon, no drawn datum** — `ink-muted` already means time/metadata, so a pencil row reads as "secondary," not "unplaced." The drawn rule is the disambiguator (the convergent P0 across all four Train-panel agents).
- **A new colour token for the provisional zone** — unneeded; `ink-muted` + the dash carry it, and a new token would fork the confidence palette.
- **Folding day-status into the commitment axis** — conflates "placed" with "done"; a future hollow tick is committed-but-not-done. Two orthogonal instruments.
