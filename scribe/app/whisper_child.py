"""Long-meeting-safe transcription.

Each speaker stream is cut into ~20-minute 16 kHz mono WAV pieces with ffmpeg, so
whisper never holds more than one piece (decoded audio, VAD copy, mel features) in
memory. Pieces are transcribed one after another in a spawned child process that
the parent watches:

- a per-piece timeout (3x the piece's length + 10 minutes; more for the first piece,
  which loads or downloads the model) so a hang can't block the queue;
- a resident-memory cap (SCRIBE_WHISPER_MAX_MB) so one piece can't take the
  container down;
- a crashed, killed or failing piece becomes a gap in the notes and the next piece
  gets a fresh child. The parent never loads whisper itself.

The child exits when the job is done, so the model's memory goes back to the system.
"""

from __future__ import annotations

import csv
import io
import logging
import multiprocessing
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .recorder import StreamInfo, concat_stream, load_streams
from .transcribe import Gap, Segment, Transcriber, merge_segments

log = logging.getLogger("scribe.whisper")

SEGMENT_SECONDS = 20 * 60
MODEL_LOAD_ALLOWANCE_SECONDS = 15 * 60
POLL_SECONDS = 0.5


@dataclass(frozen=True)
class AudioPiece:
    path: Path
    start_s: float
    end_s: float

    @property
    def seconds(self) -> float:
        return max(0.0, self.end_s - self.start_s)


class PieceFailed(Exception):
    def __init__(self, reason: str, *, child_lost: bool) -> None:
        super().__init__(reason)
        self.reason = reason
        self.child_lost = child_lost


def piece_timeout(seconds: float, *, first: bool = False) -> float:
    """3x real time + 10 minutes (+ model load time for a fresh child's first piece)."""
    return 3 * seconds + 600 + (MODEL_LOAD_ALLOWANCE_SECONDS if first else 0)


def parse_segment_list(text: str, out_dir: Path) -> list[AudioPiece]:
    """ffmpeg's `-segment_list_type csv`: `filename,start,end` per piece."""
    pieces: list[AudioPiece] = []
    for row in csv.reader(io.StringIO(text)):
        if len(row) < 3:
            continue
        try:
            start, end = float(row[1]), float(row[2])
        except ValueError:
            continue
        name = Path(row[0]).name
        if name:
            pieces.append(AudioPiece(path=out_dir / name, start_s=start, end_s=end))
    return pieces


def split_stream(source: Path, out_dir: Path, segment_seconds: int = SEGMENT_SECONDS,
                 timeout: float = 3600) -> list[AudioPiece]:
    """Decode one speaker stream into 16 kHz mono WAV pieces of `segment_seconds`."""
    out_dir.mkdir(parents=True, exist_ok=True)
    listing = out_dir / "pieces.csv"
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
           "-ac", "1", "-ar", "16000", "-f", "segment", "-segment_time", str(segment_seconds),
           "-segment_list", str(listing), "-segment_list_type", "csv", "-reset_timestamps", "1",
           str(out_dir / "piece%04d.wav")]
    subprocess.run(cmd, check=True, capture_output=True, timeout=timeout)
    return parse_segment_list(listing.read_text(encoding="utf-8"), out_dir)


def read_rss_mb(pid: int) -> float | None:
    """Resident memory of a process (Linux /proc); None where unavailable."""
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024
    except (OSError, ValueError, IndexError):
        return None
    return None


def _child_main(conn: Any, model: str, threads: int, factory: Callable[[str, int], Any]) -> None:
    """Child loop: (wav, offset_ms, uid, name) → ("ok", [Segment]) | ("error", reason); None ends it."""
    transcriber = None
    while True:
        try:
            task = conn.recv()
        except EOFError:
            return
        if task is None:
            return
        wav, offset_ms, uid, name = task
        try:
            if transcriber is None:
                transcriber = factory(model, threads)
            conn.send(("ok", transcriber.transcribe(Path(wav), offset_ms=offset_ms, uid=uid, name=name)))
        except Exception as e:  # reported to the parent; the piece becomes a gap
            conn.send(("error", type(e).__name__))


class WhisperChild:
    """Parent-side handle to one spawned transcription process."""

    def __init__(self, model: str, threads: int, factory: Callable[[str, int], Any] = Transcriber) -> None:
        ctx = multiprocessing.get_context("spawn")
        self._conn, child_conn = ctx.Pipe()
        self.process = ctx.Process(target=_child_main, args=(child_conn, model, threads, factory), daemon=True)
        self.process.start()
        child_conn.close()
        self.used = False

    def transcribe(self, piece: AudioPiece, *, offset_ms: int, uid: str, name: str, timeout: float,
                   max_mb: float, rss_mb: Callable[[int], float | None] = read_rss_mb) -> list[Segment]:
        self.used = True
        self._conn.send((str(piece.path), offset_ms, uid, name))
        deadline = time.monotonic() + timeout
        while True:
            try:
                if self._conn.poll(POLL_SECONDS):
                    status, payload = self._conn.recv()
                    if status == "ok":
                        return payload
                    raise PieceFailed(f"transcription error ({payload})", child_lost=False)
            except (EOFError, OSError):
                self.kill()
                raise PieceFailed("transcriber crashed", child_lost=True) from None
            if not self.process.is_alive():
                self.kill()
                raise PieceFailed("transcriber crashed", child_lost=True)
            if time.monotonic() > deadline:
                self.kill()
                raise PieceFailed("transcription timed out", child_lost=True)
            rss = rss_mb(self.process.pid) if self.process.pid else None
            if rss is not None and rss > max_mb:
                self.kill()
                raise PieceFailed("transcriber ran out of memory", child_lost=True)

    def kill(self) -> None:
        if self.process.is_alive():
            self.process.kill()
        self.process.join(5)
        self._conn.close()

    def close(self) -> None:
        if self.process.is_alive():
            try:
                self._conn.send(None)
            except (OSError, ValueError):
                pass
            self.process.join(10)
        self.kill()


def _transcribe_stream(stream: StreamInfo, get_child: Callable[[], WhisperChild], drop_child: Callable[[], None],
                       *, max_mb: float, rss_mb: Callable[[int], float | None],
                       timeout_for: Callable[..., float], segment_seconds: int,
                       split: Callable[..., list[AudioPiece]]) -> tuple[list[Segment], list[Gap]]:
    segments: list[Segment] = []
    gaps: list[Gap] = []
    pieces_dir = stream.path / "pieces"
    try:
        webm = concat_stream(stream, stream.path / "stream.webm")
        if webm is None:
            return segments, gaps
        shutil.rmtree(pieces_dir, ignore_errors=True)
        pieces = split(webm, pieces_dir, segment_seconds)
    except Exception as e:
        log.warning("a speaker stream could not be decoded: %s", type(e).__name__)
        return segments, [Gap(stream.uid, stream.name, stream.start_ms, None, "audio could not be decoded")]
    for piece in pieces:
        offset_ms = stream.start_ms + int(piece.start_s * 1000)
        child = get_child()
        try:
            segments += child.transcribe(piece, offset_ms=offset_ms, uid=stream.uid, name=stream.name,
                                         timeout=timeout_for(piece.seconds, first=not child.used),
                                         max_mb=max_mb, rss_mb=rss_mb)
        except PieceFailed as e:
            log.warning("a %d-second piece was not transcribed: %s", int(piece.seconds), e.reason)
            gaps.append(Gap(stream.uid, stream.name, offset_ms, stream.start_ms + int(piece.end_s * 1000), e.reason))
            if e.child_lost:
                drop_child()
        finally:
            piece.path.unlink(missing_ok=True)
    shutil.rmtree(pieces_dir, ignore_errors=True)
    (stream.path / "stream.webm").unlink(missing_ok=True)
    return segments, gaps


def transcribe_streams(model: str, threads: int, audio_dir: Path, *, max_mb: float,
                       factory: Callable[[str, int], Any] = Transcriber,
                       rss_mb: Callable[[int], float | None] = read_rss_mb,
                       timeout_for: Callable[..., float] = piece_timeout,
                       segment_seconds: int = SEGMENT_SECONDS,
                       split: Callable[..., list[AudioPiece]] = split_stream) -> tuple[list[Segment], list[Gap]]:
    """Every speaker stream in `audio_dir`, piece by piece. Never raises for a bad
    stream or piece: those come back as gaps."""
    state: dict[str, WhisperChild | None] = {"child": None}

    def get_child() -> WhisperChild:
        if state["child"] is None:
            state["child"] = WhisperChild(model, threads, factory)
        return state["child"]

    def drop_child() -> None:
        state["child"] = None

    per_speaker: list[list[Segment]] = []
    gaps: list[Gap] = []
    try:
        for stream in load_streams(audio_dir):
            segs, stream_gaps = _transcribe_stream(stream, get_child, drop_child, max_mb=max_mb, rss_mb=rss_mb,
                                                   timeout_for=timeout_for, segment_seconds=segment_seconds,
                                                   split=split)
            per_speaker.append(segs)
            gaps += stream_gaps
    finally:
        if state["child"] is not None:
            state["child"].close()
    return merge_segments(per_speaker), sorted(gaps, key=lambda g: (g.from_ms, g.name))
