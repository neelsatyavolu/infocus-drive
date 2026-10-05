"""One finished recording (a job folder with a `job.json` marker) → transcript + summary on
the Drive → Portal READY.

Raw audio is never deleted because something after the recording failed: the job is
marked `failed` (or `written` when only the READY call didn't get through) and kept for
a retry. It is deleted once the Portal acknowledges READY for complete notes, or by the
7-day cleanup.
"""

from __future__ import annotations

import errno
import logging
import shutil
import time
from pathlib import Path

from . import jobs, portal_client, preflight
from .config import LEFTOVER_MAX_AGE_SECONDS, ScribeConfig
from .notes_writer import folder_name, local_time, write_notes
from .ollama_runtime import summarize_meeting
from .preflight import NOT_WRITABLE
from .summarize import NO_SPEECH, SUMMARY_UNAVAILABLE
from .transcribe import Gap, Segment, render_markdown, transcript_json, transcript_lines
from .whisper_child import transcribe_streams

log = logging.getLogger("scribe.pipeline")

INCOMPLETE_NOTE = "\n> Some of this meeting's audio could not be transcribed; transcript.md lists what is missing.\n"
_NOT_WRITABLE_ERRNOS = {errno.EACCES, errno.EPERM, errno.EROFS, errno.ENOSPC, errno.EDQUOT}


def transcribe(cfg: ScribeConfig, audio_dir: Path) -> tuple[list[Segment], list[Gap]]:
    return transcribe_streams(cfg.whisper_model, cfg.whisper_threads, audio_dir, max_mb=cfg.whisper_max_mb)


def failure_reason(error: Exception) -> str:
    if isinstance(error, OSError) and error.errno in _NOT_WRITABLE_ERRNOS:
        return NOT_WRITABLE
    if isinstance(error, RuntimeError) and "not mounted" in str(error):
        return NOT_WRITABLE
    return f"processing failed ({type(error).__name__})"


def process(cfg: ScribeConfig, job_dir: Path) -> str:
    """Run (or resume) one job. Returns the job's state afterwards ("done" when deleted)."""
    marker = jobs.read_marker(job_dir)
    if marker is None:
        log.warning("skipping %s: no job marker", job_dir.name)
        return "missing"
    if marker.state == "written":  # notes are on the Drive; only READY didn't get through
        return _deliver(cfg, job_dir)
    if preflight.problems(cfg):  # don't spend an hour transcribing what can't be saved
        log.error("notes folder not writable; keeping the recording for a retry")
        jobs.update_marker(job_dir, state="failed", last_error=NOT_WRITABLE)  # not counted as an attempt
        portal_client.post_notes(cfg, marker.meeting_id, "FAILED", reason=NOT_WRITABLE)
        return "failed"
    marker = jobs.update_marker(job_dir, state="processing", attempts=marker.attempts + 1, last_error=None)
    portal_client.post_notes(cfg, marker.meeting_id, "PROCESSING")
    try:
        segments, gaps = transcribe(cfg, job_dir)
        summary_md, folder = _write(cfg, marker, segments, gaps)
    except Exception as e:
        reason = failure_reason(e)
        log.exception("notes failed for a meeting: %s", reason)
        jobs.update_marker(job_dir, state="failed", last_error=reason)  # audio kept for a retry
        portal_client.post_notes(cfg, marker.meeting_id, "FAILED", reason=reason)
        return "failed"
    jobs.update_marker(job_dir, state="written", notes_folder=folder,
                       drive_path=f"{cfg.meetings_root.strip('/')}/{folder}", complete=not gaps)
    return _deliver(cfg, job_dir, summary_md)


def _write(cfg: ScribeConfig, marker: jobs.JobMarker, segments: list[Segment],
           gaps: list[Gap]) -> tuple[str, str]:
    starts_at = marker.starts_at_dt
    when = local_time(starts_at, cfg.timezone)
    date_label = f"{when:%A, %B %-d, %Y · %-I:%M %p}"
    if marker.part > 1:
        date_label += f" · part {marker.part}"
    started_label = f"{when:%b %-d, %Y, %-I:%M %p %Z}"
    rec_start = marker.recording_started_ms
    transcript_md = render_markdown(marker.title, date_label, segments, rec_start, gaps)
    meta = {"meetingId": marker.meeting_id, "title": marker.title, "startsAt": marker.starts_at,
            "recordingStartedMs": rec_start, "part": marker.part, "complete": not gaps}
    if segments:
        body = "\n".join(transcript_lines(segments, rec_start))
        summary_md = summarize_meeting(cfg, marker.title, started_label, body)
    else:
        summary_md = NO_SPEECH
    if gaps:
        summary_md = summary_md.rstrip("\n") + "\n" + INCOMPLETE_NOTE
    folder = folder_name(starts_at, marker.title, marker.meeting_id, cfg.timezone, rec_start, marker.part)
    write_notes(cfg.meetings_dir, cfg.meetings_root, folder, transcript_md=transcript_md,
                transcript=transcript_json(meta, segments, rec_start, gaps), summary_md=summary_md)
    if summary_md.startswith(SUMMARY_UNAVAILABLE):
        log.warning("notes written without a summary (summarizer failed); the transcript is complete")
    return summary_md, folder


def _deliver(cfg: ScribeConfig, job_dir: Path, summary_md: str | None = None) -> str:
    """READY to the Portal. Complete notes: the raw audio is deleted once acknowledged."""
    marker = jobs.read_marker(job_dir)
    if marker is None or not marker.notes_folder:
        return "missing"
    if summary_md is None:
        try:
            summary_md = (cfg.meetings_dir / marker.notes_folder / "summary.md").read_text(encoding="utf-8")
        except OSError:
            jobs.update_marker(job_dir, state="failed", last_error="notes folder missing")
            return "failed"
    acked = portal_client.post_notes(cfg, marker.meeting_id, "READY", summary_markdown=summary_md,
                                     drive_path=marker.drive_path)
    if not acked:
        log.warning("READY not acknowledged yet; keeping the recording and retrying later")
        return "written"
    if marker.complete:
        shutil.rmtree(job_dir, ignore_errors=True)
        return "done"
    jobs.update_marker(job_dir, state="partial")
    return "partial"


def cleanup_leftovers(tmp_dir: Path, now: float | None = None, keep: set[str] | frozenset[str] = frozenset()) -> int:
    """Delete recordings older than 7 days (by the marker's recording start, else the folder's
    mtime), except `keep` (live recordings and queued jobs). Returns how many were removed."""
    if not tmp_dir.is_dir():
        return 0
    cutoff = (now or time.time()) - LEFTOVER_MAX_AGE_SECONDS
    removed = 0
    for entry in tmp_dir.iterdir():
        try:
            if entry.name in keep or not entry.is_dir() or entry.is_symlink():
                continue
            marker = jobs.read_marker(entry)
            started = marker.recording_started_ms / 1000 if marker else entry.stat().st_mtime
            if started < cutoff:
                shutil.rmtree(entry, ignore_errors=True)
                removed += 1
        except OSError:
            continue
    return removed
