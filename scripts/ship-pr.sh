#!/usr/bin/env bash
# ship-pr.sh — push → PR → wait on required checks (ignoring the known flake) →
#              squash-admin-merge → delete branch → prune worktree.
#
# Usage:
#   scripts/ship-pr.sh                       # current branch, in the cwd repo
#   scripts/ship-pr.sh <branch>              # a branch in the main checkout
#   scripts/ship-pr.sh /path/to/worktree     # a worktree (uses git -C, prunes it after)
#   scripts/ship-pr.sh --title "..." --body "..."   # override PR title/body
#
# The mechanical PR dance re-hand-rolled every campaign (reflection item 3).
# Merge autonomy is durably granted (memory: feedback_merge_autonomy), so this
# admin-merges on green without asking. It IGNORES the flaky iOS build check —
# override the pattern with APEX_FLAKY_CHECK (regex).
#
# The known flake: the "iOS Build & Test" GitHub check is intermittently red for
# infra reasons; the rule "don't block on it" was re-pasted 30+ times. It lives
# here now instead of in prompts.

set -euo pipefail

FLAKY="${APEX_FLAKY_CHECK:-(iOS )?Build & Test|iOS-Build-Test|build-and-test}"
POLL_SECS="${APEX_POLL_SECS:-30}"
MAX_WAIT_SECS="${APEX_MAX_WAIT_SECS:-1800}"

TITLE=""; BODY=""; ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --body)  BODY="$2";  shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) ARG="$1"; shift ;;
  esac
done

# Resolve the repo dir + branch from the positional arg.
WORKTREE=""
if [[ -n "$ARG" && -d "$ARG" ]]; then
  REPO_DIR="$(cd "$ARG" && pwd)"; WORKTREE="$REPO_DIR"
  BRANCH="$(git -C "$REPO_DIR" branch --show-current)"
elif [[ -n "$ARG" ]]; then
  REPO_DIR="$(pwd)"; BRANCH="$ARG"
else
  REPO_DIR="$(pwd)"; BRANCH="$(git -C "$REPO_DIR" branch --show-current)"
fi
g() { git -C "$REPO_DIR" "$@"; }
[[ -n "$BRANCH" && "$BRANCH" != "main" ]] || { echo "refusing to ship '$BRANCH' — use a feature branch" >&2; exit 1; }
echo "[ship] repo=$REPO_DIR branch=$BRANCH"

echo "[ship] pushing…"
g push -u origin "$BRANCH"

# Create the PR if none exists yet (standard Claude Code trailer on the body).
if ! gh pr view "$BRANCH" --repo thearnavmenon/ProjectApex >/dev/null 2>&1; then
  TRAILER=$'\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  if [[ -n "$TITLE" ]]; then
    gh pr create --repo thearnavmenon/ProjectApex --head "$BRANCH" \
      --title "$TITLE" --body "${BODY}${TRAILER}"
  else
    gh pr create --repo thearnavmenon/ProjectApex --head "$BRANCH" --fill
    gh pr edit "$BRANCH" --repo thearnavmenon/ProjectApex \
      --body "$(gh pr view "$BRANCH" --repo thearnavmenon/ProjectApex --json body -q .body)${TRAILER}" >/dev/null || true
  fi
fi
PR_URL="$(gh pr view "$BRANCH" --repo thearnavmenon/ProjectApex --json url -q .url)"
echo "[ship] PR: $PR_URL"

# Poll checks, ignoring the flake. A check is "settled OK" when COMPLETED with a
# non-failing conclusion. We proceed once every non-ignored check is settled OK;
# we abort if a non-ignored check actually fails.
echo "[ship] waiting on required checks (ignoring: $FLAKY)…"
waited=0
while true; do
  ROLLUP="$(gh pr view "$BRANCH" --repo thearnavmenon/ProjectApex --json statusCheckRollup -q '.statusCheckRollup')"
  pending="$(jq -r --arg flaky "$FLAKY" '
    [ .[] | select((.name // .context) | test($flaky) | not)
          | select((.status // "COMPLETED") != "COMPLETED") ] | length' <<<"$ROLLUP")"
  failed="$(jq -r --arg flaky "$FLAKY" '
    [ .[] | select((.name // .context) | test($flaky) | not)
          | select((.conclusion // .state // "") | test("FAILURE|CANCELLED|TIMED_OUT|ERROR|STARTUP_FAILURE")) ]
    | (map(.name // .context) | join(", "))' <<<"$ROLLUP")"
  if [[ -n "$failed" && "$failed" != "" ]]; then
    echo "[ship] ABORT — required check failed: $failed" >&2
    echo "[ship] fix and re-run; not merging." >&2
    exit 1
  fi
  if [[ "$pending" == "0" ]]; then
    echo "[ship] all required checks green (flake ignored)."
    break
  fi
  (( waited >= MAX_WAIT_SECS )) && { echo "[ship] timed out after ${MAX_WAIT_SECS}s waiting on checks" >&2; exit 1; }
  echo "[ship]   $pending check(s) still running… (${waited}s)"
  sleep "$POLL_SECS"; waited=$((waited + POLL_SECS))
done

echo "[ship] merging (squash, admin, delete-branch)…"
gh pr merge "$BRANCH" --repo thearnavmenon/ProjectApex --squash --admin --delete-branch

# Prune the worktree if we were given one.
if [[ -n "$WORKTREE" ]]; then
  echo "[ship] pruning worktree $WORKTREE"
  git -C "${APEX_MAIN_REPO:-$WORKTREE}" worktree remove "$WORKTREE" --force 2>/dev/null \
    || git worktree remove "$WORKTREE" --force 2>/dev/null || true
fi
echo "[ship] done: $PR_URL"
