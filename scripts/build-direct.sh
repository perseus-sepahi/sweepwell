#!/bin/bash
# The public direct-download build: Developer ID signed, notarized and stapled, as
# macOS/Direct/Sweepwell.dmg. Uses the "notary" keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="Developer ID Application: MOHAMMADREZA SEPAHI (ZY74XX7D42)"
OUT=macOS/Direct
DERIVED=build/direct
APP="$DERIVED/Build/Products/Release/Sweepwell.app"

xcodegen generate
rm -rf "$DERIVED"
xcodebuild -project Sweepwell.xcodeproj -scheme Sweepwell -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM=ZY74XX7D42 \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" build | grep -E "error:|BUILD" 

# Read the text once: with pipefail, `strings | grep -q` fails when grep stops reading early.
TEXT=$(mktemp)
strings "$APP/Contents/MacOS/Sweepwell" > "$TEXT"
if grep -q "SWEEPWELL-OWNER-BUILD" "$TEXT"; then echo "REFUSED: owner marker in the binary" >&2; exit 1; fi
if grep -qE "SWEEPWELL_AS_CUSTOMER|SWEEPWELL_TRIAL_USED|SWEEPWELL_SCREENSHOT" "$TEXT"; then echo "REFUSED: test hooks in the binary" >&2; exit 1; fi
if ! grep -q "buy.stripe.com" "$TEXT"; then echo "REFUSED: no Stripe checkout link in the binary" >&2; exit 1; fi
if grep -q "buy.stripe.com/test_" "$TEXT"; then echo "REFUSED: test-mode checkout link" >&2; exit 1; fi
rm -f "$TEXT"
codesign --verify --deep --strict "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then echo "REFUSED: get-task-allow" >&2; exit 1; fi

mkdir -p "$OUT"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Sweepwell.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/Sweepwell.dmg"
hdiutil create -volname Sweepwell -srcfolder "$STAGE" -format UDZO -ov "$OUT/Sweepwell.dmg" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$OUT/Sweepwell.dmg"
xcrun notarytool submit "$OUT/Sweepwell.dmg" --keychain-profile notary --wait
xcrun stapler staple "$OUT/Sweepwell.dmg"
spctl -a -vvv -t open --context context:primary-signature "$OUT/Sweepwell.dmg"
shasum -a 256 "$OUT/Sweepwell.dmg"
