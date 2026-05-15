#!/usr/bin/env bash
# Perstalk launcher.
#
# Usage:
#   ./start.sh                                                    # default port 5050
#   PERSTALK_PORT=8080 ./start.sh                                 # custom port
#   PERSTALK_MODEL=mlx-community/whisper-base-mlx ./start.sh      # smaller speech model
#   PERSTALK_LLM=mlx-community/Llama-3.2-3B-Instruct-4bit ./start.sh
#
# On first run this creates a virtualenv and installs dependencies. Subsequent
# runs just re-activate the venv and start the server.

set -euo pipefail

cd "$(dirname "$0")"

# --- pretty output ------------------------------------------------------------
if [ -t 1 ]; then
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_DIM=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_RESET=''
fi
say()  { printf "%s\n" "$*"; }
warn() { printf "%b%s%b\n" "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf "%b%s%b\n" "$C_RED"    "$*" "$C_RESET" >&2; }
ok()   { printf "%b%s%b\n" "$C_GREEN"  "$*" "$C_RESET"; }

# --- preflight: macOS + Apple Silicon ----------------------------------------
case "$(uname -s)" in
  Darwin) ;;
  *)
    err "Perstalk only runs on macOS (uses Apple's MLX framework)."
    err "Detected: $(uname -s)."
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64) ;;
  *)
    err "Perstalk requires an Apple Silicon Mac (M1 / M2 / M3 / M4)."
    err "Detected architecture: $(uname -m). MLX does not support Intel Macs."
    exit 1
    ;;
esac

# --- preflight: Python 3.9+ --------------------------------------------------
PY=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  err "No python3 found on PATH."
  err "Install Python 3.9+ — easiest path: https://www.python.org/downloads/macos/"
  exit 1
fi

PY_VERSION_OK=$("$PY" -c 'import sys; print(1 if sys.version_info >= (3, 9) else 0)')
if [ "$PY_VERSION_OK" != "1" ]; then
  err "Found $($PY --version 2>&1) — Perstalk needs Python 3.9 or newer."
  exit 1
fi

# --- venv + deps -------------------------------------------------------------
if [ ! -d ".venv" ]; then
  say "${C_BOLD}First run — setting up.${C_RESET}"
  say "${C_DIM}Creating virtualenv with $PY ($($PY --version 2>&1))…${C_RESET}"
  "$PY" -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  say "${C_DIM}Upgrading pip…${C_RESET}"
  pip install --upgrade pip --quiet
  say "${C_DIM}Installing dependencies (this can take a couple of minutes)…${C_RESET}"
  pip install -r requirements.txt
  ok  "Setup complete."
  say ""
else
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

# --- free the port if a previous run is still hanging around ------------------
PORT="${PERSTALK_PORT:-5050}"
if command -v lsof >/dev/null 2>&1 && lsof -ti :"$PORT" >/dev/null 2>&1; then
  warn "Port $PORT is in use — stopping the previous server…"
  lsof -ti :"$PORT" | xargs kill -9 2>/dev/null || true
  sleep 0.3
fi

URL="http://127.0.0.1:$PORT"

# --- launch ------------------------------------------------------------------
say "${C_BOLD}Starting Perstalk${C_RESET} on ${C_GREEN}$URL${C_RESET}  ${C_DIM}(Ctrl+C to stop)${C_RESET}"
say "${C_DIM}First run downloads ~3.6 GB of models from Hugging Face. Then they're cached locally.${C_RESET}"

# Open the browser once the server reports ready (best-effort, fire-and-forget).
if command -v open >/dev/null 2>&1; then
  (
    for _ in $(seq 1 60); do
      sleep 1
      if curl -fsS "$URL/healthz" >/dev/null 2>&1; then
        open "$URL" 2>/dev/null || true
        break
      fi
    done
  ) >/dev/null 2>&1 &
fi

exec python server.py
