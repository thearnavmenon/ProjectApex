#!/usr/bin/env bash
# deploy-efs.sh — deploy the Supabase Edge Functions touched on this branch.
#
# Usage:
#   scripts/deploy-efs.sh                     # auto: functions changed vs origin/main
#   scripts/deploy-efs.sh update-trainee-model update-trainee-goal   # explicit
#   scripts/deploy-efs.sh --all               # every function under supabase/functions
#
# Edge Functions deploy manually and often, and "OWNER must deploy X" reminders
# litter the memory files (reflection item 7). This makes the common case one
# command. It does NOT store secrets — production secrets live in Supabase-managed
# env vars (docs/agents/edge-functions.md). Requires the Supabase CLI to be logged
# in (`supabase login`) and the project linked (`supabase link`); the access token
# should come from your keychain/secret store, never pasted into a chat.

set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

command -v supabase >/dev/null 2>&1 || { echo "supabase CLI not found" >&2; exit 1; }

fns=()
if [[ "${1:-}" == "--all" ]]; then
  for d in supabase/functions/*/; do
    b="$(basename "$d")"; [[ "$b" == _* ]] && continue   # skip _shared etc.
    fns+=("$b")
  done
elif [[ $# -gt 0 ]]; then
  fns=("$@")
else
  # Auto-detect: function dirs with changes vs origin/main.
  git fetch -q origin main 2>/dev/null || true
  base="$(git merge-base origin/main HEAD 2>/dev/null || echo origin/main)"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    name="$(sed -E 's#^supabase/functions/([^/]+)/.*#\1#' <<<"$f")"
    [[ "$name" == _* ]] && continue
    fns+=("$name")
  done < <(git diff --name-only "$base"...HEAD -- 'supabase/functions/*' | sort -u)
  # de-dupe
  if [[ ${#fns[@]} -gt 0 ]]; then
    IFS=$'\n' read -r -d '' -a fns < <(printf '%s\n' "${fns[@]}" | sort -u && printf '\0')
  fi
fi

if [[ ${#fns[@]} -eq 0 ]]; then
  echo "No changed Edge Functions vs origin/main. Nothing to deploy."
  exit 0
fi

echo "Will deploy: ${fns[*]}"
for fn in "${fns[@]}"; do
  echo "── supabase functions deploy $fn ──"
  supabase functions deploy "$fn"
done
echo "Deployed: ${fns[*]}"
