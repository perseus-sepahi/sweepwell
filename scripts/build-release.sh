#!/bin/bash
# Builds the Release app for Apple silicon into dist/Sweepwell.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Sweepwell.xcodeproj -scheme Sweepwell -configuration Release \
    -derivedDataPath build CODE_SIGN_IDENTITY="-" build | grep -E "error:|warning: |BUILD" || true
rm -rf dist/Sweepwell.app
mkdir -p dist
ditto build/Build/Products/Release/Sweepwell.app dist/Sweepwell.app
codesign --verify --deep --strict dist/Sweepwell.app
echo "Built dist/Sweepwell.app ($(lipo -archs dist/Sweepwell.app/Contents/MacOS/Sweepwell))"
