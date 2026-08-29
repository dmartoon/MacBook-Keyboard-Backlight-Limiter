#!/usr/bin/env bash
# Builds Dim Keys.app in ./build/
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="Dim Keys"
EXEC="KeyboardBacklightLimiter"
OUT="build/${APPNAME}.app"

echo "==> swift build -c release"
swift build -c release --arch arm64

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"
echo "==> assembling ${OUT}"
rm -rf "${OUT}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "${BIN_PATH}/${EXEC}" "${OUT}/Contents/MacOS/${EXEC}"
cp "Resources/Info.plist" "${OUT}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${OUT}/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "${OUT}"

echo
echo "Built: ${OUT}"
echo "Run:   open \"${OUT}\""
echo "Or:    \"${OUT}/Contents/MacOS/${EXEC}\"    # foreground with logs"
