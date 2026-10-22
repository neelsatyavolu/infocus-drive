"""Speaker audio → text (faster-whisper), and merging speakers into one transcript."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

log = logging.getLogger("scribe.transcribe")

# A segment is a repeat when this share of its 3-word runs was in the speaker's previous segment.
REPEAT_SHARE = 0.8
_NOT_WORD = re.compile(r"[^a-z0-9' ]+")
# Whisper can put words said 40 seconds apart in one segment, which then carries the first word's
# time and lands before other people's replies. Segments are cut at pauses this long and at
# sentence ends; a speaker's pieces that nobody spoke between are joined again (join_turns).
PAUSE_MS = 1_500
_SENTENCE_END = re.compile(r"[.?!][\"')\]]*$")


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


def _pieces(seg: Any) -> list[tuple[float, float, str]]:
    """(start s, end s, text) for one whisper segment, cut at long pauses and sentence ends."""
    words = getattr(seg, "words", None) or []
    if not words:
        return [(seg.start, seg.end, seg.text)]
    groups: list[list[Any]] = [[]]
    for word in words:
        last = groups[-1][-1] if groups[-1] else None
        if last is not None and ((word.start - last.end) * 1000 >= PAUSE_MS
                                 or _SENTENCE_END.search(last.word.strip())):
            groups.append([])
        groups[-1].append(word)
    return [(g[0].start, g[-1].end, "".join(w.word for w in g)) for g in groups if g]


class Transcriber:
    """Loads the whisper model once per processing job (frees RAM between meetings)."""

    def __init__(self, model: str, threads: int) -> None:
        from faster_whisper import WhisperModel  # heavy import, only in the container

        self._model = WhisperModel(model, device="cpu", compute_type="int8", cpu_threads=threads)

    def transcribe(self, wav: Path, *, offset_ms: int, uid: str, name: str) -> list[Segment]:
        # condition_on_previous_text=False: a window that went wrong (cross-talk, noise) must not
        # seed the next one, or whisper repeats one phrase for minutes and the real speech is lost.
        # No hotwords (not even a short list of names): with them whisper skipped whole minutes of
        # speech and wrote names nobody said. The summary fixes name spellings instead.
        segments, _info = self._model.transcribe(str(wav), language="en", vad_filter=True, beam_size=1,
                                                 condition_on_previous_text=False, word_timestamps=True)
        out: list[Segment] = []
        for seg in segments:
            for start, end, raw in _pieces(seg):
                text = " ".join(raw.split())
                if text:
                    out.append(Segment(start_ms=offset_ms + int(start * 1000), end_ms=offset_ms + int(end * 1000),
                                       uid=uid, name=name, text=text))
        return out


def _runs(text: str) -> set[tuple[str, ...]]:
    words = _NOT_WORD.sub(" ", text.lower()).split()
    return {tuple(words[i:i + 3]) for i in range(len(words) - 2)}


def drop_repeats(segments: list[Segment]) -> list[Segment]:
    """One speaker's segments in order, without the ones that only repeat the segment before
    (a speech-recognition loop). The first of a run stays; short replies ("Yeah.") always stay."""
    kept: list[Segment] = []
    previous: set[tuple[str, ...]] = set()
    for seg in segments:
        runs = _runs(seg.text)
        if not runs or len(runs & previous) < REPEAT_SHARE * len(runs):
            kept.append(seg)
        previous = runs
    if len(kept) < len(segments):
        log.info("left out %d repeated segments", len(segments) - len(kept))
    return kept


def merge_segments(per_speaker: Iterable[Iterable[Segment]]) -> list[Segment]:
    """All speakers in time order (ties: earlier end, then name)."""
    merged = [seg for segments in per_speaker for seg in segments]
    return sorted(merged, key=lambda s: (s.start_ms, s.end_ms, s.name, s.uid))


def join_turns(segments: list[Segment]) -> list[Segment]:
    """Merged segments with each run of one speaker's lines joined into one line, unless someone
    else spoke in between or the speaker paused for PAUSE_MS or longer."""
    out: list[Segment] = []
    for seg in segments:
        last = out[-1] if out else None
        if last is not None and last.uid == seg.uid and seg.start_ms - last.end_ms < PAUSE_MS:
            out[-1] = Segment(last.start_ms, max(last.end_ms, seg.end_ms), last.uid, last.name, f"{last.text} {seg.text}")
        else:
            out.append(seg)
    return out


# "Meeting adjourned", "this meeting is now adjourned", "we're adjourned".
_ADJOURNED = re.compile(r"\b(?:meeting|we|we're)\b[^.?!]{0,20}?\badjourned\b", re.IGNORECASE)


def cut_at_adjournment(segments: list[Segment], gaps: Iterable[Gap] = ()) -> tuple[list[Segment], list[Gap], bool]:
    """Segments and gaps up to the end of the last line that adjourns the meeting, and whether one did.
    People keep talking after the meeting ends (a real recording had 35 minutes of college and
    politics chat), and that is not meeting business: it stays out of the transcript and the notes."""
    gaps = list(gaps)
    ends = [s.end_ms for s in segments if _ADJOURNED.search(s.text)]
    if not ends:
        return segments, gaps, False
    cut = ends[-1]
    kept_gaps = [g if g.to_ms is not None and g.to_ms <= cut else Gap(g.uid, g.name, g.from_ms, cut, g.reason)
                 for g in gaps if g.from_ms < cut]
    return [s for s in segments if s.start_ms <= cut], kept_gaps, True


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


ADJOURNED_NOTE = "_The meeting was adjourned here. What was said after that is not in the transcript._"


def render_markdown(title: str, date_label: str, segments: list[Segment], meeting_start_ms: int,
                    gaps: Iterable[Gap] = (), adjourned: bool = False) -> str:
    lines = transcript_lines(segments, meeting_start_ms)
    if adjourned:
        lines.append(ADJOURNED_NOTE)
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
