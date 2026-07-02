#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/Claudeometer.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$CONTENTS_DIR/Resources"
cp ".build/release/ClaudeUsageBar" "$MACOS_DIR/ClaudeUsageBar"

if [[ -f "$ROOT_DIR/assets/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/assets/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi

if [[ -d "$ROOT_DIR/assets/moods" ]]; then
  cp "$ROOT_DIR"/assets/moods/*.png "$CONTENTS_DIR/Resources/" 2>/dev/null || true
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ClaudeUsageBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.sgsi.claudeometer</string>
  <key>CFBundleName</key>
  <string>Claudeometer</string>
  <key>CFBundleDisplayName</key>
  <string>Claudeometer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.4</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <!-- The team relay (configured locally via CLAUDEOMETER_RELAY_URL) may be
       plain HTTP, so ATS's default HTTPS-only policy must be relaxed or every
       relay request fails. This is a blanket exception (internal tool, small
       trusted user base) — tighten to a scoped NSExceptionDomains entry once
       the relay gets TLS. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

# Allow release.sh (or callers) to stamp a version: VERSION=0.1.1 ./scripts/build-app.sh
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION:-0.2.4}" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true

# Ad-hoc code-sign the finished bundle. Without this the app is only
# linker-signed with an identifier that doesn't match CFBundleIdentifier, and
# macOS refuses to register it with Notification Center (so every notification
# is silently dropped) and re-prompts for Keychain access unpredictably. This
# is NOT a Developer ID signature — see scripts/release.sh for signed +
# notarized builds — but it gives the app a consistent, registrable identity.
# The signing identifier defaults to CFBundleIdentifier (com.sgsi.claudeometer).
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
