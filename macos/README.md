# Perstalk Flow for macOS

Native macOS shell for Perstalk's local MLX dictation backend.

This is the first step toward a Wispr Flow-style workflow:

- Runs as a menu-bar app with no Dock icon.
- Shows a fixed bottom-center black pill inspired by Wispr Flow, with cancel
  and finish controls around a live waveform.
- Double-tap Fn/Globe to dictate, then tap Fn/Globe once to process and insert.
- Reports shortcut registration status in Settings and keeps the last working
  shortcut if a newly selected global shortcut cannot register.
- Starts selected-microphone capture immediately on shortcut press, draws a
  rolling waveform from real microphone sample levels, then checks backend/model
  readiness after release before processing.
- Defaults to `whisper-large-v3-turbo` and
  `Qwen2.5-1.5B-Instruct-4bit` for lower rewrite latency.
- Lets you switch local Whisper transcription models and Qwen rewrite models
  independently from Settings.
- Lets you disable Qwen rewrite entirely so inserted output comes directly from
  Whisper transcription.
- Keeps the captured audio queued during first-run model warmup instead of
  failing after a short wait.
- Ignores accidental taps shorter than 350 ms before they hit the backend.
- Sends audio to the existing FastAPI + MLX backend through one `/dictate` call.
- Normalizes common spoken formatting commands such as `comma`, `period`,
  `question mark`, `new line`, and `new paragraph` before rewrite.
- Rewrites the transcript with the local LLM before insertion, with a light
  active-app hint so Mail, Slack, notes, and developer tools can get more
  appropriate formatting.
- Uses Accessibility to insert directly into supported focused text fields, with
  clipboard paste as a fallback that restores the previous clipboard contents.
- Reports the exact latest insertion path: direct insertion, clipboard paste
  fallback, or copy-only mode when Accessibility is not available.
- Includes a paste test in Settings and the menu-bar icon to validate the
  target app, Accessibility permission, and clipboard fallback without recording.
- Auto-dismisses short-lived success, no-speech, and accidental-tap states so
  the popup behaves like a transient overlay.
- Lets you cancel active preparing, warming, or processing from the popup or
  the menu-bar icon.
- Updates menu-bar action labels dynamically so the primary action reflects
  start, stop-and-insert, or cancel.
- Tracks the last external app and reactivates it before paste, so the popup or
  menu bar app does not become the paste destination.
- Keeps the latest 50 cleaned dictations in a local history file so the last
  result can be copied again from the menu if a target app swallows the paste.
- Lets you disable local dictation history entirely from Settings; disabling it
  clears existing entries and stops future saves.
- Lets you clear local dictation history from Settings or the menu-bar icon.
- Includes a simple native Settings window for microphone selection, local model
  selection, rewrite prompt editing, hotkeys, launch at login, backend status,
  and permissions.
- Opens the relevant macOS Privacy & Security pane when microphone or
  Accessibility permission has already been denied.
- Records total, ASR, rewrite, and model names for recent dictations in local
  history for regression checks.
- App-owned backends restart automatically when model settings change.
- Can be configured to open automatically when you log in.
- Builds with a bundled `AppIcon.icns` generated from `macos/AppIcon.svg`.

## Build

From the repo root:

```bash
./macos/build-app.sh
```

The generated app lives at:

```text
macos/build/Perstalk Flow.app
```

## Smoke Test

Run the native bundle audit from the repo root:

```bash
./macos/smoke-test.sh
```

The smoke test rebuilds the app, validates the bundle plist, verifies the local
signature, checks the generated icon, compiles the bundled backend, and confirms
the native `/dictate` endpoint is present.

## Paste QA

Run the local TextEdit paste workflow test from the repo root:

```bash
./macos/qa-paste-test.sh
```

This launches the built app if needed, opens a blank TextEdit document, triggers
`perstalk-flow://paste-test`, and reports whether the sample was inserted into
TextEdit or copied as a permission fallback. A copied fallback means the URL
trigger and target tracking worked, but macOS Accessibility permission still
needs to be granted for automatic paste-at-cursor.

## Package

Create a shareable zip archive and SHA-256 checksum from the repo root:

```bash
./macos/package-app.sh
```

Artifacts are written to:

```text
macos/dist/Perstalk-Flow-<version>-<build>.zip
macos/dist/Perstalk-Flow-<version>-<build>.zip.sha256
```

Verify the archive with:

```bash
shasum -a 256 -c macos/dist/Perstalk-Flow-<version>-<build>.zip.sha256
```

## Run

```bash
open "macos/build/Perstalk Flow.app"
```

The app reuses an already-running backend at `http://127.0.0.1:5050`.

If the backend is not running, it starts one automatically:

- In development, it uses this checkout and `.venv/bin/python` when available.
- If the app is moved outside the repo, it copies the bundled backend into
  `~/Library/Application Support/Perstalk Flow/backend`, creates a private
  `.venv`, installs `requirements.txt`, and launches from there.

Backend setup and server logs are written to:

```text
~/Library/Application Support/Perstalk Flow/backend.log
```

Model files are still cached by Hugging Face under the normal user cache, so
the first launch can still download several GB of MLX model weights.

When Perstalk launches its own backend, it stops that backend on quit. If it
reuses a backend that was already running, it leaves that external process
alone.

Open **Settings...** from the menu-bar icon to choose a microphone, change the
dictation shortcut, select local transcription and rewrite models, toggle Qwen
rewrite, edit the rewrite prompt, enable launch at login, check backend and
permission status, request or reset paste permissions, or run a paste test.

For repeatable target-app QA, focus a text field in the app you want to test and
run:

```bash
open perstalk-flow://paste-test
```

The app also accepts `perstalk-flow://show` and `perstalk-flow://settings` for
opening the popup or Settings window during local testing.

## Native model settings

| Setting | Options | Notes |
| --- | --- | --- |
| Transcribe model | `whisper-large-v3-turbo`, `whisper-base-mlx`, `whisper-small-mlx`, `whisper-large-v3-mlx` | Local Whisper model used for speech-to-text. |
| Rewrite model | `Qwen2.5-1.5B-Instruct-4bit`, `Qwen2.5-3B-Instruct-4bit`, `Qwen2.5-7B-Instruct-4bit` | Local Qwen model used for cleanup when rewrite is enabled. |
| Rewrite toggle | On / Off | Off skips Qwen loading and inserts Whisper output directly. |
| Rewrite prompt | User-editable | Saved through the backend `/settings` endpoint. |

If another process is already serving `127.0.0.1:5050`, Perstalk will reuse it
and cannot restart it to apply model changes. Stop the external backend, then
start from the macOS app to let the selected settings take effect.

Recent cleaned dictations are stored locally at:

```text
~/Library/Application Support/Perstalk Flow/dictation-history.json
```

Use **Copy last dictation** from the menu-bar icon to recover the most recent
cleaned result without opening the history file, **Copy last transcript** to
inspect raw ASR output, or **Copy last formatted transcript** to inspect spoken
formatting normalization before rewrite.

Use **Clear dictation history** from Settings or the menu-bar icon to remove
the local history file contents.

Turn off **Save local dictation history** in Settings to clear existing history
and prevent new dictations from being saved locally.

History entries include total/ASR/rewrite timings and model names so speed
regressions are easier to spot while testing real apps.

## Permissions

macOS will ask for:

- Microphone permission for recording dictation.
- Accessibility permission for automatic paste-at-cursor.

If Accessibility is not approved, Perstalk still copies the cleaned text to the
clipboard. When Accessibility is approved, Perstalk tries direct focused-field
insertion first and only uses the clipboard fallback when the target control
does not support direct text replacement.

If macOS reports stale Accessibility trust for a rebuilt development app,
Perstalk still attempts the clipboard paste keystroke and leaves the cleaned
text on the clipboard so you can press `Command-V` manually if the event is
blocked.

Perstalk does not open the Accessibility prompt automatically after every
dictation. If a rebuilt development app keeps reporting copy-only after you have
already approved it, use **Reset Paste Permission** from Settings or the
menu-bar icon, then approve the current **Perstalk Flow** build in Accessibility.

Development builds are ad-hoc signed by default. For a more official local app
that keeps macOS trust across builds, build with a stable signing identity:

```bash
PERSTALK_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./macos/build-app.sh
```

If microphone or Accessibility access has already been denied, use
**Request / Open Microphone** or **Request / Open Paste Permission** in Settings
to jump directly to the relevant macOS Privacy & Security pane.

## Current Shortcut

`Fn Fn` is the default. Double-tap Fn/Globe to record, then tap Fn/Globe once
to transcribe, rewrite, and insert. You can change it in **Settings...** to
`Option-Space`, `Control-Space`, `Option-D`, or `Control-Option-Space`.

The menu-bar item and popup button still work as start/stop toggles. If the
Fn/Globe key does not reach Perstalk, check macOS Keyboard settings for Globe/Fn
system shortcuts such as dictation or emoji picker.
