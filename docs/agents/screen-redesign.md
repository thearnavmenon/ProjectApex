# Screen redesign — orchestrated UI redesign playbook

The repeatable flow for redesigning **any** screen or group of screens (Progress, Today, onboarding, settings, future features) to a single cohesive identity. This is the method used for the 2026‑06‑18 workout‑screen redesign (umbrella #473); reuse it wholesale.

**Shape:** inspiration → prototype in an isolated harness → user picks a direction → foundation‑first design system → per‑screen agent fan‑out → build‑verify → merge. The orchestrator (you, the main session) never lets unreviewed/unbuilt code reach `main`.

Trigger phrases: "redesign the X screen(s)", "make X match our design", "use our redesign flow on X", `/screen-redesign`.

---

## Reuse these — they already exist

- **Design system (production):** `ProjectApex/DesignSystem/` — `ApexTheme.swift` + `ApexComponents.swift`. The **Brutalist Athletic** identity: pure black, condensed slab type (`.fontWidth(.condensed)` + `.black`), one volt‑lime accent on live/primary actions only, amber for paused, gold for PRs, tabular numerals. Public kit: `Apex` tokens, `ApexNumeral`, `ApexButton`, `apexCard()`, `ApexSectionLabel`, `ApexTagChip`, `ApexMetricPill`, `ApexRing`, `WeightParts`. **Extend this; do not reinvent tokens.**
- **Prototype harness:** `UIPrototypes/ApexUIProto.xcodeproj` — a git‑ignored standalone SwiftUI simulator app with a `protoScreen(name, dir)` router and an interactive gallery (`ProtoIndexView`). Plus the render gallery `UIPrototypes/renders/index.html`. **Always prototype here and keep the gallery updated** (see the `feedback_ui_prototype_harness` memory). New `.swift` files in `UIPrototypes/ApexUIProto/` auto‑compile (file‑system‑synchronized group).

---

## Phase 0 — Scope & identity mode

1. List the target screens; map each to its **production file(s)** (grep `struct … : View`).
2. Decide the identity mode:
   - **Extend** the established Brutalist system (default — keeps the app cohesive). Skip Phase 1; reuse the design system as‑is.
   - **Explore** a fresh identity (only if the user wants a genuinely different look). Run Phase 1.

---

## Phase 1 — Inspiration (only when exploring a new identity)

- Use the **Mobbin MCP** (`mcp__mobbin__search_screens`, `platform: ios`, `mode: deep`). Look **broadly across categories**, not just the app's domain — every app is fair inspiration.
- Fan out **parallel background agents** (Agent tool), one per pattern‑cluster (e.g. hero/metric + numeric entry; timers/live/paused; summary/recap/streak; sheets/selectors/rows; overall visual identity). Each agent: load Mobbin via `ToolSearch`, **examine the returned images**, and return a tight report — top picks with `mobbin_url` links, "what to borrow", anti‑patterns. (Fan‑out keeps image tokens out of the orchestrator's context.)
- Synthesize **2–3 named, genuinely divergent directions** (color w/ hex, typography, depth/material, motion, anchor references). Present them; let the user choose.

---

## Phase 2 — Prototype + render gallery (always)

1. Build prototype screens in `UIPrototypes/ApexUIProto/` — one file per screen, self‑contained **mock data**, no app dependencies. Register each in the `protoScreen` router and the gallery list.
2. Build: `xcodebuild build -project UIPrototypes/ApexUIProto.xcodeproj -scheme ApexUIProto -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' CODE_SIGNING_ALLOWED=NO` — run as a **background Bash job**, poll the log. (**OS=26.5** — CI's 26.2 is not installed locally; xcodebuild exits 70 otherwise.)
3. Render each screen: `SIMCTL_CHILD_PROTO_SCREEN=<key> xcrun simctl launch booted <bundleid>` then `xcrun simctl io booted screenshot out.png`. A cold start can capture a blank first frame — re‑shoot if blank.
4. Update `UIPrototypes/renders/index.html` and present the gallery. **Get the user to pick a direction before writing any production code.** This is the gate the prior (abandoned) redesign skipped.

---

## Phase 3 — Implement (foundation‑first, then fan out)

### 3a. Foundation (only if new tokens/components are needed)
Extend `ProjectApex/DesignSystem/` **additively**. Files under `ProjectApex/` auto‑compile (no `.xcodeproj` edits — `PBXFileSystemSynchronizedRootGroup`). One PR; **merge before any screen** (everything depends on it).

### 3b. Per‑screen fan‑out
- Open an **umbrella issue**; each PR references it (`Part of #N`, never `Closes` until the user signs off).
- One **agent per screen** in an isolated worktree (Agent tool, `isolation: "worktree"`, `run_in_background: true`), one PR each.
- Run in **controlled batches of ~3** — a dozen concurrent full‑app builds thrash the machine and is counter‑productive.
- Use the **agent prompt template** below.

---

## Orchestrator duties (the main session owns these)

- **Build‑verify the slices agents couldn't.** Many worktree agents have `xcodebuild` **permission‑DENIED** and will say so; some build fine. Build the denied ones yourself before merging: `xcodebuild build -project <wt>/ProjectApex.xcodeproj -scheme ProjectApex -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath <wt>/.build CODE_SIGNING_ALLOWED=NO` (copy `APIKeys.xcconfig` into the worktree first — see gotchas).
- **Finish stalled agents.** Some agents come to rest *mid‑build* without committing/PR‑ing. Inspect the worktree (`git -C <wt> status/log`): if edited‑but‑uncommitted → build‑verify, then `git -C <wt> add/commit/push` + `gh pr create`; if committed‑but‑no‑PR → just create the PR. **`SendMessage` to resume an agent is NOT available** in this harness.
- **Guard intent over the prototype.** Where the prototype idealizes something that conflicts with the real screen's deliberate behaviour/safety (e.g. making a *permanent/destructive* action the bright primary), **preserve the real intent and flag it** — don't ship the prototype's version silently. (Real incident: the weight‑correction sheet — session‑only must stay the prominent, safe default.)
- **Merge on green:** `gh pr merge <n> --squash --admin --delete-branch` (standing merge autonomy; don't block on the iOS Build & Test flake). **Verify** `gh pr view <n> --json state` shows `MERGED` before deleting/relying; then `git worktree remove <wt> --force`.
- **Final pass:** one whole‑app integration build; real‑app screenshots of a couple of representative screens (see the screenshot trick); a per‑wave **diary** entry; an umbrella‑issue completion comment listing PRs + flagged design‑calls; keep `UIPrototypes/` + `renders/index.html` updated; update the project memory.

---

## Agent prompt template (per screen)

Fill the bracketed bits per screen. Keep every screen's PR to **one file** where possible.

```
You are implementing a slice of the approved "<IDENTITY>" redesign for the iOS SwiftUI app ProjectApex (umbrella #<N>). You run in an isolated git worktree off main, which already has the merged design system at ProjectApex/DesignSystem/ and several already-restyled screens (skim one for the established style).

YOUR SCREEN: <name> — restyle ProjectApex/Features/<path>/<File>.swift.

READ FIRST: (1) the real screen fully; (2) the approved target look by ABSOLUTE path /Users/arnav/Desktop/ProjectApex/UIPrototypes/ApexUIProto/<Proto>.swift (git-ignored — read at the absolute path, it is NOT in your worktree); (3) ProjectApex/DesignSystem/ApexTheme.swift + ApexComponents.swift.

HARD RULES:
- Restyle the VISUAL layer only. Preserve ALL behaviour/logic/state/bindings/init API/accessibility/navigation. Specifically keep: <list the real screen's interactions/gates/callbacks>.
- The prototype is the VISUAL target, NOT a feature spec. Render only data/affordances the real screen actually has; if the prototype shows something the real screen lacks (or vice versa), preserve the real behaviour and FLAG the gap — do not invent data or add new behaviour.
- Use the design system (Apex*, apexCard, ApexNumeral, …); do not redefine tokens. Pure black bg; lime accent only on the live/primary action. Be surgical.

BUILD & VERIFY:
- If <worktree-root>/APIKeys.xcconfig is missing: cp /Users/arnav/Desktop/ProjectApex/APIKeys.xcconfig <worktree-root>/
- Run xcodebuild as a BACKGROUND bash job + poll the log (never foreground/quiet — it can be killed):
  xcodebuild build -project <worktree-root>/ProjectApex.xcodeproj -scheme ProjectApex -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath <worktree-root>/.build CODE_SIGNING_ALLOWED=NO
  Rebuild until ** BUILD SUCCEEDED **. If your environment DENIES xcodebuild, say so explicitly so the orchestrator builds it.

GIT/PR: worktree off main; use git -C <root> for ALL git. Do NOT touch DIARY.md. Commit (end the message with "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"), push, and OPEN THE PR (gh pr create) titled "feat(#<N>): <identity> <screen>", body ending "Part of #<N>". DO NOT merge.

REPORT BACK (raw facts): branch + PR URL; build result (or "xcodebuild denied"); a checklist confirming each preserved interaction; which prototype features you did NOT add; anything needing a human eye.
```

---

## Real‑app screenshot trick (for deep‑flow screens)

Production screens live deep in the app flow, so headless capture needs a temporary hook:

1. In a worktree (or a temporary **uncommitted** edit on `main`), add an env‑gated branch at the top of `ProjectApexApp.swift`'s `WindowGroup`: when `SCREENSHOT_SCREEN` is set, render the target screen with mock data instead of the normal root. Reuse the screen's own `#Preview` construction for the mocks.
2. Build **Debug** (`#if DEBUG` mock helpers like `WorkoutViewModel.mockActive()` are only present in Debug). This build doubles as an integration check.
3. `xcrun simctl install … && SIMCTL_CHILD_SCREENSHOT_SCREEN=<key> xcrun simctl launch …`, `sleep ~3`, `xcrun simctl io booted screenshot`.
4. **Revert the hook** (`git checkout -- ProjectApex/ProjectApexApp.swift`) — it must never be committed.

---

## Gotchas (hard‑won)

- **OS=26.5** for every local/agent build (CI pins 26.2, not installed here).
- Fresh worktrees lack the git‑ignored **`APIKeys.xcconfig`** → copy it from the main checkout before building.
- **`UIPrototypes/` is git‑ignored** → agents must read prototype files by **absolute path** (`/Users/arnav/Desktop/ProjectApex/UIPrototypes/…`), not from their worktree.
- Do **not** run `xcodebuild` inside a Workflow subagent (3‑min stall‑detector kills it). Use the Agent tool + background Bash builds.
- Some worktree agents can't run `xcodebuild` at all (sandbox) → orchestrator build‑verifies those.
- Reading PNGs: once the context holds many images, single reads only and **downscale** (`sips -Z 1500`) — images taller than 2000px are rejected for multi‑image requests.
- Production restyles **drop the prototype's `Direction` parameter** (prod = one baked identity).
- Leftover unused `streak`/`tintColor` params are fine to retain to keep call‑sites/inits stable (trivial later cleanup).

---

## Bookkeeping

- Umbrella issue: `Part of #N` on each PR; **close on the user's visual sign‑off, not before** (process commitment 1).
- Per‑wave **DIARY.md** entry (plain words; the problem, what changed, how checked, PR/issue numbers).
- Keep `UIPrototypes/` + `renders/index.html` updated — part of "done" for any UI change.
- Update the relevant project memory (status, learnings).
