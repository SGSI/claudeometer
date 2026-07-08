#!/usr/bin/env bash
set -euo pipefail

# release.sh — build, sign, notarize, staple, and package Claudeometer.
# Produces a notarized dmg that opens with NO Gatekeeper warnings.
#
# One-time prerequisites:
#   1. Apple Developer Program membership ($99/yr).
#   2. A "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + Developer ID Application).
#   3. A notarytool credential profile saved in your keychain:
#        xcrun notarytool store-credentials claudeometer \
#          --apple-id "you@example.com" --team-id "TEAMID" \
#          --password "<app-specific-password>"      # create at appleid.apple.com
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="claudeometer" \
#   ./scripts/release.sh 0.1.1
#
#   # ...and also create/attach the GitHub release in one go:
#   PUBLISH=1 DEVELOPER_ID="..." NOTARY_PROFILE="claudeometer" ./scripts/release.sh 0.1.1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-${VERSION:-}}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
PUBLISH="${PUBLISH:-0}"
REPO="SGSI/claudeometer"
APP="build/Claudeometer.app"
DMG="dist/Claudeometer.dmg"

fail() { echo "error: $*" >&2; exit 1; }

[ -n "$VERSION" ]       || fail "version required:  ./scripts/release.sh <version>   (e.g. 0.1.1)"
[ -n "$DEVELOPER_ID" ]  || fail "set DEVELOPER_ID  (e.g. 'Developer ID Application: Name (TEAMID)') — see header"
[ -n "$NOTARY_PROFILE" ]|| fail "set NOTARY_PROFILE (your notarytool keychain profile) — see header"
command -v xcrun >/dev/null || fail "Xcode command line tools required (xcrun not found)"

echo "==> Building app (version $VERSION)"
VERSION="$VERSION" ./scripts/build-app.sh >/dev/null

echo "==> Code signing app with hardened runtime"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Packaging dmg"
mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "Claudeometer" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

echo "==> Notarizing (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP" || true

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo
echo "================  NOTARIZED BUILD READY  ================"
echo "dmg:    $DMG"
echo "sha256: $SHA"
echo
echo "Bump the Homebrew cask in this repo (Casks/claudeometer.rb), commit, and push:"
echo "    version \"$VERSION\""
echo "    sha256 \"$SHA\""
echo "  (and delete the postflight quarantine-strip block — no longer needed once notarized)"
echo

if [ "$PUBLISH" = "1" ]; then
  command -v gh >/dev/null || fail "gh not found; cannot publish"
  echo "==> Publishing GitHub release v$VERSION"
  if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" -R "$REPO" --clobber
  else
    gh release create "v$VERSION" "$DMG" -R "$REPO" \
      -t "Claudeometer v$VERSION" --notes "Claudeometer v$VERSION — signed & notarized."
  fi
  echo "Released: https://github.com/$REPO/releases/tag/v$VERSION"
fi
