# Snapshot / visual-regression harness for the rebuild's drawn instruments

**Status**: accepted, 2026-06-11

**Relates to**: [ADR-0024](0024-pure-swift-design-system-foundation.md) (the token + font foundation this depends on) and `DESIGN.md` (Data visualization / Motion). Decided for [#342](https://github.com/thearnavmenon/ProjectApex/issues/342) via a three-advisor panel (test-infra / CI-determinism / SwiftUI-rendering) + an independent reviewer + a capstone coherence review.

## Context

The rebuild introduces ~10 bespoke **drawn instruments** (capability band, floor staircase, Lens iris, day-spine, day-status tick vocabulary, root-spine rows) whose correctness is **geometric and token-precise** and invisible in code review: solid-vs-hollow dot = measured-vs-estimated, dashed-4-2 = projection, 2px floor tick vs 1px stretch tick, "single ink" with a mandatory dim remap. The repo has a plain Xcode project (`objectVersion 77`, **0 SPM deps**, no `Package.resolved`), a **hosted** test target already mixing XCTest + Swift Testing, CI hard-pinned to Xcode 26.3 / iPhone 17 Pro / iOS 26.2, a known-flaky iOS suite the team **admin-merges past**, and a parallel session incrementally rebuilding the shell.

## Decision

Adopt **pointfreeco/swift-snapshot-testing** (pin `.exact` 1.17+, the line with first-class Swift Testing support) as an `XCRemoteSwiftPackageReference` added directly to `ProjectApex.xcodeproj` (no `.xcworkspace` migration — `objectVersion 77` supports this), linked **only** to `ProjectApexTests`, with `Package.resolved` committed. Drive it from `@Test` via `assertSnapshot(of: UIHostingController, as: .image(...))` — **one rendering route** (UIHostingController), never mixed with `ImageRenderer`.

- **Two layers, not one.** (1) a thin **image-snapshot** layer over the ~10 instruments for holistic layout + token/hue verification; (2) a **larger** body of cheap deterministic non-image `@Test` assertions (Path geometry, tick weights, dot fill-vs-stroke, dash pattern, resolved token color) — because the honesty invariants must hold at **every** Dynamic-Type size + appearance, and a pixel test proves only one.
- **Matrix.** Per instrument: `{light, dim} × {default @ .large, one AX anchor}` ≈ 4 image refs + one confidence pair (measured vs estimated) + a degraded-layout case only for the two hero-num/display-bearing instruments. Render at a **fixed `CGSize` per instrument, never a full screen** (isolates each instrument from the parallel session's shell churn — the single biggest flake/maintenance win). References live committed under `ProjectApexTests/__Snapshots__/`. ≈40–60 PNGs, PR-reviewable.
- **Motion: structural, not temporal.** Each instrument is an animation-free value-driven View whose entrance is applied by a **separate wrapper** (a #342 component-architecture constraint imposed on every instrument slice). Snapshot the **bare end-state with animations disabled** → "frame-1 == end-state" by construction (no RunLoop spin, no spring-scrubbing flake). Reduce Motion: inject `accessibilityReduceMotion = true` and assert the image is **byte-identical** to the normal end-state (its contract is "150ms crossfade to the same destination"). The one motion-bearing moment (milestone ratchet) is spec-quarantined (witness rule) and never enters the snapshot surface.
- **Determinism.** Inherit the existing CI pin (reuse the scheme/testplan/destination — do **not** fork a scheme). `precision ≈ 0.99`, `perceptualPrecision ≈ 0.98` (deltaE; never 1.0 — absorbs sub-pixel AA jitter while still failing on a wrong ink). **Record references on the CI-pinned toolchain (Xcode 26.3), not a dev Mac** (local 26.5 skew is the #1 cross-machine flake). A CI guard fails if record-mode is left on. A precondition `@Test` asserts `UIFont(name:)` for both faces resolves (else references silently encode San Francisco). A deliberate hue-swap negative test (`#1B2CFF` vs `#1322CC`) proves the tolerance still catches a wrong ink.
- **Gating.** The **image** layer runs behind an opt-in `APEX_SNAPSHOT_TESTS` gate (mirroring `APEX_INTEGRATION_TESTS`) so a font-render nudge can't be auto-merged-past in the mandatory path — but it reuses the existing pinned scheme so it can't silently rot.

### Hard prerequisite (capstone)

**Do not record any reference image until [ADR-0024](0024-pure-swift-design-system-foundation.md) has landed centralized color tokens — including the data-viz token family — AND embedded/registered both fonts.** References baked before then encode San Francisco and the 236 legacy colors and would mass-rebaseline on consolidation. **#342 strictly depends on #341.**

### #342 owns the `APEX_INTEGRATION_TESTS` cleanup (capstone)

Verified contradiction: `ProjectApex.xctestplan` sets `APEX_INTEGRATION_TESTS=1` while `ci.yml`'s comment claims it is "intentionally absent." Because #342 copies that env-gate **pattern** for `APEX_SNAPSHOT_TESTS` and its no-flake-in-the-mandatory-path guarantee depends on the gate actually working, **#342 owns reconciling this** (verify the gate truly toggles in CI) before recording any reference.

## Consequences

- The project gains its **first third-party SPM dependency**; `Package.resolved` is committed and the CI `-resolvePackageDependencies` step (currently a no-op) becomes load-bearing. Mitigated by exact-pin + committed lock.
- Every drawn instrument must be authored animation-free with a separate entrance wrapper — a real cross-slice architecture constraint, flagged to whoever scopes the instrument slices.
- Two layers to maintain: ~40–60 reference PNGs (regenerated by **one owner** on the pinned toolchain per slice) + a larger fast geometry/token assertion body (the primary net for per-DT invariants).
- Blast-radius coupling to the iOS 26.2 runtime: a runner-image rotation breaks all references at once — watch CI runtime announcements.

## Alternatives rejected

- **Homegrown `ImageRenderer` + hand-rolled deltaE diff (zero deps).** Its premise that `assertSnapshot` is "XCTest-shaped" is factually wrong in 1.17+; the hard part (perceptual tolerance, AA/color-space normalization, record/compare UX) is identical hosting code either way and would be a fresh flake source for a team that admin-merges past flakes. *Its correct insight — instruments must be Canvas/Path, never Swift Charts (the legacy `.catmullRom`+green chart is the no-slope-law violation being deleted) — is adopted as **what** we render, not the diff engine.*
- **Swift Testing Attachments alone** — a diagnostics channel, not an assertion; adopted only as a complement (attach failing actual+diff to the xcresult).
- **Ungated in the mandatory plan / a forked scheme** — ungated gets auto-merged-past; a forked scheme rots and duplicates CI surface.
- **Whole-screen / full-Dynamic-Type-axis snapshots** — whole-screen references are invalidated by the parallel session's shell churn; the full DT axis explodes to ~200 brittle PNGs and still under-tests the per-size invariants (covered by geometry assertions instead).

## Open questions for the human (HITL)

- Confirm #341 is the explicit `depends-on` anchor for the reference-recording prerequisite (it is filed and #342 is blocked-by it).
- **Reference-recording ownership**: a CI "record mode" job, or one machine pinned to Xcode 26.3 for recording? (Your local is 26.5.)
- Confirm comfort with the **first third-party SPM dependency** (exact-pin + committed lock is the mitigation).
- Reconcile the `APEX_INTEGRATION_TESTS` testplan-vs-`ci.yml` contradiction as part of #342, or file as a spinoff (must be resolved before #342 records references either way).

*Advisor dissent recorded: advisor 3 (homegrown) overruled on a factual error + flake-source grounds, but its two correct points (Canvas/Path not Swift Charts; one fixed rendering route) are adopted. Advisors 1 vs 2 split on CI gating; sided with gating-out (admin-merge-past-flake autonomy) while keeping the shared pinned scheme.*
