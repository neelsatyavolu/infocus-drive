"""Notes status → Drive `POST /api/internal/scribe/notes/{id}` → Portal.

The Scribe never holds the Portal service token: the Drive app relays the
status to the Portal's `/api/service/meetings/{id}/notes` with it.
"""

from __future__ import annotations

import logging
import time
from typing import Literal

import httpx

from .config import ScribeConfig

log = logging.getLogger("scribe.notes_status")

NotesStatus = Literal["RECORDING", "PROCESSING", "READY", "FAILED"]
ATTEMPTS = 3
TIMEOUT = httpx.Timeout(30.0, connect=5.0)


def notes_payload(status: NotesStatus, summary_markdown: str | None = None,
                  drive_path: str | None = None) -> dict[str, str]:
    body: dict[str, str] = {"status": status}
    if summary_markdown is not None:
        body["summaryMarkdown"] = summary_markdown
    if drive_path is not None:
        body["drivePath"] = drive_path
    return body


def post_notes(cfg: ScribeConfig, meeting_id: str, status: NotesStatus, *,
               summary_markdown: str | None = None, drive_path: str | None = None,
               client: httpx.Client | None = None) -> bool:
    """Best effort with retries; never raises. Returns True when it was accepted."""
    if not cfg.drive_url or not cfg.internal_token:
        log.warning("SCRIBE_DRIVE_URL or SCRIBE_INTERNAL_TOKEN missing; notes status not sent")
        return False
    url = f"{cfg.drive_url}/api/internal/scribe/notes/{meeting_id}"
    body = notes_payload(status, summary_markdown, drive_path)
    headers = {"Authorization": f"Bearer {cfg.internal_token}"}
    http = client or httpx.Client(timeout=TIMEOUT)
    try:
        for attempt in range(1, ATTEMPTS + 1):
            try:
                resp = http.post(url, json=body, headers=headers)
                if resp.status_code < 500:
                    if resp.status_code >= 400:
                        log.warning("notes %s rejected: %s", status, resp.status_code)
                    return resp.status_code < 400
                log.warning("notes %s: %s (attempt %s)", status, resp.status_code, attempt)
            except httpx.HTTPError as e:
                log.warning("notes %s: %s (attempt %s)", status, type(e).__name__, attempt)
            if attempt < ATTEMPTS:
                time.sleep(2 ** attempt)
        return False
    finally:
        if client is None:
            http.close()
