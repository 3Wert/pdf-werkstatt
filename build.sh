#!/bin/zsh
# Baut PDF-Werkstatt.app und installiert nach ~/Applications.
set -e
cd "$(dirname "$0")"
# Vor jedem Bau den Stand festhalten (Sicherung landet über den post-commit-Haken in iCloud Drive)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  git add -A && git commit -q -m "Automatischer Stand vor Build $(date '+%d.%m.%Y %H:%M')" && echo "Stand gesichert: $(git rev-parse --short HEAD)"
fi
NAME="PDF-Werkstatt"
ZIEL="$HOME/Applications/$NAME.app"
APP="$PWD/build/$NAME.app"
VERSION="$(cat VERSION 2>/dev/null || echo 1.0)"
BUILD=$(date +%Y%m%d%H%M)

mkdir -p build
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -o build/PDFWerkstatt Sources/*.swift -framework AppKit -framework PDFKit -framework AVFoundation -framework CoreImage
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/PDFWerkstatt "$APP/Contents/MacOS/"

# Symbol (nur neu erzeugen, wenn es fehlt)
if [[ ! -f build/AppIcon.icns ]]; then
  swiftc -o build/icon tools/icon.swift -framework AppKit
  build/icon build/icon_1024.png
  ICS=build/AppIcon.iconset; rm -rf $ICS; mkdir $ICS
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out $ICS/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out $ICS/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICS -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>de.marlonelsner.pdf-werkstatt</string>
  <key>CFBundleExecutable</key><string>PDFWerkstatt</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Marlon Elsner</string>
  <key>NSCameraUsageDescription</key><string>Für das Fotografieren einer Unterschrift auf Papier.</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>PDF-Dokument</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    <key>NSDocumentClass</key><string>WDocument</string>
  </dict></array>
</dict></plist>
PL
codesign --force -s - "$APP"
rm -rf "$ZIEL"; mkdir -p "$HOME/Applications"; mv "$APP" "$ZIEL"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$ZIEL"
# Fertige App als Zip in iCloud Drive + Update-Information (aktuell.json) für die Update-Prüfung
OUT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/PDFWerkstatt"
mkdir -p "$OUT"
ZIPNAME="PDF-Werkstatt-$VERSION-$BUILD.zip"
ditto -c -k --keepParent "$ZIEL" "$OUT/$ZIPNAME"
rm -f "$OUT/PDF-Werkstatt.zip"; cp "$OUT/$ZIPNAME" "$OUT/PDF-Werkstatt.zip"     # fester Name für Anleitungen
ls -t "$OUT"/PDF-Werkstatt-*.zip | tail -n +4 | xargs rm -f 2>/dev/null || true   # nur die letzten drei behalten
SHA=$(shasum -a 256 "$OUT/$ZIPNAME" | cut -d' ' -f1)
# Änderungsliste: Zeilen unter der obersten Überschrift von CHANGES.md
NOTES=$(awk '/^## /{n++; next} n==1 && /^- /{sub(/^- /,""); gsub(/"/,"\\\""); printf "%s\"%s\"", (c++?",":""), $0}' CHANGES.md 2>/dev/null)
cat > "$OUT/aktuell.json" <<J
{"version":"$VERSION","build":"$BUILD","date":"$(date '+%d.%m.%Y')","file":"$ZIPNAME","sha256":"$SHA","notes":[$NOTES]}
J
echo "Update bereitgestellt: $ZIPNAME ($VERSION, Build $BUILD)"
# Optional auch auf den Webserver (für Kollegen ohne iCloud): PDFW_WEB=vps:/opt/3wert-neu/html/pdf-werkstatt ./build.sh
if [ -n "$PDFW_WEB" ]; then
  scp -q "$OUT/$ZIPNAME" "$OUT/aktuell.json" "$PDFW_WEB/" && echo "Auch hochgeladen nach $PDFW_WEB"
fi
echo "Installiert: $ZIEL"
