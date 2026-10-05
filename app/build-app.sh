#!/bin/sh
# Bouwt HintMeet.app (overlay) in app/build/. Nog niet ondertekend; dat komt in M6.
set -e
cd "$(dirname "$0")/HintMeet"
swift build -c release
APP=../build/HintMeet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/HintMeet "$APP/Contents/MacOS/HintMeet"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HintMeet</string>
  <key>CFBundleIdentifier</key><string>com.zoof-it.hintmeet</string>
  <key>CFBundleExecutable</key><string>HintMeet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>HintMeet luistert mee tijdens je meeting om op het juiste moment een hint uit je dossier te tonen. Audio en transcriptie blijven op deze Mac.</string>
</dict>
</plist>
PLIST
# ad-hoc ondertekenen: nodig voor microfoontoestemming; Developer ID en notarisatie volgen later
codesign --force --deep --sign - "$APP"
echo "Gebouwd: $(cd ../build && pwd)/HintMeet.app"
