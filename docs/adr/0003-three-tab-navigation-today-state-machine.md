# Three-tab navigation: Today / Program / Progress, with Today as a state machine

**Status**: accepted, 2026-05-01

## Context

The shipped MVP used four tabs (Program / Workout / Progress / Settings). The Workout tab was a state-machine router with no content when idle — it was a "place" the user only visited to start a session, not a real surface. Settings had become a kitchen sink (API keys + scanner launcher + regenerate + training profile + dev tools). The daily flow on a cold launch took four taps before the user saw a prescription.

This ADR depends on ADR-0002 (queue-shape programme): Today's state-machine semantics assume queue progression rather than calendar-anchored sessions.

## Decision

Collapse to **three tabs — Today / Program / Progress** — with Settings reachable via a gear icon in Today's nav bar. Today is a state machine with three explicit states:

1. **Pre-session** — landing surface when no session is live. Hero is "Up next" (queue head from ADR-0002), with greeting+streak chip, last-session card (collapsible log), AI signals strip, recent+up-next strip, and a footer link to the Program tab.
2. **Live-session** — `WorkoutView` is the **root** of Today's NavigationStack. Pop-back is impossible because there's nothing behind it. Tab bar stays visible (mid-session escape to Program / Progress is allowed and preserves session state). Mid-session backward review of the current session lives in a swipe-down `Session Log` sheet on `ActiveSetView`.
3. **Post-session** — full-screen celebration summary fires on completion → dismisses to a distinct post-session surface with the populated session log (exercises, weights, reps, RPE) front-and-centre, "Up next" deferred to a small footer line, and the E2 de-dupe confirmation card from ADR-0001 placed near the bottom (post-session bookkeeping, not the celebration).

Post-session state reverts to pre-session at **4am calendar-day flip** (anchored to user's local clock, immune to app foregrounding mid-night).

## Considered Options

Four navigation-shape alternatives:

- **(A) Add Today as a 5th tab** alongside the existing four. Rejected: HIG-borderline, doesn't address the Workout-tab-is-empty-when-idle problem, and Settings remains the kitchen sink.
- **(B) Replace Program with Today**. Rejected: loses the calendar (queue list, post-ADR-0002) as a first-class surface; users still want to browse the full programme.
- **(C) Collapse Workout into Today, Settings → gear icon (chosen).** Workout disappears as a tab; Today's state machine owns pre-/in-/post-session. Three tabs total.
- **(D) Hub-and-spoke (no tabs).** Single feed, every surface a card. Rejected: bigger rewrite than v2 warrants and loses the mental separation between "what's now" / "the plan" / "how I'm trending."

Within the chosen (C) shape, three sub-variants for the **live-session state** were weighed:

- **L1 — Workout is Today's root (chosen).** No pop-back. Tab bar visible. Already aligned with the shipped P4-E3 architecture (Workout was promoted to the Program-tab nav stack rather than full-screen-cover); this just makes Workout the root of Today's stack instead.
- **L2 — Workout pushed on top of Today; Today root becomes a Live Control Panel** with pause/end-early/Session-Log content. Rejected: redundant with affordances already in `ActiveSetView`; doubles the surface for the same data.
- **L3 — Workout pushed on top; Today root shows pre-session UI** ("Up next: …"). Rejected: confusing — showing "Up next: Push A" while the user is mid-set in Push A.

Three sub-variants for the **post-session state**:

- **P1 — Summary as full-screen takeover, then snap directly to pre-session ("Up next").** Rejected: transitionally jarring — the user just finished, they don't want the app immediately pushing the next session.
- **P2 — Today's post-session state IS the summary, persists until manual dismiss.** Rejected: no celebration moment.
- **P3 — Hybrid: full-screen summary fires on completion, dismisses to a distinct post-session surface that persists until the next calendar-day flip (chosen).** Celebration moment + persistent reference surface.

Sub-variants for the **revert trigger** from post-session → pre-session:

- **R1 — Calendar-day flip with 4am cutoff (chosen).** Predictable, automatic, late-night-session-friendly.
- **R2 — Next session started.** Rejected: post-session sticks for arbitrarily long if user doesn't train.
- **R3 — Manual dismiss only.** Rejected: friction for no benefit.
- **R4 — Either-or hybrid.** Rejected: complexity without clear win.

Sub-variants for **Up Next visibility on the post-session screen**:

- **U1 — Fully hidden.** Rejected: hides useful info.
- **U2 — Small footer card** ("Up next: Pull A — when you're ready," no Start CTA) (chosen). Acknowledges queue continues without competing with celebration framing.
- **U3 — Secondary card below the log.** Rejected: too prominent; starts to look like pre-session shape.

## Consequences

- The Workout tab disappears entirely; live-session badge state moves to Today's tab badge.
- Settings becomes a gear icon in Today's nav bar — content is reduced (per follow-up Settings reorganisation work).
- Crash recovery and migration alerts collapse into Today's hero card rather than firing as launch-time alert dialogs (eliminates pain point #3 from the v2 design).
- Live Activities and Dynamic Island deep-links land in `ActiveSetView` (Today's root in live-session state), no intermediate router needed.
- The post-session state-transition trigger (4am local) intentionally uses the local calendar even though the *programme* (per ADR-0002) is calendar-free — "today" is a local-clock concept for the user, even when the programme isn't.
