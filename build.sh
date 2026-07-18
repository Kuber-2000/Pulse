#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pulse"
APP_DIR="${APP_NAME}.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp Info.plist "$APP_DIR/Contents/Info.plist"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

swiftc -O main.swift Sensors.swift \
  -framework Cocoa \
  -framework IOKit \
  -framework QuartzCore \
  -framework ServiceManagement \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

# Force LaunchServices to re-read the bundle (so LSUIElement is honored).
touch "$APP_DIR"

echo
echo "Built $APP_DIR"
echo "  Run:        open $APP_DIR"
echo "  Install:    mv $APP_DIR /Applications/"
echo "  Login item: System Settings → General → Login Items → +"
