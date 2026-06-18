# AI Co-Developer Instructions
1. **Strictly Non-Autonomous:** You are an assistant, not an autonomous agent. ONLY work on the specific task I explicitly assign to you. Do NOT automatically start the next task on the backlog.
2. **Context-Aware Coding:** Before writing code, consult the docs in the "Doc map" section below for the right canonical source. Don't grep `ARCHITECTURE.md` for current state — it's a Phase 1 reference, superseded by `CONTEXT.md` + `docs/adr/` for anything Phase 2.
3. **Slice completion tracking:** When I confirm a tracer-bullet slice is complete and working, close the corresponding GitHub issue with a completion comment summarising what shipped, any pre-deploy reminders, and links to spinoff issues. (The Slice 1 closure pattern in #2 is the precedent — issue closure happens via a merged PR's Closes #N keyword per Process commitment rule 1, not before.) `BACKLOG.md` is the long-form work log: append phase/slice entries to it when a phase or major slice closes, and mark the things-to-do in §2D when the dispatch surfaces new follow-ups. Sweep cadence applies (re-read on phase boundary, prune what reality has moved past). The pre-2026-06-01 prohibition on touching `BACKLOG.md` is retired — reality moved past it.
4. **Wait for Commands:** After completing a coding task or closing the slice issue, simply tell me it is done and wait for my next instruction. Do not proceed on your own.

## Doc map — where each kind of information lives

Each doc has one job. When you need an answer, go to the doc whose job covers it; when you change reality, update only that doc.

- **`CLAUDE.md`** (this file) — agent rules and conventions. Not project state.
- **`CONTEXT.md`** — current state of the project (domain language, architecture as it stands today, active conventions). Replace in place when reality changes; do not append historical layers.
- **`docs/adr/`** — append-only decision history. Each ADR captures *why* a decision was made and what it superseded. Old ADRs stay; supersession is via header link, not deletion.
- **GitHub issues (`thearnavmenon/ProjectApex`)** — in-flight and recently-closed work. Self-pruning on close.
- **`BACKLOG.md`** — long-form work log. Started as product-feature tracker (P0-T01, FB-XXX); evolved into the phase-by-phase log that records both shipped slices and open follow-ups (§2D in Phase 5 is the things-to-do section). Append on phase/slice closure; prune on sweep cadence.
- **`ARCHITECTURE.md`** — Phase 1 reference, kept for legacy services and UI/UX spec only. Has a staleness banner; do not treat as current for Phase 2.

**Sweep cadence.** At each phase or milestone boundary (e.g. when a Phase or major slice closes), re-read `CONTEXT.md` end-to-end and prune anything reality has moved past. If a fact is now wrong, replace it; if a decision motivated the change, append an ADR. Discipline is "prune on phase boundary," not "prune continuously."

## Process commitment

1. **Branch + commit per logical unit, PR-before-close.** Slice/issue work happens on a feature branch off `main`, never on `main` directly. Each logical unit gets its own commit and its own PR. GitHub issues close via the PR's Closes #N keyword on merge — never via standalone close-comment before the work is committed and merged. *Motivating failure (6h-19m incident):* four logical units (Slice 5, #23, #24.1, #24.2) conflated into a single uncommitted working-tree state on `main`, with issue #4 closed prematurely via a celebratory comment that pointed at no commit, no PR, and nothing on `origin/main`.

2. **Cross-cutting grep is grep-and-report, not grep-and-rewrite.** When the "Cross-cutting fixes — grep before declaring done" section below surfaces additional sites, list them with a recommendation and wait for explicit authorization before editing. The grep section finds the sites; this rule constrains what to do with them. *Motivating failure (four-cosmetic-test-files incident):* agent grepped for `URLError` mocks during #24.2, found four, edited all four without authorization. Three of the four had not been authorized — they were unilateral "consistency" rewrites of tests that were already passing.

3. **Surface ambiguity, don't fill it silently.** When an instruction has a hole or an "or" with an unspecified default, surface the ambiguity and ask before acting on a unilateral interpretation. Absence of explicit prohibition is not authorization. *Motivating failure (ADR-0007 form decision):* the directive "amend ADR-0001 or whichever ADR codifies no-silent-fallbacks" had a hole when grep showed no ADR explicitly codified the principle, and the agent unilaterally chose new-ADR rather than asking.

## Cross-cutting fixes — grep before declaring done

When the fix is to a *pattern* rather than a single call site (test-harness bugs, Codable shape changes, retry-policy adjustments, lifecycle hooks, etc.), grep the codebase for every occurrence of that pattern before declaring the fix complete — not just the file that triggered the investigation. A near-miss happened in #23: the H1 stream-drain fix landed in `MockURLProtocol`, but `WAQMockURLProtocol` had identical code with the same bug; only a full-suite run caught it. The lesson: when the change is structural, the search radius is the whole codebase.

Practical form: after writing the fix, grep for the pattern that motivated it (e.g. `request.httpBody` for URLProtocol mocks, `static var.*Handler` for shared mock state, `weightKg >=` for validation predicates) and confirm every hit either uses the fix or has a documented reason to differ. Report the grep result alongside the fix, not after the user notices the second site.

## Agent skills

### Issue tracker

GitHub Issues on `thearnavmenon/ProjectApex` via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Screen redesign (orchestrated UI)

The repeatable flow for redesigning any screen(s) to a cohesive identity: Mobbin inspiration → isolated prototype harness + render gallery → user picks a direction → foundation-first design system → per-screen agent fan-out (worktrees, one PR each) → orchestrator build-verifies/merges. Reuses `ProjectApex/DesignSystem/` and the `UIPrototypes/` harness. Established 2026-06-18 (Brutalist workout redesign, #473). See `docs/agents/screen-redesign.md`.

### Edge Function secrets

Authoritative for Edge Function secret storage, service-role access list, and key rotation policy. Read before any Slice 9b+ Edge Function work — do not redo the analysis from scratch. See `docs/agents/edge-functions.md`.

### Migrations workflow

Forward migrations live in `supabase/migrations/`, created via `supabase migration new <name>` and applied via `supabase db push` (forward-only; the runner scans every `*.sql` under that directory and registers it against `supabase_migrations.schema_migrations`).

Reverse migrations live in `docs/migrations/down/<matching-filename>.sql` — same filename as the forward migration, in a path the Supabase tooling does not scan. Documentation only, not auto-applied; intended for manual operator use (`psql -f`) when a forward migration needs to be rolled back. Living under `docs/` matches the role: rarely run at alpha-cohort scale, useful as a "here's how to roll this back" reference (same way ADRs are reference docs).

Each forward migration's first lines must include the pointer comment:

```sql
-- Reverse migration: docs/migrations/down/<this-filename>.sql
-- (documentation only; not auto-applied by `supabase db push`)
```

so a reader of the forward migration finds the reverse without needing the convention by memory. Convention established in PR #92 (slice A2).

Stale references to a top-level `migrations/` directory should be removed if encountered — that path was retired in the 2026-05-06 recovery (PR #52, Step D); the canonical baseline is `supabase/migrations/20260506091314_remote_schema.sql`.

### Integration test flag

`APEX_INTEGRATION_TESTS=1` — environment variable that gates live-API tests requiring real credentials and network access. Default: `isEnabled = NO` in the shared scheme (PR #38). Opt-in: toggle via Scheme Editor or pass `xcodebuild -e APEX_INTEGRATION_TESTS=1`. CI omits the variable intentionally. Tests gated by this flag:
- `AIInferenceServiceTests.test_liveAPI_*` — real Anthropic API round-trip
- `AnthropicProviderCachingTests.test_smokeTest_cacheEffectiveness_*` — two identical Anthropic calls asserting `cache_read_input_tokens > 0` on the second call (verifies prompt-caching mechanism end-to-end; uses a padded system prompt to clear the 1,024-token cache minimum)

### Worktree-aware git commands (mandatory in `.claude/worktrees/*` sessions)

When working inside a worktree (path matches `.claude/worktrees/<name>/`), every git-mutating command MUST be `git -C <worktree-absolute-path> <subcommand>` rather than relying on the shell's current working directory. The bash agent's `cd` does not reliably persist across tool calls, and a `git commit` that runs from the parent main repo silently lands the wrong files on the wrong branch. This was a real incident during Slice 1.

Required form:

```bash
git -C /Users/arnav/Desktop/ProjectApex/.claude/worktrees/<name> add <paths>
git -C /Users/arnav/Desktop/ProjectApex/.claude/worktrees/<name> commit -m "..."
git -C /Users/arnav/Desktop/ProjectApex/.claude/worktrees/<name> push ...
```

Same rule for `git status`, `git log`, `git diff` when you need them to reflect the worktree's state. Read tools (`Read`, `grep` on absolute paths) are unaffected — they don't depend on cwd.

## Coding Discipline (Karpathy Guidelines)

_Adapted from forrestchang/andrej-karpathy-skills, derived from Andrej Karpathy's observations on LLM coding pitfalls._

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
