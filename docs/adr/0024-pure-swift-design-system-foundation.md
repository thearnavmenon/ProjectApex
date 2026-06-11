# Pure-Swift design-system foundation for the Phase 3 UI rebuild

**Status**: accepted, 2026-06-11

**Relates to**: `DESIGN.md` (the locked token spec this turns into code) and `docs/design/ui-overhaul-spec.md` §10 (the implementation phase). Decided for [#341](https://github.com/thearnavmenon/ProjectApex/issues/341) via a three-advisor panel (iOS-platform-idioms / design-tokens / testability) + an independent reviewer + a capstone coherence review. Gates [#342](https://github.com/thearnavmenon/ProjectApex/issues/342) (snapshot harness) and [#343](https://github.com/thearnavmenon/ProjectApex/issues/343) (shell chrome).

## Context

`DESIGN.md` is locked and comprehensive, but **none of it is in Swift**: there is no design-token layer, ~236 hardcoded `Color(red:…)` sites, an empty `AccentColor.colorset`, and Space Grotesk / Inter are **not embedded** (verified: no `.ttf`/`.otf`, no `UIAppFonts`). The dim variant in `DESIGN.md` is a **non-uniform remap** (e.g. the small-scale accent cut lifts to `#7B85FF`, band fill goes 8%→12%, hollow-dot stroke flips). The app target is a single `PBXFileSystemSynchronizedRootGroup` (adding Swift files does **not** touch `project.pbxproj`); the test target lists files individually. A parallel dev session is actively editing the same checkout. Tests are Apple Swift Testing on a hosted target.

## Decision

A **pure-Swift** design-system module at `ProjectApex/DesignSystem/`. **Foundation only — migrate zero of the 236 legacy color sites** (incremental rollout; old + new coexist).

- **Color: pure-Swift tokens, no role colorsets.** The non-uniform dim remap makes asset-catalog colorsets unreadable as a source of truth, and pure Swift exposes sRGB component values to **headless** unit tests (no UI host needed). Colors are delivered via a `Theme` injected through the **Environment**; dim is **one enum, two tables, explicit `Appearance`** (the remap is not a separate design — it is the same roles, re-tabulated; re-inject across `fullScreenCover`/sheet boundaries).
- **Accent split, enforced at compile time (P0-4).** Two roles: a **fill-only `ShapeStyle`** (the bright `accent #1B2CFF`, for large fills/floods/gauge fill) and a **text-ink role with no bright-accent case** (`accent-ink #1322CC`). Bright accent has no path to text — a misuse is a compile error, not a lint.
- **Accent-ink is reusable as a stroke/dot value (capstone amendment).** The "no bright-accent text" guard governs the **text role only**; the underlying `accent-ink` value is the sanctioned color for **drawn-instrument strokes/dots/lines** (2pt series line, 5pt list-scale dot). Only band/large-shape **fills** use the bright-accent `ShapeStyle`. This keeps P0-4 intact while giving the instruments a home that doesn't blur the split.
- **Data-viz token family is part of this foundation (capstone amendment — the blocking item).** The foundation **must** ship the eight `data-viz` tokens (`series-primary`, `series-compare`, `band` fill+opacity, `projection` dash 4-2, `point-measured`, `point-estimated`, `axis`) **and** their `data-viz-dim` remap (`#7B85FF` line, `#7B85FF`@12% band, hollow-dot stroke flip), **plus the shared geometric constants** (floor tick 2px, stretch tick 1px, list-scale dot 5pt, dash 4-2). Without these, #342's instrument references have no token source to verify against, so #342's "the foundation has landed centralized color tokens" precondition becomes unverifiable. The single test file adds a data-viz resolution + distinctness assertion so the precondition is mechanically checkable.
- **Typography: runtime registration, not the build-setting key.** Embed Space Grotesk + Inter under `Resources/Fonts/` and register them at launch via `CTFontManagerRegisterFontsForURL`. The `UIAppFonts`/build-setting route writes `project.pbxproj` and would collide with the parallel session. Fonts are exposed as typed tokens, **relative-to-text-style** (Dynamic Type), with `hero-num`/`display` **capped at 1.3×** and **tabular figures baked in**; numbers never ellipsize (spec law).
- **Structure + API.** `Theme` (color) via Environment because color is the only thing that varies at runtime; everything else (spacing, shape, type, motion, haptic constants) as **static namespaced enums**. The "work is ink, time is pencil" (+ plan-is-pencil) two-tone helper lives here. Build **only the one mandated shared component the spec names** at foundation scope — nothing speculative.
- **Testing: one file.** Token resolution, dim distinctness (same role → distinct values), AA contrast assertion (`accent-ink` ≥4.5:1 on `paper`; bright accent never reachable as text), data-viz token resolution/distinctness, and typography (relative scaling, 1.3× cap, tabular). Pure-Swift makes the contrast/honesty rules **executable**.

## Consequences

- New screens inherit dim, AA, and accent-never-as-text **for free**; the legacy 236 sites are untouched and both coexist until the close-out slice.
- The `DESIGN.md` hex values become **executable fixtures** — a wrong ink fails a test.
- Slightly more ceremony at fill sites (two accent roles to choose between) — the deliberate cost of structural P0-4.
- Fonts require verified, license-cleared faces that ship tabular figures (see open questions).
- This foundation is the **hard gate** for #342 (no reference recorded before tokens + fonts land) and the chrome-token source for #343.

## Alternatives rejected

- **Asset-catalog-first / hybrid colors** — the non-uniform dim forces per-color overrides, can't be unit-tested without a UI host, and degrades "never-as-text" from a compile error to a convention; a hybrid adds a second, desyncable source of truth.
- **Build-setting `UIAppFonts` key** — writes `project.pbxproj` and conflicts with the parallel session. (Kept as a fallback only if runtime registration proves unreliable.)
- **Migrating any of the 236 sites in #341** — violates the incremental rollout and collides with the parallel session.

## Open questions for the human (HITL)

- **Fonts**: confirm Space Grotesk + Inter are license-cleared for embedding and that the chosen faces ship true tabular figures. (Until the `.ttf`/`.otf` files exist, the typography half of #341 cannot complete — this is the one real blocker on starting #341.)
- **Dim override**: ship a Settings dim/appearance override in #341, or defer to the Settings slice (follow system appearance only for now)?
- **Accent asset**: populate `AccentColor.colorset` as a mirror of the token, or leave it empty?
- **Test framework**: confirm new tests use Apple Swift Testing (the modern half of the mixed target).

*Advisor dissent recorded: advisors 1 & 2 preferred the build-setting font key; overruled for runtime registration to avoid the pbxproj conflict (kept as fallback).*
