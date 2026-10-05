"""Write finished notes to `<meetings dir>/<YYYY-MM-DD HHmm> <title> (<id6>) rec <HHmm>[ part N]/`.

Only the notes folder (IFD_MEETINGS_ROOT) is mounted into the Scribe; it runs
as a non-root user, so files are owned by that uid (see docs/MEETINGS-SCRIBE.md).
"""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

log = logging.getLogger("scribe.notes")

MAX_TITLE_LEN = 80
_UNSAFE = re.compile(r'[\x00-\x1f\x7f/\\:*?"<>|]')


def sanitize_title(title: str) -> str:
    """A title that is safe as one folder name on SMB, macOS and Windows."""
    text = " ".join(_UNSAFE.sub(" ", title or "").split())
    text = text[:MAX_TITLE_LEN].strip(" .")
    return text or "Meeting"


def local_time(starts_at: datetime, timezone: str) -> datetime:
    try:
        zone = ZoneInfo(timezone)
    except (ZoneInfoNotFoundError, ValueError):
        zone = ZoneInfo("UTC")
    if starts_at.tzinfo is None:
        starts_at = starts_at.replace(tzinfo=ZoneInfo("UTC"))
    return starts_at.astimezone(zone)


def folder_name(starts_at: datetime, title: str, meeting_id: str, timezone: str,
                recording_started_ms: int, part: int = 1) -> str:
    """`2026-10-04 2115 Producer meeting (abc123) rec 2117` (`… part 2` for a later recording of the
    same meeting), so a second notes session never overwrites the first."""
    when = local_time(starts_at, timezone)
    rec = local_time(datetime.fromtimestamp(recording_started_ms / 1000, tz=ZoneInfo("UTC")), timezone)
    name = f"{when:%Y-%m-%d %H%M} {sanitize_title(title)} ({meeting_id[-6:]}) rec {rec:%H%M}"
    return f"{name} part {part}" if part > 1 else name


def _write_atomic(path: Path, content: str) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


def write_notes(meetings_dir: Path, meetings_root: str, folder: str, *, transcript_md: str,
                transcript: dict[str, Any], summary_md: str) -> str:
    """Write the three files and return the Drive-relative folder path."""
    target = meetings_dir / folder
    if target.resolve().parent != meetings_dir.resolve():
        raise ValueError("notes folder escapes the meetings root")
    if not meetings_dir.is_dir():
        raise RuntimeError("meetings folder is not mounted")
    target.mkdir(exist_ok=True)
    files = {
        "transcript.md": transcript_md,
        "transcript.json": json.dumps(transcript, ensure_ascii=False, indent=2) + "\n",
        "summary.md": summary_md,
    }
    for name, content in files.items():
        _write_atomic(target / name, content)
    return f"{meetings_root.strip('/')}/{folder}"
