"""One finished recording → transcript + summary on the Drive → Portal READY."""

from __future__ import annotations

import logging
import multiprocessing
import shutil
import time
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from . import portal_client
from .config import LEFTOVER_MAX_AGE_SECONDS, ScribeConfig
from .notes_writer import folder_name, local_time, write_notes
from .recorder import concat_stream, load_streams
from .ollama_runtime import summarize_meeting
from .summarize import NO_SPEECH
from .transcribe import (Segment, Transcriber, merge_segments, render_markdown, to_wav,
                         transcript_json, transcript_lines)

log = logging.getLogger("scribe.pipeline")


@dataclass(frozen=True)
class Job:
    meeting_id: str
    title: str
    starts_at: datetime
    recording_started_ms: int
    audio_dir: Path


def transcribe_all(cfg: ScribeConfig, audio_dir: Path) -> list[Segment]:
    streams = load_streams(audio_dir)
    if not streams:
        return []
    transcriber = Transcriber(cfg.whisper_model, cfg.whisper_threads)
    per_speaker: list[list[Segment]] = []
    for stream in streams:
        webm = concat_stream(stream, stream.path / "stream.webm")
        if webm is None:
            continue
        wav = stream.path / "stream.wav"
        try:
            to_wav(webm, wav)
        except Exception as e:  # one broken stream must not lose the others
            log.warning("ffmpeg failed for a stream: %s", type(e).__name__)
            continue
        per_speaker.append(transcriber.transcribe(wav, offset_ms=stream.start_ms, uid=stream.uid, name=stream.name))
        wav.unlink(missing_ok=True)
    return merge_segments(per_speaker)


def transcribe_in_child(cfg: ScribeConfig, audio_dir: Path) -> list[Segment]:
    """Run whisper in a fresh child process that exits afterwards, so the model's
    memory is returned to the system (not just to Python's allocator)."""
    with ProcessPoolExecutor(max_workers=1, mp_context=multiprocessing.get_context("spawn")) as pool:
        return pool.submit(transcribe_all, cfg, audio_dir).result()


def process(cfg: ScribeConfig, job: Job) -> None:
    try:
        segments = transcribe_in_child(cfg, job.audio_dir)
        when = local_time(job.starts_at, cfg.timezone)
        date_label = f"{when:%A, %B %-d, %Y · %-I:%M %p}"
        started_label = f"{when:%b %-d, %Y, %-I:%M %p %Z}"
        transcript_md = render_markdown(job.title, date_label, segments, job.recording_started_ms)
        meta = {"meetingId": job.meeting_id, "title": job.title, "startsAt": job.starts_at.isoformat(),
                "recordingStartedMs": job.recording_started_ms}
        if segments:
            body = "\n".join(transcript_lines(segments, job.recording_started_ms))
            summary_md = summarize_meeting(cfg, job.title, started_label, body)
        else:
            summary_md = NO_SPEECH
        drive_path = write_notes(
            cfg.meetings_dir, cfg.meetings_root, folder_name(job.starts_at, job.title, job.meeting_id, cfg.timezone),
            transcript_md=transcript_md, transcript=transcript_json(meta, segments, job.recording_started_ms),
            summary_md=summary_md,
        )
    except Exception as e:
        log.exception("notes failed for a meeting: %s", type(e).__name__)
        shutil.rmtree(job.audio_dir, ignore_errors=True)  # nothing retries; never keep raw audio
        portal_client.post_notes(cfg, job.meeting_id, "FAILED")
        return
    shutil.rmtree(job.audio_dir, ignore_errors=True)
    portal_client.post_notes(cfg, job.meeting_id, "READY", summary_markdown=summary_md, drive_path=drive_path)


def cleanup_leftovers(tmp_dir: Path, now: float | None = None, keep: set[str] | frozenset[str] = frozenset()) -> int:
    """Delete raw audio folders older than 7 days (except `keep`, live recordings).
    Returns how many were removed."""
    if not tmp_dir.is_dir():
        return 0
    cutoff = (now or time.time()) - LEFTOVER_MAX_AGE_SECONDS
    removed = 0
    for entry in tmp_dir.iterdir():
        try:
            if entry.name in keep:
                continue
            if entry.is_dir() and not entry.is_symlink() and entry.stat().st_mtime < cutoff:
                shutil.rmtree(entry, ignore_errors=True)
                removed += 1
        except OSError:
            continue
    return removed
