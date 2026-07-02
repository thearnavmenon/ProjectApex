#!/usr/bin/env bash
# apex-render.sh — build, install, launch, and screenshot on the simulator.
#
# Usage:
#   scripts/apex-render.sh app [--out DIR]         # the real ProjectApex app
#   scripts/apex-render.sh <PROTO_SCREEN> [--out DIR]   # a UIPrototypes screen
#
# "app"  → builds ProjectApex, installs the FRESHEST .app (by mtime), launches
#          RTG.ProjectApex, screenshots, downscales with `sips -Z 1400`.
# a key  → builds UIPrototypes/ApexUIProto, launches with
#          SIMCTL_CHILD_PROTO_SCREEN=<key> (the redesign harness convention).
#
# Fixes the re-typed render boilerplate and the `head -1` stale-.app bug
# (reflection-notes.md item 1). Screenshots land in --out (default: ./renders).

set -euo pipefail
source "$(cd "$(dirname "$0")/lib" && pwd)/apex-sim.sh"

target="${1:-}"; [[ -n "$target" ]] || apex_die "usage: apex-render.sh <app|PROTO_SCREEN> [--out DIR]"
shift
OUT="./renders"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) apex_die "unknown arg: $1" ;;
  esac
done

ROOT="$(apex_root)"
mkdir -p "$OUT"
apex_disk_preflight
UDID="$(apex_resolve_udid)"
apex_boot "$UDID"

build_bg() {  # build in background, poll the log for BUILD SUCCEEDED/FAILED
  local desc="$1"; shift
  local log; log="$ROOT/.build/logs/render-${desc}-$(date +%H%M%S).log"
  mkdir -p "$(dirname "$log")"
  apex_log "building $desc → $log"
  ( "$@" >"$log" 2>&1 ) &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do sleep 5; done
  wait "$pid" || { tail -30 "$log" >&2; apex_die "$desc build failed (see $log)"; }
  apex_log "$desc build OK"
}

if [[ "$target" == "app" ]]; then
  apex_ensure_apikeys "$ROOT"
  build_bg app xcodebuild build \
    -project "$ROOT/ProjectApex.xcodeproj" -scheme ProjectApex -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/.build" \
    CODE_SIGNING_ALLOWED=NO
  APP="$(apex_freshest_app "$ROOT/.build/Build/Products" ProjectApex.app)"
  [[ -n "$APP" ]] || apex_die "no ProjectApex.app under $ROOT/.build"
  SHOT="$OUT/app-$(date +%Y%m%d-%H%M%S).png"
  LAUNCH_ENV=()
else
  PROTO="$ROOT/UIPrototypes/ApexUIProto.xcodeproj"
  [[ -d "$PROTO" ]] || apex_die "UIPrototypes/ApexUIProto.xcodeproj not found (redesign harness absent)."
  build_bg "proto" xcodebuild build \
    -project "$PROTO" -scheme ApexUIProto -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/.build-proto" \
    CODE_SIGNING_ALLOWED=NO
  APP="$(apex_freshest_app "$ROOT/.build-proto/Build/Products" ApexUIProto.app)"
  [[ -n "$APP" ]] || apex_die "no ApexUIProto.app under $ROOT/.build-proto"
  SHOT="$OUT/${target}-$(date +%Y%m%d-%H%M%S).png"
  LAUNCH_ENV=(SIMCTL_CHILD_PROTO_SCREEN="$target")
fi

BUNDLE="$(apex_bundle_id "$APP")"
[[ -n "$BUNDLE" ]] || apex_die "could not read bundle id from $APP"
apex_log "installing $APP ($BUNDLE)"
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
env "${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"}" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep 3   # let the first frame render (cold start can capture blank otherwise)
xcrun simctl io "$UDID" screenshot "$SHOT"
sips -Z 1400 "$SHOT" >/dev/null
apex_log "screenshot: $SHOT"
echo "$SHOT"
