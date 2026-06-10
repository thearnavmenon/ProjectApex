# Apex — DESIGN.md

The visual design system for the Phase 3 UI overhaul. This file is the canonical
token spec; the behavioral/interaction spec lives in `docs/design/ui-overhaul-spec.md`,
and per-screen design docs live in `docs/design/` (first one: `onboarding-calibration.md`).

Format and philosophy follow the [design.md](https://github.com/google-labs-code/design.md)
guide: high-contrast neutrals, ONE accent used sparingly as the sole interaction
driver, named tokens with prose rationale, an architectural concept grounding the
identity. Motion is our own added pillar (the guide omits it).

**Status:** Foundation locked 2026-06-10, including all fixes from the two-agent
UI/UX expert review (see Decision log). Per-screen specs layer on top.

## Overview

Architectural concept: **"A single ink, drawn precisely."** An engineer's technical
drawing — one ink (ultramarine) on warm paper (cream), high contrast, zero
decoration. Color is meaning, not garnish: when ultramarine appears, the coach is
doing something. Calm and exact in the live loop; the ink floods full-bleed for
brand + coaching moments. No serif, no multi-color palette, no generic-Apple look —
the restraint is the premium.

## Colors

High-contrast neutrals + ONE accent (the anti-generic move). Light ("paper") is the
default appearance; the dim variant below remaps the same roles.

```yaml
colors:
  paper:        "#F6F2E8"   # cream canvas (user call 2026-06-10; supersedes true white)
  surface:      "#FFFFFF"   # cards/sheets lift BRIGHTER than paper — crisp, no warm shadowing
  well:         "#EDE7D9"   # recessed cream — input wells, inactive tracks
  hairline:     "#DCD5C4"   # 1px structural borders, cream-tinted (cool grey reads dirty on cream)
  ink:          "#14151A"   # near-black — ALL text, labels, icons by default (~15:1 on paper)
  ink-muted:    "#66645C"   # warm grey — metadata, secondary labels (≥4.5:1 on paper)
  accent-ink:   "#1322CC"   # deep ultramarine — the DEFAULT interactive color (links,
                            # buttons-as-text, active tab, selected icon). ~6:1 on paper: AA.
  accent:       "#1B2CFF"   # bright ultramarine — LARGE FILLS ONLY (primary button fields,
                            # full-bleed brand floods, gauge fill, big graphic shapes).
                            # ~4.3:1 on paper: fails AA for normal text — never use it for
                            # text, small icons, or hairlines.
  accent-press: "#0E1Aa3"   # pressed/active depth on accent fills
  on-accent:    "#FFFFFF"   # text/icons on ultramarine fields
  alert:        "#C9241B"   # back-off / safety / destructive TEXT and icons (AA on paper)
  alert-fill:   "#FF3B30"   # alert as a large fill (banner field, stop button) with white on it
```

Rationale:
- **Contrast roles are the load-bearing fix** from the UI review (P0-4): bright
  `accent` on cream is ~4.3:1, which fails WCAG AA for normal text and makes thin
  strokes shimmer in gym lighting. So: reading surfaces are always `ink`;
  interactive emphasis is `accent-ink`; bright `accent` is reserved for shapes big
  enough that contrast is about presence, not legibility.
- **Success is NOT green.** A "win" reads in ultramarine — on-brand, earned, plus
  weight/motion/haptic. Red is reserved strictly for "back off / stop" so it always
  means exactly that.
- **Never** introduce a third hue. State changes come from ink, weight, and motion
  (see States), not from new colors.

### Dim variant

Same roles, remapped — "the negative of the page." Specced now (review P1): a gym
app shipping light-only earns day-one glare complaints in dark home gyms and
late-night sessions. Not a separate design; a token remap.

```yaml
colors-dim:
  paper:        "#14151A"   # ink becomes the canvas
  surface:      "#1C1E25"   # cards lift LIGHTER than paper (no shadows in dim)
  well:         "#101116"   # recessed
  hairline:     "#2A2D36"
  ink:          "#F6F2E8"   # cream becomes the text
  ink-muted:    "#9B9DA6"
  accent-ink:   "#7B85FF"   # ultramarine lifted for dark — #1B2CFF is ~1.6:1 on ink and
                            # unusable; this cut holds AA for interactive text/icons
  accent:       "#1B2CFF"   # full-bleed floods stay TRUE ultramarine with white on top —
                            # the brand color itself never shifts, only its small-scale cut
  accent-press: "#98A0FF"
  on-accent:    "#FFFFFF"
  alert:        "#FF6B61"
  alert-fill:   "#FF3B30"
```

Follow the system appearance by default; offer an in-app override in Settings.

## Typography

Bold display sans + clean UI sans. **No serif anywhere** — editorial character comes
from weight and scale, not serifs.

```yaml
type:
  display:  { family: "Space Grotesk", weight: 600, tracking: "-0.02em" }
            # coach's voice, brand moments, big headlines
  hero-num: { family: "Space Grotesk", weight: 700, features: ["tnum"] }
            # weight × reps, huge; tabular figures so digits never jitter
  ui:       { family: "Inter", weight: 500 }   # labels, nav, controls
  body:     { family: "Inter", weight: 400 }   # reading text
```

Scale anchors (pt, before Dynamic Type):

```yaml
type-scale:
  hero-num: 64     # the live-loop weight/reps numbers
  display:  34     # coach's read, screen titles in brand moments
  title:    22     # section titles
  body:     17
  label:    13     # metadata, axis labels (ink-muted)
```

Inline emphasis within running text comes from **weight/value, never hue** —
accent-colored words inside a sentence read as tappable (the accent means "act
here"). Two-tone emphasis is sanctioned: key numbers in full ink/heavier weight,
connective tissue in `ink-muted`.

**Work is ink, time is pencil** (system law, promoted from `live-loop.md` §1):
all work numbers — prescriptions, logged sets, evidence — render in `ink`; all
time digits — clocks, countdowns — render in `ink-muted`, same Space Grotesk
tnum cut. The pencil side extends to **plans**: where plan and actual differ,
actual is ink, plan is pencil ("100 kg × 6 · plan 5" — done work is the
most-true data in the app; the plan is not work). Holds at every scale, down
to 13pt stat lines (digits ink, words pencil).

### Dynamic Type & localization (review P2)

- Body, labels, and UI text track Dynamic Type through the AX sizes.
- `hero-num` and `display` cap at 1.3× — past that, layout sheds decoration
  (gauge shrinks, metadata hides) before numbers truncate. Numbers never ellipsize.
- The coach's-read hero must survive 4-line wrap at AX sizes without clipping.
- Buttons size to their label (no fixed-width text buttons); all-caps only in
  brand moments and never on localized strings; minimum tap target 44pt.

## Spacing & Shape

```yaml
spacing: { xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 48 }
rounded: { sm: 8, md: 16, lg: 24, pill: 999 }
elevation:
  card: "y2 blur12 rgba(20,21,26,0.06)"   # only the active/coach surface lifts (light mode)
```

Friendly-but-engineered rounding; depth from hairlines + one soft shadow, never
shadow stacks. In dim, depth comes from surface lightness, not shadow.

## States (review P0-4)

A single accent can't carry every state, so states are built from **ink + weight +
motion**, not more colors:

```yaml
states:
  interactive: "accent-ink text/icon (the only resting use of the accent at small scale)"
  pressed:     "accent-press + log-settle motion (below)"
  selected:    "surface card, 2px ink border, label steps 500 → 600 — selection is
                structural, so the accent stays free to mean 'act here'"
  disabled:    "ink-muted at 40%, no motion"
  focus:       "2px accent-ink ring, 2pt offset (keyboard/a11y)"
  success:     "ultramarine moment — never green: weight + ratchet motion + haptic"
  error:       "alert — reserved for back-off / stop / destructive meanings only"
```

## Data visualization (review P2)

One accent has to chart everything, and charts must encode **confidence** (the
trainee model distinguishes measured from estimated — see `ui-overhaul-spec.md` §8):

```yaml
data-viz:
  series-primary:   "accent-ink line, 2pt"
  series-compare:   "ink at 30% opacity, 2pt"
  band:             "accent at 8% fill, hairline edges (floor/stretch capability band)"
  projection:       "dashed 4-2, accent-ink — anything projected/estimated is dashed"
  point-measured:   "solid accent-ink dot"
  point-estimated:  "hollow dot (ink stroke) — low-confidence data LOOKS less certain"
  axis:             "label type, ink-muted; hairline gridlines, horizontal only"
```

Dim remaps (added with `post-workout.md` — the small-scale accent cut lifts,
exactly as `accent-ink` does):

```yaml
data-viz-dim:
  series-primary:   "#7B85FF line, 2pt"
  band:             "#7B85FF at 12% fill, hairline #2A2D36 edges"
  point-measured:   "solid #7B85FF dot"
  point-estimated:  "hollow dot (dim-ink #F6F2E8 stroke)"
```

**The capability band is one component, three contexts** — the onboarding
model reveal, the post-workout evidence strip, and Progress's pattern detail:
same anatomy (band fill, edge ticks — floor 2px full ink, stretch 1px
hairline — dot, dimension-bracket movement, caption slot), differing only in
scale and caption. Full anatomy in `post-workout.md` §6.

## Tags

The tag family (established in `splash-today.md`, extended through the loop
and the summary): a **1px `ink` rectangle, 2pt corner radius, tracked caps at
11pt** (Inter 500). Tags state classification facts only — `WARM-UP`, `AMRAP`,
`UPPER A`, `AMENDED` — and never carry metadata (dates sit beside the tag,
unboxed). The **PR stamp is the family's only inverted member**: ink-filled
rectangle, paper text — a notary stamp, reserved for genuine e1RM/rep PRs.

## Iconography

SF Symbols, medium weight (≈1.75pt stroke at 17pt), `ink` by default, `accent-ink`
only when interactive. Filled variant only for the selected tab. No decorative icons.

## Motion

Motion is a first-class identity pillar — but **restrained** (review P1): expressive
motion is reserved for the **bookends** (≤4 moments); routine navigation is fast and
invisible. "Drain-and-rise on every transition" is explicitly rejected — it tires by
session three and risks ProMotion jank.

```yaml
motion:
  # Expressive — bookends ONLY: app open, workout start, post-workout reveal,
  # milestone celebration. Nowhere else.
  transition-bookend: "drain-and-rise — color washes down/away, next screen rises
                       through it. spring(response:0.5, damping:0.85)"
  gauge-focus:        "iris/aperture segments rotate into alignment, tiny overshoot.
                       spring(response:0.5, damping:0.7)"
  celebrate-ratchet:  "milestone — the floor line clicks up one notch with a confident
                       bounce + haptic thud"
  # Workhorse — everything else.
  transition-nav:     "150ms ease-out fade/slide. Routine nav should feel like nothing."
  card-morph:         "the live session card reshapes between sets via shared-element —
                       never a hard cut. ~350ms"
  log-settle:         "one-tap 'done' presses down and locks. 0.2s, crisp, no bounce"
reduce-motion: "every expressive transition falls back to a 150ms crossfade; haptics kept"
```

**Motion canon:** *the ink lives at the bottom of the world* — it drains downward
at app open (splash) and floods upward from the Start button at workout start.
One physics across the bookends; specifics in `docs/design/splash-today.md`.

Feel: Apple-fluid springs, Opal-alive, a touch of Duolingo snap — never floaty.

## Haptics (review P2)

```yaml
haptics:
  set-logged:      "impact(.medium) — the thud of a plate set down"
  rest-complete:   "two light taps"
  milestone:       "notification(.success) + impact(.rigid) — the ratchet click"
  back-off:        "notification(.warning)"
  feel-pill:       "none — ignoring it must cost nothing (see spec §5)"
  routine-nav:     "none — motion carries it"
```

## Decision log

| Date | Decision |
|---|---|
| 2026-06-10 | Full rebuild scope; guiding principle "quietly right in the moment, visibly smart around it"; 3-tab nav (Today / Train / Progress). |
| 2026-06-10 | Identity rounds: dark-first rejected; serif rejected (bold sans only); Claude palette + bone/limestone warm-whites rejected; then **cream `#F6F2E8` chosen over true white** by user — supersedes the true-white call earlier the same day. |
| 2026-06-10 | **Ultramarine `#1B2CFF`** chosen by user as the single accent (over Klein cobalt, acid lime, vivid emerald). |
| 2026-06-10 | Two-agent review (UI expert + UX expert, Uber-calibre brief) — all four P0s and the P1s accepted: **P0-1** feel-pill ignore ≠ confirm (spec §5); **P0-2** deterministic local fallback for every coach line (spec §4/§6); **P0-3** onboarding/first-run calibration flow is a required design target (`onboarding-calibration.md`); **P0-4** contrast roles — text/icons in ink, `accent-ink #1322CC` as default interactive, bright accent for large fills only. P1: dim variant specced now; motion restraint; live-loop edge cases + plan-peek. P2: gauge always backed by literal number + label; data-viz/icon/haptic/Dynamic-Type tokens added. |
| 2026-06-10 | Motion: drain-and-rise restricted to ≤4 bookend moments; 150ms workhorse nav; Reduce Motion fallback mandatory. |
| 2026-06-11 | Second two-agent review (UI craft + UX/product) of the 16 Mobbin onboarding references — all proposals accepted into `docs/design/onboarding-calibration.md` (record in its §8). Headlines: the model reveal gets a full layout + honesty-rendering spec and is designed first; equipment gates capability seeding; single-selects auto-advance; progress honesty (full denominator, ~10% endowed start); honest-labor pacing for the drawing beat; pre-filled weights banned; protected zone before Today; adidas step-checklist + wheels rejected. |
| 2026-06-11 | Splash + Today locked (`docs/design/splash-today.md`) after a **three-agent** review (UI craft + UX/product + visual/art-direction). **Wordmark: caps APEX with the custom aperture-A** — the A's counter drawn as the 6-blade iris (2–1 panel call; the iris integration is load-bearing). Cross-screen iris travel cut for v1 (in-place focus instead). Motion canon added ("the ink lives at the bottom of the world"). Today gains the drafting-rule hairline system, the evidence-number lockup (SG 600 tnum), the Lens unknown/calibrating state, and a full state machine (back-off day, session-not-generated + pre-generation policy, program complete, gap return). Inline emphasis = weight, never hue. |
| 2026-06-11 | Post-workout summary locked (`docs/design/post-workout.md`) after the **four-agent** panel. Two-deck read — claim ≤45 chars `display` + proof ≤90 chars `body` (the draft's single 34pt hero failed its own type math; caught by all four). **The amended record replaces sealed-at-Finish**: facts (weight/reps) correctable from history with struck-not-erased provenance + AMENDED tag until next-session-or-48h; feel sealed forever; the stored read never rewrites. Bookend #3 = one ballistic arc (apex hang, finished-page law, tide line); the dot landing, conversion beat, and ratchet sequence locked (witness rule: never fired unseen, never replayed). Band strip respecced as a drawn instrument and promoted to **one component, three contexts**. Exit control named "Today" ("Done" was spent). Promotions landed here: work-is-ink/time-is-pencil (+ plan-is-pencil), the tag family, dim data-viz tokens. |
| 2026-06-11 | Live loop locked (`docs/design/live-loop.md`) after a **four-agent** review (+ motion/animation, new). Headlines: **every logged set is editable until Finish** (the correction surface — undo, didn't-finish, symmetric over/under, pain flag); last-time anchor under the prescription; prescriptions pre-snap to gym-loadable; **Done is a full-bleed bottom ink slab** that relabels to Finish; **"work is ink, time is pencil"** (time digits always `ink-muted`); locked morph timelines, hard-swap timer digits, no idle animation, overshoot banned loop-wide; feel pill = ruled three-cell row (Easy/Solid/Grind), ignored = unknown; PR = inverted ink stamp, no celebration; warm-ups get compact rests and no pill. Candidates for app-wide promotion next round: work-ink/time-pencil, the tag family. |
