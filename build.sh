#!/bin/bash
# Builds ClaudeTouchBar.app. It has to be a real bundle: macOS only shows the
# "allow controlling Terminal" prompt for apps with a bundle id and a usage string.
set -euo pipefail
cd "$(dirname "$0")"
APP="ClaudeTouchBar.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O main.swift -o "$APP/Contents/MacOS/ClaudeTouchBar"
codesign --force --sign - --identifier space.tabataba.claude-touchbar "$APP"
echo "built $(pwd)/$APP"
