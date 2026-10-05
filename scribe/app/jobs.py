"""Job markers: one `job.json` beside each recording's raw audio in IFD_SCRIBE_TMP.

The marker says what the audio is (meeting, title, start, part, speakers) and how
far it got, so a recording survives a failure, a deploy or a reboot and is
processed (or retried) later. Raw audio is deleted only once the Portal has
acknowledged READY for complete notes, or after 7 days.

States: recording → queued → processing → written → (deleted | partial);
any step can end in failed. `partial` = notes delivered with gaps (audio kept
for a manual retry until the 7-day cleanup).
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime
from pathlib import Path
from typing import Any

log = logging.getLogger("scribe.jobs")

MARKER = "job.json"
MAX_ATTEMPTS = 3
# Re-queued at startup (and the hourly pass): anything that isn't finished or given up.
RECOVERABLE = ("recording", "queued", "processing", "written", "failed")


@dataclass(frozen=True)
class JobMarker:
    meeting_id: str
    title: str
    starts_at: str  # ISO 8601
    recording_started_ms: int
    part: int = 1
    state: str = "recording"
    attempts: int = 0
    speakers: dict[str, str] = field(default_factory=dict)
    notes_folder: str | None = None
    drive_path: str | None = None
    complete: bool = True
    last_error: str | None = None
    updated_ms: int = 0

    @property
    def starts_at_dt(self) -> datetime:
        return datetime.fromisoformat(self.starts_at)


def now_ms() -> int:
    return int(time.time() * 1000)


def write_marker(job_dir: Path, marker: JobMarker) -> JobMarker:
    marker = replace(marker, updated_ms=now_ms())
    tmp = job_dir / f".{MARKER}.tmp"
    tmp.write_text(json.dumps(asdict(marker), ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, job_dir / MARKER)
    return marker


def read_marker(job_dir: Path) -> JobMarker | None:
    try:
        data: dict[str, Any] = json.loads((job_dir / MARKER).read_text(encoding="utf-8"))
        known = {k: v for k, v in data.items() if k in JobMarker.__dataclass_fields__}
        return JobMarker(**known)
    except (OSError, ValueError, TypeError):
        return None


def update_marker(job_dir: Path, **changes: Any) -> JobMarker:
    marker = read_marker(job_dir)
    if marker is None:
        raise FileNotFoundError(f"no job marker in {job_dir.name}")
    return write_marker(job_dir, replace(marker, **changes))


def job_dirs(tmp_dir: Path) -> list[tuple[Path, JobMarker]]:
    """Every job folder with a readable marker, oldest recording first."""
    found: list[tuple[Path, JobMarker]] = []
    if not tmp_dir.is_dir():
        return found
    for entry in tmp_dir.iterdir():
        if entry.is_dir() and not entry.is_symlink():
            marker = read_marker(entry)
            if marker is not None:
                found.append((entry, marker))
    return sorted(found, key=lambda item: (item[1].recording_started_ms, item[0].name))


def recoverable(tmp_dir: Path, *, failed_retry_after_ms: int = 0, now: int | None = None) -> list[Path]:
    """Jobs to (re)queue: unfinished ones, and failed ones with attempts left whose last
    attempt is at least `failed_retry_after_ms` old."""
    current = now if now is not None else now_ms()
    out: list[Path] = []
    for job_dir, marker in job_dirs(tmp_dir):
        if marker.state not in RECOVERABLE:
            continue
        if marker.state in ("failed", "processing", "queued", "recording") and marker.attempts >= MAX_ATTEMPTS:
            continue
        if marker.state == "failed" and current - marker.updated_ms < failed_retry_after_ms:
            continue
        out.append(job_dir)
    return out


def next_part(tmp_dir: Path, meetings_dir: Path, meeting_id: str) -> int:
    """1 + the recordings already known for this meeting (pending jobs and written notes),
    counted once each by their recording start."""
    starts = {m.recording_started_ms for _, m in job_dirs(tmp_dir) if m.meeting_id == meeting_id}
    suffix = f"({meeting_id[-6:]})"
    if meetings_dir.is_dir():
        for folder in meetings_dir.iterdir():
            if suffix not in folder.name or not folder.is_dir():
                continue
            try:
                meta = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(meta, dict) and meta.get("meetingId") == meeting_id:
                starts.add(int(meta.get("recordingStartedMs") or 0))
    return len(starts) + 1
