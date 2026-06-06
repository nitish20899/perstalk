#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Perstalk Flow"
APP_DIR="macos/build/$APP_NAME.app"
DIST_DIR="macos/dist"
VERSION="$(plutil -extract CFBundleShortVersionString raw macos/Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw macos/Info.plist)"
ARCHIVE_BASENAME="Perstalk-Flow-${VERSION}-${BUILD}"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_BASENAME.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

./macos/smoke-test.sh >/dev/null

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

printf '%s\n' "$ARCHIVE_PATH"
printf '%s\n' "$CHECKSUM_PATH"
