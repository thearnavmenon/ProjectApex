# Abandon the Phase 3 UI overhaul; revert to the 4-tab ContentView

**Status**: accepted, 2026-06-15

**Supersedes**: [ADR-0003](0003-three-tab-navigation-today-state-machine.md) (the 3-tab Today/Program/Progress intent), [ADR-0024](0024-pure-swift-design-system-foundation.md), [ADR-0025](0025-snapshot-visual-regression-harness.md), [ADR-0026](0026-incremental-shell-rollout-strangler.md), and [ADR-0028](0028-drafting-rule-and-status-tick-instruments.md) — the whole Phase-3 UI program.

## Context

The Phase 3 UI overhaul rebuilt the app behind a dormant compile-time flag (`useNewShell`, ADR-0026): a 3-tab `AppShell` (Today / Train / Progress) drawn in a pure-Swift design system (ADR-0024), with a snapshot harness (ADR-0025) and a drafting-rule instrument vocabulary (ADR-0028). The new screens were built dormant; the live app stayed on the 4-tab `ContentView` (Program / Workout / Progress / Settings). The go-live flip was prepared but never merged.

On a hands-on review of the built screens (flag flipped locally), the new UI was rejected:

- **Progress** rendered as an almost-empty screen — the title and a single stray "floor-spine" tick floating in a void, no empty state.
- **Train** — the program "calendar" — shipped **placeholder copy** that escaped into the UI ("numbers placed closer to the day", "PLACED ABOVE · SHAPE BELOW"), and the far-future "to-be-placed" days drew as a full-bleed **diagonal hatch** that reads as a rendering glitch rather than a schedule. It did not read as a calendar at all.
- **Today** truncated exercise names to uselessness ("Dumbbell…", "Incline D…").
- The design's signature **cream "paper"** identity never even appeared, because the device follows system appearance and runs in dark mode — so only the unflattering dim variant was ever seen.

The user's verdict: the built UI lacked the finish and seamlessness of the live 4-tab app. The gap between the (genuinely thorough) locked specs and the unpolished build was the deciding factor — this was not a near-miss to ship.

## Decision

Abandon the Phase 3 UI overhaul and remove its code:

- Delete `AppShell`, the new `Today` / `Train` (program day-spine) / `Progress` (capability ledger) / `LiveLoop` screens and their hosts, `CoachLineRules`, and the pure-Swift `DesignSystem` module (theme tokens, typography, layout/motion/haptics, and the drawn instruments: capability band, lens, drafting-rule, status-tick, token gallery).
- Delete the embedded fonts (Space Grotesk / Inter) — the live UI uses system fonts.
- Delete the snapshot-visual-regression harness and drop the `swift-snapshot-testing` SPM dependency (its only consumers were the removed instrument tests).
- Delete all associated unit/snapshot tests.
- Remove the `useNewShell` flag and the shell switch from `ProjectApexApp` — the app renders `ContentView` unconditionally — and drop the now-orphaned font registration and theme-root modifier.
- Remove the dead **Appearance** (System / Light / Dim) setting, whose only consumer was the deleted theme root; the app remains dark-only (`.preferredColorScheme(.dark)` throughout).

**Kept (not UI chrome).** The redesign-era *backend/domain* features that the live 4-tab UI depends on stay: the per-axis confidence lifecycle (ADR-0020), calibration-review projections (ADR-0021), goal renegotiation (ADR-0022), and capability-driven recalibration (ADR-0023), together with their PreWorkout banners and review screens (CalibrationReview / GoalReview). These are features, not new-UI chrome.

**Test coverage.** The launch/setup-gate unit test (which pins the *production* `AppLaunchGate` predicate, #421) lived inside the deleted `AppShellMachineryTests`; it is re-homed verbatim to a new `AppLaunchGateTests`. The other deleted tests covered deleted code only.

**Specs archived, not deleted.** `DESIGN.md` and `docs/design/` move to `docs/archive/` so the design thinking (the coach-voice honesty constitution, the capability-band visualization, the per-screen specs) stays available if any idea is revisited.

## Consequences

- The app is back to the known-good 4-tab `ContentView`, which is polished and battle-tested. No user-facing behaviour changes (the new UI was never live).
- We lose the new UI's strongest ideas on the home/progress surfaces — the grounded coach voice and the capability-band-over-time visualization. If the UI is reattempted, the archived specs are the starting point, and the lesson is explicit: the purity bets (cream/light default, no colour-coding, the hatch / "drawn-confidence" vocabulary, removing streaks/percentages) read as unfinished or broken in practice and need rework before another build.
- ~9,000 lines of source + tests removed; one SPM dependency dropped.
- ADR-0003 / 0024 / 0025 / 0026 / 0028 are superseded (history retained per the append-only convention).
