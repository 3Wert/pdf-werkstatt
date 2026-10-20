#!/bin/zsh
# Baut PDF-Werkstatt.app und installiert nach ~/Applications.
set -e
cd "$(dirname "$0")"
# Vor jedem Bau den Stand festhalten; build.sh schiebt ihn danach zu GitHub
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  git add -A && git commit -q -m "Automatischer Stand vor Build $(date '+%d.%m.%Y %H:%M')" && echo "Stand gesichert: $(git rev-parse --short HEAD)"
fi
NAME="PDF-Werkstatt"
ZIEL="$HOME/Applications/$NAME.app"
APP="$PWD/build/$NAME.app"
VERSION="$(cat VERSION 2>/dev/null || echo 1.0)"
BUILD=$(date +%Y%m%d%H%M)

mkdir -p build
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -o build/PDFWerkstatt Sources/*.swift -framework AppKit -framework PDFKit -framework AVFoundation -framework CoreImage -framework Vision
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
# Release auf GitHub (öffentlich): Zip + aktuell.json; die App holt sich Updates von dort.
# Ohne Release bauen: PDFW_NO_RELEASE=1 ./build.sh
if [ -z "$PDFW_NO_RELEASE" ]; then
  OUT="build/release"; rm -rf "$OUT"; mkdir -p "$OUT"
  ZIPNAME="PDF-Werkstatt-$VERSION-$BUILD.zip"
  ditto -c -k --keepParent "$ZIEL" "$OUT/$ZIPNAME"
  cp "$OUT/$ZIPNAME" "$OUT/PDF-Werkstatt.zip"      # fester Name für die Anleitung
  SHA=$(shasum -a 256 "$OUT/$ZIPNAME" | cut -d' ' -f1)
  NOTES=$(awk '/^## /{n++; next} n==1 && /^- /{sub(/^- /,""); gsub(/"/,"\\\""); printf "%s\"%s\"", (c++?",":""), $0}' CHANGES.md 2>/dev/null)
  cat > "$OUT/aktuell.json" <<J
{"version":"$VERSION","build":"$BUILD","date":"$(date '+%d.%m.%Y')","file":"$ZIPNAME","sha256":"$SHA","notes":[$NOTES]}
J
  awk '/^## /{n++; if(n>1) exit} n==1' CHANGES.md > "$OUT/notes.md" 2>/dev/null || echo "Version $VERSION" > "$OUT/notes.md"
  git push -q origin HEAD 2>/dev/null || echo "Hinweis: Push fehlgeschlagen (offline?)"
  if gh release create "v$VERSION-$BUILD" "$OUT/$ZIPNAME" "$OUT/PDF-Werkstatt.zip" "$OUT/aktuell.json" --title "PDF-Werkstatt $VERSION ($BUILD)" --notes-file "$OUT/notes.md" >/dev/null 2>&1; then
    echo "Release veröffentlicht: v$VERSION-$BUILD → https://github.com/3Wert/pdf-werkstatt/releases/latest"
  else
    echo "Hinweis: Release nicht veröffentlicht (offline oder gh nicht angemeldet)"
  fi
fi
echo "Installiert: $ZIEL"
