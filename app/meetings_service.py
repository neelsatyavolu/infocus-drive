"""Meetings Scribe: Portal ↔ Drive ↔ Scribe routes (docs/MEETINGS-SCRIBE.md).

- `/api/service/meetings/*` (packages service bearer): the Portal starts,
  rekeys and stops the Scribe, and reads finished transcripts.
- `/api/internal/scribe/*` (SCRIBE_INTERNAL_TOKEN, local callers only): the
  Scribe reports notes status; the Drive relays it to the Portal with the
  packages token, so the Scribe container never holds that token.

Meeting keys and room tokens are never logged.
"""

from __future__ import annotations

import hmac
import ipaddress
import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any, Literal
from urllib.parse import urlsplit

import httpx
from fastapi import APIRouter, Depends, HTTPException, Path as PathParam, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

from config import get_settings
from service_auth import require_service_token

log = logging.getLogger("infocus.meetings")

MEETING_ID_PATTERN = r"^[a-z0-9]{10,40}$"
KEY_PATTERN = r"^[A-Za-z0-9_-]{16,128}={0,2}$"
SCRIBE_TIMEOUT = httpx.Timeout(15.0, connect=3.0)
PORTAL_TIMEOUT = httpx.Timeout(20.0, connect=5.0)
PROXY_HEADERS = ("x-forwarded-for", "x-real-ip", "cf-connecting-ip", "forwarded")

router = APIRouter(prefix="/api/service/meetings", dependencies=[Depends(require_service_token)])


def _origin(url: str) -> str:
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}".lower()


def _check_http_url(value: str) -> str:
    parts = urlsplit(value)
    local = parts.hostname in ("localhost", "127.0.0.1")
    if parts.scheme not in ("https", "http") or not parts.hostname or (parts.scheme == "http" and not local):
        raise ValueError("must be an https URL")
    if parts.username or parts.password:
        raise ValueError("must not carry credentials")
    return value.rstrip("/")


def _check_pinned(value: str, configured: str, env_name: str) -> str:
    value = _check_http_url(value)
    if not configured or _origin(value) != _origin(configured):
        raise ValueError(f"must match {env_name}")
    return value


class _Body(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)

    meetingId: str = Field(pattern=MEETING_ID_PATTERN)


class ScribeStart(_Body):
    title: str = Field(min_length=1, max_length=200)
    startsAt: datetime
    roomUrl: str = Field(max_length=500)
    roomToken: str = Field(min_length=1, max_length=4096, pattern=r"^[A-Za-z0-9._~+/=-]+$")
    key: str = Field(pattern=KEY_PATTERN)
    epoch: int = Field(ge=0, le=1_000_000)
    portalBaseUrl: str = Field(max_length=500)
    # People's names (and nicknames) the transcriber should expect; see scribe/app/vocabulary.py.
    vocabulary: list[Annotated[str, Field(max_length=80)]] = Field(default_factory=list, max_length=300)

    @field_validator("roomUrl")
    @classmethod
    def _room_pinned(cls, value: str) -> str:
        return _check_pinned(value, get_settings().meeting_room_url, "MEETING_ROOM_URL")

    @field_validator("portalBaseUrl")
    @classmethod
    def _portal_pinned(cls, value: str) -> str:
        return _check_pinned(value, get_settings().portal_base_url, "PORTAL_BASE_URL")


class ScribeRekey(_Body):
    key: str = Field(pattern=KEY_PATTERN)
    epoch: int = Field(ge=0, le=1_000_000)
    # Re-ticketing (optional, additive): a fresh room ticket for the Scribe's next connections.
    roomToken: str | None = Field(default=None, min_length=1, max_length=4096, pattern=r"^[A-Za-z0-9._~+/=-]+$")
    roomUrl: str | None = Field(default=None, max_length=500)
    ticketExpiresAt: datetime | None = None

    @field_validator("roomUrl")
    @classmethod
    def _room_pinned(cls, value: str | None) -> str | None:
        return None if value is None else _check_pinned(value, get_settings().meeting_room_url, "MEETING_ROOM_URL")


class ScribeStop(_Body):
    pass


def _scribe_token() -> str:
    token = (get_settings().scribe_internal_token or "").strip()
    if not token:
        raise HTTPException(status_code=503, detail="SCRIBE_INTERNAL_TOKEN not configured on drive")
    return token


async def forward_to_scribe(path: str, payload: dict[str, Any]) -> tuple[int, Any]:
    """POST to the scribe service. Returns (status, json). Never logs the payload."""
    url = get_settings().scribe_url.rstrip("/") + path
    try:
        async with httpx.AsyncClient(timeout=SCRIBE_TIMEOUT) as client:
            resp = await client.post(url, json=payload, headers={"Authorization": f"Bearer {_scribe_token()}"})
    except httpx.HTTPError as e:
        log.warning("scribe %s unreachable: %s", path, type(e).__name__)
        raise HTTPException(status_code=502, detail="Scribe unavailable") from e
    try:
        data = resp.json()
    except ValueError:
        data = {"detail": "Scribe returned an invalid response"}
    return resp.status_code, data


async def _relay(path: str, body: BaseModel, include: set[str] | None = None) -> JSONResponse:
    status, data = await forward_to_scribe(path, body.model_dump(mode="json", exclude_none=True, include=include))
    if status >= 500:
        log.warning("scribe %s failed with %s", path, status)
        return JSONResponse({"detail": "Scribe error"}, status_code=502)
    return JSONResponse(data, status_code=status)


@router.post("/scribe/start")
async def scribe_start(body: ScribeStart) -> JSONResponse:
    return await _relay("/sessions/start", body)


@router.post("/scribe/rekey")
async def scribe_rekey(body: ScribeRekey) -> JSONResponse:
    return await _relay("/sessions/rekey", body, include={"meetingId", "key", "epoch", "roomToken"})


@router.post("/scribe/stop")
async def scribe_stop(body: ScribeStop) -> JSONResponse:
    return await _relay("/sessions/stop", body)


def meetings_root_rel() -> str:
    rel = (get_settings().ifd_meetings_root or ".ifd-meetings").strip().strip("/")
    if not rel or ".." in rel.split("/"):
        raise HTTPException(status_code=503, detail="IFD_MEETINGS_ROOT is invalid")
    return rel


def meetings_dir() -> Path:
    return Path(get_settings().drive_root) / meetings_root_rel()


def find_meeting_folders(root: Path, meeting_id: str) -> list[Path]:
    """Every notes folder (one per recording part) of a meeting, oldest recording first.
    Names contain "(<last 6 of id>)"; transcript.json confirms the full id."""
    if not root.is_dir():
        return []
    tag = f"({meeting_id[-6:]})"
    found: list[tuple[int, str, Path]] = []
    for folder in root.iterdir():
        if not folder.is_dir() or folder.is_symlink() or tag not in folder.name:
            continue
        try:
            meta = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(meta, dict) and meta.get("meetingId") == meeting_id:
            started = meta.get("recordingStartedMs")
            found.append((started if isinstance(started, int) else 0, folder.name, folder))
    return [folder for _, _, folder in sorted(found)]


@router.get("/{meeting_id}/transcript")
def meeting_transcript(meeting_id: str = PathParam(pattern=MEETING_ID_PATTERN)) -> Response:
    """The transcript; a meeting recorded in several parts gets them all, in order."""
    parts = [folder / "transcript.md" for folder in find_meeting_folders(meetings_dir(), meeting_id)]
    texts = [md.read_text(encoding="utf-8") for md in parts if md.is_file() and not md.is_symlink()]
    if not texts:
        raise HTTPException(status_code=404, detail="Transcript not found")
    return Response("\n---\n\n".join(texts), media_type="text/markdown; charset=utf-8")


# ---------------------------------------------------------------------------
# Scribe → Drive → Portal notes status
# ---------------------------------------------------------------------------


def _client_host(request: Request) -> str:
    return request.client.host if request.client else ""


def require_scribe_caller(request: Request) -> None:
    """Direct local callers only (the Scribe container via the Docker host
    gateway). Requests through nginx / the tunnel carry proxy headers and are
    refused. Then the shared Scribe token."""
    if any(h in request.headers for h in PROXY_HEADERS):
        raise HTTPException(status_code=404, detail="Not found")
    try:
        ip = ipaddress.ip_address(_client_host(request))
    except ValueError:
        raise HTTPException(status_code=404, detail="Not found") from None
    if not (ip.is_loopback or ip.is_private):
        raise HTTPException(status_code=404, detail="Not found")
    expected = _scribe_token()
    auth = request.headers.get("authorization") or ""
    if not auth.lower().startswith("bearer ") or not hmac.compare_digest(auth[7:].strip(), expected):
        raise HTTPException(status_code=401, detail="Invalid token")


internal_router = APIRouter(prefix="/api/internal/scribe", dependencies=[Depends(require_scribe_caller)])


class NotesUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["RECORDING", "PROCESSING", "READY", "FAILED"]
    summaryMarkdown: str | None = Field(default=None, max_length=200_000)
    drivePath: str | None = Field(default=None, max_length=500)
    # Why notes FAILED (e.g. "notes folder not writable"); additive, the Portal may ignore it.
    reason: str | None = Field(default=None, max_length=200)

    @field_validator("drivePath")
    @classmethod
    def _under_meetings_root(cls, value: str | None) -> str | None:
        if value is None:
            return None
        parts = value.split("/")
        root = meetings_root_rel().split("/")
        if parts[: len(root)] != root or len(parts) != len(root) + 1 or parts[-1] in ("", ".", ".."):
            raise ValueError("must be a folder directly under IFD_MEETINGS_ROOT")
        return value


async def forward_to_portal(meeting_id: str, payload: dict[str, Any]) -> int:
    """POST the notes status to the Portal with the packages token. Returns the HTTP status."""
    s = get_settings()
    base = (s.portal_base_url or "").rstrip("/")
    token = (s.packages_service_token or "").strip()
    if not base or not token:
        raise HTTPException(status_code=503, detail="PORTAL_BASE_URL or PACKAGES_SERVICE_TOKEN not configured")
    url = f"{base}/api/service/meetings/{meeting_id}/notes"
    try:
        async with httpx.AsyncClient(timeout=PORTAL_TIMEOUT) as client:
            resp = await client.post(url, json=payload, headers={"Authorization": f"Bearer {token}"})
    except httpx.HTTPError as e:
        log.warning("portal notes unreachable: %s", type(e).__name__)
        return 502
    return resp.status_code


@internal_router.post("/notes/{meeting_id}")
async def scribe_notes(body: NotesUpdate, meeting_id: str = PathParam(pattern=MEETING_ID_PATTERN)) -> JSONResponse:
    status = await forward_to_portal(meeting_id, body.model_dump(exclude_none=True))
    if status >= 500:
        log.warning("portal notes %s failed with %s", body.status, status)
        return JSONResponse({"detail": "Portal unavailable"}, status_code=502)
    if status >= 400:
        log.warning("portal rejected notes %s: %s", body.status, status)
        return JSONResponse({"detail": "Portal rejected the update"}, status_code=status)
    return JSONResponse({"ok": True})
