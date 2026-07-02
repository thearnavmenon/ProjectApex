#!/usr/bin/env bash
# apex-build.sh — one canonical way to build/test ProjectApex on the simulator.
#
# Usage:
#   scripts/apex-build.sh build                         # build the app
#   scripts/apex-build.sh test                          # run the full test suite
#   scripts/apex-build.sh test --only-testing ProjectApexTests/FooTests
#   scripts/apex-build.sh test --only-testing ProjectApexTests/FooTests/testBar
#
# Env overrides: APEX_SIM_NAME (default "iPhone 17 Pro"), APEX_MAIN_REPO.
#
# What it pins for you (so it never gets re-derived by hand — reflection item 1):
#   • scheme = ProjectApex
#   • one concrete simulator UDID (newest runtime, booted iPhone 17 Pro preferred)
#     used for BOTH -destination and any later install/launch → no OS mismatch
#   • -derivedDataPath <root>/.build  → never touches the global DerivedData cache
#   • copies APIKeys.xcconfig into fresh worktrees
#   • free-disk preflight (+ purges the global cache when critically low)
#
# Runs xcodebuild in the foreground, teeing to a timestamped log whose path is
# printed on the FIRST line. Run this script itself as a background Bash job when
# you want async, then tail/Monitor the printed log (never foreground a long
# build with -quiet — it can be killed).

set -euo pipefail
source "$(cd "$(dirname "$0")/lib" && pwd)/apex-sim.sh"

action="${1:-build}"; shift || true
case "$action" in
  build|test) ;;
  *) apex_die "usage: apex-build.sh [build|test] [--only-testing X ...]" ;;
esac

only_testing_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only-testing) only_testing_args+=("-only-testing:$2"); shift 2 ;;
    *) apex_die "unknown arg: $1" ;;
  esac
done

ROOT="$(apex_root)"
apex_disk_preflight
apex_ensure_apikeys "$ROOT"
UDID="$(apex_resolve_udid)"
apex_log "simulator UDID: $UDID"

LOG_DIR="$ROOT/.build/logs"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/${action}-${STAMP}.log"
# First line of output = the log path, so a background run surfaces it immediately.
echo "LOG: $LOG"

set -x
xcodebuild "$action" \
  -project "$ROOT/ProjectApex.xcodeproj" \
  -scheme ProjectApex \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/.build" \
  CODE_SIGNING_ALLOWED=NO \
  "${only_testing_args[@]+"${only_testing_args[@]}"}" 2>&1 | tee "$LOG"
