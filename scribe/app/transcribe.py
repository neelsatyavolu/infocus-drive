"""Speaker audio → text (faster-whisper), and merging speakers into one transcript."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

log = logging.getLogger("scribe.transcribe")


@dataclass(frozen=True)
class Segment:
    start_ms: int  # absolute wall-clock ms
    end_ms: int
    uid: str
    name: str
    text: str


@dataclass(frozen=True)
class Gap:
    """Audio that isn't in the transcript (a stream or piece that failed). Absolute wall-clock ms."""
    uid: str
    name: str
    from_ms: int
    to_ms: int | None
    reason: str


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


def gap_lines(gaps: Iterable[Gap], meeting_start_ms: int) -> list[str]:
    """`- Abby, 00:20:00–00:40:00: transcription timed out` (no end: from that time on)."""
    lines = []
    for gap in gaps:
        start = format_clock(gap.from_ms - meeting_start_ms)
        span = f"{start}–{format_clock(gap.to_ms - meeting_start_ms)}" if gap.to_ms is not None else f"from {start}"
        lines.append(f"- {gap.name}, {span}: {gap.reason}")
    return lines


def render_markdown(title: str, date_label: str, segments: list[Segment], meeting_start_ms: int,
                    gaps: Iterable[Gap] = ()) -> str:
    lines = transcript_lines(segments, meeting_start_ms)
    body = "\n\n".join(lines) if lines else "_No speech was recorded._"
    missing = gap_lines(gaps, meeting_start_ms)
    note = ""
    if missing:
        note = "> Some audio could not be transcribed and is missing below:\n>\n" + \
            "\n".join(f"> {line}" for line in missing) + "\n\n"
    return f"# {title}\n\n{date_label}\n\n{note}{body}\n"


def transcript_json(meta: dict[str, Any], segments: list[Segment], meeting_start_ms: int,
                    gaps: Iterable[Gap] = ()) -> dict[str, Any]:
    speakers = {s.uid: s.name for s in segments}
    return {
        **meta,
        "speakers": [{"uid": uid, "name": name} for uid, name in speakers.items()],
        "segments": [
            {"startMs": max(0, s.start_ms - meeting_start_ms), "endMs": max(0, s.end_ms - meeting_start_ms),
             "uid": s.uid, "name": s.name, "text": s.text}
            for s in segments
        ],
        "gaps": [
            {"uid": g.uid, "name": g.name, "fromMs": max(0, g.from_ms - meeting_start_ms),
             "toMs": None if g.to_ms is None else max(0, g.to_ms - meeting_start_ms), "reason": g.reason}
            for g in gaps
        ],
    }
