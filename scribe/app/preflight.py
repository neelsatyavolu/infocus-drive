"""Can the Scribe save anything? Checked at startup, on every health check and before
each recording, so a permissions problem fails loudly up front instead of after an
hour of recording."""

from __future__ import annotations

import logging
import os
import tempfile
from pathlib import Path

from .config import ScribeConfig

log = logging.getLogger("scribe.preflight")

NOT_WRITABLE = "notes folder not writable"


class PreflightFailed(Exception):
    def __init__(self, problems: list[str]) -> None:
        super().__init__("; ".join(problems))
        self.problems = problems
        self.reason = NOT_WRITABLE


def writable(path: Path) -> bool:
    """A real write test (permissions, read-only mounts and full disks all show up here)."""
    if not path.is_dir():
        return False
    try:
        fd, name = tempfile.mkstemp(prefix=".scribe-preflight-", dir=path)
        os.close(fd)
        os.unlink(name)
        return True
    except OSError:
        return False


def problems(cfg: ScribeConfig) -> list[str]:
    found = []
    if not writable(cfg.meetings_dir):
        found.append(f"notes folder {cfg.meetings_dir} is missing or not writable")
    if not writable(cfg.tmp_dir):
        found.append(f"recordings folder {cfg.tmp_dir} is missing or not writable")
    return found


def require(cfg: ScribeConfig) -> None:
    found = problems(cfg)
    if found:
        log.error("PREFLIGHT FAILED, notes cannot be saved: %s", "; ".join(found))
        raise PreflightFailed(found)
