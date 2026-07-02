#!/usr/bin/env bash
# Shared helpers for the apex-* build/render scripts.
# Source this; don't execute it. All functions echo to stderr for progress and
# to stdout only for their return value, so callers can capture cleanly.
#
# Why this exists: the xcodebuild/simctl recipe was re-derived by hand in almost
# every session (see reflection-notes.md item 1). The three recurring failures
# this file removes for good:
#   1. Simulator UDID re-derived / hardcoded then gone stale.
#   2. Build-OS vs booted-sim mismatch (build for 26.5, sim is 26.3).
#   3. Wrong .app installed because `head -1` grabbed a stale DerivedData dir.
# We fix all three by resolving ONE concrete device UDID (newest runtime,
# preferring an already-booted iPhone 17 Pro) and using `-destination id=<udid>`
# for the build AND `simctl <udid>` for install/launch — so build and run always
# target the same simulator, and by picking the freshest .app by mtime.

set -euo pipefail

# The canonical main checkout. Fresh worktrees copy APIKeys.xcconfig from here.
APEX_MAIN_REPO="${APEX_MAIN_REPO:-/Users/arnav/Desktop/ProjectApex}"

# Device family we standardize on. Override with APEX_SIM_NAME if needed.
APEX_SIM_NAME="${APEX_SIM_NAME:-iPhone 17 Pro}"

apex_log() { printf '\033[2m[apex]\033[0m %s\n' "$*" >&2; }
apex_die() { printf '\033[31m[apex] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Root of the repo/worktree this script lives in (scripts/lib/.. -> scripts/.. ).
apex_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s\n' "$here"
}

# Copy the git-ignored APIKeys.xcconfig into a fresh worktree if it is missing,
# so the build does not break. No-op in the main checkout.
apex_ensure_apikeys() {
  local root="$1"
  if [[ ! -f "$root/APIKeys.xcconfig" ]]; then
    if [[ -f "$APEX_MAIN_REPO/APIKeys.xcconfig" ]]; then
      cp "$APEX_MAIN_REPO/APIKeys.xcconfig" "$root/APIKeys.xcconfig"
      apex_log "copied APIKeys.xcconfig into $root"
    else
      apex_log "WARNING: no APIKeys.xcconfig found (build may fail)"
    fi
  fi
}

# Free-disk preflight. DerivedData ballooning to ENOSPC caused real data loss
# (reflection-notes.md item 1). We pin -derivedDataPath to the repo's .build, so
# the risk is the global Xcode DerivedData cache — safe to purge, Xcode rebuilds
# it. Warn under 8 GB free; auto-purge the *global* cache under a 4 GB floor.
apex_disk_preflight() {
  local free_gb
  free_gb="$(df -g / | awk 'NR==2 {print $4}')"
  apex_log "free disk: ${free_gb} GB"
  if (( free_gb < 8 )); then
    apex_log "WARNING: low disk (${free_gb} GB free)."
    local global="$HOME/Library/Developer/Xcode/DerivedData"
    if (( free_gb < 4 )) && [[ -d "$global" ]]; then
      apex_log "purging global Xcode DerivedData cache to reclaim space: $global"
      rm -rf "${global:?}/"* 2>/dev/null || true
      apex_log "purged. (Local -derivedDataPath builds are unaffected.)"
    fi
  fi
}

# Resolve one concrete simulator UDID: newest iOS runtime, our device family,
# preferring an already-booted one. Echoes the UDID on stdout.
apex_resolve_udid() {
  local name="${1:-$APEX_SIM_NAME}"
  local udid
  udid="$(xcrun simctl list devices available -j | jq -r --arg name "$name" '
    [ .devices | to_entries[]
      | select(.key | test("iOS"))
      | ( .key | capture("iOS-(?<a>[0-9]+)-(?<b>[0-9]+)(-(?<c>[0-9]+))?") ) as $v
      | .value[]
      | select(.name == $name)
      | { udid: .udid,
          booted: (if .state == "Booted" then 1 else 0 end),
          ver: [ ($v.a|tonumber), ($v.b|tonumber), (($v.c // "0")|tonumber) ] } ]
    | sort_by([ .booted, .ver ]) | last | .udid // empty')"
  # Fall back to any "iPhone 17*" if the exact family name is missing.
  if [[ -z "$udid" && "$name" == "$APEX_SIM_NAME" ]]; then
    udid="$(xcrun simctl list devices available -j | jq -r '
      [ .devices | to_entries[]
        | select(.key | test("iOS"))
        | ( .key | capture("iOS-(?<a>[0-9]+)-(?<b>[0-9]+)(-(?<c>[0-9]+))?") ) as $v
        | .value[]
        | select(.name | test("^iPhone 1[567]"))
        | { udid: .udid,
            booted: (if .state == "Booted" then 1 else 0 end),
            ver: [ ($v.a|tonumber), ($v.b|tonumber), (($v.c // "0")|tonumber) ] } ]
      | sort_by([ .booted, .ver ]) | last | .udid // empty')"
  fi
  [[ -n "$udid" ]] || apex_die "no available iPhone simulator found (need '$name')."
  printf '%s\n' "$udid"
}

# Boot the given UDID and wait for it to be ready (no-op if already booted).
apex_boot() {
  local udid="$1"
  apex_log "booting simulator $udid (waits for ready)…"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" 2>/dev/null || true
}

# Freshest .app by MODIFICATION TIME (not `head -1`, which grabbed stale dirs and
# cost 6 days of re-render loops in one session). Args: <search-root> <AppName.app>
apex_freshest_app() {
  local search_root="$1" app_name="$2" newest="" app
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    if [[ -z "$newest" || "$(stat -f '%m' "$app")" -gt "$(stat -f '%m' "$newest")" ]]; then
      newest="$app"
    fi
  done < <(find "$search_root" -maxdepth 4 -name "$app_name" -type d 2>/dev/null)
  printf '%s\n' "$newest"
}

# Bundle id read straight from a built .app (avoids hardcoding / drift).
apex_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Info.plist" 2>/dev/null
}
