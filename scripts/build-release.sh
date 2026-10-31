#!/bin/bash
# The owner's own copy: Release, Apple silicon, ad-hoc signed, always Pro (OWNER), into
# dist/Sweepwell.app. Never distribute this one; scripts/build-direct.sh makes the public build.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Sweepwell.xcodeproj -scheme Sweepwell -configuration Release \
    -derivedDataPath build CODE_SIGN_IDENTITY="-" SWIFT_ACTIVE_COMPILATION_CONDITIONS=OWNER build | grep -E "error:|warning: |BUILD" || true
rm -rf dist/Sweepwell.app
mkdir -p dist
ditto build/Build/Products/Release/Sweepwell.app dist/Sweepwell.app
codesign --verify --deep --strict dist/Sweepwell.app
echo "Built dist/Sweepwell.app ($(lipo -archs dist/Sweepwell.app/Contents/MacOS/Sweepwell))"
