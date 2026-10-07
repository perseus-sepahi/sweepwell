#!/bin/bash
# scripts/ui/window.sh <light|dark> <module> <autoscan 0|1> <out.png> [KEY=VALUE ...]
# Launches the main window on a module in the demo home and captures just that window.
# ACTIVATE=1 brings it to the front first, for true active-window rendering.
source "$(dirname "$0")/common.sh"
theme=$1; module=$2; scan=$3; out=$4; shift 4
pkill -x Sweepwell 2>/dev/null || true; sleep 0.7
env SWEEPWELL_HOME="$WORK/demo-home" SWEEPWELL_THEME="$theme" SWEEPWELL_MODULE="$module" SWEEPWELL_AUTOSCAN="$scan" "$@" "$APP" >/dev/null 2>&1 &
sleep 7
if [ "${ACTIVATE:-0}" = 1 ]; then
    osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "Sweepwell") to true' >/dev/null 2>&1 || true
    sleep 1.2
fi
id=$("$WORK/windows" | awk '$2==0 && $6>300 {print $1; exit}')
screencapture -x -o -l "$id" "$out" && sips -Z 1300 "$out" >/dev/null && echo "$out"
pkill -x Sweepwell || true
