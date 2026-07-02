# Build / render / test / ship — the canonical recipe

One place for the xcodebuild/simctl/PR recipe that used to be re-derived from
scratch almost every session. The `scripts/` helpers below encode it so you
don't. Prefer them over hand-typed `xcodebuild`/`simctl`/`gh` incantations.

All scripts live in `scripts/` and are checked in. They work from the main
checkout **and** from a `.claude/worktrees/*` worktree (they resolve their own
root from `$0`), so an agent in a worktree runs the same command.

## `scripts/apex-build.sh [build|test] [--only-testing X ...]`

Builds or tests the app. What it pins so you never re-derive it:

- **scheme** `ProjectApex`, **config** Debug, `CODE_SIGNING_ALLOWED=NO`.
- **one concrete simulator UDID** — newest installed iOS runtime, an
  already-booted `iPhone 17 Pro` preferred. Used for `-destination id=<udid>`.
  This kills the recurring *build-OS vs booted-sim mismatch* and the stale
  hardcoded-UDID problem.
- `-derivedDataPath <root>/.build` — never pollutes the global DerivedData cache.
- copies the git-ignored `APIKeys.xcconfig` into a fresh worktree if missing.
- **free-disk preflight**: warns under 8 GB; purges the *global* Xcode
  DerivedData cache (a pure rebuildable cache) under a 4 GB floor. ENOSPC once
  caused real data loss mid-orchestration; this is the guard.

Runs `xcodebuild` in the foreground, teeing to a timestamped log under
`.build/logs/`. The **first line printed is `LOG: <path>`**. Run the script
itself as a **background Bash job** and tail/Monitor that log — never foreground
a long build with `-quiet`, it can be killed.

```bash
scripts/apex-build.sh build
scripts/apex-build.sh test --only-testing ProjectApexTests/WorkoutSessionManagerTests
```

Env: `APEX_SIM_NAME` (default `iPhone 17 Pro`), `APEX_MAIN_REPO`.

## `scripts/apex-render.sh <app|PROTO_SCREEN> [--out DIR]`

Build → install the **freshest `.app` by mtime** (not `head -1`, which grabbed a
stale DerivedData dir and cost days of re-render loops) → launch → screenshot →
`sips -Z 1400`. Screenshots land in `--out` (default `./renders`).

- `app` renders the real `ProjectApex` app (bundle id read from the built
  `.app`, so no hardcoding).
- any other key renders `UIPrototypes/ApexUIProto` with
  `SIMCTL_CHILD_PROTO_SCREEN=<key>` — the redesign-harness convention. Errors
  cleanly if the prototype project isn't present.

```bash
scripts/apex-render.sh app
scripts/apex-render.sh navbarlive --out UIPrototypes/renders
```

## `scripts/ship-pr.sh [<branch>|<worktree-path>] [--title T --body B]`

push → create PR (standard Claude Code trailer) → wait on required checks
**ignoring the known flaky `iOS Build & Test` check** → `gh pr merge --squash
--admin --delete-branch` → prune the worktree if one was passed.

Merge autonomy is durably granted (memory `feedback_merge_autonomy`), so this
admin-merges on green without asking. It **aborts** if a *non-ignored* check
fails. Override the flake pattern with `APEX_FLAKY_CHECK` (regex).

```bash
scripts/ship-pr.sh                                   # current branch
scripts/ship-pr.sh .claude/worktrees/slice-3-foo     # a worktree, pruned after merge
```

## `scripts/deploy-efs.sh [names… | --all]`

Deploys the Supabase Edge Functions **changed vs `origin/main`** (or the ones you
name, or `--all`). Edge Functions deploy manually and often; this removes the
"OWNER must deploy X" hand-step. Needs the Supabase CLI logged in + project
linked; secrets stay in Supabase-managed env vars, never on disk. See
`docs/agents/edge-functions.md`.

## `scripts/apex-status.sh`

One "what's left?" rollup: open PRs + their check state, open issues (umbrellas
first), the BACKLOG §2D things-to-do, recent commits. Read-only; the model
reading the dump does the synthesis.

## Hard-won constants (don't re-learn these)

- Build **`OS=26.5`** locally (CI pins 26.2, which isn't installed here;
  `xcodebuild` exits 70 on a missing runtime). The scripts sidestep this by
  targeting a real device UDID instead of an `OS=` string.
- Fresh worktrees lack the git-ignored **`APIKeys.xcconfig`** → the scripts copy
  it from `APEX_MAIN_REPO`.
- Do **not** run `xcodebuild` inside a Workflow subagent (3-min stall-detector
  kills it). Use the Agent tool + background Bash builds, or these scripts.
- `.build/` (local derivedDataPath) is git-ignored.
