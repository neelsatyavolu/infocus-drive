"""Shared fakes for the Scribe tests. Importable by spawned child processes too
(the whisper child loads `fake_transcriber` from here)."""

import os
import sys
import time
from pathlib import Path

SCRIBE = str(Path(__file__).resolve().parent.parent / "scribe")
if SCRIBE not in sys.path:
    sys.path.insert(0, SCRIBE)

from app import config as scribe_config  # noqa: E402
from app.transcribe import Segment  # noqa: E402

TOKEN = "s" * 40
MEETING = "cmeet0000000000abc123"
KEY = "B" * 43


def make_cfg(tmp_path, **overrides) -> scribe_config.ScribeConfig:
    base = dict(internal_token=TOKEN, drive_url="http://host.docker.internal:8787",
                portal_base_url="https://portal.example.com", meeting_room_url="https://rooms.example.com",
                meetings_dir=tmp_path / "Meetings", meetings_root="Meetings", tmp_dir=tmp_path / "tmp",
                whisper_model="small.en", whisper_threads=2, ollama_model="qwen2.5:1.5b",
                ollama_models_dir=tmp_path / "models" / "ollama", timezone="America/Los_Angeles")
    return scribe_config.ScribeConfig(**{**base, **overrides})


class FakeTranscriber:
    """Behaves according to the piece file's text: ok/boom/crash/hang/slow."""

    def __init__(self, model, threads):
        self.model = model

    def transcribe(self, wav, *, offset_ms, uid, name):
        kind = Path(wav).read_text().strip()
        if kind == "boom":
            raise ValueError("bad audio")
        if kind == "crash":
            os._exit(3)
        if kind == "hang":
            time.sleep(120)
        if kind == "slow":
            time.sleep(4)
        return [Segment(offset_ms, offset_ms + 1000, uid, name, f"{kind} piece")]


def fake_transcriber(model, threads):
    return FakeTranscriber(model, threads)
