# UI overhaul — locked behavior & interaction spec

**Status:** locked 2026-06-10 after a grilled decision process (panel splits on each
major surface) and a two-agent UI/UX expert review whose accepted fixes are folded
in below. Visual tokens live in the repo-root `DESIGN.md`. Per-screen design docs
layer on top in `docs/design/` (first: `onboarding-calibration.md`).

This is a design spec, not an implementation plan — no slices or issues exist for
it yet.

## 1. Scope & guiding principle

Full UI rebuild from scratch. The one-line test every screen answers to:

> **Quietly right in the moment, visibly smart around it.**

Calm and dead-simple while you're lifting (the live loop earns trust by getting out
of the way); smart and expressive around the workout (Today, post-workout, progress
— where the coach shows its thinking).

## 2. Navigation

Three tabs, settings tucked in a corner (not a tab):

- **Today** — the coach/home surface: next workout + one-tap start.
- **Train** — the program: calendar, week structure, exercise library. Exercise
  detail/history is also reachable contextually from "Why this?" inside a session.
- **Progress** — capability bands, e1RM trends, history.

(The Train/Today boundary was a review P2: Today owns *now*, Train owns *the plan*.)

## 3. Today screen

- Hero: the next workout and a single one-tap **Start**.
- One short coach line above it ("Recovered — push squats today"). Grounded in at
  least one concrete number from the model; terse honesty over praise.
- Coach alerts (back-off, re-calibration, goal review) are a **calm list** below the
  start action — never pop-ups in front of it.
- **Fallback (review P0-2):** the coach line must have a deterministic local
  fallback computed from model/session data with no AI call. Rule-based ships
  first; the AI line is an upgrade, not a dependency. If even the fallback has
  nothing meaningful to say, the line collapses — an empty slot, never filler.

## 4. Live session loop

- **One set at a time.** One screen owns the current set: exercise, target
  weight × reps as hero numbers, one big **done** tap.
- Rest timer lives on the same screen post-log (the card morphs; no modal, no
  separate screen).
- **Feel pill** after each set: a small "how did that feel?" pill — optional by
  design.
- **Plan-peek (review P1):** a collapsed session overview is always one swipe away
  without leaving the loop — experienced lifters can see the whole session;
  one-set-only must never feel infantilizing.
- "Adjust" handles weight/rep deviations from prescription.

### Data integrity — ignore ≠ confirm (review P0-1, revises the original decision)

An ignored feel pill **does not** record an on-target feel. It logs "reps as
prescribed, **feel unknown**" — never a fabricated feel. Everything downstream
(e1RM, readiness, floor/ratchet logic) treats unknown-feel sets with reduced
confidence. A lifter who ignores the pill 80% of the time must not poison the
model with data that never happened — the moat depends on this.

### Edge cases are first-class (review P1)

The off-path is the real path for serious lifters. The loop must handle, without
dumping everything on "Adjust":

- warm-up sets (distinct from working sets, lighter logging),
- AMRAP / max-rep sets,
- failed or missed reps,
- supersets / paired exercises,
- prescribed load unachievable with available plates,
- mid-session interruption — a paused session is **resumable**, mandatory.

## 5. Post-workout summary

- **Hero: the coach's read** — 1–2 lines naming what the session *proved* about
  you ("Squat's clearing its band cleanly — third week it's held; bench is where
  the work is next"). Grounded in ≥1 concrete logged number; fails toward terse
  honesty over praise. A generic or wrong line is worse than nothing.
- **Numbers sit underneath as evidence**, not headline: the most-moved capability,
  position vs floor/stretch — plus one quiet volume/PR stat line (review P2: don't
  fully delete the scoreboard).
- **PRs fold into the read** ("…and you set a PR doing it"), not a trophy section.
- **Celebration is earned:** genuine milestones only (PR / level-up / floor-ratchet)
  get the flourish + haptic; flat days stay in the calm coach voice. Honest flat
  days must feel respected, not punished.
- **Cut:** trophy hero, total-volume-as-hero, sets ring, duration stat,
  "AI adjustments" count, share-as-primary.
- **Fallback (review P0-2):** same rule as Today — a deterministic read from set
  data ("3 of 4 top sets hit; the last one was a grind") whenever the AI line is
  unavailable, slow, or fails validation.

Rationale (unanimous two-lens panel, including the reward/retention lens): for
committed trainees, *being seen doing it well* is the dopamine — relationship and
accountability drive return, not a volume tally you could compute yourself. The
per-session delta was rejected as hero because honest sessions often move e1RM ~0:
a delta-hero manufactures fake precision or frequent visible nothing; the read
survives a bad day.

## 6. The Lens (readiness/score gauge)

A camera-iris aperture: opens with readiness, *focuses* as data resolves. Brand
texture, not sole carrier (review P2): always backed by a literal number + word
label — glanceable in gym light and readable by VoiceOver.

## 7. Motion

Expressive motion at the bookends only (app open, workout start, post-workout
reveal, milestone); 150ms workhorse transitions everywhere else; Reduce Motion
falls back to crossfade. Full token spec in `DESIGN.md` §Motion.

## 8. Cross-cutting data-honesty rules

These came out of the review touching every surface; they are design law, not
per-screen details:

1. **Never fabricate data.** Absence of input is recorded as absence (feel
   unknown), not as a default that looks like a measurement.
2. **Confidence is visible.** Estimated/low-confidence values *look* less certain
   wherever they render (hollow points, dashed projections — `DESIGN.md`
   §Data visualization). Applies from onboarding seeds (see
   `onboarding-calibration.md`) through capability charts.
3. **Every coach utterance is grounded** in at least one concrete number the user
   can verify, and every AI-generated line has a deterministic local fallback.

## 9. Review record (2026-06-10)

Two independent agents — one UI expert, one UX expert, both briefed as senior
Uber-calibre practitioners optimizing customer satisfaction/usage/experience.
Headline: *the design trusts the AI's judgment and the user's compliance; v1 must
let both fail loudly instead of silently.*

| # | Finding | Disposition |
|---|---|---|
| P0-1 | Feel-pill "accept by ignoring" fabricates data | **Accepted** — §4 ignore ≠ confirm |
| P0-2 | Coach's read has no failure mode | **Accepted** — §3/§5 deterministic fallbacks |
| P0-3 | No onboarding = cold-start cliff, no activation | **Accepted** — `onboarding-calibration.md` |
| P0-4 | Ultramarine text on cream fails WCAG AA | **Accepted** — `DESIGN.md` contrast roles |
| P1 | Dim variant now; motion restraint; loop edge cases; plan-peek | **Accepted** — `DESIGN.md` + §4/§7 |
| P2 | Gauge needs literal number; Train/Today boundary; quiet stat; missing tokens | **Accepted** — §6/§2/§5 + `DESIGN.md` |

## 10. Next design targets

1. ~~Onboarding / first-run calibration~~ — specced in `onboarding-calibration.md`.
2. ~~Splash / brand moment + Today screen~~ — specced in `splash-today.md`
   (includes the wordmark/app-icon asset deliverable: the aperture-A).
3. ~~Live-loop screen~~ — specced in `live-loop.md`.
4. ~~Post-workout summary (bookend #3)~~ — specced in `post-workout.md`.
5. Progress; Train.
6. Per-screen specs then get broken into issues/slices for implementation.
