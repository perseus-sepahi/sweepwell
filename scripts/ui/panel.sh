#!/bin/bash
# scripts/ui/panel.sh <light|dark> <expand vital|-> <out.png> [KEY=VALUE ...]
# Opens the menu bar panel in the demo home and captures just the panel window.
source "$(dirname "$0")/common.sh"
theme=$1; expand=$2; out=$3; shift 3
pkill -x Sweepwell 2>/dev/null || true; sleep 0.7
env SWEEPWELL_HOME="$WORK/demo-home" SWEEPWELL_LAUNCHED_AT_LOGIN=1 SWEEPWELL_OPEN_PANEL=1 \
    SWEEPWELL_PANEL_EXPAND="$expand" SWEEPWELL_THEME="$theme" "$@" "$APP" >/dev/null 2>&1 &
id=""
for _ in $(seq 1 40); do sleep 0.25; id=$("$WORK/windows" | awk '$2==101 && $7==1 {print $1; exit}'); [ -n "$id" ] && break; done
sleep 1.2
screencapture -x -o -l "$id" "$out" && sips -Z 820 "$out" >/dev/null && echo "$out"
pkill -x Sweepwell || true
