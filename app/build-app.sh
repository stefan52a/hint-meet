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
# achtergronddienst die HintMeet start als de telefoon aanklopt terwijl de app dicht is (Settings → Phone)
cp .build/release/HintMeetWaker "$APP/Contents/MacOS/HintMeetWaker"
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
# ondertekenen: met het eigen certificaat (app/make-signing-cert.sh) als dat er is, zodat macOS de
# microfoontoestemming na een nieuwe build onthoudt; anders ad-hoc (dan vraagt macOS na elke build opnieuw).
# Developer ID en notarisatie volgen later.
SIGN_ID="HintMeet Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
  echo "Let op: ad-hoc ondertekend. Draai eenmalig app/make-signing-cert.sh, dan vraagt macOS niet na elke build opnieuw om de microfoon."
fi
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
# draait de achtergronddienst voor de telefoon (Settings → Phone → Also when HintMeet is closed): herstarten,
# zodat hij het nieuwe programma gebruikt
if launchctl print "gui/$(id -u)/com.zoof-it.hintmeet.waker" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/com.zoof-it.hintmeet.waker"
fi
echo "Geïnstalleerd: $DEST"
