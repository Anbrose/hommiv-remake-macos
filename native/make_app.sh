#!/bin/bash
# Wrap the h4view executable into a minimal .app bundle so it launches like a normal
# macOS app (Dock icon, foreground window on the current Space).
#
#   ./make_app.sh                       builds release and creates build/h4view.app
#   open build/h4view.app --args <heroes4.h4r> <map.h4c>
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/h4view.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/h4view "$APP/Contents/MacOS/h4view"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>h4view</string>
  <key>CFBundleIdentifier</key><string>dev.homm4mac.h4view</string>
  <key>CFBundleName</key><string>h4view</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "created $APP"
