#!/bin/bash
# scripts/ui/panel.sh <light|dark> <expand vital|-> <out.png> [KEY=VALUE ...]
# Opens the menu bar panel in the demo home and captures just the panel window.
# BACKDROP=1 puts a test wallpaper behind the panel and captures the glass over it; the
# capture only happens once the backdrop is confirmed to cover the whole panel, so nothing
# else on screen can end up in the image.
source "$(dirname "$0")/common.sh"
theme=$1; expand=$2; out=$3; shift 3
pkill -x Sweepwell 2>/dev/null || true; sleep 0.7
env SWEEPWELL_HOME="$WORK/demo-home" SWEEPWELL_LAUNCHED_AT_LOGIN=1 SWEEPWELL_OPEN_PANEL=1 \
    SWEEPWELL_PANEL_EXPAND="$expand" SWEEPWELL_THEME="$theme" SWEEPWELL_PANEL_BACKDROP="${BACKDROP:-0}" "$@" "$APP" >/dev/null 2>&1 &
id=""
for _ in $(seq 1 40); do sleep 0.25; id=$("$WORK/windows" | awk '$2==101 && $7==1 {print $1; exit}'); [ -n "$id" ] && break; done
sleep 1.5
if [ "${BACKDROP:-0}" = 1 ]; then
    read px py pw ph <<< "$("$WORK/windows" | awk '$2==101 && $7==1 {print $3, $4, $5, $6; exit}')"
    read bx by bw bh <<< "$("$WORK/windows" | awk '$2==25 && $7==1 {print $3, $4, $5, $6; exit}')"
    if [ -n "${bx:-}" ] && [ "$bx" -le "$px" ] && [ "$by" -le "$py" ] && [ $((bx+bw)) -ge $((px+pw)) ] && [ $((by+bh)) -ge $((py+ph)) ]; then
        screencapture -x -R "$px,$py,$pw,$ph" "$out" && sips -Z 820 "$out" >/dev/null && echo "$out"
    else
        echo "backdrop does not cover the panel; not capturing" >&2
    fi
else
    screencapture -x -o -l "$id" "$out" && sips -Z 820 "$out" >/dev/null && echo "$out"
fi
pkill -x Sweepwell || true
