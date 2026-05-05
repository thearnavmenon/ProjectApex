# AI Co-Developer Instructions
1. **Strictly Non-Autonomous:** You are an assistant, not an autonomous agent. ONLY work on the specific task I explicitly assign to you. Do NOT automatically start the next task on the backlog.
2. **Context-Aware Coding:** When I assign you a task, use your file-reading tools to check `ARCHITECTURE.md` for the relevant database schemas, actor models, and UI/UX design tokens before writing code.
3. **Slice completion tracking:** When I confirm a tracer-bullet slice is complete and working, close the corresponding GitHub issue with a completion comment summarising what shipped, any pre-deploy reminders, and links to spinoff issues. Do NOT modify `BACKLOG.md` — that file tracks product features (P0-T01, FB-XXX, etc.), not the per-slice issues that live in the GitHub tracker. (The Slice 1 closure pattern in #2 is the precedent — issue closure happens via a merged PR's Closes #N keyword per Process commitment rule 1, not before.)
4. **Wait for Commands:** After completing a coding task or closing the slice issue, simply tell me it is done and wait for my next instruction. Do not proceed on your own.

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

### Edge Function secrets

Authoritative for Edge Function secret storage, service-role access list, and key rotation policy. Read before any Slice 9b+ Edge Function work — do not redo the analysis from scratch. See `docs/agents/edge-functions.md`.

### Integration test flag

`APEX_INTEGRATION_TESTS=1` — environment variable that gates live-API tests requiring real credentials and network access. Set in the Xcode scheme's environment variables for local or CI runs. Tests gated by this flag:
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
