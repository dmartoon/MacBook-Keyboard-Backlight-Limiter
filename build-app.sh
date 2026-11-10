#!/usr/bin/env bash
# Builds Dim Keys.app in ./build/
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="Dim Keys"
EXEC="KeyboardBacklightLimiter"
OUT="build/${APPNAME}.app"

# SDK version passed to the linker explicitly, as in release.sh, which says
# why. Without it this build draws the panel unlike the shipped one, and the
# self-test measures the wrong layout.
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
SDKVER=$(xcrun --show-sdk-version)
echo "==> swift build -c release (minos ${MINOS}, sdk ${SDKVER})"
swift build -c release --arch arm64 \
  -Xlinker -platform_version -Xlinker macos -Xlinker "$MINOS" -Xlinker "$SDKVER"

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"
STAMP=$(vtool -show-build "${BIN_PATH}/${EXEC}" | awk '$1=="minos"{m=$2} $1=="sdk"{s=$2} END{print m" "s}')
if [ "$STAMP" != "${MINOS} ${SDKVER}" ]; then
  echo "error: binary is stamped minos/sdk ${STAMP}, expected ${MINOS} ${SDKVER}" >&2
  exit 1
fi
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
