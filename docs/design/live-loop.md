# Live loop — design spec (the set screen)

**Status: locked 2026-06-11** after a four-agent review (UI craft / UX-product /
visual–art-direction / **motion-animation** — the motion lens added this round).
All accepted findings folded in; record and dispositions in §13. Companion docs:
`DESIGN.md` (tokens + motion canon), `ui-overhaul-spec.md` (locked behavior —
live loop is §4), `splash-today.md` (Start handoff, evidence lockup, tag/hairline
systems), flow-audit-2 (the shipped app's gym-floor traps, checked row by row).

## 1. Job

The calm half of the principle, at its most extreme. A lifter mid-session is
fatigued, chalky, and between efforts; the screen must answer three things in
under a second: **what am I doing, what's the target, where do I tap.** The
model's intelligence shows as *the numbers being right*, not as chrome. Per-set
feel capture is the differentiated data play of the whole product — and its
risk; everything in this spec protects signal quality on the working sets.

**Two system rules, established here:**

- **Work is ink, time is pencil.** All work numbers (prescription, ledger,
  preview) render in `ink`; all time digits (session clock, rest countdown)
  render in `ink-muted` — same Space Grotesk 700 tnum cut. The set↔rest morphs
  then read as one system with no choreography doing the explaining: ink
  settles into the record, a pencil number passes the time, at 0:00 the page
  returns to ink.
- **One lockup, three scales.** The evidence lockup (`splash-today.md`) is the
  loop's single typographic object: ledger rows ~15pt, next-set preview 22pt,
  the prescription hero 64pt+.

## 2. Entry — bookend #2

From Today's Start, two phases (one physics with the splash drain, inverted):

- **t −100→0ms:** Start's `log-settle` press — 2–3pt translate + accent→press
  color. No scale (a 56pt slab scaling reads cartoonish). **No haptic on
  Start** — `impact(.medium)` stays exclusive to set-logged; if Start thuds,
  the plate-thud means two things within thirty seconds.
- **t 0 (touch-up):** commit; Start disables. **The pressed slab melts into the
  rising edge** — overlap, never release-then-flood (a released button is a
  double-flash).
- **0–250ms:** ink climbs to full coverage — the ruling-pen edge inverted
  (~1.5° cant, zero wobble, 1px edge highlight). Today doesn't move; it is
  covered. Full ultramarine at ~250ms is the brand beat — no mark, no text.
- **250–650ms:** the ink falls back to the bottom of the world, revealing the
  set screen **in place, top-first** — position line readable ~380ms,
  **prescription readable ≤450ms (the real deadline** — it's what the lifter
  needs while walking to the rack**)**, Done revealed last ~620ms. The reveal
  order is the screen's reading order and its VoiceOver order. 8pt staggered
  settle as the edge passes.
- **≤700ms:** fully interactive; per-element input goes live as each element
  lands — never a whole-screen input lock.

Re-entry from a resumed/paused session: no bookend — 150ms crossfade to the
exact position. Reduce Motion: crossfade always.

## 3. The set screen

Top to bottom on paper. Hairlines are **static datum lines** — the top margin
rule and one rule above the Done slab only (gridding all zones fights
near-silence); content morphs *between* them, the rules never animate.

- **Margin row (on the top rule):** leading — the elapsed session clock,
  **minute-granularity** ("42 min", pencil register; one moving number per
  screen — the rest countdown is the only counting figure, and the clock
  excludes paused time). Trailing — pause control (`accent-ink`; exit lives in
  the pause menu) and the **plan-peek chip**: the tag-family drawn rectangle
  showing live progress ("12 / 24"), not a static word. Two 44pt targets.
- **Set-position ticks on the rule:** "set 2 of 5" drawn as five 4pt ticks at
  the left margin — filled for settled sets, hollow for remaining. The Today
  tick system becomes the loop's progress instrument.
- **Exercise line — glance tier 1:** exercise name in **SG 600 22pt** (the
  missing middle register; readable from the rack), "set 2 of 5" muted beside
  it, set-type tag when not a working set (`WARM-UP` muted / `AMRAP` full ink —
  a directive). Supersets: current exercise only ("A1 · Bench — round 2 of 4");
  the partner is named by the next-set preview, never crammed into this line.
- **The prescription — the hero lockup, micro-specced:**
  - Digits SG 700 tnum, auto-fit **72→56pt** against a named longest-legal
    string; if still over, two lines: weight as hero, "× reps" at ~34pt below.
    Numbers never truncate.
  - **×** is U+00D7 (never the letter x), weight 500, ~half cap-height,
    optically centered on the digits' median, `ink-muted`, thin-spaced — the
    × is connective tissue per the two-tone law.
  - Units at ~0.35× digit size, SG 500 (one voice — never Inter in the hero),
    baseline-aligned, muted, singular symbol ("lb", never "lbs"). Vertical
    metrics set for the kg descender. No trailing ".0" (false precision);
    decimal point kerned out of tabular width.
  - **Grammar:** dumbbells "2 × 22.5 kg"; bodyweight "BW × 8"; weighted BW
    "BW + 10 kg × 5"; timed holds "0:45 hold"; AMRAP "102.5 kg × 5+" when a
    rep floor exists, "× max" only when truly open (unit scale, full ink).
  - Low-confidence loads carry the hollow marker (continuity with Today).
- **Last-time anchor** beneath, `label` muted tnum: **"Last: 100 kg × 5 · 5 · 4"**
  — the moment-of-truth context (audit F6; Gymshark ships it). This converts
  the prescription from an oracle's command into a checkable claim — the core
  trust transaction of the product. Data is local (cached history).
- **Plate math — the dimension callout** (plate-loaded lifts only, auto-omitted
  otherwise): a short hairline with terminal ticks spanning the weight digit
  group, beneath it "BAR 20 · PER SIDE 20 · 5 · 1.25" in tnum 13pt muted — a
  measured-drawing annotation, not a text line. Computed from the gym profile
  and always in agreement with the loadability snap (below).
- **"Why this?"** — `accent-ink` text at `label` scale → exercise detail /
  history / the model's reasoning sheet. (Secondary interactive text in the
  loop is `accent-ink` per the States law; **the only accent *fill* is Done.**)
- **Done — the bottom of the world.** Not a floating button: a **full-bleed ink
  slab**, edge to edge, flat top with a 1px `accent-press` top rule, ~96pt
  total with the home-indicator zone inside it (label and effective tap zone
  sit above the indicator), "Done" in SG 600 ~22pt `on-accent`. The ink that
  flooded up from Start stays pooled at the bottom edge all session. Guards:
  touch-up-inside with small-movement tolerance (brushes don't fire),
  disabled-while-morphing (no double-logs), and every logged set is editable
  (§6) — generosity is cheap because mis-logs are correctable. **One tap =
  logged as prescribed.** `log-settle` (2–3pt translate + color, never scale) +
  `impact(.medium)` fired **at commit, not touch-down** — a thud for a
  dragged-off cancel would be fabrication in tactile form.
- **Adjust = tap the number.** The hero weight or rep figure morphs in place
  into a `− value +` row (≥56pt buttons, hold-to-repeat with acceleration; tap
  the value for keypad entry). Weight snaps to the gym's loadable increments.
  Done stays put and **logs whatever is displayed** (stated law). "Log
  different numbers" survives only as early-session discoverability copy.
  **Propagation:** after an adjusted set, ask once — "this set only / rest of
  exercise" — so the honest path never costs four round-trips (friction
  fabricates: by set 3 the lifter taps Done at 102.5 while lifting 100).
- **Pre-snap:** prescriptions snap to gym-loadable **before the hero renders**,
  with a quiet "adjusted to your plates" note when snapping moved the number
  (audit F8 — the unloadable 102.5 never renders at 64pt in a gym without
  1.25s).

## 4. After the tap — the rest morph (same card, no modal, no new screen)

All times from t=0 = Done commit. The morph begins at **commit+80ms** (the
thud lands on a still screen and belongs to the tap, not the motion);
perceived total ~430ms; the morph never blocks input.

1. **80–260ms:** the prescription compresses and **settles downward into the
   ledger row** (transform + opacity cross between text layers at ~170ms —
   never animate font size). Annotations (plate callout, last-time, Why this?)
   fade 80–200ms. **The Done slab sinks with the work it logged** (80–230ms) —
   the button you pressed joins the record.
2. **160–380ms:** the **rest countdown rises as the temporary hero** — pencil
   register (`ink-muted`), SG 700 tnum at ~56pt (one step below the work
   hero), spring 0.5/0.85, **no overshoot**. Beneath it, the **depleting
   drafting rule**: a full-bleed hairline with 30s ticks, drawn off
   left-to-right with the ruling-pen edge at micro scale.
3. **240–390ms:** the **feel pill** rises (fade + 8pt, ease-out, ~150ms, **no
   spring** — it asks a question 25×/session; it must be the quietest object
   in the stack). The pill is **one ruled three-cell row** — a single 1px ink
   rectangle divided by two hairline verticals: **Easy | Solid | Grind**
   (Inter 500 17pt ink, equal cell widths, ≥48pt tall, never reflows). One
   tap: the cell takes the log-settle press, the row collapses by **crossfade**
   (150ms — no traveling chrome) into its tag on the ledger row. Ignored: it
   fades as one of the rest-end morph's exits — never a separate event, never
   a slide (motion must not editorialize the ignoring). Feel logs as unknown,
   costing nothing (`ui-overhaul-spec.md` §8).
4. **The ledger row** (the just-logged set): digits stay **full ink** at ~15pt
   SG 600 tnum — done work is the most-true data in the app; a record is
   permanent ink — non-numerics muted, a filled margin tick aligning with the
   tick system, tags (feel, PR) from the tag family. **Tappable → the set-edit
   view** (§6).
5. **280–430ms, opacity only (furniture, no travel):** **next-set preview** —
   the evidence lockup at 22pt ("Next: A2 · Row — 60 kg × 8"; at exercise
   boundaries it names the next exercise so the walk happens during rest) —
   and **timer controls**: **−15s · +15s · Skip rest**, `accent-ink`, ≥44pt
   hit areas each (audit F10; symmetric trim because the only way to shorten
   rest must not be the Skip cliff).
6. **Warm-up register:** warm-up sets get a **compact rest** — short timer
   (their prescribed rest, often ≤60s) in a reduced layout, no feel pill (feel
   on 40% loads is noise and trains pill-blindness before the working sets),
   one-tap skip. Three full 2:30-register morphs before the first working set
   would teach reflexive skipping. Warm-up *adjustments* are still logged —
   the lifter who bumps a warm-up down is telling the model something.

**Rest end:** the doublet (two light taps, ~120ms apart) fires **synced to the
displayed 0:00** → 0:00 holds ~300ms → the morph (haptic always leads motion;
fact first, consequence second). **Input guard:** if a pill tap or stepper
touch is in flight at 0:00, the rest state holds at a static 0:00 until the
interaction commits — the screen never rearranges under a descending thumb.

**Rest → next set (350ms, auto):** the timer hero compresses and sinks
(0–220ms); **the ledger row exits downward** (80–300ms) — spent work sinks
home to the bottom of the world; the full record lives in plan-peek. The
next-set preview **is the seed of the next screen**: matched geometry on the
container, text crossfade at midpoint, 80–350ms — new work rises from near the
ink. The position line persists and hard-swaps its digit (tnum holds the
frame); at exercise/superset boundaries it **crossfades** (150ms) inside the
same morph — in supersets, name-change is the common case, not the edge. The
Done slab rises back 150–350ms.

**Timer engineering:** digits **hard-swap** — no opacity cross, no slide, no
odometer (a 1Hz cross-fade on a hero is 150 micro-animations per rest).
Implementation: `Text(timerInterval:)` — no Timer publisher, no per-second
view invalidation, and the identical API renders the Live Activity countdown
out-of-process. The timer text is isolated in its own subview. **No final-5
treatment** — no pulse, no color, no scale (it would play 25×/session, and
urgency contradicts "timer end never forces anything"). All timers are
**wall-clock-derived** (timestamp arithmetic, never an in-process tick) —
calls, backgrounding, and force-quits cannot drift them. Actual rest taken
(including over-rest) is **recorded as data** — rest duration is model food.

## 5. Plan-peek, jump, swap

- **Plan-peek:** the chip is the primary path (a custom top-edge pull fights
  Notification Center and sheet-dismiss; a content-area pull-down may ship as
  a secondary gesture, droppable). Opens a standard sheet: every exercise with
  its sets (the Fitbod rail + one-line summaries), done sets as ledger rows —
  **every row tappable → the set-edit view** — current position highlighted,
  struck sets shown with their reason (§7).
- **Jump (equipment busy):** from plan-peek. The current exercise marks "come
  back" and **auto-requeues after the current exercise's last set**; the
  exercise-transition preview names it; the Finish guard catches it if never
  done (§8). **Pairs travel as pairs** — jumping out of a superset moves and
  returns both.
- **Swap:** from plan-peek. A short **ranked list** of pattern-equivalents the
  gym supports (recents-first; the Hevy picker shape constrained to the
  pattern) — never a single oracle suggestion (one wrong suggestion is a dead
  end). **No AI call; works offline.** Mid-exercise swap: logged sets stay on
  the ledger under the old exercise (honest history, both visible); the new
  exercise starts at set 1 with a prescription derived **locally from the
  pattern's capability band** (the pre-generated plan has no number for an
  exercise it didn't generate — name the source).
- **Add an exercise** mid-session (the bolt-on curl): same picker, appended to
  the plan, prescription from the band, logged as added.

## 6. The set-edit view — the correction surface (load-bearing)

**Every logged set is editable until Finish** — from its ledger row during
rest and from plan-peek any time. This single surface is simultaneously the
Done mis-tap undo, the "I didn't finish" path, and a §8 data-honesty
requirement (an uncorrectable mis-log is fabricated data; the one-tap bet's
errors concentrate on the heaviest, most informative sets).

- Edits: reps (keypad + stepper), weight, **feel** (the three cells again),
  delete the set. **Symmetric** — "log what actually happened" covers *more*
  reps too (the lifter who got 6 on a prescribed 5 is the single most valuable
  ratchet signal; correction must not be framed as confessing failure).
- **"I didn't finish"** on the rest morph is this view, pre-focused on reps —
  a peer-level affordance folded into the ledger row, not sotto-voce text
  sitting 8pt under "Grind".
- **A quiet pain/limitation flag** lives here (and only here): "something
  hurt" → pattern + optional note. Never required, never blocking. This is
  the input channel the safety intervention (§7) listens to — the shipped
  app captured pain per set and acted on it; the rebuild must not regress it.
- The **correction window for all set data closes at Finish, not at 0:00** —
  the pill's *visual* dies at rest-end, the data stays editable. (The buddy
  chat and the phone call are the two most ordinary rest events in a gym;
  they must not destroy the honesty affordances.)

## 7. The off-script paths (first-class)

| Case | Treatment |
|---|---|
| Warm-up sets | Lighter register: WARM-UP tag, compact rest, no pill (§4.6), one-tap Done. |
| AMRAP | "× 5+" target. Done opens the rep counter: **keypad-first** (starts empty — no anchor) + fast-repeat stepper. **Bail semantics:** dismissed empty = "set completed, reps unknown" (honest absence, low confidence), surfaced once post-workout for a fill-in — never a silent zero, never silent as-prescribed. |
| Didn't finish / did more | The set-edit view (§6), symmetric. |
| Plate unavailable | Never arises at render (pre-snap, §3); inside Adjust the stepper only offers loadable values. |
| Equipment busy | Jump/swap (§5). |
| Mid-session interruption | Pause (margin row) → paused state → Today's resume card. **Auto-pause at ~10 min idle** (clock stops). Sentinel + write-ahead queue written **after every logged set** — force-quit resumes losslessly (the shipped app's one genuinely good machinery; named so the rebuild doesn't regress it). |
| Abandonment | Next-day launch: the resume card offers a one-tap honest close ("Finish Tuesday's session?" — logs what happened, nothing more). Hard auto-end at 24h. |
| Model intervenes | A **revision note**, not a banner: full-bleed hairlines above/below, a 2px `accent-ink` tick at the left margin (the only accent outside the slab; red tick only for safety back-off + `notification(.warning)`), body with the grounded number in SG 600 tnum. **Mechanics:** trigger is a deterministic local rule (grind streak, pain flag, readiness delta — no AI between sets); the lifter can decline ("Do it anyway" quiet text); a declined cut logs the set as off-plan; plan-peek shows struck sets with the reason. Enters inside an existing morph when possible; else fade + 8pt, 200ms, layout shift animated in the same window, never during an in-flight touch. |
| PR mid-session | The tag family's only inverted member: a tiny ink-filled rectangle, paper "PR" — **a notary stamp on the ledger row**, set during the row's normal settle, plus a 120ms left-to-right ink draw-on at settle-end. No bounce, no haptic, never accent — `celebrate-ratchet` and milestone haptics stay gated post-workout. A tick alone is sub-perceptual and makes the post-workout reveal feel retroactive; one static word is a fact, not a trophy. Genuine e1RM/rep PRs only (no Fitbod four-records-per-ab-session inflation). |

## 8. Finish & exit

The last working set's end morph **carries the feel pill and the ledger row's
edit path** above Finish — final sets are the closest-to-failure,
highest-information sets; without this every session's last set logs
feel-unknown *by structure*.

- **The slab persists: Done's label crossfades to "Finish"** (300–450ms) with
  a **500ms input cooldown** (a double-tapped last Done must not fire Finish).
  One persistent ink object the whole session; its label changes exactly once;
  bookend #3 floods from it.
- Composition: **the ledger, complete** — the session's settled rows are the
  hero, the one-liner above them in `display` ("Done — 4 of 5 lifts") as a
  fade, ≤8pt, **no flourish, no haptic** — quiet before the post-workout
  reveal.
- **The Finish guard names partials honestly:** "Cable row — skipped · Squat —
  3 of 5 sets" one line each, never "Done — N of N" over a partial session.
  Finish on a partial is one tap, never a blocker.
- **Discard ≠ end early:** a session with zero logged sets discards (no
  record); any logged set means an honest partial record. Early exit lives in
  the pause menu.

## 9. States & rules

- **Appearance:** follows system, **plus a one-tap appearance toggle in the
  pause menu** — the dim variant is already canon and the 11pm dim-garage
  glare complaint is real; on OLED, dim is also the meaningful power saver
  across an 80-minute keep-awake session.
- **Offline acceptance criterion: zero in-loop operations require network.**
  Set writes queue locally; the swap list, history ("Why this?", last-time),
  and plate math are on-device. The session was pre-generated (Today's
  policy); any mid-session re-prescription is a deterministic local rule.
  Never a spinner between sets (the shipped 8s-per-set AI call is the named
  failure).
- **Rest-alert reliability stack**, in order: foreground haptics (work in
  silent mode) → **Live Activity (the DND-proof primary**, survives Focus and
  lock) → notification fallback ("Rest done — Squat, set 3"; suppressed by
  Focus, may be unauthorized). Notification authorization is checked at first
  session start with a one-line inline nudge — never a mid-onboarding prompt.
  Returning after 0:00 lands on the **next-set screen** (the rest state is
  past), with **no replayed morph and no re-fired doublet** — return plays
  states, not reruns; replaying a transition for a past change is motion
  dishonesty.
- **Idle & power:** **nothing animates at idle** — the 1Hz digit swap is the
  screen's entire idle motion (also the ProMotion downclock strategy). After
  ~20s of untouched rest, an **idle-dim tier**: brightness fades down over 1s
  (a power state, not choreography — exempt from the motion budget), ≤100ms
  restore on touch or significant device motion; the timer stays legible
  dimmed. Keep-awake for the session; suspended face-down/pocketed
  (proximity/orientation — a hot screen in a pocket logs sets and eats
  battery).
- **Lifecycle:** portrait-locked v1 (a rotating loop mid-set is all cost).
  Sessions key to their **start date** — midnight never orphans the resume
  card or resets the clock. **One active session per user**, device-locked; a
  second device sees it read-only ("In progress on iPhone"). Watch companion:
  out of v1 scope, stated (the rest timer on the wrist is the most-requested
  follow-up).
- **Motion law, loop-wide:** every spring is 0.85+ damping or pure ease-out —
  **overshoot is banned in the loop** (the only sanctioned overshoots,
  `gauge-focus` and `celebrate-ratchet`, don't appear here). Reduce Motion:
  every morph is a 150ms crossfade, rows appear in place, haptics kept, the
  0:00 hold-beat kept (the haptic→change order survives).
- **Dynamic Type / AX:** the lockup sheds plate callout, then last-time, then
  preview before digits shrink; Done never shrinks. VoiceOver order **per
  state** — set screen: exercise → prescription → last-time → Done → Adjust →
  Why this?; rest state: ledger row → timer → pill → preview → controls.
- **Per-set notes:** cut for v1 beyond the pain flag (§6) — stated here so
  it's a decision, not an omission.

## 10. Explicitly cut

Video demo as hero (lives behind "Why this?"), muscle-% rings, live
volume/calorie counters, share buttons, in-app music controls, mid-session
confetti or streaks, RPE number pads as a *feel* instrument (the pill is the
instrument; keypads are for rep *counts*), forced rest, timer-as-modal-
destination, manual-start rest (auto-start at Done is the only honest rest
clock), rolling-odometer digits, final-5 urgency effects, per-set notes (v1).

## 11. Mobbin references (panel-annotated)

*(Note: four originally-downloaded frames didn't match their captions — l01/
l03/l04/l07 showed adjacent screens from the same flows. The patterns cited
below were verified against the flow search previews; per-frame citations go
to the flows.)*

Guided set screens:
- [Fitbod — log set](https://mobbin.com/screens/cf28f4cb-660a-42bb-aff7-abb4f0c75aaa) — the canonical guided screen (big REPS/POUNDS pairs, active set bold). Take: full-session visibility before commitment → plan-peek content. Reject: video header, list-of-sets-as-screen.
- [Hevy — logging flow](https://mobbin.com/flows/7b6374ff-8ff6-4d7b-babe-077e72b6ee1f) — the spreadsheet pole. Take: the **inline bottom rest bar (−15/+15/Skip)** → our §4 controls; warm-up "W" rows; previous-session column (→ our last-time anchor). Reject: the timer ring modal (a timer is not a destination), permanently-visible Finish over zero logged sets, live volume/duration counters. Note "Discard Workout" → our §8 discard/end-early split.
- [Gymshark — superset flow](https://mobbin.com/flows/9068346a-3a42-4144-b6ae-3c7b85379d63) — take: **Target vs Previous side-by-side at the moment of input** (the strongest external proof for the last-time anchor) and the keypad rep entry (→ AMRAP counter); its truncated round-tabs are the superset-density failure our single position line avoids; the Notes pencil marks the per-set-notes cut.
- [Runna — circuit logging](https://mobbin.com/flows/637dd0a9-6338-43a6-a474-765843d736bb) — take: explicit Active/Complete state badges (position clarity). Reject: persistent two-button chrome bar, "Tip:" filler lines (ungrounded — our coach-line law), manual-start rest (**rejected explicitly**: the rest clock is honest only if it starts when the set ends).

Feel / feedback:
- [Duolingo — too easy / just right / too hard](https://mobbin.com/screens/1a9e1a67-9d93-46e3-a14d-0a5b379db838) — the verbal register to beat. **Recorded decision:** their scale is *relative to target*; ours is *absolute experience* (Easy/Solid/Grind ≈ RPE ≤6 / 7–8 / 9+) — absolute beats relative here because the model knows its own intent and the lifter shouldn't need to.
- [pliability — 3-emoji](https://mobbin.com/screens/409de7d4-dd7d-498c-9a1e-0bf055641fe2) — one-tap validated; emoji rejected (😐 is unmappable). Theirs is per-session; our per-set pill is the moat and the fatigue risk.
- [Tonal — star survey](https://mobbin.com/screens/7c0a426f-2096-4035-80a3-90574f6bfb84) — the anti-pattern (four fields, unanchored stars), and a warning: the pill never grows a follow-up question. One tap, forever. (Its tracked-caps micro-labels and hairlines are, separately, the closest typographic register to ours in the set.)
- [Alan — slider](https://mobbin.com/screens/8fffbc40-4c0f-4772-9b9c-8eb803b1b543) — continuous scales fabricate resolution; rejected. Their explicit Skip button is the lesson: our ignorable pill needs none — ignore-as-unknown is the structurally better honesty mechanic.
- [Fitbod — records](https://mobbin.com/screens/fbea91c5-5d67-4f8c-a15b-06153cb6a509) — four "records" from one ab session: trophy inflation, the named opposite of the ink PR stamp.

## 12. The six open questions, resolved

1. **Plate math:** keep, always visible, plate-loaded lifts only, as the
   dimension callout naming the bar — tap-to-reveal hides it from exactly the
   fatigued people who need it (and would manufacture a reveal animation per
   set). (Unanimous.)
2. **Feel wording:** Easy · Solid · Grind locked (lifter vernacular,
   self-anchoring, absolute scale); warm-ups skip the pill. Copy-test that
   "Solid" reads as effort-report, not self-praise. (Unanimous.)
3. **Rest-end:** auto-morph, with the doublet→300ms-hold→morph sequence, the
   in-flight-touch guard, and the correction window decoupled from the timer
   (§6). (Unanimous once those three amendments landed.)
4. **Appearance:** follow system + a one-tap in-session toggle in the pause
   menu. (3–1; the dissent wanted system-only — the toggle won on the OLED
   power argument plus the dim variant already being canon.)
5. **Done sizing:** resolved by reclassification — the full-bleed bottom slab
   (~96pt, indicator inside, label above it), not a floating button and never
   the bottom third. Guards: touch tolerance, disabled-while-morphing,
   editable sets as undo.
6. **Mid-session PR:** the inverted-tag **PR stamp** + 120ms draw-on — one
   static word, no celebration; §8 cuts both ways (suppressing a true number
   is also dishonesty). (Unanimous.)

## 13. Review record (2026-06-11, four agents)

Panel: UI-craft, UX/product, visual/art-direction, and **motion/animation**
(new this round). Headlines: *the draft's correction story was its biggest
hole — a one-tap Done with no edit path systematically over-records compliance
on exactly the heaviest sets (UX); the set and rest states were one drawn
detail short of the squint test (visual); the morph choreography had an
internal contradiction (the ledger row) and no locked timelines (motion); and
the hero lockup didn't survive its own longest string (UI).*

| # | Finding (agent) | Disposition |
|---|---|---|
| P0 | Logged sets must be editable until Finish — undo, didn't-finish, symmetric over/under, the §8 requirement (UX, UI, motion concur) | **Accepted** — §6, the spec's load-bearing addition. |
| P0 | Last-time anchor at the moment of truth (UX; audit F6) | **Accepted** — §3. |
| P0 | Session-end must carry the final set's pill (UX, motion independently) | **Accepted** — §8. |
| P0 | Hero-lockup grammar: auto-fit + two-line law, ×/unit micro-spec, dumbbell/BW/hold grammars, name at 22pt (UI + visual merged) | **Accepted** — §3. |
| P0 | "Work is ink, time is pencil" + one lockup three scales (visual) | **Accepted** — §1. |
| P0 | Done reclassified as the full-bleed bottom slab; Done→Finish label crossfade; commit-not-press haptic (visual + motion; UI/UX guards folded) | **Accepted** — §3, §8. |
| P0 | Ledger-row contradiction resolved: exits downward, record lives in plan-peek; full morph timelines locked (motion) | **Accepted** — §4. |
| P0 | Timer: hard-swap digits via `Text(timerInterval:)`, no final-5 treatment, one moving number, wall-clock derivation (motion + UI) | **Accepted** — §4. |
| P0 | Two-phase flood construction, prescription readable ≤450ms, no Start haptic (motion) | **Accepted** — §2. |
| P1 | Pre-snap to loadable + Adjust ask-once propagation (UX; audit F8) | **Accepted** — §3. |
| P1 | Pain/limitation flag restored (UX — shipped-app regression) | **Accepted** — §6. |
| P1 | Adjust = tap-the-number morphing steppers (UI; Gymshark precedent) | **Accepted** — §3. |
| P1 | Jump/abandonment/finish-guard lifecycle with numbers; pairs travel as pairs; discard ≠ end-early (UX) | **Accepted** — §5, §7, §8. |
| P1 | Correction window decoupled from the rest timer (UX) | **Accepted** — §6 (pill visual still dies at 0:00 — motion's purity kept). |
| P1 | Rest-end sequence: doublet → 300ms hold → morph; in-flight-touch guard; pill ignore-exit folded into the morph (motion) | **Accepted** — §4. |
| P1 | Warm-up compact rest register (UX walkthrough) | **Accepted** — §4.6. |
| P1 | Secondary controls recolored `accent-ink` (resolves the token-law violation without an exemption); ±15s symmetric, ≥44pt (UI, UX; audit F10) | **Accepted** — §3, §4. |
| P1 | Intervention mechanics: deterministic trigger, declinable, struck sets visible; revision-note treatment (UX + visual + motion) | **Accepted** — §7. |
| P1 | Idle/power: zero idle animation, idle-dim tier, Live Activity return plays states not reruns (motion) | **Accepted** — §9. |
| P1 | Tag family (incl. inverted PR stamp); dimension-callout plate math; set-position ticks; depleting countdown rule (visual) | **Accepted** — §3, §4, §7. |
| P2 | Reliability stack + authorization nudge; offline acceptance criterion; portrait lock; two-device; midnight; sentinel-per-set; watch scope (UX, UI) | **Accepted** — §9. |
| P2 | AMRAP keypad-first + bail = reps-unknown (UX, UI) | **Accepted** — §7. |
| P2 | Reference-frame mismatches (l01/l03/l04/l07) flagged by two agents independently | **Accepted** — §11 note; citations moved to flow level. |

Deferred: watch companion (named v1 cut); per-set notes (named v1 cut);
bar-speed-style warm-up readiness signal (hook noted in §4.6); "work is ink,
time is pencil" and the tag family as app-wide `DESIGN.md` promotions at the
next screens' round.
