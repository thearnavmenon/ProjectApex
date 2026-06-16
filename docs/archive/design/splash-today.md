# Splash + Today — design spec

**Status: locked 2026-06-11** after a three-agent review (UI craft / UX-product /
**visual–art-direction** — the third lens added this round). All accepted findings
folded in; record and dispositions in §6. Companion docs: `DESIGN.md` (tokens),
`ui-overhaul-spec.md` (locked behavior — Today is §3), `onboarding-calibration.md`
(first-run splash variant, §3.0; honest-checklist pattern, §3.7).

---

## Part 1 — Splash / launch bookend

### Job

The brand moment — bookend #1 of the four sanctioned expressive-motion moments.
"A single ink, drawn precisely," made literal: the app opens as a field of ink
that is drawn off to reveal the day. It is also, honestly, the loading screen —
it absorbs cold-launch latency; it never adds artificial delay.

### The mark

**Caps wordmark: APEX**, Space Grotesk 700 as the base cut, tracked +0.04–0.06em,
with one custom intervention: **the A's triangular counter is redrawn as a
6-blade camera iris** — the aperture-A. The A is literally an apex; its counter
is the iris's natural home; the same iris is the Lens gauge on Today. One
drawing unifies wordmark, app icon, and instrument, and it is what makes a flat
ultramarine flood unmistakably ours instead of a recolored GCOO. (Panel split
2–1 on case — both behavior-lens agents leaned lowercase-quiet; the
art-direction agent's caps argument won because it is load-bearing: the iris
needs the capital A's counter, and the custom letterform is the squint-test
fix. Recorded in §6.)

- Lockup: wordmark ≈60% of screen width, optically centered with a slight
  upward bias (true center reads low under the Dynamic Island), baseline and
  clearance specced in the asset, not improvised.
- **No tagline on cold launch.** A daily user would read it 300×/year, and 60%
  white on `#1B2CFF` fails AA (~3.4:1). The expectation line exists only in the
  first-run variant owned by `onboarding-calibration.md` §3.0. The mark stands
  alone, like Grill'd and lululemon.
- Follow-up asset work: app icon derived from the aperture-A.

### Static launch frame — seam engineering

iOS launch screens are static storyboards **and do not load custom fonts** —
live Space Grotesk would silently fall back to SF. So:

- The wordmark ships as a **pre-rendered vector asset** (PDF in the asset
  catalog); the first in-app frame reuses the *identical asset*, pixel-snapped —
  never runtime-set text, which differs by sub-pixels and shimmers at handoff.
- Window background is `accent` during launch (SwiftUI flashes the window color
  for a frame before first render — a cream flash mid-flood breaks the seam).
- Status bar declared light-content for the launch configuration.
- Acceptance criterion: frame-capture comparison across the static→live seam.

### The drain — art direction

Ink drawn off by a **ruling pen, not water leaving a tank**: a near-flat retreat
edge with ~1.5° cant, zero wobble — explicitly no meniscus, no wave — with a 1px
lighter edge-highlight at the retreat line, on the tokened spring. Today is
revealed **in place** beneath the ink (the drawing was always there); the only
secondary motion is an 8pt staggered settle of Today's content as the edge
passes it. During the drain, the iris inside the A focuses (blades rotate to
alignment, 0–350ms); after the drain lands, **Today's Lens does its own
`gauge-focus` settle in place** as readiness resolves.

**Motion canon (added to `DESIGN.md` §Motion):** *the ink lives at the bottom of
the world* — it drains downward at open and floods upward from the Start button
at workout start. One physics, two bookends.

**Cut for v1: the cross-screen iris travel** (splash glyph flying to the Lens
position). All three agents converged against shipping it now: it has no
destination on first-run or notification routes, dies under Reduce Motion,
couples drain timing to Today's layout, and at ≤1.2s nobody tracks a small
flying glyph. The in-place focus (in the A, then in the Lens) delivers the
"mark becomes the instrument" story at a fraction of the risk. Revisit only if:
a stable v1 ships, the routing table below holds, and motion capture proves the
travel reads at full speed.

### Timing — controllable budgets, not wishes

- The splash may add **≤300ms over data-ready**; the drain begins ≤200ms after
  the first in-app frame and runs ≤500ms.
- **No minimum dwell.** If everything is ready, drain immediately.
- Slow-launch tier: past ~2.5s of held flood, the screen must admit it's
  loading — the iris in the A **breathes** (slow aperture oscillation) and one
  quiet `on-accent` line appears ("Setting up"). A static flood at 4s reads as
  crashed. (Today is local-first and shouldn't hold; if engineering ever makes
  the hold real — migration, model rebuild — this tier is its design.)

### Launch routing table

| Entry | Treatment |
|---|---|
| Cold launch → Today | Full bookend: flood, iris focus, drain. |
| Cold launch, paused-session sentinel | **No bookend** — 150ms crossfade straight into the resume context. A running rest timer outranks brand. |
| Notification tap / deep link / widget / Live Activity | 150ms crossfade direct to the target surface; if the target is an alert, its row is highlighted. The drain plays only when the destination is Today proper. |
| First run | Drain into onboarding screen 1 (`onboarding-calibration.md` §3.0) — or into the *resumed step* if onboarding was interrupted (its persistence rule). |
| Warm foreground / resume | Nothing. Ever. An app opened 4×/day never replays its logo. |

### Reduce Motion & dim

Reduce Motion: 150ms crossfade, iris pre-focused, no drain, no settle. Dim
variant: the flood stays true `#1B2CFF` with white mark — the brand color never
shifts (per `DESIGN.md` colors-dim rationale).

---

## Part 2 — Today

### Job

Answer **"what does my coach want from me right now?"** in one glance, and make
starting it one tap. Everything else on the screen is quiet. This is the calm
half of the principle; the expressiveness lives in the bookends on either side.

### The drawing — Today's visual signature

The identity promises a technical drawing; this screen draws one. Structural
hairlines run **full-bleed edge to edge** (not iOS-style inset separators) with
**4pt tick marks at the left margin**; the top rule carries the screen's margin
annotations. This costs nothing, screenshots as unmistakably ours, and exists in
no app in the reference set. (Candidate for app-wide promotion to `DESIGN.md`
when the remaining screens are designed; for now it is Today's system.)

### Layout (paper canvas, top → bottom)

1. **Margin row (on the top rule).** Leading: settings glyph (`accent-ink` —
   it's interactive and follows the token law) and the date in `label`
   `ink-muted`. Trailing: the **compact Lens** — **iris ≥24pt** (6 blades,
   stroke weight matched to the hairline system) **+ readiness number**
   (Space Grotesk tnum, 17pt). **No word, no middot at compact scale** — the
   word lives in the sheet and, when it matters, the coach line speaks it
   (no-echo rule below). Blade aperture openness encodes the state — the motif
   doing its job, not decoration. Two corners, two 44pt targets, no collision.
   - **The Lens is an instrument, not a control — written exemption** from the
     interactive-must-be-accent-ink rule. It renders in ink. Its tap-sheet's
     discoverability is owned by the onboarding model-reveal handoff (the user
     has already met the iris) — not by coloring the gauge like a button.
2. **Coach line.** `display` type, 1–2 lines, the screen's only verbal voice:
   "Recovered — push squats today."
   - Grounded in ≥1 model number; deterministic local fallback per
     `ui-overhaul-spec.md` §3. The fallback vocabulary (days-since-pattern,
     position-vs-floor) makes genuine collapse **rare** — there is almost
     always one true sentence.
   - **Length contract:** hard character budget (fits 2 lines at default type);
     an AI line over budget fails validation and the fallback fires. A coach
     line is **never ellipsized** — a truncated grounding is a fabrication.
   - **Emphasis by weight/value only, never hue** (Tempo's colored keyword
     reads as tappable — accent inside running text is banned). Two-tone
     allowed: the grounded number in full ink/heavier, connective tissue in
     `ink-muted` (the pliability statement technique).
   - **No-echo rule:** the coach line never opens with the Lens's state word
     while both are visible.
   - **Collapse is layout-stable:** the slot reserves its vertical rhythm so
     absence reads as intentional quiet, not a broken fetch.
3. **The session card** — the hero, the screen's only elevated surface
   (`surface` + `elevation.card` + hairline):
   - **Eyebrow:** small tracked-caps `label` — "TODAY · DAY 2 OF 4" (the
     Fitness+ "FOR TODAY" move; absorbs day-position from the old meta line).
   - **Title** in pattern language: "Lower — squat focus".
   - **Evidence lines (the typographic signature of the app):** max 3
     two-column rows — exercise name left in Inter 500 (tail-truncates), the
     numbers right-aligned as a **lockup**: loads in **Space Grotesk 600 tnum
     ~22pt**, units in 13pt `ink-muted` ("5×5 · **102.5** kg") — numbers
     **never truncate** (`DESIGN.md` Dynamic Type law). Selection rule:
     model-placed top-set lifts by pattern priority. Overflow: "+2 accessories"
     in `ink-muted`. These numbers are the trainee model showing its work.
   - **Confidence continuity (§8.2 applies — no exemption):** evidence lines
     derived from low-confidence bands (week 1, post-layoff, unknown-feel-heavy
     history) carry the **hollow-marker cue** before the load, and the eyebrow
     gains a quiet "CALIBRATING" tag. Onboarding teaches hollow = estimate; the
     surface seen most keeps the vocabulary.
   - **Meta line** `ink-muted`: "~55 min".
   - **Start** — full-width, **≥56pt**, `rounded.md` 16 (a drawn rectangle, not
     a friendly pill), label "Start" in Space Grotesk 600 `on-accent`,
     `log-settle` press, disabled-while-transitioning (no double-fire). **The
     only accent fill on the screen.** Pressing it is bookend #2: ink floods
     upward from the button and the live loop rises through it.
4. **Coach alerts** (when present): `well` rows with ink icons.
   - **Severity law:** a back-off (safety) row is `alert` red, always slot 1,
     **never collapsed** behind "more"; max one red at a time. Verify red-on-
     `well` contrast at build (≈4.6:1 is at the AA floor) — if it misses, red
     rows sit on `surface`.
   - **Max 2 visible** + a quiet "2 more" count row. Calm dies at three.
   - **Dismissal is durable** per signal watermark (the existing ack machinery:
     calibration-review ack, re-armed re-calibration banner, goal review).
     A dismissed alert stays dismissed — non-persistent dismissals teach users
     to ignore the coach's most important channel (shipped-app audit F7).
   - Each row type names its destination (the existing flows); no dead pointers.
5. **Footer line** (optional, `ink-muted`, **non-interactive** — stated, not
   implied): "Thursday: upper — bench focus." Quiet proof a plan exists.

### Scroll contract

Today scrolls. Coach line + the **full** session card including Start fit above
the fold at default type on the smallest supported device; alerts may peek below
the fold (the peek invites the scroll). No pull-to-refresh — local-first;
refresh on foregrounding. Layout accounts for the 3-tab bar + home indicator.

### States

| State | Treatment |
|---|---|
| **Training day, session generated** | The layout above. |
| **Session not yet generated** | **Pre-generation policy:** the next session generates in the background on previous-session completion (or first Today render). Skeleton card shows the shape honestly — "Lower — squat focus · placing your numbers" — evidence lines render **only** from a generated session. If Start is hit before ready, the card runs the §3.7-style honest checklist inline (generate-then-start). Never a bare spinner, never a 2-minute gym-floor wait behind the screen's only button (the shipped app's worst trap — not re-inherited). |
| **Back-off day** (model says don't — distinct from scheduled rest) | Hierarchy inverts to match the coach's judgment: the coach line leads with the back-off; the card presents the **reduced prescription as the primary Start**; the original session demotes to a "Train anyway" outline secondary; the red alert row sits above the fold. Start starts the reduced session — what the button starts is never ambiguous. |
| **Rest day** (scheduled) | No fake workout, no grayed Start. Coach line leads; the hero slot becomes a recessed `well` rest card (surface→well is the honest material for rest) stating concretely what recovery buys, grounded. One `ink-muted` action: "Log an unplanned session." |
| **First-ever Today** | The onboarding handoff. Coach line comes from the seeds ("First session doubles as calibration — expect a weight check or two", owned by `onboarding-calibration.md`); evidence lines carry hollow markers; the Lens shows its calibrating state (below). |
| **Paused / in-progress session** | Hero becomes the resume card — elapsed time + position ("Paused at set 3 of 5 — squat"), accent **Resume**. Renders **only** for a session with ≥1 logged set; sentinel-only ghosts never surface (audit F3 guard). |
| **Done for today** | The coach's-read one-liner echoed from the summary + tomorrow's preview. No second Start — but the same quiet off-script action as rest day ("Start another session"); two-a-days are real for this audience. |
| **Returning after a gap** | The coach line claims an adjustment **only if** the session was verifiably regenerated post-gap; otherwise it offers the action ("It's been 10 days — regenerate today to ease back in?"). Stale pre-gap evidence numbers carry the calibrating cue. (The shipped app's fabricated "we've adjusted" — audit F8 — is the named failure.) |
| **Program complete** | The biggest retention handoff in the product, not a shrug: hero becomes the cycle recap (the projection/calibration data exists) + "Start your next program" as the primary CTA. |
| **No program / generation pending** | Honest state, exactly one working CTA, **named per state** in build specs — never an unspecified "do something" (unnamed CTAs are how dead pointers happen). If generation runs, the honest checklist — never a bare spinner. |
| **Degraded (model/coach offline)** | The card renders from local program data; the coach line collapses; the Lens shows unknown. Today never blocks on a network call to show the workout. |
| **Date rollover** | Header date and all "today" content refresh on day change and on foregrounding — no stale yesterday-screen. |

### The Lens — compact states & sheet

- **Compact states:** focused iris + number (resolved) · **unfocused iris + "—"**
  (unknown / calibrating / stale — day one, post-layoff) · slow blade
  oscillation (computing, the "Updating" register). **A gauge that is always
  confident fabricates confidence** — the unknown state is a §8 requirement,
  not polish.
- **The sheet** (a true sheet — it stays small; the deep view does not creep in):
  nothing ever sits above the gauge. Iris large + number + state word, then the
  *why* grounded in 1–2 **training-load** numbers — readiness is computed from
  training data only and the sheet **says so** ("Based on your training load —
  no sleep or HRV data"); copy never implies sources we don't have. Two-tier
  disclosure below (Bevel pattern): "How to read this" / one-time "How it's
  calculated." State-word lexicon defined once, five words max, designed to the
  longest.
- The old "Progress owns the deep view" pointer is **dropped** — no readiness
  deep view exists yet; the sheet is the readiness surface v1. A readiness
  history view is a Progress-phase question.

### Accessibility

VoiceOver order: coach line → session card (title, evidence, Start) → alerts →
Lens → footer. Lens label: "Readiness 72, recovered" (the iris is never the sole
carrier — `ui-overhaul-spec.md` §6). Dynamic Type shedding order: **footer first**,
then card meta, then the Lens compacts to number-only — lift numbers and Start
are the last to compromise. Coach line wraps to 4 lines at AX sizes, never
truncates.

### Explicitly cut

Greetings and name-dropping, streak counters as hero, photo/video heroes,
dashboard card stacks, promo/upsell banners inside Today (nothing ever outranks
the day's answer), mascots, week-progress rings (a 0% ring punishes starting),
pull-to-refresh.

---

## Part 3 — Mobbin references (panel-annotated)

Splash:
- [lululemon — MADE TO FEEL](https://mobbin.com/screens/c264bfcf-b63d-4866-a625-23a228d59dfd) — the masterclass: letterforms drawn for one purpose, brand glyph embedded *inside* the word. Licenses the aperture-A. Energy from scale + commitment, not bubble shapes.
- [Grill'd](https://mobbin.com/screens/74204dde-4809-4779-9b63-b9b5d399d908) / [GCOO](https://mobbin.com/screens/7fc8f7ed-353e-45f7-a753-9dcce187698a) — pure flood + wordmark works *because* the letterforms are owned; the flood is rented, the mark is owned. GCOO's bottom-edge "by GBIKE" is the right slot for any secondary line. No tagline on either.
- [pliability — statement](https://mobbin.com/screens/f7f0ec2e-89bf-4361-a9f3-ee19a8cd43bc) — steal the two-tone value emphasis (white/grey within one sentence) for coach lines; reject the rotating manifesto (filler by our own law).
- [Taco Bell](https://mobbin.com/screens/09e3fcc6-17f1-497c-b4aa-abf291eb0205) — the named failure: gradient softens the ink; "Welcome" is filler; an outlined pill on a non-interactive screen reads as a control. Nothing on a splash may look tappable.

Today / coach home:
- [Tempo — coach line](https://mobbin.com/screens/20034c2d-8a1d-4a1d-a8cd-8376815176ae) — validates the pattern; **warning:** its accent-colored keyword reads tappable — Apex emphasizes by weight, never hue. Also the only reference that specced its day-1 variant; we now have too.
- [Apple Fitness+ — For Today](https://mobbin.com/screens/35c82e3b-a43e-47c5-ae01-573f85d5a8ba) — the eyebrow label is taken ("TODAY · DAY 2 OF 4"); the content shelf is rejected.
- [pliability — program card](https://mobbin.com/screens/1446a54b-066c-4420-85d1-db2f122e0a57) — color-as-CTA recall validated (their acid yellow ↔ our ultramarine slab); the barnacled card top (avatar, gift icon, 0% ring) is the clutter tax we don't pay.
- [Fitplan](https://mobbin.com/screens/dc1aeee1-289b-4cc5-83fc-f09201d3f4cb) — exercise list visible beneath Start proves lifters want to see inside before committing → evidence lines. Video chrome rejected.
- [Hevy — utility list](https://mobbin.com/screens/ffc35de8-fc69-4292-b7ac-710ab04c6e65) — "Apex with the model off": the cautionary baseline for visual craft, AND the honest pole — its standing Quick Start is why done-state and rest-state keep an off-script action. Its comma-run-on truncated list is the negative proof for two-column evidence rows.

Readiness:
- [The Outsiders — High Readiness](https://mobbin.com/screens/62d556a4-d34e-4c5a-b50e-20463d8644d7) — the best reference in the set: "Overnight Data Missing" as a first-class honesty card → the Lens unknown state and source-disclosure sheet; "Not every day is this workable" is the copy register; the huge flush-left number-as-composition informs the sheet.
- [Oura — readiness arc](https://mobbin.com/screens/146a11e1-f12f-4536-810a-029788d8a1ce) — canonical number+word+arc proportions (number ~4× the word); the "Updating…" header → our computing state; the promo banner above the score is the violation Today's cut list bans.
- [Tempo — Primed 100](https://mobbin.com/screens/ffece9a9-c86b-46a0-a023-28bc7c6aceeb) — flat accent disc needs no ring/gradient (sheet hero precedent); **but** "100" + fully-lit muscle map = fabricated precision and granularity (§8's named failure); and its disc-blue sits near ultramarine — the *blades* are what keep our gauge from reading as Tempo's.
- [Bevel — recovery ring](https://mobbin.com/screens/aa0c2117-bc7b-4904-bbd7-afa5558f7153) — the two-tier "How to interpret / How it's calculated" disclosure, with source attribution. The neumorphic skin is rejected (dates fast, off-register).
- [Gentler Streak — rest day](https://mobbin.com/screens/f9bf6004-fa31-4dbe-818a-6acbd51f0cae) — rest-as-guidance with actionable chips → the rest card + unplanned-session action. The mascot, greeting, and tri-color bar are all rejected; take the brief, not a pixel.

---

## Part 4 — The five open questions, resolved

1. **Iris-seed shared element:** travel **cut for v1**; iris integrated into the
   wordmark's A, focusing in place; Today's Lens settles in place post-drain.
   (Unanimous against shipping the travel; the art-direction agent's integrated
   version is preserved in §6 as the only acceptable v2 construction.)
2. **Lens placement:** header-right compact — readiness is context, not
   command; the coach line cites it when it matters. (Unanimous.)
3. **Wordmark case:** **caps APEX with the aperture-A** — the 2–1 call, won on
   load-bearing grounds (§6).
4. **Rest-day card:** quiet `well` card kept — an empty Today reads as broken,
   the card states what recovery buys and hosts the off-script action.
   (Unanimous.)
5. **Alert stacking:** max-2 + counted "more" row, with the severity law: red
   back-off rows never collapse, always slot 1, max one red at a time.
   (Unanimous, amendments folded.)

---

## Part 5 — Build-time notes

- Pre-generation policy (States) needs an engine home: trigger on
  session-completion processing; surface a "ready" flag Today can read.
- The Lens unknown state needs a real signal: readiness-confidence or
  data-recency from the trainee model (exists conceptually in the confidence
  lifecycle work, #166).
- Alert rows bind to existing ack machinery (calibration-review ack, re-armed
  re-calibration banner #305, goal review P5-D06) — reuse the watermark
  semantics, don't invent a parallel dismissal store.
- Wordmark + app icon are design-asset deliverables (vector, pre-rendered) —
  not code-time improvisation.

## Part 6 — Review record (2026-06-11, three agents)

Panel: UI-craft expert, UX/product expert, and a visual/art-direction expert
(new this round), same Uber-calibre brief; each reviewed the draft + all 15
references. Headlines: *the draft splash failed the squint test (stock type on a
flood is a font specimen, not a mark); the Today state machine was missing
roughly half its rows, two of them traps documented in the shipped-app audits;
and the launch-screen seam was unbuildable as written (storyboards don't load
custom fonts).*

| # | Finding (agent) | Disposition |
|---|---|---|
| P0 | Squint-test failure → custom aperture-A wordmark, caps (visual) | **Accepted** — Part 1 The mark. Case split 2–1 (UI, UX: lowercase-quiet; visual: caps, iris-in-A). Caps won: the iris integration is load-bearing and the custom letterform is the distinctiveness fix. One-word change if reversed. |
| P0 | Launch-seam engineering: pre-rendered asset, window bg, status bar, seam test (UI) | **Accepted** — Part 1 Static frame. |
| P0 | Drain art direction: ruling-pen edge, reveal-in-place, motion canon (visual) | **Accepted** — Part 1 The drain; canon line added to `DESIGN.md`. |
| P0 | Session-not-yet-generated state + pre-generation policy — the gym-floor trap (UX) | **Accepted** — States. |
| P0 | Back-off day state — hierarchy must invert (UX) | **Accepted** — States. |
| P0 | Lens unknown/calibrating state — an always-confident gauge fabricates (UX, UI) | **Accepted** — The Lens. |
| P0 | Evidence-line lockup spec + two-column rule + confidence cue (UI, visual, UX) | **Accepted** — Layout 3; §8.2 cue chosen over an exemption. |
| P1 | Launch routing table (UI, UX) | **Accepted** — Part 1 Routing. |
| P1 | Scroll contract; header collision; settings `accent-ink` + Lens instrument exemption (UI) | **Accepted** — Layout 1 / Scroll contract. |
| P1 | Coach-line length contract, no-echo, weight-not-hue emphasis, stable collapse (UI, visual, UX) | **Accepted** — Layout 2. |
| P1 | Tagline cut from cold launch (visual, UI) | **Accepted** — Part 1 The mark. |
| P1 | Drafting-rule hairlines + margin annotations (visual) | **Accepted** — The drawing. |
| P1 | First-ever Today, program-complete, returning-after-gap, done+wants-more states (UX) | **Accepted** — States. |
| P1 | Alert severity law + durable dismissal (UX, UI) | **Accepted** — Layout 4. |
| P1 | Slow-launch tier + budget realism (UI, UX) | **Accepted** — Timing. |
| P2 | Compact Lens = iris+number only, ≥24pt blades (visual, UI) | **Accepted** — Layout 1. |
| P2 | Start = drawn rectangle `rounded.md`, ≥56pt, SG 600 label (visual, UI) | **Accepted** — Layout 3. |
| P2 | Lens sheet: nothing above the gauge, source disclosure, two-tier education, drop the dangling Progress pointer (all three) | **Accepted** — The Lens sheet. |
| — | Iris travel choreography (visual: A's eye detaches → header, sole moving figure, 3-phase ≤1.2s) | **Deferred** — the only acceptable v2 construction if travel is ever revisited. |
| — | Drafting-rule system app-wide promotion | **Deferred** to the next screens' design round. |
