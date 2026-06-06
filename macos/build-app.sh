#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Perstalk Flow"
EXECUTABLE_NAME="PerstalkFlow"
PACKAGE_DIR="PerstalkMac"
BUILD_DIR="$PWD/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
ICON_SOURCE="$PWD/AppIcon.svg"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
CODESIGN_IDENTITY="${PERSTALK_CODESIGN_IDENTITY:--}"

swift build \
  --package-path "$PACKAGE_DIR" \
  --configuration release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/backend"

if [[ -f "$ICON_SOURCE" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  qlmanage -t -s 1024 -o "$ICONSET_DIR" "$ICON_SOURCE" >/dev/null 2>&1
  ICON_PNG="$ICONSET_DIR/$(basename "$ICON_SOURCE").png"
  if [[ ! -f "$ICON_PNG" ]]; then
    printf 'Could not render %s\n' "$ICON_SOURCE" >&2
    exit 1
  fi

  sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
  rm "$ICON_PNG"
  iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cp "$PACKAGE_DIR/.build/release/PerstalkMac" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "Info.plist" "$APP_DIR/Contents/Info.plist"
cp "../server.py" "$APP_DIR/Contents/Resources/backend/server.py"
cp "../text_formatting.py" "$APP_DIR/Contents/Resources/backend/text_formatting.py"
cp "../index.html" "$APP_DIR/Contents/Resources/backend/index.html"
cp "../requirements.txt" "$APP_DIR/Contents/Resources/backend/requirements.txt"

xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR" >/dev/null
xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -dr 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true

printf '%s\n' "$APP_DIR"
