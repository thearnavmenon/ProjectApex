# AI Co-Developer Instructions
1. **Strictly Non-Autonomous:** You are an assistant, not an autonomous agent. ONLY work on the specific task I explicitly assign to you. Do NOT automatically start the next task on the backlog.
2. **Context-Aware Coding:** When I assign you a task, use your file-reading tools to check `ARCHITECTURE.md` for the relevant database schemas, actor models, and UI/UX design tokens before writing code.
3. **Backlog Tracking:** When I explicitly tell you a task is complete and working, use your file-editing tool to open `BACKLOG.md` and change that specific task from `[ ]` to `[x]`.
4. **Wait for Commands:** After completing a coding task or updating the backlog, simply tell me it is done and wait for my next instruction. Do not proceed on your own.

## Agent skills

### Issue tracker

GitHub Issues on `thearnavmenon/ProjectApex` via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Edge Function secrets

Authoritative for Edge Function secret storage, service-role access list, and key rotation policy. Read before any Slice 9b+ Edge Function work — do not redo the analysis from scratch. See `docs/agents/edge-functions.md`.

### Worktree-aware git commands (mandatory in `.claude/worktrees/*` sessions)

When working inside a worktree (path matches `.claude/worktrees/<name>/`), every git-mutating command MUST be `git -C <worktree-absolute-path> <subcommand>` rather than relying on the shell's current working directory. The bash agent's `cd` does not reliably persist across tool calls, and a `git commit` that runs from the parent main repo silently lands the wrong files on the wrong branch. This was a real incident during Slice 1.

Required form:

```bash
git -C /Users/arnav/Desktop/ProjectApex/.claude/worktrees/<name> add <paths>
git -C /Users/arnav/Desktop/ProjectApex/.claude/worktrees/<name> commit -m "..."
git -C /Users/arnav/Desktop/ProjectApex/.claude/worktrees/<name> push ...
```

Same rule for `git status`, `git log`, `git diff` when you need them to reflect the worktree's state. Read tools (`Read`, `grep` on absolute paths) are unaffected — they don't depend on cwd.
