#!/bin/zsh
# Builds AlbumWall.app (Apple Silicon + Intel) next to this script.
#   ./build.sh          → AlbumWall.app
#   ./build.sh --zip    → also AlbumWall.zip, ready to attach to a GitHub release
set -e
cd "$(dirname "$0")"
APP=AlbumWall.app
BIN="$APP/Contents/MacOS/AlbumWall"
VERSION=1.0.1

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

for ARCH in arm64 x86_64; do
  swiftc -O main.swift -target "$ARCH-apple-macos13.0" -o "build/AlbumWall-$ARCH" \
    -framework Cocoa -framework WebKit -framework ServiceManagement
done
lipo -create build/AlbumWall-arm64 build/AlbumWall-x86_64 -output "$BIN"
rm -rf build

cp -R web "$APP/Contents/Resources/web"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AlbumWall</string>
  <key>CFBundleIdentifier</key><string>io.github.bstnys.albumwall</string>
  <key>CFBundleExecutable</key><string>AlbumWall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Spotify 또는 음악 앱에서 재생 중인 곡의 앨범 커버를 바탕화면에 보여주고, 커버 클릭으로 재생/일시정지하기 위해 필요합니다.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Built $(pwd)/$APP ($(lipo -archs "$BIN"))"

if [[ "$1" == "--zip" ]]; then
  rm -f AlbumWall.zip
  ditto -c -k --keepParent "$APP" AlbumWall.zip
  echo "Zipped $(pwd)/AlbumWall.zip"
fi
