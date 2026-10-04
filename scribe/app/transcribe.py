"""Speaker audio → text (faster-whisper), and merging speakers into one transcript."""

from __future__ import annotations

import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

log = logging.getLogger("scribe.transcribe")

FFMPEG_TIMEOUT_SECONDS = 30 * 60


@dataclass(frozen=True)
class Segment:
    start_ms: int  # absolute wall-clock ms
    end_ms: int
    uid: str
    name: str
    text: str


def to_wav(source: Path, wav: Path) -> None:
    """Decode any speaker stream to 16 kHz mono PCM for whisper."""
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
           "-i", str(source), "-ac", "1", "-ar", "16000", "-f", "wav", str(wav)]
    subprocess.run(cmd, check=True, capture_output=True, timeout=FFMPEG_TIMEOUT_SECONDS)


class Transcriber:
    """Loads the whisper model once per processing job (frees RAM between meetings)."""

    def __init__(self, model: str, threads: int) -> None:
        from faster_whisper import WhisperModel  # heavy import, only in the container

        self._model = WhisperModel(model, device="cpu", compute_type="int8", cpu_threads=threads)

    def transcribe(self, wav: Path, *, offset_ms: int, uid: str, name: str) -> list[Segment]:
        segments, _info = self._model.transcribe(str(wav), language="en", vad_filter=True, beam_size=1)
        out: list[Segment] = []
        for seg in segments:
            text = " ".join(seg.text.split())
            if text:
                out.append(Segment(start_ms=offset_ms + int(seg.start * 1000),
                                   end_ms=offset_ms + int(seg.end * 1000), uid=uid, name=name, text=text))
        return out


def merge_segments(per_speaker: Iterable[Iterable[Segment]]) -> list[Segment]:
    """All speakers in time order (ties: earlier end, then name)."""
    merged = [seg for segments in per_speaker for seg in segments]
    return sorted(merged, key=lambda s: (s.start_ms, s.end_ms, s.name, s.uid))


def format_clock(ms: int) -> str:
    total = max(0, ms) // 1000
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def transcript_lines(segments: list[Segment], meeting_start_ms: int) -> list[str]:
    return [f"[{format_clock(s.start_ms - meeting_start_ms)}] {s.name}: {s.text}" for s in segments]


def render_markdown(title: str, date_label: str, segments: list[Segment], meeting_start_ms: int) -> str:
    lines = transcript_lines(segments, meeting_start_ms)
    body = "\n\n".join(lines) if lines else "_No speech was recorded._"
    return f"# {title}\n\n{date_label}\n\n{body}\n"


def transcript_json(meta: dict[str, Any], segments: list[Segment], meeting_start_ms: int) -> dict[str, Any]:
    speakers = {s.uid: s.name for s in segments}
    return {
        **meta,
        "speakers": [{"uid": uid, "name": name} for uid, name in speakers.items()],
        "segments": [
            {"startMs": max(0, s.start_ms - meeting_start_ms), "endMs": max(0, s.end_ms - meeting_start_ms),
             "uid": s.uid, "name": s.name, "text": s.text}
            for s in segments
        ],
    }
