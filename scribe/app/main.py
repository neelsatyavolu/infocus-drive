"""InFocus Scribe API (localhost only; Drive forwards Portal requests here)."""

from __future__ import annotations

import hmac
import logging
from contextlib import asynccontextmanager
from datetime import datetime
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .config import get_config
from .session import SessionManager, StartRequest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("scribe")

MEETING_ID_PATTERN = r"^[a-z0-9]{10,40}$"
KEY_PATTERN = r"^[A-Za-z0-9_-]{16,128}={0,2}$"


def require_internal_token(request: Request) -> None:
    expected = get_config().internal_token
    if not expected:
        raise HTTPException(status_code=503, detail="Scribe token not configured")
    auth = request.headers.get("authorization") or ""
    if not auth.lower().startswith("bearer ") or not hmac.compare_digest(auth[7:].strip(), expected):
        raise HTTPException(status_code=401, detail="Invalid token")


def _origin(url: str) -> str:
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}".lower()


def _pinned(value: str, configured: str, env_name: str) -> str:
    if not configured or _origin(value) != _origin(configured):
        raise ValueError(f"must match {env_name}")
    return value


class _Body(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)
    meetingId: str = Field(pattern=MEETING_ID_PATTERN)


class StartBody(_Body):
    title: str = Field(min_length=1, max_length=200)
    startsAt: datetime
    roomUrl: str = Field(max_length=500, pattern=r"^https?://")
    roomToken: str = Field(min_length=1, max_length=4096, pattern=r"^[A-Za-z0-9._~+/=-]+$")
    key: str = Field(pattern=KEY_PATTERN)
    epoch: int = Field(ge=0, le=1_000_000)
    portalBaseUrl: str = Field(max_length=500, pattern=r"^https?://")

    @field_validator("portalBaseUrl")
    @classmethod
    def _portal_matches_config(cls, value: str) -> str:
        return _pinned(value, get_config().portal_base_url, "PORTAL_BASE_URL")

    @field_validator("roomUrl")
    @classmethod
    def _room_matches_config(cls, value: str) -> str:
        return _pinned(value, get_config().meeting_room_url, "MEETING_ROOM_URL")


class RekeyBody(_Body):
    key: str = Field(pattern=KEY_PATTERN)
    epoch: int = Field(ge=0, le=1_000_000)


class StopBody(_Body):
    pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    cfg = get_config()
    cfg.tmp_dir.mkdir(parents=True, exist_ok=True)
    if not cfg.internal_token:
        log.error("SCRIBE_INTERNAL_TOKEN is not set; every request will be refused")
    manager = SessionManager(cfg)
    manager.start_worker()
    app.state.manager = manager
    try:
        yield
    finally:
        await manager.shutdown()


app = FastAPI(title="InFocus Scribe", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)


@app.exception_handler(RequestValidationError)
async def _validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
    """422 without echoing submitted values (keys, tokens)."""
    errors = [{k: v for k, v in err.items() if k in ("type", "loc", "msg")} for err in exc.errors()]
    return JSONResponse(status_code=422, content={"detail": errors})


def _manager(request: Request) -> SessionManager:
    return request.app.state.manager


@app.get("/health")
def health() -> dict[str, bool]:
    return {"ok": True}


@app.post("/sessions/start", dependencies=[Depends(require_internal_token)])
async def start(body: StartBody, request: Request) -> dict[str, object]:
    state = _manager(request).start(StartRequest(
        meeting_id=body.meetingId, title=body.title, starts_at=body.startsAt, room_url=body.roomUrl,
        room_token=body.roomToken, key=body.key, epoch=body.epoch, portal_base_url=body.portalBaseUrl,
    ))
    return {"ok": True, "state": state}


@app.post("/sessions/rekey", dependencies=[Depends(require_internal_token)])
async def rekey(body: RekeyBody, request: Request) -> dict[str, object]:
    try:
        applied = await _manager(request).rekey(body.meetingId, body.key, body.epoch)
    except Exception as e:  # never let a browser error carry the key into logs
        log.warning("rekey failed: %s", type(e).__name__)
        raise HTTPException(status_code=409, detail="Rekey failed") from None
    if not applied:
        raise HTTPException(status_code=404, detail="Not recording this meeting")
    return {"ok": True}


@app.post("/sessions/stop", dependencies=[Depends(require_internal_token)])
async def stop(body: StopBody, request: Request) -> dict[str, object]:
    stopped = _manager(request).stop(body.meetingId)
    return {"ok": True, "state": "stopping" if stopped else "not-recording"}
