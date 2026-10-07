# Shared setup for the UI capture scripts. Captures only Sweepwell's own windows (by id),
# never a screen region, so nothing else on screen ends up in the images.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${SWEEPWELL_UI_WORK:-${TMPDIR:-/tmp}/sweepwell-ui}"
mkdir -p "$WORK"
APP="$ROOT/build/Build/Products/Debug/Sweepwell.app/Contents/MacOS/Sweepwell"
[ -x "$WORK/windows" ] || swiftc -O "$ROOT/scripts/ui/windows.swift" -o "$WORK/windows" 2>/dev/null
if [ ! -d "$WORK/demo-home" ]; then
    sed 's/bs=1m count="$2"/bs=100k count="$2"/' "$ROOT/scripts/make-demo-home.sh" > "$WORK/mini-demo.sh"
    bash "$WORK/mini-demo.sh" "$WORK/demo-home" >/dev/null
fi
