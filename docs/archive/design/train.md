# Train — the program & the exercise library

**Status: locked 2026-06-11** after the four-agent panel (UI-craft, UX/product,
visual/art-direction, motion/animation). The fifth and final per-screen spec of
the Phase 3 UI overhaul (after `onboarding-calibration.md`, `splash-today.md`,
`live-loop.md`, `post-workout.md`, `progress.md`). Visual tokens are `DESIGN.md`;
behavior law is `ui-overhaul-spec.md`. The panel's headline: *the draft was the
most competent-but-anonymous of the five specs — its one novel epistemic problem
(diminishing knowledge across a planning horizon) was specced as a colour swap,
not a drawn instrument; it punted plan agency to the panel when the live loop
already shipped mid-set swap; its "if shown" trend chart was the seam that let
Hevy's banned slope back onto the exercise surface; and the calibration-review
pointer chain was already dangling with no owner. The lock draws the horizon,
stakes the agency, kills the chart, and gives the review a home.*

---

## 1. Job

Train is **the plan and the lexicon** — the two durable scaffoldings of the
product. Everything else is *now* (Today) or *evidence* (Progress, post-workout);
Train is the part that holds still: the program ahead of you, and the dictionary
of movements behind it.

**The nav law (`ui-overhaul-spec.md` §2), made exact:**

- **Today owns *now*** — the next workout and one-tap Start.
- **Progress owns *patterns and sessions*** — capability bands, e1RM history, the
  session record (`progress.md` §1 boundary).
- **Train owns *the plan and exercises*** — the calendar / week structure / cycle
  shape, and the exercise library (browse, how-to, per-exercise history). Exercise
  detail is also the contextual destination of the loop's **"Why this?"**
  (`live-loop.md` §3) and carries the model's reasoning. **Re-calibration changes
  the program, so the calibration-review surface lives here too** (§9).

Two halves, one tab, because both answer "the things that hold still":

1. **The program** — forward-looking. What's this week, what's coming, the shape
   of the cycle. The thing a committed lifter opens Train to *see ahead*.
2. **The library** — a reference. Every movement: how it's done, what it works,
   and your own history with it. A lookup, reached by search and contextually from
   the loop — not a feed you scroll.

**Guiding principle, located.** "Quietly right in the moment, visibly smart around
it" — Train is *entirely* in the "around it" zone, where the coach shows its
thinking about the **plan**. So Train is expressive in **content** and **drawing**,
never in **motion**: it is **not a bookend** (drain-and-rise is reserved for
app-open / workout-start / post-workout / milestone, `DESIGN.md` Motion). Like
Progress, Train is a browse/reference surface — workhorse motion only. Its
intelligence is what it *says* and how it *draws the plan*, never how it moves.

---

## 2. Structure, navigation, and motion discipline

**One root, the program; the library is reached from it — not a co-equal second
root.** A segmented "Program | Library" toggle would manufacture a fourth nav
surface inside a three-tab law (the smell `progress.md` §11.4 named). But the
library is one of Train's two declared halves (§1), so it is **not** demoted to a
header glyph either: a **persistent, full-width search affordance is pinned in the
program-root header** — the lexicon is one tap from the root without becoming a
nav root. The structure:

1. **Program root** (§3) — the cycle drawn as a vertical day-spine: this week in
   full, the horizon compressed below it.
2. **Day preview** (§4) — tap a day → the session that day (or its shape).
3. **Plan edits** (§5) — reschedule / swap / "can't train today," reached from a
   day or its preview; model-absorbed, rendered as provenance.
4. **Exercise library** (§6) — the pinned search/browse; also where the loop's
   "Why this?" lands *past* it, at the leaf.
5. **Exercise detail** (§7) — the leaf, **one scroll**, reached **four ways**:
   library search/browse; a tapped exercise inside a day preview; the loop's "Why
   this?"; and **Progress's variant rows** (`progress.md` §4 — "zero affordance
   until Train ships"; Train ships the destination, so they light up now).
6. **"Why this?"** (§8) — the model's plan logic, a sheet over the leaf.
7. **Calibration review** (§9) — the renegotiation / goal-review flow; Train hosts,
   Progress and Today link in.

**Motion laws of the tab** (inheriting `progress.md` §2's discipline wholesale —
a reference surface earns trust by being instantly *there*):

- **No bookend anywhere on Train.** All navigation is 150ms `transition-nav`,
  **fully assembled at frame 1** — no staggered day-row cascade, no on-scroll
  entrance fade, no first-visit ceremony. Scroll position and the open week persist
  across tab switches. The "today" marker and every day-row render **static — no
  pulse, no breathe** (the app-wide idle law, `live-loop.md` §9 / `post-workout.md`
  §3).
- **A plan never animates its own reshuffle, *including under the eye*.** This is
  the one genuine motion hazard on the tab, because Train's just-in-time generation
  (`splash-today.md` pre-generation policy) can complete *while the lifter is
  looking*. Three triggers: a skeleton day the model finishes placing while its
  preview is open; a post-session back-off that regenerates the upcoming week
  (`post-workout.md` §8 render-after-verify landing on a Train surface); a
  renegotiation commit the lifter triggers *from* Train (§9). In every case the
  affected day/week/preview **hard-swaps to the assembled new state via a ≤150ms
  crossfade — never a skeleton-grows-numbers tween, never a row cascade, never a
  ratchet or flourish.** The ink↔pencil generation boundary (§3) never animates: a
  generating day swaps pencil→ink assembled, with no per-row "inking-in."
- **Geometry tweening is banned** on plan changes, exactly as `progress.md` §2 bans
  it for the ledger — a rescheduled day does not slide to its new slot; the plan
  re-renders assembled. A user-initiated edit (§5) is just a user-triggered
  regeneration and obeys the same law.
- **Cross-tab transitions are workhorse, and the crossing tab owns the push.**
  Day-preview → the session record (Progress's surface) and the leaf's
  band-link-up → Progress pattern detail are plain `transition-nav` pushes — **no
  shared-element morph** (the leaf→band morph would rotate a data axis 90°, banned
  for the same reason `progress.md` §2 bans the strip→chart morph). **The
  witness-rule seam:** a session record reached from Train still honors
  `post-workout.md` §7 in full — a never-witnessed ratchet flourish fires once
  there, by contract (Train, like Progress, renders fossils and never plays them).
- **The reasoning sheet is workhorse, not theater.** It renders its line
  **assembled, frame 1** — AI line and deterministic fallback visually identical
  (`post-workout.md` §5's no-visual-difference law), **no typed-on, no fade-in, no
  shimmer.** Train does **not** inherit the post-workout read's bookend reveal; the
  *only* "why"-class line that gets a reveal is the post-workout read, because it
  rides a bookend (§8).
- **The library is silent.** List and filter render assembled; **filter application
  is a hard re-render / crossfade — no staggered re-sort, no "N results"
  count-up.** Haptics: Train, like routine nav, is silent — it mints no new haptic
  and steals none (`.medium` is the plate-thud, `.rigid` the ratchet pawl, both
  spoken for, `DESIGN.md` Haptics).

---

## 3. The program root — the plan, drawn as a spine

The forward plan rendered as **a measured vertical day-spine** — Train's analog of
Progress's floor spine. The left edge **is the time datum**; days hang off it down
the page; the **generation horizon is a marked position on that spine.** This is
the lock's central move: the program root is a *drawn instrument*, not a card list
(the Centr/Gymshark furniture), because Train's one novel problem deserves its own
drawing.

**The core problem: the plan is provisional, and the further out you look the less
the app actually knows.** Generation is **Option 4 — skeleton + per-week + per-set**
(locked; memory `project_program_generation_granularity`). The *skeleton* (pattern
/ focus per day) exists far out; the actual *prescriptions* are generated
per-week, per-set, close to the day. A calendar rendering "Week 4 · Day 3 · Squat
120 × 5" four weeks early **fabricates precision the model has not computed** — the
Train analog of the no-slope law.

**The generation horizon — a drawn datum, not a colour swap.** (The draft's
fatal under-spec; the panel's loudest convergent P0.)

- Days the model has **generated** render in **full ink** with real prescriptions.
  Days still **skeleton** render in **pencil** (`ink-muted`) as *shape only* — the
  pattern and focus, never a number ("Lower — squat focus · numbers placed closer
  to the day").
- Between them runs an **explicit horizon datum** — a full-bleed drafting-rule
  hairline across the spine with a margin annotation in the drafting register
  ("PLACED ABOVE · SHAPE BELOW", or a dated label). Material alone (ink vs pencil)
  is insufficient: `ink-muted` is the same token that means *time/metadata*
  everywhere else, so a pencil row would read as "secondary detail," not "the model
  hasn't computed this." The datum line disambiguates.
- The skeleton zone carries the **dashed confidence vocabulary** (`DESIGN.md`
  data-viz / `ui-overhaul-spec.md` §8.2) — a "to-be-placed" drafting hatch — so
  "the model is guessing here" reads *identically* to how it reads on the Progress
  chart. One confidence vocabulary across screens.
- **Granularity is per-day, not per-week.** The horizon routinely falls *inside*
  the current week: today + the next day or two are placed (ink), the back half of
  the same week is still skeleton (pencil). A half-generated day is honest about
  it (§4).
- **How far out:** the **whole mesocycle skeleton** shows — the arc of the block is
  the committed lifter's reason to open the tab — but compressed: this week and
  next week at row detail, everything beyond collapsed to one pattern-per-day
  pencil glyph per day. A **commitment gradient** (weight / compression increasing
  with distance) reinforces diminishing knowledge. *(This gradient is honest: the
  §8.2 ban on opacity gradients applies to *confidence signals on the e1RM chart*,
  where a gradient would imply a continuous signal; a compression gradient on
  *calendar furniture* is a different object — flagged so it is not misread as a
  violation.)*

**Composition (top to bottom):**

- **Position lockup** (on the top rule): "Week 2 of 6" + the cycle's name/intent if
  it has one ("Strength block"), in the evidence-lockup grammar (`splash-today.md`):
  work numbers ink, "of 6" pencil. The pliability program-summary card is the
  reference form, minus its "weeks completed" bar.
- **This week, in full** — the week's days down the spine, each a row: pattern /
  focus, the session's exercises in brief, and **rest days as first-class nodes on
  the spine** (the Gymshark/Centr rest-as-node; the honest-rest material of
  `splash-today.md`'s rest state — a recessed `well` node stating what recovery
  buys, never a gap or a grayed cell). Today's day carries a **quiet static "today"
  marker** (the one tie to the Today tab).
- **The horizon, compressed** — the remaining weeks below the datum, skeleton shape
  only, on the commitment gradient.

**Day status renders in the app's own tick vocabulary — never a check, ring, or
percentage.** (The panel's positive render for "completed = fact, never graded";
without it, an implementer reaches for a green check and the adherence trap is
back.) Reusing the filled/hollow tick system of `live-loop.md` §3 and
`post-workout.md` §9: **a done day = a filled tick** (a logged fact — no count, no
ring); **a future generated day = a hollow tick**; **a skeleton day = a tick not
yet drawn** (the to-be-placed hatch). The block's progress is read from the
skeleton-shape compression down the spine, **never an "N/84" totalizer.**

**What Train's calendar must never become.** The nav law hands Train the calendar
Progress deliberately *cut* (`progress.md` §3 "no calendar, no streaks"). The cut
was against **adherence theater**. Train holds a calendar for a different job — the
plan's structure — and must not import the trap: **no streak flame, no completion
ring as a score, no "0 of 3 sessions complete," no shame for a missed day**
(Peloton calendar-adherence theater, Hevy's streak flame, Apple's completion dots,
Equinox's session counter, pliability's "0 of 2" bar — all banned by name). A
completed day is a logged fact; a missed day is just a day the plan moved past.

---

## 4. The day preview — a session before it's *now*

Tap any day → the session for that day. The look-ahead / look-back the live loop
can't give (the loop is strictly *now*, one set at a time).

- **A generated future day:** the full prescription — exercises, sets × reps,
  target loads **pre-snapped to gym-loadable** (`live-loop.md`), in the
  work-is-ink grammar. **Rendered at the reduced/preview lockup scale**
  (`live-loop.md`'s one-lockup-three-scales — the ~22pt preview cut, *not* the 64pt
  loop hero), so it is unmistakably a *look-ahead*, never a paused or broken loop:
  no Done slab, no logging, no rest timer.
- **A skeleton future day:** the shape only — "Lower · squat focus · ~5 exercises ·
  numbers placed closer to the day." Honest about being unplaced. No fake loads.
- **A partially-generated day** (the per-day horizon, §3): some exercises placed
  (ink), some shape-only (pencil) — the same day-row honestly half-drawn.
- **A past day:** marked done (filled tick); tapping it crosses to **the session
  record** — **Progress's surface** (`progress.md` §2.3, the post-workout screen in
  history form), a plain `transition-nav` push that honors the witness-rule seam
  (§2). Train owns the plan; the *evidence* of a completed session is Progress.
- **Per-exercise entry:** each exercise row taps through to the exercise leaf (§7)
  — the same leaf the library and the loop reach.

---

## 5. Plan agency — editing a plan the model owns

(The draft's biggest hole; the panel's strongest convergent P0. The decisive
argument, UX's: the live loop already ships per-set **swap**, **jump**, and
**add** (`live-loop.md` §5–§6) — so the app lets a lifter change the plan *mid-set,
fatigued*, but the draft gave them no way to change a day *they can calmly see is
impossible*. Agency at the hardest moment and none at the easiest is indefensible.
And **"I can't train today" had no home anywhere** — Today starts *now*, the loop
runs a *running* session, post-workout closes a *finished* one; only Train sees the
future. It is structurally Train's job.)

**Level (b): light edits the model absorbs — surfaced as constrained affordances,
never a free-form editor.** Two edits ship:

1. **Reschedule a day / "can't train today."** Move or skip a day; the plan
   re-flows. Crucially, this is **honest about its model consequence**: a
   rescheduled day is "moved to Thursday — the model planned for this," **not** the
   gap-return path's pessimistic "it's been 10 days" (`splash-today.md` /
   `post-workout.md` audit-F8). The line between a rescheduled day and a missed day
   is the line between agency and abandonment — the app must keep it.
2. **Swap a variant within its pattern** (front ↔ back squat). This **reuses the
   loop's swap surface** (`live-loop.md` §5 — ranked pattern-equivalents scoped to
   the gym, no AI, offline), now on a day-preview's exercise row. Pattern intent is
   preserved, so the **band is unaffected** (variants feed one band).

**Full manual override (c) is rejected** — on a hard provenance ground shared by
every lens: an off-model, hand-authored day has **no prescription source.** Every
load in the app derives from the band; a hand-keyed prescription would render
numbers with no honest provenance and break the ink/pencil law. A movement the plan
doesn't want is a **renegotiation** (§9), not a free edit.

**Edits render as provenance, never silent rewrite.** Reusing the post-workout
amendment vocabulary (`post-workout.md` §8): a swapped variant or rescheduled day
shows the original **struck in pencil**, the new in **ink**, with an `AMENDED` /
`EDITED` tag from the tag family. No new edit chrome is invented; the commit is an
assembled re-render (§2 — never an animated reshuffle).

*(Deferred, not cut: an Equinox-style "add to calendar" export of scheduled
sessions — a real convenience for lifters who plan around life. Noted as a
candidate; out of v1 scope, no surface specced.)*

---

## 6. The exercise library — the lexicon

Browse, search, filter. A reference, not a catalog to shop — and its scope is
**already forced by the live loop**, which ships the swap/add picker
(`live-loop.md` §5): "every pattern-equivalent the gym supports," addable, scoped
to the gym profile. The library *is* that picker surfaced as a reference.

- **Scope — resolved.** Default browse = **your program's movements + the
  gym-loadable set**; **search reaches the full, pattern-organized set.** Anything
  your gym can't load is **visibly un-loadable** (honest, not hidden — Bevel's "All
  equipment" listing un-owned machines is the negative proof). The two tiers are
  **visually distinct**: program / logged movements carry the ownership cue; the
  searchable remainder is plain.
- **Organizing principle: by pattern/movement** — a pattern → variant tree under
  **tag-caps pattern headers** (`DESIGN.md` tags), echoing Progress's taxonomy and
  the per-movement principle (the Tonal "Browse 310+ moves" take, `progress.md`
  §10). The library's spine matches the band's: a variant *feeds a pattern*, and
  the library says so. This typographic structure is what lets the lexicon
  **out-draw** the anonymous Tonal/Bevel thumbnail-list, rather than match it.
- **Honest, gym-scoped filters** — by muscle group (a plain checklist, Bevel's
  form) and by **equipment scoped to your gym profile** (the same profile that
  drives the loop's loadability snap and plate math). The honesty differentiator is
  that the list shows what you can *actually* load. **No interactive muscle
  body-map filter** (Peloton's) — the plain checklist, not the banned area-encoding
  (§7, §12).
- **The ownership cue is drawn, not asserted** — a logged exercise carries the
  **band-relative micro-mark** (§7) / a real last-load annotation; an unlogged one
  is plain. **Never a fabricated "0 sessions" or "—"** dressed as data (the absence
  is the honest signal; `ui-overhaul-spec.md` §8.2).
- **No user-authored custom exercises in v1.** An off-model movement has no band,
  no prescription source, no reasoning home — the same provenance gap that kills
  full plan-override (§5). The loop's session-scoped **bolt-on** (`live-loop.md` §5
  — logged as *added*, no reasoning) is the only custom channel, and it is
  session-scoped by design. A missing movement is a **gap-report**, not a
  library-authoring entry. Bevel's top-of-list "Add custom exercise" and Tonal's
  separate "Custom" nav tab are the affordances to *not* copy.

---

## 7. Exercise detail — the leaf, built from instruments we already own

The single most reuse-heavy screen in Train: it redraws **nothing**, and it is
**one vertical scroll, not tabs.** Hevy's Summary / History / How-to /
**Leaderboard** segmented leaf is the `progress.md` g01–g04 metric-democracy
anti-pattern reborn at the exercise grain (peer metric tabs over an identical
skeleton); ours is one scroll with **one metric** (the e1RM — no "Heaviest Weight /
One Rep Max / Best Set" toggle).

**Anatomy (top to bottom):**

- **How-to** — a demonstration (illustration / loop), the movement's **primary and
  secondary muscles as named-muscle text rows** in the tag-caps register (Equinox's
  `EQUIPMENT / TARGET MUSCLE / COORDINATION`), and terse execution cues. At most a
  **single static honest muscle highlight** on the demo figure (Hevy's quads-in-red
  is honest); **no interactive muscle heatmap / 3D body model** (Equinox's, Tempo's)
  — that is the banned area-encoding (`progress.md` §9.5 muscle-radar ban,
  `post-workout.md` §11 "we model patterns, not pecs") in a how-to costume. No
  "Read More" truncation theater — cues are terse by default.
- **Your history with this exercise** — the **per-session set log** in the
  anchor-grammar rows of `post-workout.md` §9 (Hevy's "Day 6 · 20 × 10 · 65 × 8 ·
  95 × 5 (1RM) · 100 × 3" is the data shape; ours renders it in our grammar:
  work-is-ink / time-is-pencil, PR sets carrying the **inverted ink PR stamp**, not
  a trophy emoji). The History-tab set log is the one Hevy keeper, re-rendered.
- **No chart at the leaf.** (The killed "if shown" hedge — the seam through which
  Hevy's banned slope returned.) An exercise-scale staircase would be a **fourth**
  context of an instrument that is *one component, three contexts* (`DESIGN.md`
  data-viz / `post-workout.md` §6) and would re-fragment the one-rounding-one-floor
  discipline `progress.md` §8 fought for. The leaf does **not** plot e1RM-over-time.
- **The band-link-up — a drawn micro-mark, not a hyperlink.** The "is my deadlift
  moving?" demand is answered *here*, at a glance, without a chart: the leaf renders
  the **sanctioned list-scale band reduction** (`progress.md` §3 / `DESIGN.md`
  data-viz — the floor tick + *this exercise's* last-observation dot relative to the
  pattern's band) with the pattern's **current floor inline**, captioned "Feeds
  your **Squat** band — floor 105 →". Tapping it pushes to Progress pattern detail
  (plain `transition-nav`, **no shared-element morph**, §2). This honors
  one-component-three-contexts (the leaf shows a *reduction*, not a fourth full
  band), closes the reciprocal with `progress.md` §4's now-live variant rows
  (Progress points down, the leaf points up), and makes the up-link a visual
  continuation of the spine rather than a dead-end pointer.
- **"Why this?"** (§8) — the affordance is **present consistently** on the leaf,
  not gated into existence by entry (an identical-looking leaf that sometimes has
  reasoning and sometimes doesn't is the dead-path trap `post-workout.md` §9
  warned against). For a movement **not currently in your program** (a pure library
  browse), the sheet honestly says it has no program-specific reasoning rather than
  vanishing. The **back destination follows the entry** (library → back to library;
  loop "Why this?" → back to the live set; Progress variant row → back to pattern
  detail).

**Banned by name on this surface** (every one shipped in the §13 Hevy frames):

- **Percentile rank** — "You are stronger than 48% of male lifters your age and
  bodyweight." A demographics toll (0/3 sex/age/weight) bought to rank you against
  strangers. We compare you only to you (`progress.md` §10 All-time-staircase). Cut.
- **The Beginner → Intermediate → Advanced → Elite ladder.** A global ladder is the
  antithesis of a per-user band; the band *is* our level. Cut.
- **False precision** — "Best 1RM 106.74 kg." e1RM is an estimate; one rounding rule
  (`progress.md` §8), and estimates look estimated.
- **The metric toggle and the Leaderboard tab** (Hevy) — metric democracy and
  social ranking on a tool for committed self-competitors. Cut.

---

## 8. "Why this?" — the model's reasoning, made legible

The loop's "Why this?" (`live-loop.md` §3) is the product's **core trust
transaction** — it "converts the prescription from an oracle's command into a
checkable claim." Train shows that claim in full. This is Train's *visibly smart*
centerpiece — and its smartness is **content, never motion** (§2: the line renders
assembled, no typed-on reveal).

**Content law** (the post-workout read-content law, §5 there, ported):

- **Grounded** — every line cites ≥1 concrete number the user can verify
  (`ui-overhaul-spec.md` §8.3): "Front squat this block — your back-squat floor
  ratcheted twice, so we're loading the position that's been lagging."
- **Names the actual reason** — progression logic, band position, recovery,
  calibration need, renegotiation — in plain words, terse over flattering. A
  generic reason ("this builds strength") is suppressed; absent beats generic.
- **Deterministic fallback** (`ui-overhaul-spec.md` §8.3): when the AI line is
  slow / unavailable / fails validation, a rule-based read from program + model
  state ("Scheduled for week 2 of your squat block; last squat session cleared its
  band"). Rule-based ships first; AI line and fallback are **visually identical**
  (`post-workout.md` §5).
- **A sheet, not a screen** — it stays small (`splash-today.md` Lens-sheet
  discipline: the deep view doesn't creep in). It answers "why this?" and stops.

**One "why" register, three scales** (the §14 Q7 resolution): Today's coach line
(`splash-today.md` §2 — the one-sentence glance), the Lens sheet's source
disclosure, the post-workout read (the bookend), and Train's reasoning sheet are
**one voice at different depths**, not four bots. All obey one content law; they
differ only in scale (Today = a glance, the sheets = reference depth, the read =
the bookend). All render assembled **except** the post-workout read, which alone
gets a reveal because it rides a bookend.

---

## 9. Calibration review — Train's, because re-calibration changes the program

(Named build debt from `progress.md` §4/§12 and #269/#305, with **no owner** — and
the chain was already dangling: `splash-today.md`'s alert rows point at a
calibration-review surface under a no-dead-pointers law, and Progress's provenance
sheet explicitly disclaims ownership — "Progress is its entry, not its owner." If
Train only *linked*, the redesign would have no home and the no-dead-pointers law
would break on ship.)

**Train hosts the review / renegotiation / goal-review flow.** The decisive
argument, convergent across the product/UI/visual lenses: a re-calibration *changes
the program*, and the program is Train's domain (§1 nav law). Train is the only tab
whose subject **is** the thing re-calibration mutates. So:

- **Train hosts** the flow and its commit semantics; **Progress's provenance sheet
  and Today's alert rows link in.** This retires the build debt rather than
  relocating it, and keeps every pointer landing on a live surface instead of an
  old-app screen.
- **Rendered in the amendment / provenance vocabulary** (§5 / `post-workout.md`
  §8) — a re-domained band, a raised floor, a changed goal shows struck-not-erased,
  with the source named.
- **The commit is plain, not a celebration.** Hosting the *flow* does not make Train
  expressive: a renegotiation commit the lifter watches resolves as an **assembled
  re-render of the plan — crossfade, no reshuffle tween, no flourish** (§2's
  regeneration-under-the-eye rule). Re-calibration is **not a milestone**; Train
  plays no ratchet (the milestone quarantine, inherited from `progress.md` §2 — any
  celebration that is owed fires in the loop or the post-workout reveal, never
  here).

*(Recorded dissent — motion lens: preferred Progress/Today **linking out** to an
off-Train review so the commit-and-reshuffle never happens on a surface under the
eye. Overruled on IA grounds — the dangling-pointer / no-owner problem is decisive,
and the motion concern is fully met by the assembled-hard-swap commit rule above,
which the host must obey regardless.)*

---

## 10. States

| State | Treatment |
|---|---|
| **Generated week** | The §3 layout; this week in full ink, ticks per day status. |
| **Skeleton horizon** | Future weeks in pencil shape below the horizon datum — pattern/focus, no numbers, on the commitment gradient (§3). |
| **Partially-generated day** | Some exercises placed (ink), some shape-only (pencil) — the per-day horizon honestly half-drawn (§4). |
| **Generation pending** | A week/day the model is placing renders the `splash-today.md` honest-checklist register, never a bare spinner; it **hard-swaps pencil→ink assembled** when ready — no inking-in, even under the eye (§2). |
| **No program yet** | Pre-onboarding handoff or fresh install — exactly one working CTA, **named per state** (no unnamed "do something", `splash-today.md` law). The library is still browsable (a lexicon needs no program). |
| **Program complete** | The retention handoff, not a shrug (mirrors `splash-today.md`): the cycle recap + "Start your next program" as the primary CTA. |
| **Returning after a gap** | If the plan verifiably regenerated post-gap, Train shows the new shape **assembled**; it never claims an adjustment that didn't run (audit-F8). The reschedule path (§5) is the honest alternative to a gap. |
| **Exercise never performed** | The leaf shows how-to + an **honest empty history** ("No sets logged yet") — never a fabricated zero-state, never an empty labeled slot (the Tempo "Baseline reps —" / Gymshark "No Data Available"-under-a-full-frame fabricated-instrument tell). |
| **Library search — no results** | A plain empty state, one affordance (clear filters); no fake rows. |
| **Degraded (model/coach offline)** | The plan renders from local program data; the library browses from local data; the **reasoning sheet collapses** (no fabricated why). Train never blocks browsing on a network call. |
| **Dynamic Type / AX** | Day-row sheds in order (tick → pattern/focus → exercise-brief); the position lockup wraps without truncating numbers; the library row (pattern · variant · equipment · ownership cue) sheds the equipment subtitle before the name. Buttons size to label; 44pt minimum. |
| **VoiceOver** | Order stated per surface: program root (position lockup → this-week days in spine order, each announcing status + the horizon datum as a landmark → compressed horizon), day preview, leaf (how-to → set log → band-link-up), library (pattern headers as a rotor category). The **calendar is an a11y list with the week as a rotor step**, not a silent grid. |
| **Dim variant** | The full §3 ink/pencil + tick system remaps via `colors-dim`; **verify the generated/skeleton contrast delta holds** (`ink-muted #9B9DA6` on near-black is the at-risk pair). |
| **Reduce Motion** | Inherited: every (already-minimal) transition is a 150ms crossfade; the hard-swaps are unaffected; haptics — none to keep. |
| **Library rendering** | A pattern-organized list of the full movement set obeys the Progress §8 criterion: assembled, **zero per-frame allocation on scroll**, no entrance theater. |

---

## 11. Honesty rules (this screen's `ui-overhaul-spec.md` §8 extensions)

1. **The diminishing-knowledge law.** The further out a day, the less the app
   renders: generated days are ink with numbers, skeleton days are pencil shape
   only, separated by a **drawn horizon datum**. Never a fabricated future load.
   (The calendar's no-slope law.)
2. **The plan is pencil, work is ink.** A scheduled prescription is pencil until
   logged; only logged work is ink (`DESIGN.md` plan-is-pencil, extended from the
   live card to the whole calendar and the per-exercise log).
3. **You are compared only to you.** No percentile, no global strength ladder — a
   per-user band is the only level the app recognizes.
4. **The calendar is a plan, not a report card.** No streaks, no adherence grading,
   no completion counter; done = a filled-tick fact, missed = a day the plan moved
   past, rescheduled = a planned move (§5), never the gap path's pessimism.
5. **Absence is named, never an empty slot.** Skeleton and empty states state what
   isn't there; they never render a labeled instrument (axes, "Baseline —") for
   data that doesn't exist.
6. **The reasoning is grounded or absent.** Every "why this?" line cites a real
   number and has a deterministic fallback; a generic reason is suppressed.

---

## 12. Explicitly cut

- **Streak flame / adherence calendar grid / completion-ring-or-counter-as-score**
  (Peloton, Hevy report, Apple dots, Equinox "0 of 3", pliability "0 of 2") —
  adherence theater.
- **Percentile rank and the Beginner→Elite ladder** (Hevy strength level) — global
  comparison; we have bands.
- **False-precision e1RM** (106.74) — one rounding rule.
- **The exercise metric toggle and Leaderboard tab** (Hevy) — metric democracy and
  social ranking.
- **The segmented exercise leaf** (Hevy's four tabs) — the leaf is one scroll.
- **A per-exercise trend chart** — the leaf points up to the pattern band via a
  drawn micro-mark; no fourth staircase, no sloped line.
- **Interactive muscle heatmaps / 3D body models / muscle-impact maps** (Equinox,
  Peloton filter, Tempo) — banned area-encoding; named-muscle text rows + one
  static highlight only.
- **Fabricated future loads / empty labeled slots** — skeleton names absence.
- **Vanity plan-progress totalizers** (Tempo Volume / Calories / Intensity-min) — a
  self-computable scoreboard isn't the read; the reasoning is.
- **User-authored custom exercises** (Bevel "Add custom exercise", Tonal "Custom"
  tab) — off-model movements have no reasoning home.
- **Share-as-primary.**

---

## 13. Mobbin references (verified frames, `tmp/refs6/`)

*Every frame below was downloaded and Read; the short-codes did not map
positionally to the file labels, so each is cited by its verified content.*

- **Hevy exercise detail (the anti-pattern motherlode)** — Summary / History /
  How-to / **Leaderboard** tabs (the metric-democracy leaf we reject for one
  scroll). The **Summary chart** is the banned slope shipped on the exercise
  surface: a polyline holding flat Jul 28→Aug 15, diving a **straight diagonal** to
  an Aug 18 light day and straight back up to Aug 19, with an **auto-fit y-domain**
  (80–100 kg) turning a ~27 kg swing into a full-height V — exactly `progress.md`
  §5's outlawed shape, on a per-exercise screen, behind a metric toggle. The
  **Strength Level** block: "Best 1RM **106.74 kg**" (false precision), a
  Beginner→Intermediate→Advanced→Elite bar, "**You are stronger than 48% of male
  lifters your age and bodyweight**" behind a 0/3 sex-age-weight toll, and a
  right-aligned PR table. The **History** tab is the one keeper: a clean per-session
  set log ("Day 6 · 19 Aug · 20 × 10 · 65 × 8 · 95 × 5 🏆1RM · 100 × 3 🏆Weight") —
  the data shape our per-exercise history takes (anchor grammar, ink PR stamp
  replacing the trophy). Empty states are honest ("No data yet", "No exercise
  history", "0/3 add your sex, age and weight").
  [flow](https://mobbin.com/flows/c2621492-cd68-4948-b2dc-07435ee63203)
- **Equinox+ movement library + detail** — movement detail (1-Arm Battle Rope
  Wave): a video still, instruction text with "Read More", and metadata rows
  `EQUIPMENT / TARGET MUSCLE / COORDINATION` in tracked caps (the how-to metadata
  register we adopt); plus a 3D body model with a muscle-activation **heatmap (the
  banned area-encoding — we take the text rows, leave the heatmap)**.
  [flow](https://mobbin.com/flows/cdad1c34-cc9b-477d-8f0e-4f30a4cbdb44)
- **Tonal "Browse 310+ moves"** — the library as an alphabetical, thumbnailed index
  with a single FILTER pill; a separate **"Custom" nav tab** segregates custom moves
  (the fourth-surface answer we reject). Validates lexicon-not-feed; register
  "competent and anonymous" (the `progress.md` Tonal take — identity must come from
  our drawn rows, not thumbnails).
  [flow](https://mobbin.com/flows/e4b5365a-4cab-4d71-be87-3c87080c57a2)
- **Bevel library + muscle filter** — Search, "All groups / All equipment" chips,
  **"Add custom exercise"** (the affordance we do not copy), an alphabetical list
  with equipment subtitles and info/add affordances; the muscle filter is a plain
  checklist ("Filter by 3 muscles") — the clean baseline for our honest,
  gym-profile-scoped filter. Note it is a *picker* (Cancel/Add): its "+" is
  add-to-workout, meaningful only inside the loop's bolt-on, not the reference
  library.
  [flow](https://mobbin.com/flows/65348c72-c301-4283-b3eb-f70d26de1ef1)
- **Peloton Strength+ filtering** — exercise picker with video thumbnails +
  checkboxes; "Select muscles" by body region; a Filters sheet with a target-muscle
  **body map (rejected for the plain checklist)**.
  [flow](https://mobbin.com/flows/c8f9a5e8-384a-4468-9528-4e87bcd97c24)
- **Gymshark plan detail** — Explore (Featured / Workouts / **Plans**), a plan
  overview (7-Day · Beginner · Overview · Created-by · Schedule), and a **day list
  on a vertical timeline with REST DAY as a first-class node**. The rest-as-node
  treatment is the keeper; a fixed content product (no per-user model) is exactly
  what ours is not (drawn rows, not photo-thumbnails).
  [flow](https://mobbin.com/flows/8011d193-dd8f-4bc6-be94-f76173dba3f4)
- **Centr program timeline** — a Power-Shred program as a **vertical day-timeline
  with circular spine nodes**: "Day 1 Lower-body fire up · 35 min · Bench ·
  Dumbbells", an **"Optional" tag** on Day 3, a numbered 1–5 week stepper, "0 / 84"
  progress (the totalizer we cut). The timeline-as-spine and the per-day equipment
  line are the references; we draw the spine in our tick register, not photo-nodes,
  and lead the row with pattern/focus, not duration.
  [flow](https://mobbin.com/flows/e55c8859-c850-46f8-8c5f-d6886a44c207)
- **Apple Fitness plan calendar** — "Jane's Plan · Week 1 of 3", a M–S week strip
  with completion dots + a today ring (the **streak-invitation trap**: the dotted
  strip renders even above the honest "No Activities Scheduled" empty day — proof
  the week-strip primitive smuggles adherence-reading in structurally, the concrete
  evidence for choosing the vertical spine). The honest empty-day copy is the keeper.
  [flow](https://mobbin.com/flows/87b52387-6fc2-4d4b-9fad-757e3d7939d9)
- **pliability program overview** — "This Week / Week 1 / 2 weeks to go" + a
  "Program Overview" card (weeks · avg length · days/week · focus areas) — the
  summary-card form for the position lockup, minus its "Weeks completed 0 of 2" bar.
  [flow](https://mobbin.com/flows/854e97ba-2e04-4bb7-8d0d-71f2a90094aa)
- **Equinox+ program (ongoing)** — "View my program / Program History"; "Required
  Sessions" with per-session "Recommended for {date}", an **"Add to Cal"** affordance
  (the deferred calendar-export candidate, §5), and "Week 1 of 4 · 0 of 3 sessions
  complete" (the adherence counter we cut).
  [flow](https://mobbin.com/flows/3acc708f-6c77-4837-8733-87024b75bb2d)
- **Tempo plan progress** — a "Muscle impact" body map + Volume / Calories /
  Intensity-min totalizers + "Leave plan / Find a new plan"; and a "Baseline reps
  **—** / Target reps **—**" placeholder (the **fabricated-instrument tell** — a
  labeled slot for data that doesn't exist). The totalizers and body map are the
  named cuts; "Leave plan / Find a new plan" is a real program-level agency
  affordance the program-complete state (§10) honors.
  [flow](https://mobbin.com/flows/41393525-bb97-4f7a-9bb2-99541c52c179)

---

## 14. The open questions, resolved

1. **Plan agency: level (b), staked — not deferred.** Read-only contradicts the
   loop (which already ships mid-set swap/jump/add); full override breaks
   provenance. Train ships **reschedule-a-day / "can't train today"** and **swap a
   variant within its pattern** (reusing the loop's swap surface), model-absorbed,
   rendered as `AMENDED` provenance, with the honest reschedule-vs-gap distinction
   (§5). Unanimous on (b); UX carried the "agency at the hard moment, none at the
   easy one is indefensible" argument.
2. **Program-root form: the vertical day-spine,** drawn as a measured instrument
   (time axis = left datum, horizon = a position on it), not a card list. The
   week-strip is rejected on hard evidence — its dotted days render even above an
   honest empty day, so it smuggles streak-reading in structurally (Apple frame);
   the grid *is* the adherence form. (Unanimous; visual upgraded "pick the timeline"
   to "draw it as a spine.")
3. **The generation horizon: a drawn datum line + a "to-be-placed" hatch in the
   dashed confidence vocabulary** — material (ink/pencil) alone collides with the
   time-is-pencil semantic and is invisible at a glance. Per-day granularity (the
   horizon falls inside the week); the whole mesocycle skeleton shows but compressed
   on a commitment gradient; the boundary **never animates** (§3, §2). (Convergent
   P0 across all four.)
4. **The leaf draws no band — it points up,** and the pointer is a **drawn
   band-relative micro-mark** (floor tick + this exercise's last-observation dot +
   inline floor), not prose. This keeps one-component-three-contexts intact, answers
   "is it moving?" at a glance without a fourth chart, and closes the reciprocal
   with `progress.md` §4's now-live variant rows (§7). (Confirmed; visual + UX
   upgraded the pointer from a hyperlink to a drawing.)
5. **Library scope: your program + the gym-loadable set by default, full
   pattern-organized search behind it, two visual tiers; no user-authored custom
   exercises.** Forced by the loop, which already committed the gym-scoped picker
   and the session-scoped bolt-on as the only custom channel. Un-loadable items show
   honestly; a missing movement is a gap-report (§6). (Unanimous; the loop forced
   it — resolve, don't re-ask.)
6. **The calibration-review surface: Train hosts it.** Re-calibration changes the
   program, Train owns the program, and the pointer chain (Today alerts, Progress
   provenance sheet) was already dangling with no owner — so hosting here retires
   the build debt and keeps the no-dead-pointers law (§9). Progress and Today link
   in. (3 lenses host; motion's link-not-host dissent overruled on IA grounds, its
   concern met by the assembled-commit rule.)
7. **One "why" register, three scales.** Today's coach line, the Lens sheet, the
   post-workout read, and Train's reasoning sheet are one grounded voice at
   different depths — same content law, divergent depth only; all render assembled
   except the post-workout read, which alone rides a bookend (§8). (All four took it;
   motion sharpened it to "non-animated everywhere except the bookend.")

---

## 15. Review record (2026-06-11, four agents)

Panel: UI-craft, UX/product, visual/art-direction, motion/animation. Headline:
*the draft had "the right epistemics wearing no instrument" — its diminishing-
knowledge thesis was a colour swap, not a drawn structure (visual); it deferred
plan agency the live loop had already forced (UX: agency exists mid-set but not at
the calm planning moment); the "if shown" trend chart was the one seam through
which Hevy's banned slope returned to the exercise surface (all four); and the
calibration-review pointer chain was dangling with no owner before Train claimed it
(UX/UI/visual).*

| # | Finding (agent) | Disposition |
|---|---|---|
| P0 | The generation horizon must be a **drawn datum** (rule + hatch + dashed confidence vocabulary), per-day, not a lone ink/pencil shift; whole mesocycle compressed on a commitment gradient (all four convergent) | **Accepted** — §3, §11.1. |
| P0 | The program root is a **measured vertical day-spine** (time = left datum, horizon = a position on it), not a card list; week-strip/grid rejected on the streak-structure evidence (visual lead; UX/motion concur) | **Accepted** — §3, §14.2. |
| P0 | **Stake plan agency at level (b)** — reschedule/"can't train today" + swap-variant-within-pattern via the loop's swap surface; full override rejected on provenance; render as `AMENDED` (UX lead; visual's provenance vocabulary; UI's loop-reuse) | **Accepted** — §5, §14.1. |
| P0 | **Train hosts the calibration-review surface** — the dangling pointer chain + no owner is decisive; Progress/Today link in (UX/UI/visual) | **Accepted** — §9. *Motion's link-not-host dissent recorded + overruled.* |
| P0 | **Kill the "if shown" leaf chart → no chart at the leaf;** route "is it moving?" up via a drawn band-relative micro-mark (all four; UI's one-fact-refragmentation + visual's drawn-pointer + UX's don't-cede-the-demand) | **Accepted** — §7, §14.4. |
| P0 | **Positive done-day render** in the filled/hollow/undrawn tick vocabulary — never a check/ring/counter; the anti-adherence ban needs a drawn replacement, not just a cut-list (UI + UX + visual convergent) | **Accepted** — §3, §11.4. |
| P0 | **Regeneration-under-the-eye:** a day/week re-resolving on screen hard-swaps assembled (≤150ms crossfade), never tweens/cascades/flourishes; ink↔pencil boundary never animates (motion lead) | **Accepted** — §2, §10. |
| P0 | **The reasoning line renders assembled** — no typed-on/fade-in; Train does not inherit the post-workout bookend reveal; AI line and fallback visually identical (motion) | **Accepted** — §2, §8. |
| P0 | **The leaf is one scroll, not Hevy's tabs;** one metric, no toggle (UI; motion's chart-draw-on concern mooted) | **Accepted** — §7, §12. |
| P1 | **Per-day horizon + a partially-generated day-preview state** (UI) | **Accepted** — §3, §4, §10. |
| P1 | **State-table parity** — Dynamic Type/AX shedding, VoiceOver per surface incl. the calendar as an a11y list + rotor week-step, Dim remap (verify generated/skeleton contrast), Reduce Motion, large-list rendering (UI) | **Accepted** — §10. |
| P1 | **Promote the library entry to a persistent full-width header search** (one of two declared halves, not a glyph) (UI) | **Accepted** — §2, §6. |
| P1 | **Entry-conditional back-stack, entry-independent "Why this?" affordance** — present consistently, content/back adapt by entry; resolves the dead-path trap (UI + UX reconciled) | **Accepted** — §7. |
| P1 | **Library scope resolved + no custom exercises** — gym-loadable default + full search, two visual tiers; the loop forced it (UX/UI/visual) | **Accepted** — §6, §14.5. |
| P1 | **Band-link-up as a drawn micro-mark with inline floor** (visual + UX over the prose pointer) | **Accepted** — §7, §14.4. |
| P1 | **Day preview at the reduced lockup scale,** not the 64pt loop hero — unmistakably a look-ahead (visual; motion's not-a-paused-loop concur) | **Accepted** — §4. |
| P1 | **Cross-tab witness-rule seam** — day-preview→record and leaf→band are `transition-nav`; a record reached from Train fires a never-witnessed flourish once, by contract; no shared-element morph (motion) | **Accepted** — §2, §4. |
| P1 | **Library filter = hard re-render,** no staggered re-sort / count-up; list + today-marker static (motion) | **Accepted** — §2. |
| P2 | **Cut the muscle heatmap / body-map / muscle-impact encoding by name;** named-muscle text rows + one static highlight only (visual; UI's false-granularity concur) | **Accepted** — §7, §12. |
| P2 | **One "why" register, three scales** (all four) | **Accepted** — §8, §14.7. |
| P2 | **Name absence, never an empty labeled slot** (Tempo "Baseline —" / Gymshark fabricated-frame tell) (visual catch) | **Accepted** — §10, §11.5. |

Cross-doc flags filed (grep-and-report, not edited here): **`post-workout.md` §7
/ `progress.md` §2** — the witness-rule seam now has a *third* entry point (a
session record reached from a Train past-day preview); the "never-witnessed
flourish fires once, by contract" obligation should name Train alongside Progress
at next amendment. **`live-loop.md` §5** — Train's plan-edit swap (§5) reuses the
loop's swap surface; if that surface gains a planning-time entry, the two should
share one ranked-equivalents component. Named build debt **retired** here: the
#269/#305 calibration-review surface now has a home (§9) — the redesign of its
*internals* remains, but it is no longer ownerless. Still-open model-API
dependency (carried from `progress.md`): band-center history snapshots feed the
leaf's band-relative micro-mark (§7). Deferred, not cut: calendar export / "Add to
Cal" (§5).
