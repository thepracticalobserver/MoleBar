#!/bin/bash
# Builds a universal MoleBar.app and packages it into build/MoleBar.dmg
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MoleBar
APP=build/MoleBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/MoleBar"
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
codesign --force --sign - "$APP"
STAGE=build/dmg-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f build/MoleBar.dmg
hdiutil create -volname "MoleBar" -srcfolder "$STAGE" -ov -format UDZO build/MoleBar.dmg
rm -rf "$STAGE"
lipo -archs "$APP/Contents/MacOS/MoleBar"
ls -lh build/MoleBar.dmg
