#!/usr/bin/env bash
# Builds a distributable, notarized DMG of Dim Keys.
#
#   ./release.sh                 full pipeline: build, sign, notarize, staple
#   ./release.sh --no-notarize   everything except the Apple round trips
#
# Distinct from build-app.sh, which makes an ad-hoc build for local use only.
# The differences that matter for distribution:
#   - universal (arm64 + x86_64), not arm64 only
#   - Developer ID identity, not ad-hoc
#   - Hardened Runtime (--options runtime), which notarization requires
#   - a secure timestamp (--timestamp), which notarization also requires;
#     build-app.sh passes --timestamp=none, which would be rejected
set -euo pipefail

# The entire body lives in a function on purpose. Bash reads a script lazily by
# byte offset, so editing this file mid-run makes the interpreter resume at a
# stale offset and execute whatever fragment now sits there. Not theoretical —
# it killed a run immediately after a 40-minute notarization, with
# "library: command not found" from the middle of a comment. Wrapping forces
# bash to parse the whole body before running any of it.
#
# Body is intentionally NOT indented: the heredocs below need their terminators
# at column 0.
main() {
cd "$(dirname "$0")"

APPNAME="Dim Keys"
EXEC="KeyboardBacklightLimiter"
DIST="dist"
APP="${DIST}/${APPNAME}.app"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILDNUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
DMG="${DIST}/DimKeys-${VERSION}.dmg"

# ── signing identity ────────────────────────────────────────────────────────
# KBL_IDENTITY="-" forces ad-hoc, which exercises the whole pipeline without a
# certificate. Useful for testing the packaging; never shippable.
IDENTITY="${KBL_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ -z "$IDENTITY" ]; then
  cat >&2 <<'EOS'
error: no "Developer ID Application" certificate in the keychain.

  An "Apple Development" certificate is NOT usable for distribution — it only
  signs for local development. Create the distribution one:

    Xcode > Settings > Accounts > (your Apple ID) > Manage Certificates...
      > "+" > Developer ID Application

  Only the team's Account Holder can create it. Then re-run this script.
  To test the packaging without a certificate:  KBL_IDENTITY="-" ./release.sh --no-notarize
EOS
  exit 1
fi

TEAM_ID=$(printf '%s' "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')

echo "==> ${APPNAME} ${VERSION} (build ${BUILDNUM})"
echo "    identity: ${IDENTITY}"
[ -n "$TEAM_ID" ] && echo "    team:     ${TEAM_ID}"

# Checked up front: notarization credentials are the second thing people are
# missing, and finding out after a universal build and two signing passes is a
# waste of everyone's time.
PROFILE="${KBL_NOTARY_PROFILE:-KBL_NOTARY}"
if [ "$NOTARIZE" = "1" ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOS
error: no stored notarization credentials under profile "${PROFILE}".

  Store them once. The password is an app-specific password generated at
  appleid.apple.com — NOT your Apple ID password:

    xcrun notarytool store-credentials "${PROFILE}" \\
      --apple-id "<your-apple-id>" --team-id "${TEAM_ID:-<team-id>}" --password "<app-specific-password>"

  Note the team above is the one owning the Developer ID certificate, which may
  differ from the team on your Apple Development certificate.

  To build without notarizing:  ./release.sh --no-notarize
EOS
  exit 1
fi

# ── universal build ─────────────────────────────────────────────────────────
echo "==> swift build (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> assembling ${APP}"
rm -rf "${DIST}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}/${EXEC}" "${APP}/Contents/MacOS/${EXEC}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# CFBundleVersion is injected from the git commit count rather than hand-edited.
# Every update mechanism — Sparkle, Homebrew, any home-grown check — decides
# "is this newer?" by comparing CFBundleVersion, so a stale one silently breaks
# updates. It sat at 1 across six feature releases precisely because bumping it
# by hand is the step everyone forgets. Commit count is monotonic and free.
if GITCOUNT=$(git rev-list --count HEAD 2>/dev/null) && [ -n "$GITCOUNT" ]; then
  BUILDNUM="$GITCOUNT"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILDNUM}" "${APP}/Contents/Info.plist"
  echo "    build number: ${BUILDNUM} (git commit count)"
else
  echo "    build number: ${BUILDNUM} (from Info.plist — no git history found)" >&2
fi
echo "    architectures: $(lipo -archs "${APP}/Contents/MacOS/${EXEC}")"

# ── sign ────────────────────────────────────────────────────────────────────
# Hardened Runtime is required for notarization. Verified compatible with this
# app's dlopen of CoreBrightness — a private but Apple-signed framework, so
# library validation permits it and no entitlement exemption is needed.
echo "==> codesign (hardened runtime, secure timestamp)"
TS="--timestamp"
[ "$IDENTITY" = "-" ] && TS="--timestamp=none"
codesign --force --sign "$IDENTITY" --options runtime $TS \
         --identifier "com.martun.KeyboardBacklightLimiter" "${APP}"
codesign --verify --deep --strict --verbose=2 "${APP}"

# ── notarize the app, so it carries its own ticket even outside the DMG ────
if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing the app (this waits on Apple)"
  ditto -c -k --keepParent "${APP}" "${DIST}/app.zip"
  xcrun notarytool submit "${DIST}/app.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "${APP}"
  rm -f "${DIST}/app.zip"
fi

# ── DMG, with the /Applications symlink ─────────────────────────────────────
# Not cosmetic: SMAppService registers the bundle at whatever path it is run
# from, so launch-at-login breaks for anyone running it out of ~/Downloads.
echo "==> building ${DMG}"
STAGE=$(mktemp -d)
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${APPNAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGE}"
codesign --force --sign "$IDENTITY" $TS "${DMG}"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing the DMG"
  xcrun notarytool submit "${DMG}" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "${DMG}"
fi

# ── verify the way Gatekeeper will ──────────────────────────────────────────
echo
echo "==> verification"
spctl -a -vvv -t install "${APP}" 2>&1 | sed 's/^/    /' || true
if [ "$NOTARIZE" = "1" ]; then
  xcrun stapler validate "${APP}" 2>&1 | sed 's/^/    /'
  xcrun stapler validate "${DMG}" 2>&1 | sed 's/^/    /'
fi
echo
echo "Built: ${DMG}"
[ "$NOTARIZE" = "1" ] || echo "NOT notarized — --no-notarize was passed. Do not ship this."

}

main "$@"
