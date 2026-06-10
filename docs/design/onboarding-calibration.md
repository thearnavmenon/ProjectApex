# Onboarding / first-run calibration — design spec

**Status:** designed 2026-06-10. This is the fix for review finding **P0-3**: a
coach that *models you* is useless on day one with no model — a cold-start cliff
where trust craters before the moat exists. The UX reviewer called this the single
highest-leverage missing piece. Companion docs: `DESIGN.md` (tokens),
`ui-overhaul-spec.md` (locked behavior, esp. §8 data-honesty rules).

## 1. What this flow is for

Three jobs, in priority order:

1. **Seed the trainee model** — initial capability estimate per movement pattern,
   each with an explicit confidence tier. Honest seeds, not fake precision.
2. **Reach the first workout fast** — target under ~3 minutes, 8 screens max.
   Activation is the metric; every screen must visibly buy intelligence.
3. **Land the first "visibly smart" moment** — the payoff screen where the user
   *watches* their model get drawn. The product's promise ("a coach that models
   you") is demonstrated before the first set is ever lifted.

## 2. Principles

- **One question per screen**, thin ink progress line at top, big tap targets.
  (Fitbod's 8-step pattern — the reference everyone copies because it works.)
- **Every question shows its payoff.** A `label`-type line under each question
  says what the answer buys ("This sets your starting squat band"). Never ask
  what we can infer.
- **Estimates are welcome, and tagged.** "It's okay to guess — your first
  sessions sharpen this" (Yazio's microcopy pattern). A guess seeds the model at
  low confidence; it never masquerades as a measurement (spec §8).
- **Skip is honest.** Everything after goal is skippable. Skipping a lift seeds a
  wider, lower-confidence band derived from experience + bodyweight — it never
  invents a number the user "said."
- **No theater.** The "building your model" moment shows real derived values and
  lasts only as long as it needs to. No fake percent counters (Cal AI's 18%
  screen is the anti-pattern), no 20-question quiz wall, no paywall before the
  payoff.

## 3. The flow

```
0 Splash → 1 Goal → 2 Experience → 3 Equipment → 4 Schedule
        → 5 Bodyweight → 6 Capability seeding (core) → 7 Model reveal (payoff)
        → Today, first workout ready
```

### 0. Splash / brand moment

Ultramarine flood, bold display sans, then **drain-and-rise** into screen 1 (this
is one of the four sanctioned bookend moments). One line of voice: what the app
is — *"the coach that models you."* No carousel, no feature tour; the tour is the
payoff screen.

### 1. Goal

Single-select list (Centr/Fitbod pattern): get stronger / build muscle / both-ish
general strength. Selected state per `DESIGN.md` §States (ink border + weight, not
accent fill). Payoff line: "Sets what your program optimizes for."
Goal text feeds the existing goal machinery (heavy-reassessment, renegotiation).

### 2. Experience

Three options with one-line descriptions (Fitbod's exact pattern): new to lifting /
have lifted, getting back or inconsistent / train consistently. Payoff line:
"Calibrates how we ask about your lifts — and how wide your starting bands are."
This answer **branches screen 6** (see below).

### 3. Equipment

Multi-select illustrated grid (Fitbod): barbell / dumbbells / machines / cables /
kettlebells / bodyweight-only, plus "full commercial gym" shortcut that selects
everything. Payoff line: "Filters every exercise we'll ever prescribe."

### 4. Schedule

Days per week, single tap (2 / 3 / 4 / 5+). Payoff line: "Shapes your week
structure." Feeds the program skeleton layer.

### 5. Bodyweight

One big tabular number, numpad, kg/lb unit pill (Yazio pattern — the unit choice
persists app-wide). Microcopy: "It's okay to guess." Used for relative-strength
estimation in screen 6's fallbacks (and AMRAP/bodyweight exercises later).

### 6. Capability seeding — the core screen

One sub-screen per big pattern, same layout each time, hero numbers huge
(`hero-num` type): **squat, bench (horizontal push), deadlift (hinge)**, and — only
if "train consistently" was chosen — **overhead press**. Three to four sub-screens.

Per pattern, a three-way segmented choice, strongest data first:

| Option | Input | Seeds | Confidence |
|---|---|---|---|
| **A set I've done recently** | weight × reps (numpad + steppers) | e1RM via the engine's standard formula | **measured-ish (high)** |
| **My best guess** | weight for "about 5 solid reps" | e1RM from the guess | **estimated (medium)** |
| **Not sure** | nothing | band from experience level × bodyweight heuristics | **unknown (low)** |

Rules:
- "Beginner" experience flips the default to "Not sure" and reframes the prompt
  ("Most people skip this — your first session works it out").
- Microcopy under every variant: "A guess is fine — your first sessions sharpen
  this."
- The skip affordance is calm and equal-weight; skipping = option C, recorded as
  unknown. **Never** silently recorded as an answer (spec §8 rule 1).
- Plate-math nicety: weight input snaps to real increments for the chosen unit.

### 7. The model reveal — the payoff bookend

Two beats, both real:

1. **Drawing (~2s, honest):** short checklist ticking as actual derivation runs
   (stoic's "preparing the app for you" pattern, restyled ink-on-cream):
   "Placing your squat band ✓ / Setting your floors ✓ / Building week 1 ✓". The
   Lens iris focuses as items resolve (`gauge-focus` motion).
2. **Reveal:** the user's starting model, drawn as capability bands per pattern
   (`DESIGN.md` §Data-viz): band fill, floor line, position dot — **solid dot for
   pattern A answers, hollow for guesses/unknowns**, so confidence is visible from
   minute one. One coach line in `display` type, grounded per spec §8:
   *"Starting your squat at 80–95 kg. Two sessions and these lines get sharp."*

Below the reveal: the first workout's shape (day count + first session's main
lifts) and one **Start when ready** action → drain-and-rise to **Today**.

### Landing on Today

The Today coach line for day one frames calibration honestly: *"First session
doubles as calibration — expect a weight check or two."* First-session prescriptions
derived from low-confidence seeds start deliberately conservative; the in-session
"Adjust" path and feel pill do the sharpening (existing calibration-review
machinery re-fits after real sessions — onboarding only plants the seed it refines).

## 4. What this flow explicitly avoids

- Quiz walls (15+ questions) and any question whose payoff we can't name on-screen.
- Fake progress theater; fabricated precision in the reveal ("your squat 1RM is
  103.4 kg" from a guess — bands and hollow dots, not false decimals).
- Asking for measurements mid-flow that the model doesn't use yet (height, age,
  sex are **not** asked in v1 — add only when an engine consumer exists).
- Account creation before the payoff. Auth happens after screen 7 (or deferred
  until first sync) — never as a gate between questions and reveal.

## 5. Model integration notes (for the build, later)

- Seeds map to the existing per-pattern capability machinery (floor/stretch bands,
  ADR-0021/ADR-0023 world). The new requirement is a **confidence tier on the
  seed** (`measured / estimated / unknown`) that widens the band and weights how
  fast real session data displaces the seed.
- Onboarding pattern vocabulary must use the engine's canonical pattern names
  (e.g. `horizontal_push`) — the EF already rejects junk patterns; don't invent a
  parallel list.
- The reveal's coach line is deterministic v1 (template + derived numbers), per
  the P0-2 fallback rule — no AI call in the activation path.

## 6. Open questions (decide at build time)

1. Exact pattern set & count for screen 6 — match the engine's stimulus/pattern
   table; 3 patterns for beginners vs 4 for experienced is the current call.
2. Where auth lands (post-reveal vs deferred to first sync) — needs the Supabase
   session model looked at.
3. Whether schedule (screen 4) also asks session length — only if the skeleton
   layer actually consumes it.
4. Re-onboarding: can a user re-run calibration from Settings? (Probably yes,
   cheap — same screens, prefilled.)

## 7. Mobbin references

Question screens:
- [Fitbod — experience level](https://mobbin.com/screens/c13fe9c7-71cb-4a4b-aaac-3ea77b36f072) — 3 options + descriptions, step counter, skip. Our screen 2.
- [Fitbod — equipment grid](https://mobbin.com/screens/0cc5bce0-769e-4112-be08-3d1a7a5ccde5) — illustrated multi-select. Our screen 3.
- [Fitbod — goal select](https://mobbin.com/screens/58498852-f344-4b62-b10e-0988ac6f0091) (+ [selected state](https://mobbin.com/screens/047da3e6-9de7-4ea0-a426-65e15d0ed05a)) — our screen 1.
- [Centr — personalized goal headline](https://mobbin.com/screens/baf07542-7afb-4d8e-8af8-36ece724db81) — radio list + progress bar; take the directness, skip the name-injection (we don't have a name yet).

Numeric entry:
- [Yazio — weight entry](https://mobbin.com/screens/2b2b032e-f176-4680-972d-3de0c98154df) — big number, unit pill, numpad, "okay to guess" microcopy. Our screens 5–6.
- [MyFitnessPal — estimate microcopy](https://mobbin.com/screens/3dfe2002-71de-42d7-97f2-98f707da5b3c) and [Lifesum — wheel + why-we-ask footer](https://mobbin.com/screens/af8c7994-f702-4497-a86a-c07b3609561f) — payoff-line precedent.
- [adidas Running — step checklist](https://mobbin.com/screens/65a226b8-d0eb-46ad-8459-d5cd90ac8099) — upcoming-steps disclosure; consider for the flow's first question screen.

Payoff:
- [stoic — preparing checklist](https://mobbin.com/screens/6af627cc-8437-4dc8-bb9f-bec83e87a9ae) — closest to our beat 1, already ink-on-paper minimal.
- [stoic — plan ready](https://mobbin.com/screens/03bc31f1-71ec-4587-a2ab-e8615a694ef3) — "focused on:" recap; our reveal is this + real bands.
- [Speak — building your plan](https://mobbin.com/screens/139db00b-6179-4bb5-a77e-f682265ee343) — single-accent loading ring; on-identity.
- [Cal AI — percent counter](https://mobbin.com/screens/63944ee4-76ea-4bcd-8f0f-543e7240f4ff) — the **anti-pattern**: fake theater, kept as a what-not-to-do.
- [Yazio — hang-tight recap](https://mobbin.com/screens/3023715f-a48a-4581-a866-fadce01bea57) — input-recap card idea, minus mascot.
