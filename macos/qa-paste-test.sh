#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

APP_DIR="macos/build/Perstalk Flow.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/PerstalkFlow"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
EXPECTED_PREFIX="Perstalk paste test"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  ./macos/build-app.sh >/dev/null
fi

"$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true

if ! pgrep -x PerstalkFlow >/dev/null 2>&1; then
  open "$APP_DIR"
  sleep 2
fi

before_method="$(defaults read ai.perstalk.flow LastInsertionMethod 2>/dev/null || true)"

osascript <<'APPLESCRIPT'
tell application "TextEdit"
    activate
    make new document with properties {text:""}
end tell
APPLESCRIPT

sleep 1
open perstalk-flow://paste-test
sleep 2

document_text="$(osascript <<'APPLESCRIPT'
tell application "TextEdit"
    if (count of documents) is 0 then
        return ""
    end if
    return text of front document
end tell
APPLESCRIPT
)"
clipboard_text="$(pbpaste)"
after_method="$(defaults read ai.perstalk.flow LastInsertionMethod 2>/dev/null || true)"

printf 'Last insertion before: %s\n' "${before_method:-Not recorded}"
printf 'Last insertion after:  %s\n' "${after_method:-Not recorded}"

if [[ "$document_text" == "$EXPECTED_PREFIX"* ]]; then
  printf 'Result: inserted into TextEdit\n'
  exit 0
fi

if [[ "$clipboard_text" == "$EXPECTED_PREFIX"* && "$after_method" == *"TextEdit"* ]]; then
  printf 'Result: copied fallback for TextEdit\n'
  printf 'Note: grant Accessibility permission to verify automatic paste-at-cursor.\n'
  exit 0
fi

if [[ "$clipboard_text" == "$EXPECTED_PREFIX"* && "$after_method" == *"Clipboard paste fallback"* ]]; then
  printf 'Result: copied fallback via URL paste path\n'
  printf 'Note: LaunchServices may briefly change the frontmost app in development QA.\n'
  printf 'Note: grant Accessibility permission to verify automatic paste-at-cursor.\n'
  exit 0
fi

printf 'Result: paste test did not reach TextEdit or clipboard as expected.\n' >&2
printf 'TextEdit text: %s\n' "$document_text" >&2
printf 'Clipboard: %s\n' "$clipboard_text" >&2
exit 1
