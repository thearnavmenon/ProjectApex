# Progress — design spec (the capability ledger)

**Status: locked 2026-06-11** after a four-agent review (UI craft / UX-product /
visual–art-direction / motion-animation). All accepted findings folded in;
record, dissents, and dispositions in §12. Companion docs: `DESIGN.md` (tokens;
band component, dim data-viz, tags, ink laws), `ui-overhaul-spec.md` (§2 nav,
§8 data-honesty), `post-workout.md` (band component §6 — pattern detail is
context #3; the session record; ratchet fossils §7; witness rule),
`live-loop.md` (anchor grammar, PR stamp), `splash-today.md` (hairline/tick
vocabulary), `onboarding-calibration.md` (band component context #1).

## 1. Job

The model made visible **over time**. Today proves the coach in the moment;
the reveal proves it for a session; Progress proves it across months — the
compounding-value screen. It answers two questions: **am I actually getting
stronger?** and **how close is the next proof?** — with the model's belief,
not a pile of raw numbers.

**The core epistemics (the anti-Hevy move, g08):** competitor charts plot raw
session maxes, so a planned light day renders as a dip and reads as
regression — a true number stripped of intent. We chart **the band — the
model's belief** — as the primary object; raw observations are evidence dots
scattered around it, never connected by a line (the connecting line is *why*
g08's dip reads as a fall; a scattered dot below an unmoved band can't).

**The screen's one thing is the floor** — the heaviest line at both levels:
at root, the shared floor datum down the ledger (all your floors, now); in
detail, the floor through time (the staircase). Same line, two projections.
The floor is the app's only honest monotone metric — it can never draw
regression — which is the legitimate claim to the guaranteed-win chart shape
Bevel (g11) fakes with cumulative volume.

**Boundary (nav law):** Progress owns **patterns and sessions**; Train owns
**exercises** (library, how-to, per-exercise history). The loop's "Why this?"
opens exercise detail — Train's surface.

## 2. Structure, navigation, and motion discipline

1. **Root — the capability ledger** (§3).
2. **Pattern detail** — the band now + the band through time (§4–§5).
   Destination of the post-workout strip's tap (that gate resolves here).
3. **Session record** — the post-workout screen in history form (not
   re-specced here).

**Motion laws of the tab:**

- No bookend anywhere on Progress's own surfaces; all navigation is 150ms
  `transition-nav`, **fully assembled at frame 1** — no staggered row
  cascades, no on-scroll entrance fades, no new-data shimmer, no first-visit
  ceremony (the cold-start state *is* the design). Scroll position and period
  selection persist across tab switches. A program change renders its new
  state on next visit assembled — **a ledger never animates a reshuffle.**
- **The milestone quarantine:** Progress never plays `celebrate-ratchet`,
  never fires `impact(.rigid)` or `notification(.success)`. Staircase steps
  and fossils render statically, forever; the record row's PR stamps render
  as static ink (the 120ms draw-on belonged to the logging moment). Viewing
  the new floor here does **not** disarm a still-armed session-record
  flourish — the flourish belongs to the record's strip (`post-workout.md`
  §7); Progress carries facts, not celebration state.
- **The witness-rule seam:** a session record opened from this tab still
  honors `post-workout.md` §7 in full — a never-witnessed ratchet flourish
  fires once there, by contract. *(Cross-doc flag, filed: a tap during the
  reveal's absorption sequence cancels its remaining beats — they never
  resume; the unfired flourish stays armed. Belongs in `post-workout.md`
  §2/§7 at next amendment.)*
- **No shared-element morph into pattern detail** — from the root strip or
  the post-workout strip alike. The strip's load axis is horizontal; the
  chart's is vertical: a "strip becomes the chart edge" morph rotates a data
  axis 90° mid-flight — illegible while moving and dishonest at rest.
  **Continuity is drawn, not animated:** the chart's right edge terminates
  in the strip's exact anatomy — 2px ink floor terminal, 1px stretch
  terminal, the latest dot as its final dot — so the strip the lifter just
  tapped is recognizably the staircase's newest cross-section.
- Charts render **assembled**: no draw-on theater, no count-ups, no panning
  or zooming. Nothing on Progress ever floats above the drawing except the
  scrub callout (§5), and no chart-attached chrome ever carries evaluative
  copy (g11's "Stronger than ever!" pill, banned by name).

## 3. Root — the capability ledger

Top to bottom on paper:

- **Margin row (on the top rule):** "Progress" in `title`; trailing, the
  period control (§6). When ≥1 floor ratcheted in the selected period, the
  top rule carries one **margin annotation** in drafting register — tracked
  caps `label`, two-tone ("12W · **2** FLOORS UP · **+7.5** KG", digits ink
  tnum, words pencil). Zero ratchets: the annotation is absent — an empty
  slot, never "0 floors moved."
- **The spine.** Pattern strips render in **band-relative coordinates**:
  every row's floor at one fixed shared x-position, stretch at another, the
  dot plotted as a fraction of its own band (out-of-band positions plot
  outside, never clamped). The aligned floor ticks fuse into **one
  continuous 2px ink vertical running the full strip column** — the heaviest
  line on the screen and the root's center of gravity: every lift's position
  against its floor, readable in one squint. Without the spine this root is
  a column of unrelated sparkline widgets (g12's structure with better ink).
- **Row anatomy** (self-sizing, 64pt floor): line 1 — pattern name, Inter
  500 17pt ink, owns the line, wraps to 2 at AX, never truncates mid-word.
  Line 2 — the **list-scale band strip**, a sanctioned reduction of the §6
  band component written into its anatomy: **unlabeled drawing** (no tick
  labels — absolute numbers live in the annotation line only, resolving the
  numbers-never-twice law), floor tick 2px full strip height (fused into the
  spine), stretch 1px, dot 5pt (solid = last observation measured, hollow =
  estimated), no movement bracket (brackets are detail-scale ink). Line 3 —
  the **annotation line**, 13pt, two-tone per the ink law, always reserving
  its line height (period changes never reflow rows):
  - moved in period: "Floor **100** · **+5** since 18 Mar"
  - ratchet within reach (deterministic watermark fact, #305): "Floor
    **100** · **2 of 3** sessions above 102" — **the forward hook lives here
    permanently.** This is an instrument rendering a watermark fact, so the
    coach-voice cadence limit (`post-workout.md` §5, once per pattern per
    week) does not apply — that limit governs the voice; this is a gauge.
  - otherwise: "Floor **100** · holding" — quiet, composed.
  - calibrating: "still calibrating — **2** more sessions" (the count is the
    #166 lifecycle's actual readiness rule, never invented copy).
  Movement takes precedence over the hook; one annotation per row. Whole row
  one tap target → pattern detail.
- **Ordering law: fixed canonical pattern order** — the model's own taxonomy
  (squat, hinge, horizontal press, vertical press, horizontal pull, vertical
  pull, …), forever, for everyone. **Position never encodes program
  membership; treatment does:** in-program patterns render full rows;
  dormant/out-of-program patterns hold their canonical position but compact
  to a single muted line — name + "Floor **100**" + "last trained 12 May"
  (date in pencil), no strip. Program-split order was declined 3–1 in panel
  but overturned on the stability argument: split order reshuffles at
  exactly the highest-stakes visit (post-program-switch judgment day) and
  demotes a three-ratchet band below a never-trained pattern; a ledger's
  row order is part of the ledger.
- **Sessions — the revision table.** Below the strips, the dated session
  list (a technical sheet's revision table: tag / date / description). Each
  row: the session eyebrow (tag-family classification + date unboxed; time
  added when two sessions share a date; **AMENDED** tag carried when the
  record was amended) and the **stored claim line verbatim** (`body`
  register, 2-line max, its number never truncates) — the coach as quoted
  record, not live commentary. Most recent ~6; "All sessions" → full list.
  Tap → the session record. After an amendment, the strips and chart
  re-render from live model state while the quoted claims never recompute —
  the instrument and the quote may legitimately disagree; the annotation
  lives inside the record (`post-workout.md` §5).
- **No calendar, no streaks** (g14/g17): the revision table answers "when
  did I last train" without grading attendance, and a dated list has no
  pagination unit, so no empty page can exist (g13's structural tax).

## 4. Pattern detail

- **Title block (on the top rule):** pattern name (`title` 22pt ink); the
  screen's literal number as an evidence lockup — "FLOOR" tracked-caps label
  + **the current floor, SG 700 tnum ~40pt full ink** — with the all-time
  delta beside it in two-tone ("**+12.5** since Feb"); "Stretch **115**" at
  label scale, hollow-cued when projected; one muted status line ("last
  measured 2 days ago" / "still calibrating — **2** more sessions").
  Calibrating patterns swap the lockup for the hollow cue. "Why this band?"
  (`accent-ink`, label scale, ≥44pt hit rect) sits in the title block. On
  scroll the title block condenses into the pinned nav as "Squat · 105" —
  the only thing that pins; nothing pins on the root.
- **The band component at full scale** — the now-state, exactly the §6
  anatomy the post-workout tap promised (context #3 honored literally: same
  instrument, bigger, then its history below). Its caption carries the
  forward hook or movement annotation (same rules as the root line).
- **The staircase chart** (§5) — the band through time.
- **The record row:** genuine PRs only, anatomy per the tag law — inverted
  **PR** stamp (classification only) · value "**142.5** kg × 1" SG 600 tnum
  15pt full ink · date `label` pencil, unboxed. Most recent first; immune to
  the period control, labeled "All-time" so the exemption is visible;
  duplicate-value pairs collapse to one statement (g15's two identical
  numbers saying nothing).
- **Pattern history:** this pattern's working sets by session — collapsed
  anchor-grammar rows (`post-workout.md` §9), each opening its session
  record. This is the chart's query surface and per-session observation
  table; no second chart view exists (the g01–g04 metric-democracy cut).
- **Variants:** "Back squat · Front squat — both feed this band" — plain ink
  rows, **zero affordance** (no `accent-ink`, no chevron) until Train ships;
  the affordance arrives with the destination.
- **The provenance sheet** ("Why this band?"): a system sheet, text rows
  only, no chart, nothing animating. Contents: per-edge sources ("Floor 100:
  **14** measured sessions · Stretch 110: projected"), last calibration
  date, and the ratchet rule stated once in plain words ("the floor moves up
  when three sessions clear it" — the staircase is more legible once the
  mechanism is named). **When a calibration review or re-calibration is
  armed (#269/#305 machinery), the sheet appends one pointer row into the
  review flow** — it never re-implements the review (commit semantics don't
  belong in a provenance sheet). *(Named build debt, filed in §12: the
  calibration-review surface itself needs a redesign home before the rebuilt
  app ships, or the alert rows of `splash-today.md` point at old-app
  screens. Progress is its entry, not its owner.)*

## 5. The staircase chart — the band through time

**The no-slope law.** The model's belief is a sample-and-hold signal: it
updates at sessions and *holds* between them. Therefore **every line on this
chart is a step function** — the floor steps only at ratchet events (2px ink
verticals at hard 90° corners), stretch and band edges step at re-derivation
events (1px hairline verticals), the band fill is bounded by stepped edges.
**No diagonal exists anywhere on this screen.** A slope claims continuous
knowledge; a step claims a dated fact. Gap eras render as long flat treads
by construction. (This is also the squint-test separation from Bevel: their
staircase eases its corners because its shape is an aesthetic; ours can't,
because its shape is a claim.)

- **Geometry:** height 200pt fixed, portrait-only, plot inset to the text
  margins. Y-domain: padded extent of band-edge history + dots in window,
  snapped to 5 kg / 10 lb — **non-zero baseline, a deliberate call** (a
  zero-based load axis renders every ratchet ever earned ~invisible).
  X-domain: the selected period, **clamped to the data span when shorter**
  (week 2 never renders ten weeks of empty pre-history); the band always
  extends flat to today (a 3-week gap is visible as a long tread, never
  hidden). X-labels: weeks at 4W, months at 12W, years at All — `label`
  pencil (**work is ink, time is pencil extends to chart axes**).
- **The grid is the fossil record.** No generic gridlines. The chart's only
  horizontal references are the floor's own historical levels: each tread
  extends a 30% hairline leftward to the margin, labeled with its value in
  tnum full ink (work numbers). The y-axis *is* the staircase's history; an
  analytics grid never appears.
- **Riser dimensioning — extension lines, not tooltips.** Each ratchet riser
  is annotated as a technical-drawing dimension: old and new treads project
  short extension hairlines (1px at 30%, ~8pt) past the riser; a dimension
  line with terminal ticks spans them, "**+2.5**" tnum ink on it; below the
  riser, a 4pt margin tick on the time axis with the date in pencil. The
  `post-workout.md` §7 ghost tick is hereby defined as the strip-scale
  projection of this extension line — one fossil vocabulary, two scales.
  Risers are never tooltipped, never animated. Density shedding: deltas
  render at 4W/12W and shed at All (the step shape and extension lines
  survive; the cumulative delta lives in the title block); ratchet steps are
  **never** decimated.
- **Observation dots — the qualifying rule (who may mint a dot):** a session
  mints at most one dot — its best e1RM from a logged **working** set with
  known weight and known reps, unmodified load (no chains/bands — g01
  computes a "max" off chains anyway; we don't), within the e1RM formula's
  stated rep-validity cap; bodyweight-loaded patterns mint dots only under a
  stated bodyweight rule, else no dot. Sessions with no qualifying set
  (AMRAP-unknown only, all-warm-ups, bailed) render **no dot** — the absence
  stays named in the pattern-history rows, never plotted. Solid = qualifying
  logged observation; hollow = seeded/projected value. Dots are 5pt (4pt
  when >40 in window); at All, the window renders **weekly-best selection**
  (a selection, never an average) with the rule named in a caption ("weekly
  best shown") — silent aggregation is fabrication.
- **Confidence through time — one vocabulary:** dashed edges (`projection`
  token) mean *the model is guessing here*, covering both estimate-seeded
  eras (pre-first-measurement) and #166 gap-widened eras; edges go solid
  where measurement resumes — the chart shows *when the model started
  knowing*. The chart renders the model's actual floor/stretch values only:
  never synthetic widening, never opacity gradients (a gradient implies a
  continuous confidence signal the model doesn't emit).
- **Era annotations — intent attaches to time** (or g08 wins inside our own
  chart): model interventions render as dated margin annotations on the time
  axis in the drafting vocabulary — "pressing reduced · 28 May–11 Jun"
  (pain-flag reduction, back-off eras). The injured lifter's low dots sit
  inside a *named* era, not an unexplained dip. This is `post-workout.md`
  §6's intent-aware caption extended through time.
- **The scrub inspector — the chart's single interaction.** Touch-and-hold
  then drag raises a 1px ink scrub line + a fact callout: date · observed
  e1RM · measured/estimated, tnum 13pt, values **hard-swapping** per snap —
  you can only scrub to facts (dots and ratchet steps), nothing between.
  Haptic: `selection` detent per snap (new token `scrub-snap`), never
  `impact` (`.medium` is the plate-thud, `.rigid` is the pawl — both spoken
  for). The callout names the session; tapping it opens that session's
  record. Release: 150ms fade. Facts only, never adjectives. Per-frame work:
  the scrub layer is transform-only over rasterized static layers.
- **Period switch = 150ms cross-dissolve,** both renders fully laid out
  before frame 1; axes, treads, dots, and labels **never tween** — an
  animated re-scale shows the floor traveling, and the floor only moves at
  ratchets. The root strips' drawings (floor/stretch/dot — the now-state)
  are **period-independent**; only annotation lines join the crossfade.
- **Display precision:** 0.5 kg / 1 lb, never more (g09's "106.74 kg"); one
  rounding rule produces one string everywhere a floor renders (root,
  detail, reveal, sheet) — the one-fact law dies quietly if Progress says
  102.5 where the reveal said 103.
- **Empty/cold:** the named-absence card, never chart chrome — axes for
  data that doesn't exist are fabricated instrument (g12 renders full date
  axes under "No Data Available").

## 6. Period control

A **house-drawn segmented control** on the margin row of both root and
detail, one shared state: ascending **4W · 12W · ALL**, 13pt tracked labels,
selected segment per the States law (structural — weight 500→600 + a 2px ink
underline tick; no accent, no haptic). Default 12W (one training block;
brackets actually fire); selection persists across visits. Scope: chart
domain, annotation windows, and the root margin annotation — never the
record row (labeled "All-time") or the session list. All-time is the payoff
view (the full fossil record is the only answer this product gives to g09's
"am I good?") and is engineered to survive (§5 shedding rules), but recent
truth defaults first; the title block's permanent all-time delta carries the
compounding story in every window. **Copy law: annotations are
date-anchored ("+5 since 18 Mar") or period-named ("in 12 wk"); the word
"cycle" is banned unless a chip named Cycle exists.** Sparse data renders
sparse — two dots in a 4W window is two dots.

## 7. Honesty rules (this screen's §8 extensions)

1. The band is the claim; dots are evidence — never connected, never the
   primary line.
2. Every line is a step function; the floor never interpolates; no diagonals.
3. Absence is named, never zeroed and never charted: no-dot sessions stay in
   the rows; calibrating strips name counts-to-ready (what's *coming*, one
   better than g13's what's-missing).
4. No percentiles, no leaderboards, no demographic strength tiers (g09 —
   also a data toll, g07's 0/3 demographics prompt): the only comparison in
   the app is you against your own floor, which costs zero extra inputs.
5. No muscle radars/polars (g10's area encoding *squares* differences —
   legs-vs-core reads ~150:1 on ~12:1 numbers; it lies even when the numbers
   are honest).
6. Aggregation is selection, named in a caption, never silent, never an
   average.
7. Ratchet steps are dated facts; thinning rendered dots is rendering,
   thinning steps is deleting facts.

## 8. States

- **Cold start (estimates only):** calibrating strips with real
  counts-to-ready (#166 rule); no chart chrome anywhere; the stillest screen
  in the app — emptiness is not a motion budget.
- **Week 2:** x-domain clamps to data span; two dots are two dots.
- **Plateau / deload:** "holding" annotations + the forward hook — the
  most common visit's 1-tap answer is the distance to the next ratchet, not
  silence.
- **Dormant patterns:** compact muted rows, canonical position held.
- **Gap eras:** long flat treads + dashed edges; never a gap-filling slope
  (g08 connects straight across a 3-week gap — the second indictment).
- **Dim:** dim data-viz tokens; the 12% band fill's legibility at chart
  scale is a named contrast check.
- **Offline:** fully local; zero network.
- **Performance (the idle law's engineering form):** strips and the chart's
  static layers draw once per data-change and rasterize; zero per-frame
  canvas work during scroll; no shadows/blurs in rows. Acceptance criterion:
  a stationary Progress screen submits zero render work; a full-speed scroll
  of 8 strips + 20 rows drops no frames at 120Hz.
- **Reduce Motion:** nothing changes — every transition here is already a
  ≤150ms crossfade; scrub detents kept (haptics survive RM).
- **Dynamic Type / AX:** rows self-size; names wrap to 2 lines; strips shed
  annotations before names; the chart sheds dots → fossil deltas → ghost
  extension lines before the floor line; numbers never truncate. VoiceOver:
  strips read the band-component grammar; the chart is one summary element
  ("Squat. Floor 100 kilograms, moved up twice this period. Stretch 110.
  14 observations, 12 measured.") whose **children are the ratchet steps**,
  rotor-enumerable ("Floor moved to 105 kilograms, 28 May, up 2.5") — never
  per-dot enumeration. The staircase ships an Audio Graph descriptor (floor
  series primary). The period control exposes the adjustable trait. RTL:
  layout mirrors; numeric lockups and anchor-grammar strings are forced-LTR
  runs; the time axis stays LTR.

## 9. Explicitly cut

Calendar heatmaps and streak flames (g14/g17), muscle radars/polars
(g10/g17), percentile and demographic strength levels (g07/g09),
leaderboards (g16), monthly share reports (g17 — also a pseudo-bookend: a
generated "August Report" is a fifth expressive moment smuggled in as
content; Progress compounds quietly or the bookends stop meaning anything),
raw-max trend lines as primary (g08), connecting lines through observations,
total-volume heroes, per-set computed-1RM tables (g01 — "37 lbs 1RM" for a
20 lb warm-up set), workout-count tiles, chart draw-on animation, count-ups,
animated re-domains/pans/zooms, floating tooltips and all evaluative chart
chrome (g11), shared-element strip→chart morphs (the 90° axis rotation),
readiness history (the Lens owns Today — one instrument per surface),
bodyweight log (v1: settings/profile), History segments/sub-tabs, dot
jitter, per-dot VO enumeration.

## 10. Mobbin references (verified frames, `tmp/refs5/`)

- **Hevy exercise chart (g08)** — the Aug-18 dip: a light day rendered as
  regression by an intent-stripped polyline; it also connects straight
  across a Jul 28→Aug 15 gap (the banned slope, shipped), and its auto-fit
  y-domain turns a ~25 kg swing into full-height amplitude theater. One
  keeper: the fixed readout slot above the chart ("75 kg · Aug 18") — zero
  occlusion; our scrub callout takes the shape, facts only.
  [flow](https://mobbin.com/flows/c2621492-cd68-4948-b2dc-07435ee63203)
- **Hevy records (g07/g09)** — dash-filled PR table (absence as glyphs);
  "106.74 kg" (false precision); "stronger than 48% of male lifters" behind
  a 0/3 demographics toll. The percentile serves a real demand ("am I
  good?") — our All-time staircase is the answer that costs nothing and
  compares you only to you.
- **Bevel (g10/g11)** — the staircase form validated, and the trap named:
  cumulative volume is monotone *by construction* (a guaranteed-win chart
  wearing a dishonest metric); ours is monotone by evidence. Differentiators
  are the hard 90° corners and dimensioned risers, not the palette. Its
  "Stronger than ever!" pill floats *over* content with z-priority —
  evaluative chrome occluding data, banned by name. The polar (g10) squares
  differences. Its 1M/3M/6M/1Y segmented at this width proves the form fits.
  [flow](https://mobbin.com/flows/f7bdcb74-7c8d-4db9-9d65-04dfbb20ec97)
- **Tonal (g01–g04)** — metric democracy: Strength/Power/Volume as peer tabs
  over an identical table skeleton whose last column silently changes
  meaning; per-set computed 1RMs off chains-modified warm-ups (the direct
  evidence for our dot-qualifying rule). Take: the per-movement organizing
  principle. Its tracked-caps register is competent and anonymous — register
  without an owned drawing isn't identity.
  [flow](https://mobbin.com/flows/0b7f9e89-5714-414b-a1a0-2a02d0854c7e)
- **Gymshark (g12/g13)** — the zero-dashboard, and subtler: full chart
  frames with date axes rendered under "No Data Available" — fabricated
  instrument. Structurally a column of self-contained chart cards with no
  shared datum: what our root is *without* the spine. g13's month-paged
  history forces empty pages to exist; a dated list can't have one.
  [flow](https://mobbin.com/flows/49fb3822-c2cd-4a67-8d82-d0e19ac42898)
- **Peloton (g14/g15)** — calendar adherence theater; "Last time 0:00:30 /
  Max time 0:00:30" — two identical numbers saying nothing (→ the
  duplicate-collapse rule).
- **Hevy stats/report (g16/g17)** — the everything-menu and the monthly
  report (streak flame + one thin wedge in an empty hexagon under a hero
  Share button — a report that ships its own emptiness). The cut relocates
  the periodic-reflection need to the All-time staircase.
- *(g05 — mis-captured live-logging frame; context only.)*

## 11. The six open questions, resolved

1. **The coach does not speak on Progress.** The lab bench holds: a witness
   shouldn't grade its own testimony, and the coach is already present as
   *quoted record* (the session rows' stored claims). The moat still speaks
   — in instrument register: the root margin annotation, the forward hook,
   the title block's all-time delta. Data, not utterance. A v1.x period
   read, if ever, is period-scoped, deterministic, and stored — never
   regenerated per render. (Unanimous on no-live-line.)
2. **Ordering: fixed canonical pattern order,** program membership as
   treatment, never position (UX's overturn of the draft, 1-against-3 on
   the stability-at-judgment-day argument — the majority's own
   never-re-sorts principle is better served by canonical order).
3. **One instrument.** The pattern-history rows are the observation table;
   the scrub inspector makes dots readable in place (UI's non-interactive
   stance declined — evidence you can't read is texture); confidence-
   through-time is the single dashed vocabulary, discrete, never gradients.
4. **One root, strips-then-sessions; calendar cut confirmed.** The session
   list is the sheet's revision table; dormant compaction keeps it within
   one scroll. No History segment (a fourth nav surface inside a three-tab
   law).
5. **The provenance sheet is the v1 read surface + armed pointer** into the
   #269/#305 review flow — never the review itself (commit semantics don't
   belong in a sheet; 2–2 panel split resolved by scope). The review
   surface's redesign is **named build debt** (§4) so the shipped feature
   cannot silently die in the rebuild.
6. **4W · 12W · ALL, default 12W, persisted;** All is the payoff view and
   is engineered to survive; the title block's permanent all-time delta
   carries the compounding story into every window (visual's detail-defaults-
   to-All declined 3–1; the dissent's need is met by the delta annotation).

## 12. Review record (2026-06-11, four agents)

Panel: UI-craft, UX/product, visual/art-direction, motion/animation.
Headlines: *the draft was "the right epistemics wearing a borrowed
instrument" (visual) — the staircase lacked the no-slope law, riser
dimensioning, and its own grid; the root was a wall of private-coordinate
widgets until the spine; the screen had no forward pull until
distance-to-ratchet became a permanent annotation (UX); the dots had no
qualifying rule and would have re-derived g01's fabricated precision (UX);
the period re-domain and strip→chart morph were the two most dangerous
animations on the screen and both are now banned with reasons (motion).*

| # | Finding (agent) | Disposition |
|---|---|---|
| P0 | The no-slope law — every chart line is sample-and-hold; hard 90° corners; both edges step functions (visual; UI's never-interpolate concur) | **Accepted** — §5. |
| P0 | The root spine — band-relative rows, one fused 2px floor datum down the ledger (visual) | **Accepted** — §3. |
| P0 | Root row micro-spec + the unlabeled list-scale band variant (resolves the numbers-never-twice contradiction); two-tone annotation; reserved line heights (UI + visual independently) | **Accepted** — §3. |
| P0 | Distance-to-ratchet as permanent instrument annotation — the forward hook; voice-vs-instrument distinction recorded (UX) | **Accepted** — §3, §4. |
| P0 | Observation-dot qualifying rule (working set, known values, unmodified load, rep-validity cap, BW rule, no-dot sessions) (UX) | **Accepted** — §5. |
| P0 | Chart engineering: non-zero y-baseline, x-clamp to data span, per-period x-labels, 200pt, overplotting/weekly-best with named caption (UI + UX) | **Accepted** — §5 (UI's weekly-best selection kept over visual's never-aggregate — selection ≠ average; recorded). |
| P0 | Period re-domain = 150ms cross-dissolve, geometry tweening banned; strip now-state period-independent (motion) | **Accepted** — §5, §6. |
| P0 | No shared-element morph into detail — the 90° axis-rotation argument; continuity drawn via the chart's right-edge terminal anatomy (motion) | **Accepted** — §2. |
| P0 | Milestone quarantine written down; PR draw-on never replayed; witness-rule seam + absorption-interruption cancel rule (motion; cross-doc flag to `post-workout.md` filed) | **Accepted** — §2. |
| P0 | One-window law; "cycle" banned; date-anchored copy (UX + UI + visual convergent) | **Accepted** — §3, §6. |
| P1 | Pattern-detail title block + evidence lockup + condensing pin; detail opens with the full-scale band component (context #3 honored literally) (UI + visual + UX convergent) | **Accepted** — §4. |
| P1 | Riser dimensioning — extension lines; ghost tick redefined as the strip-scale projection; delta shedding at All; steps never decimated (visual + UI merged) | **Accepted** — §5. |
| P1 | The grid is the fossil record — tread-level hairlines as the only y-references; pencil time axes (visual; UI's generic gridlines superseded, its domain laws kept) | **Accepted** — §5. |
| P1 | Scrub inspector — facts-only callout, snap-to-facts, `selection` detents, tap-through to the session record (motion + UX; UI's instrument-not-control declined — recorded) | **Accepted** — §5. |
| P1 | Era annotations — intent attaches to time ("pressing reduced · 28 May–11 Jun"); one dashed confidence vocabulary, no synthetic widening (UX + visual + motion reconciled) | **Accepted** — §5. |
| P1 | Ordering: fixed canonical taxonomy order; dormant compaction with pencil dates (UX over UI/visual/motion's program-split preference — stability argument; dissent recorded) | **Accepted** — §3, §11.2. |
| P1 | Provenance sheet: read + ratchet-rule line + armed pointer row; review redesign = named build debt (UI/visual/motion's read-only vs UX's embed — resolved by scope) | **Accepted in part** — §4. |
| P1 | Entrance discipline: assembled frame 1, no stagger, persisted state, reshuffles never animate (motion) | **Accepted** — §2. |
| P1 | Period control: house-drawn segmented, both screens, one state; records row labeled All-time (UI; visual's tag-menu form declined — hidden options; its register kept) | **Accepted** — §6. |
| P1 | Rendering/idle engineering + 120Hz acceptance criterion (motion) | **Accepted** — §8. |
| P2 | Root margin annotation (totalizer) in drafting register; absent at zero (visual + UI merged) | **Accepted** — §3. |
| P2 | Record-row anatomy per the tag law; duplicate-value collapse; All-time immunity visible (UI) | **Accepted** — §4. |
| P2 | Session rows: AMENDED carry-through, time on date collision, claim wrap rule; instrument-vs-quote divergence stated (UX + UI) | **Accepted** — §3. |
| P2 | AX bundle: rotor-enumerable steps, observation-count child, Audio Graph, adjustable period control, RM clause, RTL runs, one-rounding-rule (UI + motion) | **Accepted** — §5, §8. |

Cross-doc flags filed (grep-and-report, not edited here): `post-workout.md`
§2/§7 — absorption-sequence taps cancel remaining beats (never resume,
flourish stays armed); `post-workout.md` §6 / `DESIGN.md` — the list-scale
band reduction joins the component anatomy. Named build debt: the
calibration-review surface (#269/#305) needs a redesign home; band-center
history snapshots remain a model-API requirement. Deferred: dot-tap→row
highlight (v1.x nicety); period read (v1.x, stored).
