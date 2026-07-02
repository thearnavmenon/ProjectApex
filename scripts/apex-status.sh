#!/usr/bin/env bash
# apex-status.sh — one "what's left?" rollup.
#
# Gathers the raw facts that the recurring "what else is left to finish?" question
# is always answered from by hand (reflection item 10): open issues, open PRs +
# their check state, umbrella issues, and the BACKLOG things-to-do section. Prints
# a compact dump; the model reading it does the synthesis.
#
# Usage: scripts/apex-status.sh

set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO=thearnavmenon/ProjectApex

echo "=================== OPEN PRs ==================="
gh pr list --repo "$REPO" --state open \
  --json number,title,headRefName,isDraft,statusCheckRollup \
  -q '.[] | "#\(.number) \(if .isDraft then "[draft] " else "" end)\(.title)  <\(.headRefName)>  checks:" +
        ( [ .statusCheckRollup[]? | (.conclusion // .state // .status // "?") ]
          | (if length==0 then "none" else (group_by(.) | map("\(.[0])×\(length)") | join(",")) end) )' \
  2>/dev/null || echo "(gh pr list failed)"

echo
echo "=================== OPEN ISSUES (umbrellas first) ==================="
gh issue list --repo "$REPO" --state open --limit 100 \
  --json number,title,labels \
  -q 'sort_by( ([.labels[].name] | index("umbrella") // 999) )
      | .[] | "#\(.number) \(.title)  [\( [.labels[].name] | join(",") )]"' \
  2>/dev/null || echo "(gh issue list failed)"

echo
echo "=================== BACKLOG — things-to-do (§2D) ==================="
if [[ -f BACKLOG.md ]]; then
  awk '/##.*2D|§2D|Things to do|things-to-do|To-?do/{f=1} f{print} /^## /{if(f&&!/2D|To-?do|Things/) exit}' BACKLOG.md \
    | head -60
else
  echo "(no BACKLOG.md)"
fi

echo
echo "=================== recent commits ==================="
git log --oneline -8
