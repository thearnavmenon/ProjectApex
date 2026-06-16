# Onboarding / first-run calibration — design spec

**Status:** designed 2026-06-10; **revised 2026-06-11** after a second two-agent
expert review (UI craft + UX/product) of the Mobbin reference set — all accepted
findings folded in, record in §8. This is the fix for review finding **P0-3**: a
coach that *models you* is useless on day one with no model — a cold-start cliff
where trust craters before the moat exists. Companion docs: `DESIGN.md` (tokens),
`ui-overhaul-spec.md` (locked behavior, esp. §8 data-honesty rules).

## 1. What this flow is for

Three jobs, in priority order:

1. **Seed the trainee model** — initial capability estimate per movement pattern,
   each with an explicit confidence tier. Honest seeds, not fake precision.
2. **Reach the first workout fast** — target under ~3 minutes. Eight top-level
   screens (10–11 views once the lift screens fan out — and the progress line
   accounts for all of them from the start; see §2).
3. **Land the first "visibly smart" moment** — the model reveal (screen 7), where
   the user *watches* their model get drawn. The reveal is the product thesis;
   every screen upstream exists to feed it. **Design the reveal first, not last.**

## 2. Principles

- **One question per screen**, thin ink progress line at top, big tap targets.
  (Fitbod's structure — minus its defects; see §8.)
- **Progress is honest.** The line's denominator includes the
  experience-determined number of screen-6 sub-screens from the start — it never
  silently stretches, re-divides, or moves backward. It starts ~10% filled after
  splash (the user *did* do something: chose the app and saw the promise). One
  honest expectation line at splash exit ("7 quick questions — about 2 minutes");
  no step-fraction counters anywhere.
- **Every question shows its payoff — and the payoff line closes a loop.** A
  `label`-type line under each question says what the answer buys, using the
  **same noun the reveal will show** ("Sets your starting squat band" → a thing
  literally labeled *squat band* 60 seconds later). Generic whys train users to
  skip all whys; loop-closing nouns compound into the trust the reveal cashes.
  Never ask what we can infer.
- **Selection and CTAs.** Single-select screens **auto-advance** on selection
  (~250ms confirm beat, no Next button); Next exists only on multi-select
  (equipment) and numeric screens. CTAs own a reserved safe area — content never
  scrolls beneath them (the occlusion failure visible in two Fitbod references).
  Disabled = `ink-muted` at 40% per `DESIGN.md`, never a dimmed accent. Selection
  is structural (ink border + weight step) — the accent never carries selection.
- **Estimates are welcome, and tagged.** "It's okay to guess — your first
  sessions sharpen this." A guess seeds the model at low confidence; it never
  masquerades as a measurement (spec §8). Note the frame: *the system* does the
  correcting — never "you can adjust it later" (the user's future chore).
- **Skip is honest.** Everything after goal is skippable. Skipping seeds a wider,
  lower-confidence band — stated on screen at the moment of skipping, never
  silently defaulted behind the user's back.
- **Never suggest a number.** Numeric inputs start empty (unit-only placeholder).
  A pre-filled "100 kg" anchors the answer and seeds the model with *our* number
  wearing the user's clothes — fabrication by suggestion (spec §8 rule 1).
- **No theater, and a copy register to match.** The "building your model" moment
  shows real derived values (honest pacing rules in §3.7). No fake percent
  counters, no quiz walls, no paywall before the payoff. Copy never uses
  superlatives or exclamation marks, and never apologizes for a question
  ("don't worry, this doesn't affect…") — every line either asks, pays off, or
  grounds.

## 3. The flow

```
0 Splash → 1 Goal → 2 Experience → 3 Equipment → 4 Schedule
        → 5 Bodyweight → 6 Capability seeding (core) → 7 Model reveal (payoff)
        → Today, first workout ready
```

### 0. Splash / brand moment

Ultramarine flood, bold display sans, then **drain-and-rise** into screen 1 (one
of the four sanctioned bookend moments). One line of voice: what the app is —
*"the coach that models you"* — and one honest expectation line on exit
("7 quick questions — about 2 minutes"). No carousel, no feature tour; the tour
is the payoff screen.

### 1. Goal

Single-select list, **the only mandatory question**; auto-advances on selection.
Options: get stronger / build muscle / general strength. Each option's
description states what the program *mechanically does differently* in model
terms (e.g. "progression chases your e1RM; rep targets bias 3–6"), not vibe
copy. Payoff line: "Sets what your program optimizes for."
Goal text feeds the existing goal machinery (heavy-reassessment, renegotiation).

### 2. Experience

Three options with one-line behavioral descriptions (behaviors, not ego-loaded
identity labels): new to lifting / have lifted, getting back or inconsistent /
train consistently. Auto-advances. Skippable, but the skip states its meaning on
screen ("Skip — we'll start your bands at their widest"). Payoff line:
"Calibrates how we ask about your lifts — and how wide your starting bands are."
This answer **branches screen 6** (sub-screen count) and therefore the progress
denominator — both fixed from this moment.

### 3. Equipment

Multi-select grid — illustrations are **single-ink technical-drawing glyphs**
(the one place illustration is sanctioned; photoreal renders don't survive cream
and clash with the identity). Payoff line: "Filters every exercise we'll ever
prescribe."

- **"Full commercial gym" is the hero option** — a full-width select-all row at
  top (most lifters' modal answer; one tap, done). Manually deselecting any item
  afterward drops it to an indeterminate state.
- Grid below: barbell / dumbbells / machines / cables / kettlebells /
  **bodyweight only** — the last is mutually exclusive and clears the grid.
- **This answer gates screen 6** (see below) — the flow never asks for a set the
  user's equipment can't produce.

### 4. Schedule

Days per week, single tap (2 / 3 / 4 / 5+); auto-advances. Payoff line: "Shapes
your week structure." Feeds the program skeleton layer.

### 5. Bodyweight

One big tabular number (`hero-num`), numpad (no T9 letters), kg/lb unit pill —
the unit choice persists app-wide; default inferred from locale. Input starts
empty. Microcopy: "It's okay to guess." Used for relative-strength estimation in
screen 6's fallbacks (and bodyweight exercises later). If bodyweight *and* all
lifts end up skipped, seeding falls back to a population-prior at lowest
confidence — the fallback chain never dead-ends.

### 6. Capability seeding — the core screens

One sub-screen per big pattern, same layout each time, hero numbers huge
(`hero-num`): **squat, bench (horizontal push), deadlift (hinge)**, and — only if
"train consistently" was chosen — **overhead press**. Three to four sub-screens.

This is the flow's real drop-off cliff: repeated asks at the exact intersection
of effort (numbers to recall), ego threat (being judged on weight), and
ignorance (beginners don't know). Mitigations are load-bearing, not nice-to-have:

- **Per-pattern progress dots** (squat · bench · deadlift · press) on these
  sub-screens — the main progress line does not stretch here (§2).
- After the first pattern is answered *or* skipped, an explicit
  **"Skip the rest — start wide"** affordance seeds all remaining patterns as
  unknown in one tap.

**Equipment gating (P0).** Sub-screens adapt to the screen-3 answer. A
bodyweight-only or dumbbell-only user is never asked for a barbell set: options
A/B re-phrase to the available modality where the engine supports it; otherwise
the sub-screen defaults to the option-C path with honest copy ("No barbell yet —
we'll start from your experience and bodyweight"). An impossible question
harvests either fabricated data or a demoralized skip.

**The three-way control.** A segmented choice, strongest data first; selected
segment per `DESIGN.md` §States. The input region below **card-morphs** (~350ms
shared element, never a hard cut) between the three modes:

| Option | Input | Seeds | Confidence |
|---|---|---|---|
| **A set I've done recently** | weight × reps — one composite control (numpad + rep stepper), not two form fields | e1RM via the engine's standard formula | **measured-ish (high)** |
| **My best guess** | weight for "about 5 solid reps" | e1RM from the guess | **estimated (medium)** |
| **Not sure** | nothing | band from experience level × bodyweight heuristics | **unknown (low)** |

Rules:
- "Beginner" experience flips the default to "Not sure" and reframes the prompt
  ("Most people skip this — your first session works it out").
- Weight inputs start empty (§2 "never suggest a number") and snap to real plate
  increments for the chosen unit — a coach app does not accept 77.34 kg as a
  guess; false decimals are fabricated precision.
- Microcopy under every variant: "A guess is fine — your first sessions sharpen
  this."
- The skip affordance is calm and equal-weight; skipping = option C, recorded as
  unknown. **Never** silently recorded as an answer (spec §8 rule 1).

### 7. The model reveal — the payoff bookend

The most important screen in the flow — and the one with **no reference
anywhere** (every "payoff" screen in the reference set is a loading or claim
screen; the closest analogues are Whoop's first-recovery and Strava's
first-effort moments). Two beats that feel like **one continuous drawing** —
beat 1 auto-advances into beat 2; the user never taps a button to open their own
payoff.

**Beat 1 — drawing (honest labor).** A short checklist whose items name real
derivation steps in the user's own numbers ("Placing your squat band — 80–95 kg ✓
/ Setting your floors ✓ / Building week 1 ✓"), restyled from the stoic pattern,
with the Speak-style accent ring on the active row and the Lens iris focusing as
items resolve (`gauge-focus`). **Pacing rules** — honesty needs pacing to be
legible (real work finishing in 200ms would *read* as fake):

- A tick fires only when its real computation completes — never before.
- Display pacing: ~300ms stagger floor per item; total dwell target ≈2s.
- Hard ceiling: if real work runs long (~5s+), items keep ticking as they
  complete — the active-row ring persists, the screen never hangs, and there is
  never a percentage anywhere in the flow.
- Wherever inputs and outputs both appear, "what you told us" and "what we
  derived" are typographically separated — they are different epistemic classes
  and must never share styling.

**Beat 2 — the reveal.** Layout spec (must hold at default *and* AX type sizes —
bands shed decoration before numbers truncate, per `DESIGN.md` Dynamic Type):

- **Stacked per-pattern band rows**: band fill (`accent` at 8%), floor tick,
  position dot — **solid dot for option-A answers, hollow for
  guesses/unknowns; wider band = lower confidence** (`DESIGN.md` §Data-viz).
  Hero numbers in `hero-num`.
- **Every band carries a source caption** — "from your 100 kg × 5" (solid) /
  "estimated from your experience + bodyweight" (hollow). The recap is merged
  *into* the reveal — there is no separate recap screen. Where it teaches, show
  the derivation: "100 kg × 5 → e1RM ≈ 116 kg". Raw-input playback is the floor;
  visible derivation is the visibly-smart ceiling.
- One coach line in `display` type, grounded per spec §8, no superlatives:
  *"Starting your squat at 80–95 kg. Two sessions and these lines get sharp."*
- **Beginner-branch reassurance line** (when most seeds are unknown): *"We
  assumed nothing — your bands start wide on purpose. Your first session narrows
  them."* Wide hollow bands must read as honesty, not as "the app knows nothing
  about me."
- Below: the first workout's shape (day count + first session's main lifts) —
  **tappable to peek the actual session** (proof, not assertion) — and one
  **Start when ready** action → drain-and-rise to **Today**.

### Landing on Today

The Today coach line for day one frames calibration honestly: *"First session
doubles as calibration — expect a weight check or two."* First-session
prescriptions derived from low-confidence seeds start deliberately conservative;
the in-session "Adjust" path and feel pill do the sharpening (existing
calibration-review machinery re-fits after real sessions — onboarding only
plants the seed it refines).

**The protected zone.** Nothing interrupts between the last question and Today:
no auth gate (see §4), no notification-permission prompt, no paywall, no rating
request. Notification priming lands contextually after the first workout. This
is precisely where the category spends its trust; the rule exists so the iOS
defaults don't creep in at build time.

## 4. What this flow explicitly avoids

- Quiz walls (15+ questions) and any question whose payoff we can't name
  on-screen.
- Fake progress theater; fabricated precision in the reveal ("your squat 1RM is
  103.4 kg" from a guess — bands and hollow dots, not false decimals). Note the
  Cal AI counter *works* (the labor illusion is real psychology) — we win the
  same moment honestly via §3.7's pacing rules, not by skipping it.
- Journey/step-checklist screens (the adidas pattern — rejected): long-flow
  machinery our 8-screen flow doesn't need, and its pre-completion check circles
  conflict with data honesty. Expectation-setting is one honest line at splash
  exit instead.
- Pre-filled suggested weights (anchoring — §2).
- Asking for measurements mid-flow that the model doesn't use yet (height, age,
  sex are **not** asked in v1 — add only when an engine consumer exists, and
  hold the line when analytics asks later).
- Account creation before the payoff. Auth happens after screen 7 (or deferred
  until first sync) — never as a gate between questions and reveal. See also the
  protected zone (§3, Landing on Today).
- Superlatives, exclamation marks, apology copy (§2 register).

## 5. Model integration notes (for the build, later)

- Seeds map to the existing per-pattern capability machinery (floor/stretch
  bands, ADR-0021/ADR-0023 world). The new requirement is a **confidence tier on
  the seed** (`measured / estimated / unknown`) that widens the band and weights
  how fast real session data displaces the seed.
- Onboarding pattern vocabulary must use the engine's canonical pattern names
  (e.g. `horizontal_push`) — the EF already rejects junk patterns; don't invent a
  parallel list.
- Equipment gating implies the seed records *which modality* produced it
  (barbell vs dumbbell set) wherever the engine's e1RM math distinguishes them —
  confirm engine support before promising per-modality phrasing (§6 q6).
- The reveal's coach line is deterministic v1 (template + derived numbers), per
  the P0-2 fallback rule — no AI call in the activation path.

## 6. Open questions (decide at build time)

1. Exact pattern set & count for screen 6 — match the engine's stimulus/pattern
   table; 3 patterns for beginners vs 4 for experienced is the current call.
2. Where auth lands (post-reveal vs deferred to first sync) — needs the Supabase
   session model looked at.
3. Whether schedule (screen 4) also asks session length — only if the skeleton
   layer actually consumes it.
4. Re-running calibration from Settings (probably yes — same screens,
   prefilled). **Needs a confidence-semantics rule before build:** a re-entered
   guess must not overwrite measured session data. Proposed default: re-entry
   seeds at `estimated`, and the model keeps the higher-confidence /
   more-recently-measured value.
5. kg/lb default inference from locale — trivial, currently unspecced anywhere.
6. Per-modality phrasing of options A/B when equipment ≠ barbell — depends on
   which modalities the engine's e1RM math supports (§5).

## 7. Mobbin references

### Take

Question screens:
- [Fitbod — experience level](https://mobbin.com/screens/c13fe9c7-71cb-4a4b-aaac-3ea77b36f072) — 3 options + behavioral descriptions, full-row targets. Our screen 2. *Don't take:* bare-text rows with zero affordance, accent-colored Skip (inverts the color grammar), "(1/8)" quiz framing, "your jam!" register.
- [Fitbod — equipment grid](https://mobbin.com/screens/0cc5bce0-769e-4112-be08-3d1a7a5ccde5) — grid + explicit no-equipment cell. Our screen 3. *Don't take:* photoreal renders (illegible, off-identity), missing select-all/mutual-exclusion logic, no full-gym shortcut.
- [Fitbod — goal select](https://mobbin.com/screens/58498852-f344-4b62-b10e-0988ac6f0091) (+ [selected](https://mobbin.com/screens/047da3e6-9de7-4ea0-a426-65e15d0ed05a), [unselected](https://mobbin.com/screens/5636c16e-2e48-4882-9b80-890741825863)) — progressive disclosure on select. *Don't take:* color-only selected state (WCAG 1.4.1 failure), six-option taxonomy mush, the floating CTA occluding the last option (both screenshots show the bug — hence §2's reserved-safe-area rule), dimmed-accent disabled state.
- [Centr — goal radio list](https://mobbin.com/screens/baf07542-7afb-4d8e-8af8-36ece724db81) — visible radio anatomy (declares single-select before first tap), thin progress bar, direct headline. *Don't take:* name-injection (requires auth-before-value), all-caps everything, zero-information CTA copy. Apex's personalization is reflecting *given answers* forward ("Getting back into it — we'll start your bands wide"), which beats mail-merge.

Numeric entry:
- [Yazio — weight entry](https://mobbin.com/screens/2b2b032e-f176-4680-972d-3de0c98154df) — the gold standard of the set: big tabular number, unit pill, numpad up, "okay to guess." Our screens 5–6. *Don't take:* T9 letters on the keypad, free decimals (false precision), "you can always adjust later" framing (§2), ~90%-done progress bar with many screens left.
- [Lifesum — why-we-ask footer](https://mobbin.com/screens/af8c7994-f702-4497-a86a-c07b3609561f) — the right *slot* for payoff lines; the copy itself is generic vapor (the negative proof for §2's loop-closing rule).

Payoff:
- [stoic — preparing checklist](https://mobbin.com/screens/6af627cc-8437-4dc8-bb9f-bec83e87a9ae) — beat-1 skeleton: ink-on-paper, product-vocabulary items, no spinner. *Don't take:* generic item copy, sub-AA social-proof line, unlabeled icon-only CTA, the tap between labor and payoff (we auto-advance).
- [Speak — building your plan](https://mobbin.com/screens/139db00b-6179-4bb5-a77e-f682265ee343) — take **only** the single-accent ring on the active checklist row. *Don't take:* logo-as-hero (brand-centric payoff), "analyzing" theater, superlative copy.
- [stoic — plan ready](https://mobbin.com/screens/03bc31f1-71ec-4587-a2ab-e8615a694ef3) — "Focused on:" plays the user's goal back; we fold that into the coach line. The reassurance-card *slot* is reused for the beginner branch. *Don't take:* claim-cards with checkmarks for work that never ran ("AI Mentors are ready ✓").
- [Yazio — hang-tight recap](https://mobbin.com/screens/3023715f-a48a-4581-a866-fadce01bea57) — recapping the user's real inputs is right; we merge it into the reveal as per-band source captions. *Don't take:* the separate screen, the mascot, inputs and derived outputs styled identically.

### Anti-patterns (kept deliberately)

- [Cal AI — percent counter](https://mobbin.com/screens/63944ee4-76ea-4bcd-8f0f-543e7240f4ff) — fake determinate progress over padded theater. Honest about why it exists (labor illusion converts); §3.7 wins the moment honestly.
- [MyFitnessPal — multi-field form](https://mobbin.com/screens/3dfe2002-71de-42d7-97f2-98f707da5b3c) — three-question screen breaks rhythm; stock fields are the generic-Apple look; and "don't worry, this doesn't affect your daily calorie goal" is microcopy *apologizing for the question's existence* — the photographic negative of §2.
- [adidas Running — step checklist](https://mobbin.com/screens/65a226b8-d0eb-46ad-8459-d5cd90ac8099) (+ [wheel picker](https://mobbin.com/screens/8f87b5a9-9db5-42e5-85eb-2c3948a91c61)) — rejected 2026-06-11 (was "consider"): journey-checklist machinery for long flows; check circles on unstarted steps read as half-done; the inline why is good but already harvested by §2's payoff lines. Wheels rejected for all load entry: slow over wide ranges, VoiceOver-hostile, and the resting value *anchors* answers (fabrication by suggestion).

## 8. Reference-review record (2026-06-11)

Second two-agent review — one UI-craft expert, one UX/product expert, same
Uber-calibre brief as the 2026-06-10 design review — each viewing all 16
reference screenshots against this spec. Shared headline: *the reference set
teaches question-asking, but the screen that matters most — the reveal — has no
reference anywhere; and copying the set faithfully produces "every fitness
app's onboarding, recolored."* All proposals accepted and folded in:

| # | Finding | Where it landed |
|---|---|---|
| P0 | Reveal under-specced; no reference exists for data-as-payoff | §3.7 full layout + source captions + design-first mandate (§1) |
| P0 | Equipment must gate capability seeding (barbell questions to bodyweight-only users harvest fabrication or demoralized skips) | §3.6 gating + §5/§6 engine notes |
| P0/P1 | Beat-1 honest-labor pacing (instant honest work *reads* fake); auto-advance into reveal | §3.7 beat 1 |
| P1 | Three-way control + input morphs unspecced | §3.6 |
| P1 | Progress honesty: denominator includes sub-screens, endowed ~10% start, per-pattern dots, "skip the rest" | §2, §3.6 |
| P1 | Auto-advance single-selects; CTA safe area; disabled ≠ dimmed accent | §2 |
| P1 | Payoff lines must close the loop with reveal nouns | §2 |
| P1 | Equipment glyphs in single-ink line art; full-gym as hero option; mutual-exclusion logic | §3.3 |
| P2 | Pre-filled weights banned (anchoring) | §2, §3.6 |
| P2 | Protected zone after last question (auth/notifications/paywall/rating) | §3 Landing |
| P2 | adidas checklist demoted to rejected; copy register (no superlatives/exclamations/apology) | §4, §7, §2 |
| P2 | Beginner reassurance on reveal; tappable first-workout peek | §3.7 beat 2 |
| P2 | Re-calibration confidence semantics; locale unit default | §6 |
