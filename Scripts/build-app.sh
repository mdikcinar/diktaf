#!/usr/bin/env bash
# Assembles Diktaf.app around the built executable.
#
# A bundle rather than a bare binary, and not for tidiness: an accessory app
# needs an Info.plist to stay out of the Dock, the microphone and speech
# permissions are refused outright without their usage descriptions in it, and
# every permission macOS grants is granted to a bundle identity. A loose
# executable can be built and run, but it cannot be allowed to do anything.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$DIR/build/Diktaf.app"
BUNDLE_ID="com.mdikcinar.diktaf"

say() { printf '  %s\n' "$1"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }

echo
echo "Building Diktaf ($CONFIG)"
echo "─────────────────────────"

swift build -c "$CONFIG" --package-path "$DIR"
BIN="$(swift build -c "$CONFIG" --package-path "$DIR" --show-bin-path)/diktaf"
[[ -x "$BIN" ]] || { echo "no executable at $BIN" >&2; exit 1; }
ok "Compiled: $BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Diktaf"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Diktaf</string>
  <key>CFBundleDisplayName</key><string>Diktaf</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Diktaf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <!-- In the menu bar, never in the Dock, and not activated by showing a window. -->
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Diktaf records what you dictate so it can be turned into text.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Diktaf uses the speech recogniser built into macOS to turn your dictation into text on this Mac.</string>
</dict>
</plist>
EOF
ok "Bundle: $APP"

# Ad-hoc, because there is nothing to notarise for a locally built app. Worth
# knowing: the identity is what macOS hangs a permission on, and an ad-hoc
# signature changes with the binary — so Accessibility may have to be granted
# again after a rebuild. A real signing identity, if you have one, avoids that:
#   DIKTAF_SIGN_IDENTITY="Developer ID Application: ..." Scripts/build-app.sh
codesign --force --sign "${DIKTAF_SIGN_IDENTITY:--}" \
         --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1
ok "Signed (${DIKTAF_SIGN_IDENTITY:-ad-hoc})"

echo
ok "Done. Run it with:  open $APP"
say "Or install it into ~/Applications with:  Scripts/install.sh"
echo
