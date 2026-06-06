#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

APP_DIR="macos/build/Perstalk Flow.app"
CONTENTS_DIR="$APP_DIR/Contents"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
BACKEND_DIR="$CONTENTS_DIR/Resources/backend"
EXECUTABLE="$CONTENTS_DIR/MacOS/PerstalkFlow"
ICON="$CONTENTS_DIR/Resources/AppIcon.icns"

pass() {
  printf '✓ %s\n' "$1"
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'Missing required file: %s\n' "$path" >&2
    exit 1
  fi
}

require_executable() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    printf 'Missing executable: %s\n' "$path" >&2
    exit 1
  fi
}

require_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plutil -extract "$key" raw "$INFO_PLIST")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected %s=%s, got %s\n' "$key" "$expected" "$actual" >&2
    exit 1
  fi
}

./macos/build-app.sh >/dev/null
pass "built app bundle"

require_file "$INFO_PLIST"
require_executable "$EXECUTABLE"
require_file "$ICON"
require_file "$BACKEND_DIR/server.py"
require_file "$BACKEND_DIR/text_formatting.py"
require_file "$BACKEND_DIR/index.html"
require_file "$BACKEND_DIR/requirements.txt"
pass "required bundle files exist"

plutil -lint "$INFO_PLIST" >/dev/null
require_plist_value "CFBundleExecutable" "PerstalkFlow"
require_plist_value "CFBundleIdentifier" "ai.perstalk.flow"
require_plist_value "CFBundleIconFile" "AppIcon"
require_plist_value "LSUIElement" "true"
require_plist_value "NSMicrophoneUsageDescription" \
  "Perstalk records your voice so it can transcribe and rewrite your dictation locally."
plutil -p "$INFO_PLIST" | grep -q "perstalk-flow"
pass "Info.plist is valid"

codesign --verify --deep "$APP_DIR"
pass "codesign verification passed"

file "$ICON" | grep -q "Mac OS X icon"
pass "app icon is an icns"

bash -n start.sh macos/build-app.sh macos/package-app.sh macos/qa-paste-test.sh macos/smoke-test.sh
pass "shell scripts parse"

python3 -m py_compile "$BACKEND_DIR/server.py" "$BACKEND_DIR/text_formatting.py"
rm -rf "$BACKEND_DIR/__pycache__"
pass "bundled backend compiles"

grep -q "@app.post(\"/dictate\")" "$BACKEND_DIR/server.py"
grep -q "formatted_transcript" "$BACKEND_DIR/server.py"
pass "bundled backend includes native dictation endpoint"

grep -q "_current_rewrite_prompt()" "$BACKEND_DIR/server.py"
pass "bundled backend warms production rewrite prompt"

grep -q "text_formatting.py" macos/PerstalkMac/Sources/PerstalkMac/BackendProcess.swift
pass "bundled runtime copy list includes backend helpers"

printf 'Perstalk Flow smoke test passed: %s\n' "$APP_DIR"
