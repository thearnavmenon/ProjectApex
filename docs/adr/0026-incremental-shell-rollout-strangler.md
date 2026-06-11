# Incremental 3-tab shell rollout: a frozen-ContentView strangler

**Status**: accepted, 2026-06-11

**Relates to**: `docs/design/ui-overhaul-spec.md` §2 (3-tab nav) and [ADR-0024](0024-pure-swift-design-system-foundation.md) (the chrome tokens the shell consumes). Decided for [#343](https://github.com/thearnavmenon/ProjectApex/issues/343) via a three-advisor panel (navigation-architecture / strangler-migration / app-state-DI) + an independent reviewer + a capstone coherence review.

## Context

The rebuild ships incrementally behind a new 3-tab shell (Today / Train / Progress + settings-in-a-corner), old screens live until each surface's slice merges, **while a parallel dev session edits the same checkout**. Verified constraints: `ContentView.swift` is 686 lines and co-locates the onboarding `fullScreenCover` gate, the crash-recovery alert chain, the paused-session banner + `navigationDestination`, and ~150 lines of fragile resume/orphan logic threaded through `selectedTab = 1` and the `workoutTab` builder. `switchToTab` is `(Int)->Void` with a no-op default and **exactly 2 external call sites** (`switchToTab(1)` "Continue Workout" → live `WorkoutView`; `switchToTab(3)` → Settings). The project uses `PBXFileSystemSynchronizedRootGroup` with **zero membership-exception sets** — adding new Swift files does **not** touch `project.pbxproj` (the classic additive-merge conflict is eliminated). Per `splash-today.md` the live loop "rises through" Start on Today (a pushed/covered surface), not a tab. `ContentView` is the single hottest file and the parallel campaign's active target.

## Decision

A **strangler-fig**: a new sibling root `AppShell.swift` renders the locked 3-tab chrome alongside an **untouched, frozen `ContentView.swift`**. Select between them with **one compile-time constant at the single entry seam** (`ProjectApexApp.body`: `useNewShell ? AppShell() : ContentView()`) — the entire shared-file edit in the bootstrap slice is that one line.

- **(a) Routing = code-as-switch.** A named per-surface `@ViewBuilder` per tab inside `AppShell`. "Is it built?" is expressed as the **literal presence of the new view's constructor** in the builder body — **not a stored flag** (a flag can be flipped before the view compiles → the exact dead pointer we must avoid; a builder branch cannot dangle). Until a surface's slice lands, its branch returns the **exact interim old view** ContentView already compiles (Train → existing Program surface; Progress → `ProgressTabView`; Today is net-new → an honest interim, see open questions). No registry/coordinator (speculative for 3 single-use surfaces).
- **(b) Re-home without breaking the fragile paths.** Today = net-new; Train = existing Program; Progress = existing Progress; the live loop stays a **pushed/covered surface, not a tab**; Settings leaves the tab bar for a corner gear presenting the existing settings root as a sheet. **Keep the raw-`Int` `switchToTab` contract** — the shell's injected closure **translates** legacy indices (1 → live-loop entry, 3 → present settings sheet) so the 2 feature-view call sites stay byte-identical. **Machinery-last**: leave the onboarding gate, crash-recovery, paused-session banner, and `ProgramViewModel` lifecycle exactly where they sit in ContentView during interim; lift them only when the live-loop/Train slice formally moves the `WorkoutView` host — as a dedicated, tested slice.
- **(c) Minimize merge surface.** All new code in **new files** (zero pbxproj churn, verified). The only shared-file edit in bootstrap is the one line in the 30-line `ProjectApexApp.swift`. **Freeze `ContentView.swift`** (no reformat, no "improve"); keep the 2 call sites byte-identical.
- **(d) Compile-time swap only — no runtime feature flag.** Single-cohort, incremental-but-user-visible rollout needs none of dark-launch / A-B / remote-kill. Reversal granularity is per-PR `git revert`. A runtime flag would add state to the area we are keeping cold and leave a second close-out target.

## Consequences

- The bootstrap slice edits **exactly one line** of one shared file; the parallel campaign rebases onto a trivial diff, not a 686-line collision.
- Interim duplication is avoided: the crash/paused/onboarding machinery exists **only** in ContentView (the shell embeds leaf views + the Int bridge), so there is no second copy to drift.
- The legacy `switchToTab(Int)` becomes a translation layer; a wrong mapping is a **silent mis-route, not a crash** — mitigated by a pure mapping unit test (Swift Testing).
- **Single-root invariant**: exactly one of `{ContentView, AppShell}` is ever mounted (the compile-time switch enforces it) — never embed one in the other, or onboarding/migration/crash alerts double-fire.
- **The close-out slice must be tracked from day one** ([#363](https://github.com/thearnavmenon/ProjectApex/issues/363)): delete the interim branches + `ContentView.swift` + the legacy Int key + bridge, migrate the 2 callers to a typed enum, flip the entry constant unconditionally. A strangler only pays off if the host is felled.
- Settings leaving the tab bar needs a grep-and-repoint sweep (`selectedTab = 3`, the program-complete "Go to Settings" button) — but most live inside frozen ContentView and stay on the old path during interim; only the new shell's settings affordance + the bridged `switchToTab(3)` need wiring in #343.

## Alternatives rejected

- **Edit `ContentView.swift` in place** (4→3 tags, inline flags) — all three advisors' strongest-alternative, all reject it: it races the parallel session on the hottest file, gives no single audit point for "what's still on fallback," and makes close-out an in-file untangle instead of "delete one file."
- **Migrate `switchToTab` → a typed `ApexTab` enum now** — type-safety is the right **close-out** move, but now it touches a shared `EnvironmentKey` read across feature views and races the parallel session; an Int bridge in one new file routes correctly with zero feature-file edits. Deferred, not discarded.
- **Move the crash/paused/onboarding machinery into the shell during interim** — the highest-stakes regression risk (resume is mandatory, spec §4; ~150 lines bound to `selectedTab=1`); machinery-last keeps every fragile wire co-located until a tested slice lifts it.
- **A per-surface routing enum/registry** — speculative configurability for 3 single-use surfaces; adds a second edit site + a dead-pointer class and a new shared object the parallel session might also reach for.
- **Any runtime feature flag / UserDefaults rollout toggle** — pure removable debt nobody asked for.

## Open questions for the human (HITL)

- **Design-token ordering (capstone-promoted):** the shell ships visible chrome (3-tab bar, settings gear) needing colors day one. Confirm [#341](https://github.com/thearnavmenon/ProjectApex/issues/341) (base color roles) lands as the precursor so the shell consumes named tokens from the start, rather than shipping interim hardcoded colors against the cream/ultramarine language.
- **Today interim content:** Today has no old equivalent and the data-honesty rule forbids a filler placeholder. Acceptable interim until the Today slice: render the existing next-workout/Program content, or a terse "next workout + Start" from the already-available `ProgramViewModel`?
- **Parallel-session handshake:** the bootstrap slice's one shared edit is `ProjectApexApp.swift`; worth a heads-up that this line changes and `ContentView.swift` is to stay frozen, so neither side reformats it.

*Advisor dissent recorded: advisor 1's enum-now + machinery-now moves overruled (race + regression risk); its grep-before-done discipline kept. Advisors 2 & 3 form the adopted spine; the synchronized-group pbxproj fact is the enabling premise.*
