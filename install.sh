#!/bin/bash
# Builds the app and (re)installs the LaunchAgent that keeps it running.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

LABEL="space.tabataba.claude-touchbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(pwd)/ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed and started $LABEL"
[ -e /etc/sudoers.d/claude-touchbar ] || echo "keep-awake while remote-control is on is not set up yet: run ./install-awake.sh"
