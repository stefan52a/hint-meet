#!/bin/sh
# Bouwt HintMeet.app in app/build/ en installeert hem in ~/Applications (Spotlight, Launchpad, Dock).
# De app onthoudt waar deze repo staat, zodat hij de pijplijn uit .venv kan starten.
# Developer ID en notarisatie volgen later (M6).
set -e
cd "$(dirname "$0")/HintMeet"
REPO=$(cd ../.. && pwd)
swift build -c release
APP=../build/HintMeet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HintMeet "$APP/Contents/MacOS/HintMeet"
ICONSET=../build/AppIcon.iconset
rm -rf "$ICONSET"
swift ../make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HintMeet</string>
  <key>CFBundleIdentifier</key><string>com.zoof-it.hintmeet</string>
  <key>CFBundleExecutable</key><string>HintMeet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSMicrophoneUsageDescription</key><string>HintMeet luistert mee tijdens je meeting om op het juiste moment een hint uit je dossier te tonen. Audio en transcriptie blijven op deze Mac.</string>
</dict>
</plist>
PLIST
# via plutil, zodat tekens als & of < in het pad de plist niet breken
plutil -insert HintMeetRepo -string "$REPO" "$APP/Contents/Info.plist"
# ad-hoc ondertekenen: nodig voor microfoontoestemming; Developer ID en notarisatie volgen later
codesign --force --deep --sign - "$APP"
echo "Gebouwd: $(cd ../build && pwd)/HintMeet.app"

# installeren: een draaiende HintMeet blijft draaien; Herstarten in het 💡-menu pakt de nieuwe versie op
DEST="$HOME/Applications/HintMeet.app"
mkdir -p "$HOME/Applications"
# eerst ernaast kopiëren, dan pas vervangen: mislukt het kopiëren, dan blijft de oude app staan
rm -rf "$DEST.new"
cp -R "$APP" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "Geïnstalleerd: $DEST"
