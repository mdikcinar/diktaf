#!/usr/bin/env bash
# Builds Diktaf and puts it in ~/Applications, started at login.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Applications/Diktaf.app"
AGENT="$HOME/Library/LaunchAgents/com.mdikcinar.diktaf.plist"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/diktaf.log"

say()  { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }

"$DIR/Scripts/build-app.sh" release

echo "Installing Diktaf"
echo "─────────────────"

# Copied rather than symlinked: a launch agent that points into a build
# directory breaks the next time the tree is cleaned, and the copy is what
# macOS hangs its permissions on.
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$DIR/build/Diktaf.app" "$DEST"
ok "Installed: $DEST"

mkdir -p "$(dirname "$AGENT")" "$(dirname "$LOG")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.mdikcinar.diktaf</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/Diktaf</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <!-- Started by launchd, so there is no terminal to complain to. Without
       these, a Diktaf that dies on startup does so in silence. -->
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

# Booted out first so this script can be re-run; neither step is worth failing
# over, since the next login loads it either way.
launchctl bootout "gui/$(id -u)/com.mdikcinar.diktaf" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null; then
  ok "Will start at login (and is starting now)"
else
  say "Could not load the launch agent; it will start at your next login."
fi

echo
say "macOS will ask for the microphone and for speech recognition the first"
say "time you dictate. Pasting needs one more, which it cannot ask for:"
say "System Settings → Privacy & Security → Accessibility → allow Diktaf."
say "Diktaf says so in the menu bar until it has been allowed."
echo
