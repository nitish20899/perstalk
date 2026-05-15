"""Perstalk — local speech-to-text + rewrite, powered by mlx-whisper and mlx-lm.

Single-page app: serves index.html and exposes
  - POST /transcribe : 16 kHz mono WAV  → text
  - POST /rewrite    : { "text": "..." } → grammar-cleaned text via local LLM
  - GET  /status     : combined readiness for both models

Both models are downloaded and warmed at startup so user actions don't block
on multi-GB downloads.
"""

from __future__ import annotations

import io
import json
import os
import sys
import threading
import time
import wave
from pathlib import Path
from typing import Optional

import numpy as np
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

# --- model configuration ------------------------------------------------------
# Whisper (speech → text). large-v3-turbo is the latest Whisper model: distilled
# from large-v3, ~8x faster decoding with near-identical accuracy. ~1.6 GB.
ASR_MODEL = os.environ.get("PERSTALK_MODEL", "mlx-community/whisper-large-v3-turbo")

# LLM (text → cleaned text). Qwen2.5-3B-Instruct-4bit is small (~2 GB), very
# fast on Apple Silicon, and excellent at instruction-following edits.
LLM_MODEL = os.environ.get("PERSTALK_LLM", "mlx-community/Qwen2.5-3B-Instruct-4bit")

BASE_DIR = Path(__file__).parent.resolve()
INDEX_FILE = BASE_DIR / "index.html"
SETTINGS_FILE = BASE_DIR / "settings.json"

app = FastAPI(title="Perstalk", version="0.4.0")


# --- shared readiness state ---------------------------------------------------
class StageState:
    """Tracks background download + warmup of a single model."""

    def __init__(self, label: str) -> None:
        self.label = label
        self.status = "pending"  # pending | downloading | warming | ready | error
        self.message = "Pending…"
        self.error: str | None = None
        self.ready_at: float | None = None
        self.started_at = time.time()
        self._lock = threading.Lock()

    def set(self, status: str, message: str, error: str | None = None) -> None:
        with self._lock:
            self.status = status
            self.message = message
            self.error = error
            if status == "ready":
                self.ready_at = time.time()

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "status": self.status,
                "message": self.message,
                "error": self.error,
                "ready_after_s": (
                    round(self.ready_at - self.started_at, 1) if self.ready_at else None
                ),
            }


ASR_STATE = StageState("asr")
LLM_STATE = StageState("llm")

# Lazily populated after warmup so transcribe/rewrite avoid per-request load.
_llm_model = None
_llm_tokenizer = None


# --- background warmup --------------------------------------------------------
def _warm_asr() -> None:
    try:
        ASR_STATE.set("downloading", f"Downloading {ASR_MODEL}…")
        print(f"[perstalk][asr] ensuring cached: {ASR_MODEL}", flush=True)

        from huggingface_hub import snapshot_download

        snapshot_download(
            repo_id=ASR_MODEL,
            allow_patterns=["*.json", "*.txt", "*.npz", "*.safetensors", "tokenizer*"],
        )

        ASR_STATE.set("warming", "Warming up speech model…")
        print("[perstalk][asr] warming model…", flush=True)

        import mlx_whisper

        silence = np.zeros(16000, dtype=np.float32)
        mlx_whisper.transcribe(silence, path_or_hf_repo=ASR_MODEL)

        ASR_STATE.set("ready", "Ready.")
        print("[perstalk][asr] ready.", flush=True)
    except Exception as exc:  # noqa: BLE001
        msg = f"{type(exc).__name__}: {exc}"
        print(f"[perstalk][asr] failed: {msg}", file=sys.stderr, flush=True)
        ASR_STATE.set("error", "Failed to load speech model.", error=msg)


def _warm_llm() -> None:
    global _llm_model, _llm_tokenizer
    try:
        LLM_STATE.set("downloading", f"Downloading {LLM_MODEL}…")
        print(f"[perstalk][llm] loading: {LLM_MODEL}", flush=True)

        from mlx_lm import generate as lm_generate
        from mlx_lm import load as lm_load
        from mlx_lm.sample_utils import make_sampler

        _llm_model, _llm_tokenizer = lm_load(LLM_MODEL)

        LLM_STATE.set("warming", "Warming up rewrite model…")
        print("[perstalk][llm] warming…", flush=True)

        messages = [
            {"role": "system", "content": "You echo a single word."},
            {"role": "user", "content": "ok"},
        ]
        prompt = _llm_tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
        lm_generate(
            _llm_model,
            _llm_tokenizer,
            prompt=prompt,
            max_tokens=4,
            sampler=make_sampler(temp=0.0),
        )

        LLM_STATE.set("ready", "Ready.")
        print("[perstalk][llm] ready.", flush=True)
    except Exception as exc:  # noqa: BLE001
        msg = f"{type(exc).__name__}: {exc}"
        print(f"[perstalk][llm] failed: {msg}", file=sys.stderr, flush=True)
        LLM_STATE.set("error", "Failed to load rewrite model.", error=msg)


@app.on_event("startup")
def _start_warmup() -> None:
    threading.Thread(target=_warm_asr, name="perstalk-asr", daemon=True).start()
    threading.Thread(target=_warm_llm, name="perstalk-llm", daemon=True).start()


# --- audio helpers ------------------------------------------------------------
def _wav_bytes_to_float32(raw: bytes) -> np.ndarray:
    with wave.open(io.BytesIO(raw), "rb") as wav:
        n_channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        framerate = wav.getframerate()
        n_frames = wav.getnframes()
        frames = wav.readframes(n_frames)

    if sample_width != 2:
        raise HTTPException(
            status_code=400,
            detail=f"Expected 16-bit PCM WAV, got sample width {sample_width} bytes.",
        )

    audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    if n_channels > 1:
        audio = audio.reshape(-1, n_channels).mean(axis=1)

    if framerate != 16000:
        duration = audio.shape[0] / float(framerate)
        target_len = int(round(duration * 16000))
        if target_len <= 0:
            raise HTTPException(status_code=400, detail="Empty audio payload.")
        x_old = np.linspace(0.0, 1.0, audio.shape[0], endpoint=False)
        x_new = np.linspace(0.0, 1.0, target_len, endpoint=False)
        audio = np.interp(x_new, x_old, audio).astype(np.float32)

    return audio


# --- routes -------------------------------------------------------------------
@app.get("/")
def root() -> FileResponse:
    return FileResponse(INDEX_FILE)


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True, "asr_model": ASR_MODEL, "llm_model": LLM_MODEL}


@app.get("/status")
def status() -> dict:
    return {
        "asr": {"model": ASR_MODEL, **ASR_STATE.snapshot()},
        "llm": {"model": LLM_MODEL, **LLM_STATE.snapshot()},
    }


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)) -> JSONResponse:
    snap = ASR_STATE.snapshot()
    if snap["status"] != "ready":
        if snap["status"] == "error":
            raise HTTPException(
                status_code=503, detail=snap["error"] or "Speech model failed to load."
            )
        raise HTTPException(
            status_code=503,
            detail=f"Speech model not ready yet ({snap['status']}: {snap['message']}).",
        )

    raw = await audio.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty upload.")

    samples = _wav_bytes_to_float32(raw)

    if samples.size < 1600:
        return JSONResponse({"text": "", "duration_ms": 0, "elapsed_ms": 0})

    import mlx_whisper

    started = time.perf_counter()
    result = mlx_whisper.transcribe(samples, path_or_hf_repo=ASR_MODEL)
    elapsed_ms = int((time.perf_counter() - started) * 1000)

    text = (result.get("text") or "").strip()
    return JSONResponse(
        {
            "text": text,
            "language": result.get("language"),
            "duration_ms": int(samples.size / 16),
            "elapsed_ms": elapsed_ms,
            "model": ASR_MODEL,
        }
    )


class RewriteRequest(BaseModel):
    text: str


DEFAULT_REWRITE_PROMPT = (
    "You are a precise text editor. Rewrite the user's text to fix grammar, "
    "spelling, and punctuation; remove disfluencies and filler words "
    "(um, uh, like, you know, sort of, kind of); and improve clarity and flow.\n"
    "\n"
    "Rules:\n"
    "- Preserve the original meaning, tone, voice, and point of view (do not "
    "change first person to third person).\n"
    "- Do not add new facts, opinions, or content that wasn't there.\n"
    "- Do not translate. Keep the same language as the input.\n"
    "- Return ONLY the rewritten text. No preamble, no commentary, no "
    "quotation marks, no markdown."
)


# In-memory copy of user-editable settings (persisted to SETTINGS_FILE).
_settings_lock = threading.Lock()
_settings = {"rewrite_prompt": DEFAULT_REWRITE_PROMPT}


def _load_settings_from_disk() -> None:
    if not SETTINGS_FILE.exists():
        return
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(
            f"[perstalk][settings] could not read {SETTINGS_FILE.name}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        return
    prompt = data.get("rewrite_prompt")
    if isinstance(prompt, str) and prompt.strip():
        with _settings_lock:
            _settings["rewrite_prompt"] = prompt
        print(
            f"[perstalk][settings] loaded user prompt from {SETTINGS_FILE.name}",
            flush=True,
        )


def _save_settings_to_disk() -> None:
    with _settings_lock:
        payload = dict(_settings)
    try:
        SETTINGS_FILE.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        print(
            f"[perstalk][settings] could not write {SETTINGS_FILE.name}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        raise HTTPException(status_code=500, detail="Could not save settings.") from exc


def _current_rewrite_prompt() -> str:
    with _settings_lock:
        return _settings["rewrite_prompt"]


_load_settings_from_disk()


class SettingsUpdate(BaseModel):
    # Optional[...] (not "X | None") because Pydantic v2 evaluates string
    # annotations at runtime, and "X | None" requires Python 3.10+. Perstalk
    # supports 3.9. The ruff hint to use the new syntax is wrong here.
    rewrite_prompt: Optional[str] = None  # noqa: UP045
    reset: Optional[bool] = False  # noqa: UP045


@app.get("/settings")
def get_settings() -> dict:
    return {
        "rewrite_prompt": _current_rewrite_prompt(),
        "default_rewrite_prompt": DEFAULT_REWRITE_PROMPT,
        "is_default": _current_rewrite_prompt() == DEFAULT_REWRITE_PROMPT,
    }


@app.put("/settings")
def put_settings(update: SettingsUpdate) -> dict:
    if update.reset:
        with _settings_lock:
            _settings["rewrite_prompt"] = DEFAULT_REWRITE_PROMPT
    elif update.rewrite_prompt is not None:
        new_prompt = update.rewrite_prompt.strip()
        if not new_prompt:
            raise HTTPException(status_code=400, detail="Prompt cannot be empty.")
        if len(new_prompt) > 8000:
            raise HTTPException(status_code=400, detail="Prompt too long (max 8000 chars).")
        with _settings_lock:
            _settings["rewrite_prompt"] = new_prompt
    else:
        raise HTTPException(status_code=400, detail="No changes provided.")

    _save_settings_to_disk()
    return get_settings()


def _strip_quotes(s: str) -> str:
    s = s.strip()
    pairs = [('"', '"'), ("'", "'"), ("\u201c", "\u201d"), ("\u2018", "\u2019")]
    for a, b in pairs:
        if len(s) >= 2 and s.startswith(a) and s.endswith(b):
            inner = s[1:-1].strip()
            if a not in inner and b not in inner:
                s = inner
                break
    return s


@app.post("/rewrite")
async def rewrite(req: RewriteRequest) -> JSONResponse:
    snap = LLM_STATE.snapshot()
    if snap["status"] != "ready":
        if snap["status"] == "error":
            raise HTTPException(
                status_code=503, detail=snap["error"] or "Rewrite model failed to load."
            )
        raise HTTPException(
            status_code=503,
            detail=f"Rewrite model not ready yet ({snap['status']}: {snap['message']}).",
        )

    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Empty text.")
    if len(text) > 20000:
        raise HTTPException(status_code=400, detail="Text too long (max 20,000 chars).")

    from mlx_lm import generate as lm_generate
    from mlx_lm.sample_utils import make_sampler

    messages = [
        {"role": "system", "content": _current_rewrite_prompt()},
        {"role": "user", "content": text},
    ]
    prompt = _llm_tokenizer.apply_chat_template(
        messages, add_generation_prompt=True, tokenize=False
    )

    # Generous max_tokens: roughly 1.5x input length should always be enough.
    input_tokens = len(_llm_tokenizer.encode(text))
    max_tokens = min(4096, max(256, int(input_tokens * 1.5) + 64))

    started = time.perf_counter()
    out = lm_generate(
        _llm_model,
        _llm_tokenizer,
        prompt=prompt,
        max_tokens=max_tokens,
        sampler=make_sampler(temp=0.0),
    )
    elapsed_ms = int((time.perf_counter() - started) * 1000)

    cleaned = _strip_quotes(out)
    return JSONResponse(
        {
            "text": cleaned,
            "elapsed_ms": elapsed_ms,
            "model": LLM_MODEL,
            "max_tokens": max_tokens,
        }
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host=os.environ.get("PERSTALK_HOST", "127.0.0.1"),
        port=int(os.environ.get("PERSTALK_PORT", "5050")),
        reload=False,
    )
