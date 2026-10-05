"""Scribe settings from the environment (compose passes only what it needs)."""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

MAX_SESSION_SECONDS = 4 * 60 * 60
LEFTOVER_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
WHISPER_MAX_MB = 2000


def _env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def _env_int(name: str, default: int) -> int:
    try:
        return int(_env(name, str(default)))
    except ValueError:
        return default


@dataclass(frozen=True)
class ScribeConfig:
    # Drive ↔ Scribe bearer (its own random secret; required, no fallback).
    internal_token: str
    # Drive app as seen from the Scribe's bridge network; notes status goes here.
    drive_url: str
    # Portal origin, e.g. https://portal.example.com. Start requests must match it.
    portal_base_url: str
    # Meeting room Worker origin. Start requests' roomUrl must match it.
    meeting_room_url: str
    # The notes folder, mounted alone (container path) ...
    meetings_dir: Path
    # ... and its Drive-relative name, reported to the Portal.
    meetings_root: str
    tmp_dir: Path
    whisper_model: str
    whisper_threads: int
    ollama_model: str
    # Ollama runs on demand inside this container (ollama_runtime.py).
    ollama_models_dir: Path
    timezone: str
    ollama_bin: str = "ollama"
    ollama_port: int = 11434
    max_session_seconds: int = MAX_SESSION_SECONDS
    # The whisper child is killed above this resident size; that 20-minute piece becomes a gap.
    whisper_max_mb: int = WHISPER_MAX_MB


def load_config() -> ScribeConfig:
    meetings_root = _env("IFD_MEETINGS_ROOT", ".ifd-meetings").strip("/")
    if not meetings_root or ".." in meetings_root.split("/"):
        meetings_root = ".ifd-meetings"
    return ScribeConfig(
        internal_token=_env("SCRIBE_INTERNAL_TOKEN"),
        drive_url=_env("SCRIBE_DRIVE_URL", "http://host.docker.internal:8787").rstrip("/"),
        portal_base_url=_env("PORTAL_BASE_URL").rstrip("/"),
        meeting_room_url=_env("MEETING_ROOM_URL").rstrip("/"),
        meetings_dir=Path(_env("SCRIBE_MEETINGS_DIR", "/meetings")),
        meetings_root=meetings_root,
        tmp_dir=Path(_env("IFD_SCRIBE_TMP", "/scribe-tmp")),
        whisper_model=_env("SCRIBE_WHISPER_MODEL", "small.en"),
        whisper_threads=max(1, _env_int("SCRIBE_WHISPER_THREADS", 2)),
        ollama_model=_env("SCRIBE_OLLAMA_MODEL", "qwen2.5:1.5b"),
        ollama_models_dir=Path(_env("OLLAMA_MODELS", "/models/ollama")),
        timezone=_env("SCRIBE_TIMEZONE", "America/Los_Angeles"),
        whisper_max_mb=max(500, _env_int("SCRIBE_WHISPER_MAX_MB", WHISPER_MAX_MB)),
    )


@lru_cache
def get_config() -> ScribeConfig:
    return load_config()
