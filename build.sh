#!/bin/bash
# Builds MoleBar.app (menu bar only, no Dock icon) into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/MoleBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/MoleBar "$APP/Contents/MacOS/MoleBar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MoleBar</string>
<key>CFBundleIdentifier</key><string>com.local.molebar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>MoleBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
