from __future__ import annotations

import mimetypes
import re
import secrets
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator
from urllib.parse import quote, urlencode

import httpx
from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from starlette.middleware.sessions import SessionMiddleware

from chunk_upload import (
    CHUNK_SIZE_DEFAULT,
    abort_session,
    complete_session,
    create_session,
    peek_session,
    package_upload_max_bytes,
    session_rel_path,
    status as chunk_upload_status,
    write_chunk,
)
from config import get_settings, require_strong_session_secret
import cli_tokens
import personal_folders
from email_auth import check_origin, router as email_auth_router
from ugos_sso import router as ugos_sso_router
from file_links import (
    DEFAULT_DAYS,
    MAX_DAYS,
    MIN_DAYS,
    LinkError,
    iso_utc,
    mint as mint_file_link,
    preview_kind,
    public_url as file_link_public_url,
    verify as verify_file_link,
)
from fsops import (
    FSError,
    as_user,
    collect_zip_entries,
    delete,
    disk_usage,
    empty_recycle,
    ensure_dir,
    folder_sizes,
    has_recycle_bin,
    is_under_recycle,
    list_dir,
    mkdir,
    move_item,
    open_for_download,
    rename,
    resolve_rel,
    search,
    use_share_root,
    upload_fingerprint,
    write_upload_stream,
)
import thumbs
import webproxy
from zipstream import stream_zip_store, zip_store_content_length
from service_auth import (
    assert_under_packages_root,
    mint_file_token,
    require_service_token,
    service_identity,
    verify_file_token,
)
from shares import (
    DEFAULT_SHARE,
    is_nas_admin,
    list_shares_for_user,
    normalize_share_for_user,
    personal_owner,
    share_path,
    user_group_names,
)
from ugos_api import nas_otp_login, nas_password_login
from users import _pwd_user, linux_user_email
from user_sync import (
    UserdClient,
    UserdError,
    allocate_username,
    ensure_for_login,
    ensure_user,
    fetch_roster_emails,
    revoke_user,
    sync_roster,
)
settings = get_settings()


@asynccontextmanager
async def lifespan(app):
    require_strong_session_secret(settings.session_secret)
    personal_folders.start_worker()
    try:
        yield
    finally:
        personal_folders.stop_worker()


app = FastAPI(title="InFocus Drive", docs_url=None, redoc_url=None, lifespan=lifespan)
app.include_router(email_auth_router)
app.include_router(ugos_sso_router)

# Allow infocus-packages (and local dev) browsers to upload/play Package Cycles media.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://infocuspaly.com",
        "https://www.infocuspaly.com",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
    ],
    allow_origin_regex=r"https://.*\.vercel\.app",
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["Content-Length", "Content-Range", "Accept-Ranges"],
    max_age=600,
)

app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    session_cookie=settings.session_cookie,
    max_age=settings.session_max_age,
    same_site="lax",
    # Tunnel terminates TLS at Cloudflare; backend is plain HTTP
    https_only=False,
)

STATIC = Path(__file__).parent / "static"
app.mount("/assets", StaticFiles(directory=STATIC), name="assets")


@app.middleware("http")
async def asset_cache_headers(request: Request, call_next):  # type: ignore[no-untyped-def]
    """Cache policy: immutable versioned assets; never cache auth/API (share-aware)."""
    response = await call_next(request)
    path = request.url.path
    if path in ("/api/thumbnail", "/api/service/thumbnail"):
        # Thumb URLs carry the file mtime (?mt=), so they're safe to cache per-user.
        # CDN-Cache-Control keeps Cloudflare from storing private JPEGs at the edge.
        response.headers["Cache-Control"] = "private, max-age=604800"
        response.headers["CDN-Cache-Control"] = "no-store"
    elif path.startswith(("/api/", "/auth/", "/infocus-sso/", "/cli/")):
        # Listings differ by X-Drive-Share / ?share= — must not be shared-cached.
        response.headers["Cache-Control"] = "private, no-store, no-cache, must-revalidate"
        response.headers["CDN-Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
    elif path == "/assets/cli-authorize.html":
        response.headers.update(_CLI_PAGE_HEADERS)
        response.headers["Cache-Control"] = "no-store"
    elif path.startswith("/assets/"):
        # Deploy cache-bust is the ?v= query on index.html / module imports.
        response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        response.headers["CDN-Cache-Control"] = "public, max-age=31536000, immutable"
    elif path in ("/", "/index.html") or path.startswith("/s/"):
        # Short edge cache so a new index.html / share.html (new ?v=) shows up quickly.
        response.headers["Cache-Control"] = "public, max-age=60, must-revalidate"
        response.headers["CDN-Cache-Control"] = "public, max-age=60, must-revalidate"
    return response

GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"
GOOGLE_USERINFO = "https://openidconnect.googleapis.com/v1/userinfo"


def _state_ser() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(settings.session_secret, salt="oauth-state")


def _lan_handoff_ser() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(settings.session_secret, salt="lan-handoff")


def _public_config(request: Request | None = None) -> dict[str, Any]:
    """Origins the client needs before / after auth (LAN prefer, OAuth host)."""
    lan = (settings.lan_origin or "").strip().rstrip("/")
    public = settings.public_base_url.rstrip("/")
    host = ""
    if request is not None:
        host = (request.headers.get("host") or request.url.netloc or "").split(":")[0].lower()
    via_lan = False
    if lan and host:
        try:
            from urllib.parse import urlparse

            lan_host = (urlparse(lan).hostname or "").lower()
            via_lan = bool(lan_host and host == lan_host)
        except Exception:
            via_lan = False
    return {
        "public_base_url": public,
        "lan_origin": lan,
        "lan_prefer": bool(settings.lan_prefer and lan),
        "via_lan": via_lan,
    }


def _safe_next_url(raw: str | None) -> str:
    """Only allow same-site relative redirects (path or hash)."""
    next_url = (raw or "").strip() or "/"
    if next_url.startswith("#"):
        return f"/{next_url}"
    if next_url.startswith("/") and not next_url.startswith("//"):
        return next_url
    return "/"


def _bearer_token(request: Request) -> str | None:
    auth = request.headers.get("authorization") or ""
    if auth[:7].lower() != "bearer ":
        return None
    return auth[7:].strip()


def _require_session_user(request: Request) -> dict[str, Any]:
    """Browser cookie session only — for actions a CLI token must never perform."""
    user = request.session.get("user")
    if not user or "uid" not in user or not _regular_uid(user):
        raise HTTPException(status_code=401, detail="Not authenticated")
    return user


def _require_user(request: Request) -> dict[str, Any]:
    """Cookie session, or `Authorization: Bearer ifd_…` from the infocus CLI.

    A bearer is never combined with the cookie: a bad token is a 401 even when
    the browser session is valid.
    """
    token = _bearer_token(request)
    if token is None:
        return _require_session_user(request)
    user = cli_tokens.lookup(token)
    if user is None:
        raise HTTPException(
            status_code=401,
            detail="Terminal sign-in expired or revoked. Run `infocus login`.",
        )
    return user


def _regular_uid(user: dict[str, Any]) -> bool:
    """Every sign-in path only issues sessions for NAS users (uid >= 1000)."""
    try:
        return int(user["uid"]) >= 1000
    except (KeyError, TypeError, ValueError):
        return False


def _active_share(request: Request, user: dict[str, Any]) -> str:
    """Resolve share from query / header / session; pin to session.

    Query wins (downloads via <a href>), then explicit header, then session.
    /api/me should omit the share header so a stale client default does not
    wipe a previously chosen share on reload.
    """
    via_cli = "cli_token_id" in user
    requested = (
        request.query_params.get("share")
        or request.headers.get("X-Drive-Share")
        or (None if via_cli else request.session.get("share"))
    )
    share = normalize_share_for_user(
        requested,
        str(user.get("username") or ""),
        int(user["uid"]),
        int(user["gid"]),
    )
    if not via_cli:
        # CLI requests carry the share per call; never mint a cookie for them.
        request.session["share"] = share
    return share


def _fs_http(e: FSError) -> HTTPException:
    return HTTPException(status_code=e.status, detail=str(e))


@app.get("/api/health")
async def health() -> dict[str, str]:
    """Liveness probe — must stay async so it never waits on the as_user thread pool.

    A hung sync health endpoint (all workers blocked on the process-wide FS lock)
    made the public site look fully down even though uvicorn was still running.
    """
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Packages service API — machine auth for infocus-packages NAS storage
# Paths must stay under Package Cycles/ (producer library) or Package Storage/ (student cycle uploads).
# ---------------------------------------------------------------------------


@app.post("/api/service/ensure-dir")
async def service_ensure_dir(request: Request) -> dict[str, Any]:
    require_service_token(request)
    body = await request.json()
    rel = assert_under_packages_root(str(body.get("path") or ""))
    ident = service_identity()
    try:
        # ensure each segment
        return ensure_dir(rel, ident.uid, ident.gid)
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/service/ensure-user")
async def service_ensure_user(request: Request) -> dict[str, Any]:
    """Create NAS users for packages accounts that do not already exist.

    Never edits/deletes existing accounts (including the super-admin).
    """
    require_service_token(request)
    body = await request.json()
    rows: list[dict[str, Any]]
    if isinstance(body.get("users"), list):
        rows = [u for u in body["users"] if isinstance(u, dict)]
    else:
        rows = [body]
    roster = fetch_roster_emails()
    results = []
    claimed: set[str] = set()
    for row in rows:
        email = str(row.get("email") or "").strip().lower()
        name = str(row.get("name") or "").strip()
        extra = set(roster)
        extra.add(email)
        username = allocate_username(email, extra)
        if username and username.lower() in claimed:
            results.append(
                {
                    "email": email,
                    "username": username,
                    "status": "skipped_duplicate_username",
                }
            )
            continue
        result = ensure_user(email, name, roster=extra)
        if result.get("username"):
            claimed.add(str(result["username"]).lower())
        results.append(result)
    return {"results": results}


@app.post("/api/service/sync-users")
def service_sync_users(request: Request) -> dict[str, Any]:
    """Reconcile packages roster → NAS: create missing, delete removed."""
    require_service_token(request)
    return sync_roster()


@app.post("/api/service/revoke-user")
async def service_revoke_user(request: Request) -> dict[str, Any]:
    """Delete the NAS user for a packages account that was removed."""
    require_service_token(request)
    body = await request.json()
    emails: list[str] = []
    if isinstance(body.get("users"), list):
        for row in body["users"]:
            if isinstance(row, dict):
                emails.append(str(row.get("email") or "").strip().lower())
            else:
                emails.append(str(row or "").strip().lower())
    elif body.get("email"):
        emails.append(str(body.get("email") or "").strip().lower())
    roster = fetch_roster_emails(force=True)
    results = [revoke_user(email, roster=roster) for email in emails if email and "@" in email]
    return {"results": results}


@app.post("/api/service/mint-token")
async def service_mint_token(request: Request) -> dict[str, Any]:
    """Mint a short-lived path-scoped token for browser upload/download."""
    require_service_token(request)
    body = await request.json()
    rel = assert_under_packages_root(str(body.get("path") or ""))
    purpose = str(body.get("purpose") or "rw")
    if purpose not in ("r", "rw", "w"):
        raise HTTPException(status_code=400, detail="purpose must be r, w, or rw")
    ttl = int(body.get("ttlSeconds") or 3600)
    token = mint_file_token(rel, ttl_seconds=ttl, purpose=purpose if purpose != "w" else "rw")
    base = settings.public_base_url.rstrip("/")
    return {
        **token,
        "uploadUrl": f"{base}/api/service/upload",
        "downloadUrl": f"{base}/api/service/file?path={quote(rel, safe='')}&token={token['token']}",
    }


@app.post("/api/service/upload")
async def service_upload(
    request: Request,
    path: str = Form(...),
    file: UploadFile = File(...),
    token: str = Form(""),
) -> dict[str, Any]:
    """
    Upload a file into Package Cycles.
    Auth: service bearer OR short-lived path token (form field `token`).
    """
    rel = assert_under_packages_root(path)
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        require_service_token(request)
    elif token:
        verify_file_token(token, rel, purpose="rw")
    else:
        raise HTTPException(status_code=401, detail="Service bearer or file token required")

    ident = service_identity()
    # Ensure parent directory exists
    parent = str(Path(rel).parent).replace("\\", "/")
    if parent and parent not in (".",):
        try:
            ensure_dir(parent if parent != "Package Cycles" else parent, ident.uid, ident.gid)
        except FSError as e:
            raise _fs_http(e) from e

    filename = Path(rel).name
    parent_rel = str(Path(rel).parent).replace("\\", "/")
    if parent_rel == ".":
        parent_rel = ""

    # Stream body into write_upload_stream under parent_rel with explicit name
    # write_upload_stream uses filename from argument, stores under parent.
    max_bytes = package_upload_max_bytes(parent_rel, 8 * 1024 ** 3)
    # Prefer declared size when present so a truncated stream never becomes final.
    expected: int | None = None
    try:
        if file.size is not None and int(file.size) >= 0:
            expected = int(file.size)
            if expected > max_bytes:
                raise HTTPException(status_code=413, detail="File too large")
    except (TypeError, ValueError):
        expected = None

    import asyncio
    import queue

    from anyio import to_thread

    chunk_q: queue.Queue[bytes | None] = queue.Queue(maxsize=16)
    pump_error: list[BaseException] = []

    async def _put(item: bytes | None) -> None:
        while True:
            try:
                chunk_q.put_nowait(item)
                return
            except queue.Full:
                await asyncio.sleep(0.005)

    async def pump() -> None:
        total = 0
        try:
            while True:
                piece = await file.read(1024 * 1024)
                if not piece:
                    break
                total += len(piece)
                if total > max_bytes:
                    raise HTTPException(status_code=413, detail="File too large")
                await _put(piece)
        except BaseException as exc:  # noqa: BLE001 — surface to writer before commit
            pump_error.append(exc)
        finally:
            await _put(None)

    def sync_chunks() -> Any:
        while True:
            item = chunk_q.get()
            if item is None:
                if pump_error:
                    raise pump_error[0]
                break
            yield item

    pump_task = asyncio.create_task(pump())
    try:
        # Atomic overwrite via write_upload_stream (os.replace) — never delete-first.
        result = await to_thread.run_sync(
            lambda: write_upload_stream(
                parent_rel,
                filename,
                sync_chunks(),
                ident.uid,
                ident.gid,
                max_bytes,
                expected_bytes=expected,
            )
        )
        await pump_task
        if pump_error:
            raise pump_error[0]
        return {"ok": True, "path": rel, "entry": result}
    except FSError as e:
        pump_task.cancel()
        raise _fs_http(e) from e
    except HTTPException:
        pump_task.cancel()
        raise
    except Exception:
        pump_task.cancel()
        raise


def _require_service_path_auth(request: Request, rel: str, token: str = "") -> None:
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        require_service_token(request)
    elif token:
        verify_file_token(token, rel, purpose="rw")
    else:
        raise HTTPException(status_code=401, detail="Service bearer or file token required")


async def _write_incoming_chunk(request: Request, upload_id: str, index: int, username: str, uid: int) -> dict[str, Any]:
    import asyncio
    import queue

    from anyio import to_thread

    body_q: queue.Queue[bytes | None] = queue.Queue(maxsize=8)
    pump_error: list[BaseException] = []

    async def _put(item: bytes | None) -> None:
        while True:
            try:
                body_q.put_nowait(item)
                return
            except queue.Full:
                await asyncio.sleep(0.002)

    async def pump() -> None:
        try:
            async for piece in request.stream():
                await _put(piece)
        except BaseException as exc:  # noqa: BLE001
            pump_error.append(exc)
        finally:
            await _put(None)

    def sync_iter() -> Any:
        while True:
            item = body_q.get()
            if item is None:
                if pump_error:
                    raise pump_error[0]
                break
            yield item

    pump_task = asyncio.create_task(pump())
    try:
        result = await to_thread.run_sync(
            lambda: write_chunk(upload_id, index, sync_iter(), username=username, uid=uid)
        )
        await pump_task
        if pump_error:
            raise pump_error[0]
        return result
    except Exception:
        pump_task.cancel()
        raise


@app.post("/api/service/upload/init")
async def service_upload_init(request: Request) -> dict[str, Any]:
    """Start a chunked service upload (browser token or service bearer)."""
    form = await request.form()
    rel = assert_under_packages_root(str(form.get("path") or ""))
    _require_service_path_auth(request, rel, str(form.get("token") or ""))
    ident = service_identity()
    size = int(form.get("size") or 0)
    chunk_size = int(form.get("chunk_size") or CHUNK_SIZE_DEFAULT)
    filename = Path(rel).name
    parent = str(Path(rel).parent).replace("\\", "/")
    if parent in (".",):
        parent = ""
    if parent:
        try:
            ensure_dir(parent, ident.uid, ident.gid)
        except FSError as e:
            raise _fs_http(e) from e
    try:
        return create_session(
            username=ident.username,
            uid=ident.uid,
            gid=ident.gid,
            share=DEFAULT_SHARE,
            rel_dir=parent,
            filename=filename,
            size=size,
            chunk_size=chunk_size,
        )
    except FSError as e:
        raise _fs_http(e) from e


@app.get("/api/service/upload/status")
def service_upload_status(
    request: Request,
    upload_id: str = Query(...),
    token: str = Query(""),
) -> dict[str, Any]:
    try:
        meta = peek_session(upload_id)
        _require_service_path_auth(request, session_rel_path(meta), token)
        ident = service_identity()
        return chunk_upload_status(upload_id, username=ident.username, uid=ident.uid)
    except FSError as e:
        raise _fs_http(e) from e


@app.put("/api/service/upload/chunk")
async def service_upload_chunk(
    request: Request,
    upload_id: str = Query(...),
    index: int = Query(..., ge=0),
    token: str = Query(""),
) -> dict[str, Any]:
    try:
        meta = peek_session(upload_id)
        _require_service_path_auth(request, session_rel_path(meta), token)
        ident = service_identity()
        return await _write_incoming_chunk(request, upload_id, index, ident.username, ident.uid)
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/service/upload/complete")
async def service_upload_complete(request: Request) -> dict[str, Any]:
    form = await request.form()
    upload_id = str(form.get("upload_id") or "")
    token = str(form.get("token") or "")
    try:
        meta = peek_session(upload_id)
        _require_service_path_auth(request, session_rel_path(meta), token)
        ident = service_identity()
        with use_share_root(share_path(str(meta.get("share") or DEFAULT_SHARE))):
            return complete_session(upload_id, username=ident.username, uid=ident.uid)
    except FSError as e:
        raise _fs_http(e) from e


def _require_service_read(request: Request, rel: str, token: str) -> None:
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        require_service_token(request)
    elif token:
        verify_file_token(token, rel, purpose="r")
    else:
        raise HTTPException(status_code=401, detail="Service bearer or file token required")


@app.get("/api/service/file")
def service_file(
    request: Request,
    path: str = Query(...),
    token: str = Query(""),
    inline: bool = Query(True),
    web: bool = Query(False),
) -> FileResponse:
    """Download/stream a Package Cycles file (Range-friendly via FileResponse).

    web=1 transcodes camera originals (ProRes, XAVC 4:2:2) to H.264/AAC for
    browser <video>. Original downloads omit web=1.
    """
    rel = assert_under_packages_root(path)
    _require_service_read(request, rel, token)

    ident = service_identity()
    try:
        file_path, name = open_for_download(rel, ident.uid, ident.gid)
    except FSError as e:
        raise _fs_http(e) from e
    serve_path = file_path
    serve_name = name
    media_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
    if web:
        proxy = webproxy.get_or_create(file_path)
        if proxy != file_path:
            serve_path = proxy
            serve_name = f"{Path(name).stem}.mp4"
            media_type = "video/mp4"
    return FileResponse(
        path=serve_path,
        filename=serve_name,
        media_type=media_type,
        content_disposition_type="inline" if inline else "attachment",
    )


@app.get("/api/service/thumbnail")
def service_thumbnail(
    request: Request,
    path: str = Query(...),
    token: str = Query(""),
    size: int = Query(512, ge=16, le=1024),
) -> FileResponse:
    """ffmpeg JPEG thumbnail for a Package Cycles / Package Storage video or image."""
    rel = assert_under_packages_root(path)
    _require_service_read(request, rel, token)

    ident = service_identity()
    try:
        file_path, _name = open_for_download(rel, ident.uid, ident.gid)
    except FSError as e:
        raise _fs_http(e) from e
    thumb_path = thumbs.get_or_create(file_path, size)
    if thumb_path is None:
        raise HTTPException(status_code=404, detail="No thumbnail")
    return FileResponse(path=thumb_path, media_type="image/jpeg")


@app.delete("/api/service/file")
def service_delete_file(request: Request, path: str = Query(...)) -> dict[str, bool]:
    require_service_token(request)
    rel = assert_under_packages_root(path)
    ident = service_identity()
    try:
        delete(rel, ident.uid, ident.gid, permanent=True)
        return {"ok": True}
    except FSError as e:
        raise _fs_http(e) from e


@app.get("/api/config")
def api_public_config(request: Request) -> dict[str, Any]:
    """Unauthenticated boot config (LAN prefer origins)."""
    return _public_config(request)


@app.post("/api/lan-handoff")
def api_lan_handoff(request: Request) -> dict[str, Any]:
    """Mint a short-lived token so the browser can open the LAN origin signed-in."""
    user = _require_session_user(request)
    if not (settings.lan_origin or "").strip():
        raise HTTPException(status_code=404, detail="LAN origin not configured")
    payload = {
        "email": user.get("email"),
        "name": user.get("name"),
        "picture": user.get("picture"),
        "username": user.get("username"),
        "uid": user.get("uid"),
        "gid": user.get("gid"),
        "share": request.session.get("share") or DEFAULT_SHARE,
        "nonce": secrets.token_urlsafe(8),
    }
    token = _lan_handoff_ser().dumps(payload)
    return {
        "token": token,
        "lan_origin": settings.lan_origin.rstrip("/"),
        "expires_in": 90,
    }


@app.get("/auth/lan-handoff")
def auth_lan_handoff(
    request: Request,
    token: str = Query(""),
    next: str = Query("/"),
) -> RedirectResponse:
    """Consume a handoff token on the LAN host and establish a session cookie there."""
    if not token:
        raise HTTPException(status_code=400, detail="Missing handoff token")
    try:
        payload = _lan_handoff_ser().loads(token, max_age=90)
    except SignatureExpired as e:
        raise HTTPException(status_code=400, detail="Handoff expired — open Drive again") from e
    except BadSignature as e:
        raise HTTPException(status_code=400, detail="Invalid handoff token") from e

    username = str(payload.get("username") or "")
    try:
        uid = int(payload["uid"])
        gid = int(payload["gid"])
    except (KeyError, TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail="Invalid handoff payload") from e

    request.session["user"] = {
        "email": payload.get("email"),
        "name": payload.get("name"),
        "picture": payload.get("picture"),
        "username": username,
        "uid": uid,
        "gid": gid,
    }
    share = str(payload.get("share") or DEFAULT_SHARE)
    request.session["share"] = share
    return RedirectResponse(_safe_next_url(next), status_code=302)


@app.get("/api/me")
def me(request: Request) -> dict[str, Any]:
    cfg = _public_config(request)
    try:
        user = _require_user(request)
    except HTTPException:
        return {"authenticated": False, **cfg}
    smb_host = (settings.smb_hostname or settings.smb_host or "").strip()
    smb_share = (settings.smb_share_infocus or DEFAULT_SHARE).strip()
    warp_team = (settings.warp_team_name or "").strip()
    warp_url = (settings.warp_enroll_url or "").strip()
    if not warp_url and warp_team:
        warp_url = f"https://{warp_team}.cloudflareaccess.com/warp"
    username = str(user.get("username") or "")
    uid = int(user["uid"])
    gid = int(user["gid"])
    admin = is_nas_admin(username)
    shares = list_shares_for_user(username, uid, gid)
    active = _active_share(request, user)
    return {
        "authenticated": True,
        "email": user.get("email"),
        "name": user.get("name"),
        "picture": user.get("picture"),
        "nas_username": username,
        "is_admin": admin,
        "groups": user_group_names(username, gid),
        "share": active,
        "shares": shares,
        "ugos_admin_path": settings.ugos_admin_path.rstrip("/") + "/infocus-sso/start" if settings.ugos_sso_enabled else settings.ugos_admin_path,
        **cfg,
        # Native SMB for Finder/Explorer — NAS password, multi-share
        # LAN: docs/FINDER-NETWORK-DRIVE.md · Remote: docs/REMOTE-SMB-WARP.md
        "network_drive": {
            "protocol": "smb",
            "host": smb_host,
            "server_url": f"smb://{smb_host}" if smb_host else "",
            "infocus_share": smb_share,
            "infocus_url": f"smb://{smb_host}/{smb_share}" if smb_host else "",
            "warp_team_name": warp_team,
            "warp_enroll_url": warp_url,
            "warp_download_url": "https://developers.cloudflare.com/warp-client/get-started/macos/",
            "note": (
                "Use NAS username + password (not Google). "
                "On campus: school Wi‑Fi (no WARP). Off campus: WARP Profile → Cloudflare One team login "
                f"(team {warp_team or '(not configured)'}, allowlisted emails only), then same smb:// URL. "
                "This site is the web app only — not a Connect to Server host."
            ),
        },
    }


@app.post("/api/share")
async def api_set_share(request: Request) -> dict[str, Any]:
    """Switch the active shared folder (NAS admins only see multiple options)."""
    user = _require_session_user(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    requested = str((body or {}).get("share") or "")
    share = normalize_share_for_user(
        requested,
        str(user.get("username") or ""),
        int(user["uid"]),
        int(user["gid"]),
    )
    request.session["share"] = share
    return {
        "share": share,
        "shares": list_shares_for_user(
            str(user.get("username") or ""),
            int(user["uid"]),
            int(user["gid"]),
        ),
    }


@app.post("/api/personal/unlock")
def api_unlock_personal(request: Request, owner: str = Form(...), key: str = Form(..., max_length=65536),
                        key_file: bool = Form(False)) -> dict[str, Any]:
    user = _require_session_user(request)
    username = str(user.get("username") or "")
    if owner != username:
        raise HTTPException(status_code=403, detail="You cannot unlock this personal folder")
    if request.url.scheme != "https" and request.url.hostname not in ("localhost", "127.0.0.1", "testserver"):
        raise HTTPException(status_code=426, detail="Open Drive over HTTPS to enter your encryption key")
    if not _nas_login_allowed(f"personal:{user['uid']}"):
        raise HTTPException(status_code=429, detail="Too many unlock attempts. Try again in a few minutes.")
    if not personal_folders.configured():
        raise HTTPException(status_code=503, detail="Personal-folder unlocking is not configured")
    try:
        result = personal_folders.folders.unlock(owner, key, key_file=key_file)
    except personal_folders.OwnerSignInRequired as e:
        raise HTTPException(status_code=428, detail=str(e)) from None
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except Exception as e:
        raise HTTPException(status_code=400, detail="Could not unlock the folder. Check the encryption key and try again.") from e
    return result


@app.post("/api/personal/auth")
def api_personal_auth(request: Request, owner: str = Form(...),
                      password: str = Form("", max_length=256), code: str = Form("", max_length=12)) -> dict[str, Any]:
    user = _require_session_user(request)
    username = str(user.get("username") or "")
    if owner != username:
        raise HTTPException(status_code=403, detail="Sign in as the personal-folder owner")
    if request.url.scheme != "https" and request.url.hostname not in ("localhost", "127.0.0.1", "testserver"):
        raise HTTPException(status_code=426, detail="Open Drive over HTTPS to sign in")
    if not _nas_login_allowed(f"personal-auth:{user['uid']}"):
        raise HTTPException(status_code=429, detail="Too many sign-in attempts. Try again in a few minutes.")
    if code:
        pending = request.session.get("personal_otp") or {}
        if pending.get("owner") != owner or float(pending.get("expires", 0)) < time.time():
            raise HTTPException(status_code=401, detail="Sign-in expired. Enter your NAS password again.")
        result = nas_otp_login(settings.ugos_api_url, code=code, token_id=pending["token_id"], return_session=True)
    else:
        request.session.pop("personal_otp", None)
        result = nas_password_login(settings.ugos_api_url, owner, password, return_session=True)
    if not result.get("ok"):
        raise HTTPException(status_code=401, detail=result.get("error", "NAS sign-in failed"))
    if result.get("need_otp"):
        request.session["personal_otp"] = {"owner": owner, "token_id": result["token_id"], "expires": time.time() + 300}
        return {"need_otp": True}
    personal_folders.save_owner_session(owner, result["session"])
    request.session.pop("personal_otp", None)
    return {"ok": True}


@app.get("/auth/login")
def auth_login(request: Request) -> RedirectResponse:
    if not settings.google_client_id or not settings.google_client_secret:
        raise HTTPException(
            status_code=503,
            detail="Google OAuth is not configured (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET)",
        )
    # Signed state (not session-only): Google always returns to PUBLIC_BASE_URL, but
    # campus LAN prefer may start login on the LAN origin — a different cookie jar.
    cfg = _public_config(request)
    return_lan = bool(cfg.get("via_lan")) or request.query_params.get("return_lan") == "1"
    if cfg.get("via_lan"):
        # Establish the OAuth browser cookie on the same public origin that
        # receives Google's callback, including sign-ins begun on campus LAN.
        return RedirectResponse(settings.public_base_url.rstrip("/") + "/auth/login?" + urlencode({
            "return_lan": "1", "next": _safe_next_url(request.query_params.get("next")),
        }))
    browser_nonce = secrets.token_urlsafe(32)
    request.session["oauth_browser_nonce"] = browser_nonce
    state = _state_ser().dumps(
        {
            "n": secrets.token_urlsafe(16),
            "browser_nonce": browser_nonce,
            "lan": return_lan,
            "next": _safe_next_url(request.query_params.get("next")),
        }
    )
    redirect_uri = f"{settings.public_base_url.rstrip('/')}/auth/callback"
    params = {
        "client_id": settings.google_client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": "openid email profile",
        "access_type": "online",
        "include_granted_scopes": "true",
        "prompt": "select_account",
        "state": state,
    }
    hd = (settings.google_hosted_domain or "").strip().lstrip("@")
    if hd:
        params["hd"] = hd
    # Remove None values
    params = {k: v for k, v in params.items() if v is not None}
    return RedirectResponse(f"{GOOGLE_AUTH}?{urlencode(params)}")


_NAS_LOGIN_WINDOW_S = 300.0
_NAS_LOGIN_MAX = 12
_nas_login_hits: dict[str, list[float]] = {}


def _nas_login_allowed(ip: str) -> bool:
    now = time.time()
    hits = [t for t in _nas_login_hits.get(ip, []) if now - t < _NAS_LOGIN_WINDOW_S]
    if len(hits) >= _NAS_LOGIN_MAX:
        _nas_login_hits[ip] = hits
        return False
    hits.append(now)
    _nas_login_hits[ip] = hits
    return True


# Per-username lockout on top of the per-IP limit (stops distributed guessing).
_NAS_USER_MAX_FAILS = 5
_NAS_USER_LOCK_S = 900.0
_nas_user_fails: dict[str, list[float]] = {}


def _nas_user_locked(username: str) -> bool:
    key = username.lower()
    now = time.time()
    fails = [t for t in _nas_user_fails.get(key, []) if now - t < _NAS_USER_LOCK_S]
    if fails:
        _nas_user_fails[key] = fails
    else:
        _nas_user_fails.pop(key, None)
    return len(fails) >= _NAS_USER_MAX_FAILS


def _nas_user_failed(username: str) -> None:
    _nas_user_fails.setdefault(username.lower(), []).append(time.time())


# Server-side so replaying an older session cookie can't reset the count.
_NAS_OTP_MAX_ATTEMPTS = 5
_nas_otp_attempts: dict[str, tuple[int, float]] = {}


def _nas_otp_take_attempt(key: str, expires: float) -> bool:
    now = time.time()
    for k in [k for k, (_n, exp) in _nas_otp_attempts.items() if exp < now]:
        del _nas_otp_attempts[k]
    used, _exp = _nas_otp_attempts.get(key, (0, expires))
    if used >= _NAS_OTP_MAX_ATTEMPTS:
        return False
    _nas_otp_attempts[key] = (used + 1, expires)
    return True


def _session_nas_user(request: Request, username: str) -> None:
    pw = _pwd_user(username)
    if pw is None or pw.pw_uid < 1000:
        raise HTTPException(status_code=403, detail="No InFocus Drive account for this NAS user")
    email = linux_user_email(username) or ""
    request.session.pop("nas_otp", None)
    request.session["user"] = {
        "email": email,
        "name": username,
        "picture": None,
        "username": pw.pw_name,
        "uid": pw.pw_uid,
        "gid": pw.pw_gid,
    }
    request.session["share"] = DEFAULT_SHARE


def _nas_userd_auth(username: str, password: str) -> dict[str, Any] | None:
    token = (settings.userd_token or "").strip()
    if not token:
        return None
    client = UserdClient(settings.userd_url, token, timeout=10.0)
    try:
        data = client.verify_password(username, password)
    except UserdError:
        return None
    finally:
        client.close()
    if str(data.get("status") or "") != "ok":
        return None
    return data


@app.post("/auth/nas")
async def auth_nas(request: Request) -> dict[str, Any]:
    ip = request.client.host if request.client else "unknown"
    if not _nas_login_allowed(ip):
        raise HTTPException(status_code=429, detail="Too many sign-in attempts. Try again in a few minutes.")
    body = await request.json()
    username = str(body.get("username") or "").strip()
    password = str(body.get("password") or "")
    if not username or not password:
        raise HTTPException(status_code=400, detail="Username and password are required")
    if _nas_user_locked(username):
        raise HTTPException(status_code=429, detail="Too many failed sign-ins for this account. Try again in 15 minutes.")
    checked = _nas_userd_auth(username, password)
    if not checked:
        _nas_user_failed(username)
        raise HTTPException(status_code=401, detail="Invalid username or password")
    _nas_user_fails.pop(username.lower(), None)
    ugos = (settings.ugos_api_url or "").strip()
    result: dict[str, Any] = {}
    if ugos:
        result = nas_password_login(ugos, username, password)
    need_otp = bool(result.get("ok") and result.get("need_otp"))
    if checked.get("otp_required") and not need_otp:
        raise HTTPException(
            status_code=503,
            detail="Two-factor sign-in is required but the NAS did not start a challenge. Try again.",
        )
    if need_otp:
        request.session["nas_otp"] = {
            "u": username,
            "tid": result.get("token_id") or "",
            "exp": time.time() + 300,
        }
        return {"ok": True, "need_otp": True}
    _session_nas_user(request, username)
    return {"ok": True, "need_otp": False}


@app.post("/auth/nas/otp")
async def auth_nas_otp(request: Request) -> dict[str, Any]:
    pending = request.session.get("nas_otp")
    if not isinstance(pending, dict) or time.time() > float(pending.get("exp") or 0):
        request.session.pop("nas_otp", None)
        raise HTTPException(status_code=401, detail="Sign-in expired. Enter your password again.")
    attempt_key = f"{pending.get('u') or ''}\0{pending.get('tid') or ''}"
    if not _nas_otp_take_attempt(attempt_key, float(pending.get("exp") or 0)):
        request.session.pop("nas_otp", None)
        raise HTTPException(status_code=401, detail="Too many invalid codes. Enter your password again.")
    body = await request.json()
    code = str(body.get("code") or "").strip()
    otp_type = int(body.get("type") or 1)
    ugos = (settings.ugos_api_url or "").strip()
    result = nas_otp_login(
        ugos,
        code=code,
        token_id=str(pending.get("tid") or ""),
        otp_type=otp_type,
    )
    if not result.get("ok") and otp_type == 1:
        result = nas_otp_login(
            ugos,
            code=code,
            token_id=str(pending.get("tid") or ""),
            otp_type=2,
        )
    if not result.get("ok"):
        raise HTTPException(status_code=401, detail=str(result.get("error") or "Invalid authentication code"))
    _session_nas_user(request, str(pending.get("u") or ""))
    return {"ok": True}


@app.get("/auth/callback")
async def auth_callback(request: Request, code: str | None = None, state: str | None = None) -> RedirectResponse:
    if not code or not state:
        raise HTTPException(status_code=400, detail="Missing code/state")
    # Prefer signed state (works across public ↔ LAN hosts). Fall back to legacy
    # session state for any mid-deploy OAuth round-trips still in flight.
    state_payload: dict[str, Any] = {"lan": False, "next": "/"}
    try:
        loaded = _state_ser().loads(state, max_age=600)
        if isinstance(loaded, dict):
            state_payload = loaded
        elif isinstance(loaded, str) and loaded:
            # Older signed-string shape if any
            state_payload = {"lan": False, "next": "/", "n": loaded}
    except (BadSignature, SignatureExpired):
        if state != request.session.get("oauth_state"):
            raise HTTPException(status_code=400, detail="Invalid OAuth state")
    request.session.pop("oauth_state", None)

    browser_verified = False
    if state_payload.get("browser_nonce"):
        expected = request.session.pop("oauth_browser_nonce", "")
        if not expected or not secrets.compare_digest(str(state_payload["browser_nonce"]), str(expected)):
            raise HTTPException(status_code=400, detail="Google sign-in belongs to another browser or was already used")
        browser_verified = True

    redirect_uri = f"{settings.public_base_url.rstrip('/')}/auth/callback"
    async with httpx.AsyncClient(timeout=20) as client:
        token_res = await client.post(
            GOOGLE_TOKEN,
            data={
                "code": code,
                "client_id": settings.google_client_id,
                "client_secret": settings.google_client_secret,
                "redirect_uri": redirect_uri,
                "grant_type": "authorization_code",
            },
        )
        if token_res.status_code != 200:
            raise HTTPException(status_code=400, detail="Token exchange failed")
        access_token = token_res.json().get("access_token")
        info_res = await client.get(
            GOOGLE_USERINFO,
            headers={"Authorization": f"Bearer {access_token}"},
        )
        if info_res.status_code != 200:
            raise HTTPException(status_code=400, detail="Userinfo failed")
        info = info_res.json()

    email = (info.get("email") or "").lower()
    if info.get("email_verified") is not True:
        raise HTTPException(status_code=403, detail="Email not verified")

    next_url = _safe_next_url(str(state_payload.get("next") or "/"))
    return_lan = bool(state_payload.get("lan")) and bool((settings.lan_origin or "").strip())

    nas = ensure_for_login(email, str(info.get("name") or ""))
    if nas is None:
        request.session.clear()
        # Pass the attempted address back so the UI can name the missing NAS user.
        denied = f"/?{urlencode({'error': 'not_authorized', 'email': email})}"
        if return_lan:
            # Stay on public for the denied message (no session to hand off).
            return RedirectResponse(denied)
        return RedirectResponse(denied)

    user = {
        "email": email,
        "name": info.get("name") or email,
        "picture": info.get("picture"),
        "username": nas.username,
        "uid": nas.uid,
        "gid": nas.gid,
    }
    if browser_verified and info.get("sub"):
        user.update(auth_provider="google", google_sub=str(info["sub"]))
    request.session["user"] = user
    request.session["share"] = DEFAULT_SHARE

    # Login often starts on campus LAN; Google always lands on public_base_url.
    # Hand the new session to the LAN origin so the user stays on the fast path.
    if return_lan:
        handoff = {
            "email": user["email"],
            "name": user["name"],
            "picture": user["picture"],
            "username": user["username"],
            "uid": user["uid"],
            "gid": user["gid"],
            "share": DEFAULT_SHARE,
            "nonce": secrets.token_urlsafe(8),
        }
        token = _lan_handoff_ser().dumps(handoff)
        lan = settings.lan_origin.rstrip("/")
        return RedirectResponse(
            f"{lan}/auth/lan-handoff?{urlencode({'token': token, 'next': next_url})}",
            status_code=302,
        )
    return RedirectResponse(next_url)


@app.post("/auth/logout")
def auth_logout(request: Request) -> JSONResponse:
    request.session.clear()
    return JSONResponse({"ok": True})


@app.get("/api/files")
def api_list(request: Request, path: str = "") -> dict[str, Any]:
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            data = list_dir(path, user["uid"], user["gid"])
            data["has_recycle"] = has_recycle_bin()
            data["in_recycle"] = is_under_recycle(path or "")
        data["share"] = share
        return data
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/upload/fingerprint")
def api_upload_fingerprint(request: Request, path: str = Form(...), size: int = Form(..., ge=0)) -> dict[str, Any]:
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            return {"fingerprint": upload_fingerprint(path, size, user["uid"], user["gid"])}
    except FSError as e:
        raise _fs_http(e) from e


@app.get("/api/folder-sizes")
def api_folder_sizes(
    request: Request,
    path: list[str] = Query(default=[]),
) -> dict[str, Any]:
    """
    Recursive content size for one or more folders (du-like).

    Used by the UI after listing so the file list stays fast; results are
    TTL-cached server-side. Incomplete walks set incomplete=true (UI shows ~).
    """
    user = _require_user(request)
    share = _active_share(request, user)
    if not path:
        return {"sizes": {}, "share": share}
    try:
        with use_share_root(share_path(share)):
            data = folder_sizes(path, user["uid"], user["gid"])
        data["share"] = share
        return data
    except FSError as e:
        raise _fs_http(e) from e


@app.get("/api/search")
def api_search(
    request: Request,
    q: str = Query("", min_length=0, max_length=200),
    path: str = "",
    limit: int = Query(40, ge=1, le=80),
) -> dict[str, Any]:
    """Recursive smart search under `path` (empty = whole active share)."""
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            data = search(q, path, user["uid"], user["gid"], limit=limit)
        data["share"] = share
        return data
    except FSError as e:
        raise _fs_http(e) from e


@app.get("/api/usage")
def api_usage(request: Request) -> dict[str, Any]:
    """Capacity of the active mount, including UGOS encrypted-home limits."""
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            owner = personal_owner(share)
            usage = disk_usage(personal=owner is not None)
            if owner and personal_folders.configured():
                usage["expires_at"] = personal_folders.folders.status(owner)["expires_at"]
            return usage
    except (FSError, OSError) as e:
        raise HTTPException(status_code=503, detail="Storage usage unavailable") from e


@app.post("/api/mkdir")
def api_mkdir(request: Request, path: str = Form(""), name: str = Form(...)) -> dict[str, Any]:
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            return mkdir(path, name, user["uid"], user["gid"])
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/rename")
def api_rename(request: Request, path: str = Form(...), new_name: str = Form(...)) -> dict[str, Any]:
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            return rename(path, new_name, user["uid"], user["gid"])
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/move")
def api_move(request: Request, path: str = Form(...), dest: str = Form(...)) -> dict[str, Any]:
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            return move_item(path, dest, user["uid"], user["gid"])
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/delete")
def api_delete(request: Request, path: str = Form(...)) -> dict[str, Any]:
    """Soft-delete into `#recycle` when present (Samba/UGOS style); permanent inside recycle."""
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            return delete(path, user["uid"], user["gid"])
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/recycle/empty")
def api_empty_recycle(request: Request) -> dict[str, Any]:
    """Permanently wipe `#recycle` on the active share. NAS admins only."""
    user = _require_user(request)
    username = str(user.get("username") or "")
    if not is_nas_admin(username):
        raise HTTPException(
            status_code=403,
            detail="Only NAS admins can empty the Recycle bin for everyone",
        )
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            return empty_recycle(user["uid"], user["gid"])
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/upload")
async def api_upload(
    request: Request,
    path: str = Form(""),
    file: UploadFile = File(...),
    expect_mtime_ns: int | None = Form(None),
) -> dict[str, Any]:
    """Stream upload to disk (no full-file RAM buffer) so large files stay fast/stable."""
    import asyncio
    import queue

    from anyio import to_thread

    user = _require_user(request)
    share = _active_share(request, user)
    share_root = share_path(share)
    max_bytes = 10 * 1024 * 1024 * 1024  # 10 GiB
    # Prefer declared multipart size when present so a truncated stream never
    # becomes the final file. Unknown size still refuses commit on pump errors.
    expected: int | None = None
    try:
        if file.size is not None and int(file.size) >= 0:
            expected = int(file.size)
            if expected > max_bytes:
                raise HTTPException(status_code=413, detail="File too large (max 10GB)")
    except (TypeError, ValueError):
        expected = None
    # Larger pieces + deeper queue keep the tunnel fed while disk writes catch up.
    _READ = 2 * 1024 * 1024
    chunk_q: queue.Queue[bytes | None] = queue.Queue(maxsize=32)
    pump_error: list[BaseException] = []

    async def _put(item: bytes | None) -> None:
        while True:
            try:
                chunk_q.put_nowait(item)
                return
            except queue.Full:
                await asyncio.sleep(0.002)

    async def pump() -> None:
        total = 0
        try:
            while True:
                piece = await file.read(_READ)
                if not piece:
                    break
                total += len(piece)
                if total > max_bytes:
                    raise HTTPException(status_code=413, detail="File too large (max 10GB)")
                await _put(piece)
        except BaseException as exc:  # noqa: BLE001 — surface to writer
            pump_error.append(exc)
        finally:
            await _put(None)

    def sync_chunks() -> Any:
        while True:
            item = chunk_q.get()
            if item is None:
                # Fail inside the writer so the temp file is discarded, not committed.
                if pump_error:
                    raise pump_error[0]
                break
            yield item

    def write_on_share() -> Any:
        with use_share_root(share_root):
            return write_upload_stream(
                path,
                file.filename or "upload.bin",
                sync_chunks(),
                user["uid"],
                user["gid"],
                max_bytes,
                expected_bytes=expected,
                expect_mtime_ns=expect_mtime_ns,
            )

    pump_task = asyncio.create_task(pump())
    try:
        result = await to_thread.run_sync(write_on_share)
        await pump_task
        if pump_error:
            raise pump_error[0]
        return result
    except FSError as e:
        pump_task.cancel()
        raise _fs_http(e) from e
    except HTTPException:
        pump_task.cancel()
        raise
    except Exception:
        pump_task.cancel()
        raise


# ---------------------------------------------------------------------------
# Chunked / resumable multi-stream upload (remote tunnel throughput)
# ---------------------------------------------------------------------------
@app.post("/api/upload/init")
def api_upload_init(
    request: Request,
    path: str = Form(""),
    name: str = Form(...),
    size: int = Form(...),
    chunk_size: int = Form(CHUNK_SIZE_DEFAULT),
) -> dict[str, Any]:
    """Start a chunked upload session. Client then PUTs pieces in parallel."""
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        # Folder uploads pass nested paths (webkitRelativePath) that may not
        # exist yet — mirror write_upload_stream and mkdir -p the parents.
        with use_share_root(share_path(share)):
            parent = resolve_rel(path or "")
            if not parent.is_dir():
                rel = (path or "").strip().lstrip("/")
                if not rel:
                    raise FSError("Parent not found", 404)
                ensure_dir(rel, int(user["uid"]), int(user["gid"]))
                parent = resolve_rel(rel)
                if not parent.is_dir():
                    raise FSError("Parent not found", 404)
        return create_session(
            username=str(user.get("username") or ""),
            uid=int(user["uid"]),
            gid=int(user["gid"]),
            share=share,
            rel_dir=path or "",
            filename=name,
            size=int(size),
            chunk_size=int(chunk_size),
        )
    except FSError as e:
        raise _fs_http(e) from e


@app.get("/api/upload/status")
def api_upload_status(request: Request, upload_id: str = Query(...)) -> dict[str, Any]:
    user = _require_user(request)
    try:
        return chunk_upload_status(
            upload_id,
            username=str(user.get("username") or ""),
            uid=int(user["uid"]),
        )
    except FSError as e:
        raise _fs_http(e) from e


@app.put("/api/upload/chunk")
async def api_upload_chunk(
    request: Request,
    upload_id: str = Query(...),
    index: int = Query(..., ge=0),
) -> dict[str, Any]:
    """Accept one chunk body (raw octets). Safe to retry; overwrites same index."""
    import asyncio
    import queue

    from anyio import to_thread

    user = _require_user(request)
    username = str(user.get("username") or "")
    uid = int(user["uid"])

    # Stream request body into a small queue so we don't hold multi-32MB in RAM twice.
    body_q: queue.Queue[bytes | None] = queue.Queue(maxsize=8)
    pump_error: list[BaseException] = []

    async def _put(item: bytes | None) -> None:
        while True:
            try:
                body_q.put_nowait(item)
                return
            except queue.Full:
                await asyncio.sleep(0.002)

    async def pump() -> None:
        try:
            async for piece in request.stream():
                await _put(piece)
        except BaseException as exc:  # noqa: BLE001
            pump_error.append(exc)
        finally:
            await _put(None)

    def sync_iter() -> Any:
        while True:
            item = body_q.get()
            if item is None:
                if pump_error:
                    raise pump_error[0]
                break
            yield item

    def do_write() -> dict[str, Any]:
        return write_chunk(
            upload_id,
            index,
            sync_iter(),
            username=username,
            uid=uid,
        )

    pump_task = asyncio.create_task(pump())
    try:
        result = await to_thread.run_sync(do_write)
        await pump_task
        if pump_error:
            raise pump_error[0]
        return result
    except FSError as e:
        pump_task.cancel()
        raise _fs_http(e) from e
    except Exception:
        pump_task.cancel()
        raise


@app.post("/api/upload/complete")
def api_upload_complete(
    request: Request,
    upload_id: str = Form(...),
    expect_mtime_ns: int | None = Form(None),
) -> dict[str, Any]:
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        # complete_session writes via write_upload_stream; pin share root.
        from chunk_upload import get_session

        meta = get_session(
            upload_id,
            username=str(user.get("username") or ""),
            uid=int(user["uid"]),
        )
        if meta.get("share") and meta["share"] != share:
            # Prefer the share recorded at init (client header should match).
            share = str(meta["share"])
        with use_share_root(share_path(share)):
            return complete_session(
                upload_id,
                username=str(user.get("username") or ""),
                uid=int(user["uid"]),
                expect_mtime_ns=expect_mtime_ns,
            )
    except FSError as e:
        raise _fs_http(e) from e


@app.post("/api/upload/abort")
def api_upload_abort(request: Request, upload_id: str = Form(...)) -> dict[str, Any]:
    user = _require_user(request)
    try:
        return abort_session(
            upload_id,
            username=str(user.get("username") or ""),
            uid=int(user["uid"]),
        )
    except FSError as e:
        raise _fs_http(e) from e


# ---------------------------------------------------------------------------
# Speed test — measures tunnel + NAS path the browser actually uses.
# Data is synthetic (zeros); nothing is written to the drive share.
# ---------------------------------------------------------------------------
_SPEEDTEST_CHUNK = 2 * 1024 * 1024  # 2 MiB chunks for higher throughput
_SPEEDTEST_MAX = 512 * 1024 * 1024  # 512 MiB hard cap
# Per-request upload piece used by multi-stream client (avoids single 512MB XHR death)
_SPEEDTEST_PIECE_MAX = 32 * 1024 * 1024


@app.get("/api/speedtest/download")
async def speedtest_download(
    request: Request,
    size: int = Query(32 * 1024 * 1024, ge=64 * 1024, le=_SPEEDTEST_MAX),
) -> StreamingResponse:
    _require_user(request)
    chunk = b"\0" * _SPEEDTEST_CHUNK

    async def generate() -> AsyncIterator[bytes]:
        remaining = size
        while remaining > 0:
            n = min(_SPEEDTEST_CHUNK, remaining)
            yield chunk if n == _SPEEDTEST_CHUNK else chunk[:n]
            remaining -= n

    return StreamingResponse(
        generate(),
        media_type="application/octet-stream",
        headers={
            "Content-Length": str(size),
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Pragma": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


@app.post("/api/speedtest/upload")
async def speedtest_upload(request: Request) -> dict[str, int]:
    """Accept one piece of a multi-stream upload test (max 32 MiB per request)."""
    _require_user(request)
    total = 0
    async for part in request.stream():
        total += len(part)
        if total > _SPEEDTEST_PIECE_MAX:
            raise HTTPException(status_code=413, detail="Speed-test piece too large (max 32MB per stream)")
    return {"received": total}


_TEXTISH_EXTS = (".md", ".markdown", ".log", ".csv", ".tsv", ".json", ".xml", ".yml", ".yaml")
# Only these render inline on the app origin; anything else (html, svg, xml, js…)
# could run script as the signed-in user, so it is always a download.
_INLINE_SAFE_PREFIXES = ("image/", "video/", "audio/")
_INLINE_SAFE_TYPES = frozenset({"application/pdf", "text/plain"})
_INLINE_UNSAFE_TYPES = frozenset({"image/svg+xml"})


def _inline_safe(media_type: str) -> bool:
    base = media_type.split(";", 1)[0].strip().lower()
    if base in _INLINE_UNSAFE_TYPES:
        return False
    return base in _INLINE_SAFE_TYPES or base.startswith(_INLINE_SAFE_PREFIXES)


def _user_file_response(file_path: Path, name: str, inline: bool) -> FileResponse:
    """Serve a user-uploaded file without letting it execute on our origin."""
    media_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
    # Text-ish types without a registered MIME still preview better as plain text.
    if media_type in ("application/octet-stream", "text/markdown") and name.lower().endswith(_TEXTISH_EXTS):
        media_type = "text/plain; charset=utf-8"
    inline = inline and _inline_safe(media_type)
    headers = {
        "X-Accel-Buffering": "no",
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
    }
    # Browsers won't run their built-in PDF viewer in a sandboxed document.
    if not (inline and media_type == "application/pdf"):
        headers["Content-Security-Policy"] = "sandbox"
    return FileResponse(
        path=file_path,
        filename=name,
        media_type=media_type,
        content_disposition_type="inline" if inline else "attachment",
        headers=headers,
    )


@app.get("/api/download")
def api_download(
    request: Request,
    path: str,
    inline: bool = Query(False, description="Serve for in-browser preview when true"),
) -> FileResponse:
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            file_path, name = open_for_download(path, user["uid"], user["gid"])
    except FSError as e:
        raise _fs_http(e) from e
    return _user_file_response(file_path, name, inline)


@app.get("/api/thumbnail")
def api_thumbnail(
    request: Request,
    path: str,
    size: int = Query(256, ge=16, le=1024),
    mt: str = Query("", description="File mtime for browser cache busting; unused server-side"),
) -> FileResponse:
    """Cached JPEG thumbnail for an image/video. 404 = no thumbnail available."""
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        with use_share_root(share_path(share)):
            file_path, _name = open_for_download(path, user["uid"], user["gid"])
    except FSError as e:
        raise _fs_http(e) from e
    # Access checked per-user above; generation reads as the service user.
    # Sync endpoint → FastAPI threadpool, so Pillow/ffmpeg don't block the loop.
    thumb_path = thumbs.get_or_create(file_path, size)
    if thumb_path is None:
        raise HTTPException(status_code=404, detail="No thumbnail")
    return FileResponse(path=thumb_path, media_type="image/jpeg")


_THUMB_WARM_MAX = 300


@app.post("/api/thumbnail/warm")
def api_thumbnail_warm(
    request: Request,
    path: list[str] = Form(default=[]),
    size: int = Form(256),
) -> dict[str, Any]:
    """Pre-generate thumbnails for a folder listing so scrolling hits warm cache.
    Only fills the disk cache — retrieval via /api/thumbnail still runs the
    per-user access check, so no per-path permission probe is needed here."""
    user = _require_user(request)
    share = _active_share(request, user)
    targets: list[Path] = []
    try:
        with use_share_root(share_path(share)):
            for rel in path[:_THUMB_WARM_MAX]:
                if thumbs.thumb_kind(rel) is None:
                    continue
                try:
                    targets.append(resolve_rel(rel))
                except FSError:
                    continue
    except FSError as e:
        raise _fs_http(e) from e
    queued = thumbs.warm_paths(targets, size)
    return {"ok": True, "queued": queued}


_ZIP_MAX_FILES = 10_000  # files after folder expansion
_ZIP_MAX_SELECTION = 500  # top-level paths in the query
_ZIP_MAX_TOTAL = 8 * 1024 * 1024 * 1024  # 8 GiB total payload cap


@app.get("/api/download/zip")
def api_download_zip(
    request: Request,
    path: list[str] = Query(default=[]),
) -> StreamingResponse:
    """Stream a STORE zip of files and/or folders. Query: ?path=a&path=b.

    Folders are expanded recursively (symlinks / #recycle / temp junk skipped).
    STORE method only — no recompress; streams under X-Accel-Buffering: no.
    """
    user = _require_user(request)
    share = _active_share(request, user)
    paths = [p for p in path if (p or "").strip()]
    if not paths:
        raise HTTPException(status_code=400, detail="No paths given")
    if len(paths) > _ZIP_MAX_SELECTION:
        raise HTTPException(
            status_code=400,
            detail=f"Too many items (max {_ZIP_MAX_SELECTION})",
        )

    try:
        with use_share_root(share_path(share)):
            entries = collect_zip_entries(
                paths,
                user["uid"],
                user["gid"],
                max_files=_ZIP_MAX_FILES,
                max_total=_ZIP_MAX_TOTAL,
            )
    except FSError as e:
        raise _fs_http(e) from e

    # Name the archive after a single top-level selection when possible.
    if len(paths) == 1:
        base = Path(paths[0].rstrip("/")).name or "download"
        zip_name = f"{base}.zip"
    elif len(entries) == 1:
        zip_name = f"{Path(entries[0][0]).name}.zip"
    else:
        zip_name = f"InFocus-Drive-{len(paths)}-items.zip"
    # Content-Disposition with RFC 5987 filename*
    cd = f"attachment; filename=\"{zip_name}\"; filename*=UTF-8''{quote(zip_name)}"

    def generate() -> Any:
        # Stream outside as_user — network-paced I/O must not hold the lock.
        yield from stream_zip_store(entries)

    headers = {
        "Content-Disposition": cd,
        "Cache-Control": "private, no-store",
        "X-Accel-Buffering": "no",
    }
    try:
        headers["Content-Length"] = str(zip_store_content_length(entries))
    except OSError:
        pass

    return StreamingResponse(
        generate(),
        media_type="application/zip",
        headers=headers,
    )


@app.api_route("/", methods=["GET", "HEAD"])
def index() -> FileResponse:
    return FileResponse(STATIC / "index.html")


def _file_link_error(err: LinkError) -> JSONResponse:
    body: dict[str, Any] = {"error": err.code}
    if err.code == "expired" and err.payload:
        try:
            body["expires_at"] = iso_utc(int(err.payload["exp"]))
        except (KeyError, TypeError, ValueError):
            pass
        name = err.payload.get("name")
        if name:
            body["name"] = name
    return JSONResponse(status_code=404, content=body)


def _open_file_link(token: str) -> tuple[dict[str, Any], Path, str]:
    payload = verify_file_link(token)
    try:
        root = share_path(str(payload["share"]))
        with use_share_root(root):
            file_path, name = open_for_download(
                str(payload["path"]),
                int(payload["uid"]),
                int(payload["gid"]),
            )
    except (FSError, TypeError, ValueError) as e:
        raise LinkError("unavailable", payload) from e
    return payload, file_path, name


@app.post("/api/file-link")
async def api_mint_file_link(request: Request) -> dict[str, Any]:
    """Mint a public, expiring download link for a single file the user can read."""
    user = _require_user(request)
    share = _active_share(request, user)
    try:
        body = await request.json()
    except Exception:
        body = {}
    rel = str((body or {}).get("path") or "").strip()
    if not rel:
        raise HTTPException(status_code=400, detail="path required")
    raw_days = (body or {}).get("days", DEFAULT_DAYS)
    try:
        days = int(raw_days)
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail="days must be 1–30") from e
    if days < MIN_DAYS or days > MAX_DAYS:
        raise HTTPException(status_code=400, detail="days must be 1–30")
    try:
        with use_share_root(share_path(share)):
            target = resolve_rel(rel)
            with as_user(int(user["uid"]), int(user["gid"])):
                if target.is_dir():
                    raise FSError("Folders can't be shared", 400)
            _file_path, name = open_for_download(rel, int(user["uid"]), int(user["gid"]))
    except FSError as e:
        raise _fs_http(e) from e
    token = mint_file_link(
        share=share,
        path=rel,
        days=days,
        uid=int(user["uid"]),
        gid=int(user["gid"]),
        name=name,
    )
    payload = verify_file_link(token)
    return {"url": file_link_public_url(token), "expires_at": iso_utc(payload["exp"])}


@app.get("/api/s/{token}", response_model=None)
def api_file_link_meta(token: str):
    try:
        payload, file_path, name = _open_file_link(token)
    except LinkError as e:
        return _file_link_error(e)
    stat = file_path.stat()
    kind = preview_kind(name)
    return {
        "name": name,
        "size": stat.st_size,
        "mtime": iso_utc(stat.st_mtime),
        "kind": kind,
        "previewable": kind is not None,
        "expires_at": iso_utc(payload["exp"]),
        "error": None,
    }


@app.get("/api/s/{token}/file", response_model=None)
def api_file_link_file(
    token: str,
    inline: bool = Query(False, description="Serve for in-browser preview when true"),
):
    try:
        _payload, file_path, name = _open_file_link(token)
    except LinkError as e:
        return _file_link_error(e)
    return _user_file_response(file_path, name, inline)


@app.get("/s/{token}")
def share_page(token: str) -> FileResponse:
    return FileResponse(STATIC / "share.html")


# ---------------------------------------------------------------------------
# Terminal sign-in for the `infocus` CLI (PKCE via a 127.0.0.1 callback)
# ---------------------------------------------------------------------------
_CLI_STATE_RE = re.compile(r"[A-Za-z0-9_-]{16,128}")
_CLI_PAGE_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; connect-src 'self'; img-src 'self' data:; "
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
        # The consent form posts to us, and we 303 it to the CLI's loopback listener.
        "form-action 'self' http://127.0.0.1:*; base-uri 'none'; frame-ancestors 'none'"
    ),
    "X-Frame-Options": "DENY",
    # The URL carries state/challenge: never send it cross-origin (the loopback
    # page is another origin). Not "no-referrer" — that makes form POSTs send
    # `Origin: null`, which check_origin rightly rejects.
    "Referrer-Policy": "same-origin",
}


def _cli_request_params(port: Any, state: Any, challenge: Any) -> tuple[int, str, str]:
    try:
        port_n = int(port)
    except (TypeError, ValueError):
        port_n = 0
    if not 1024 <= port_n <= 65535:
        raise HTTPException(status_code=400, detail="Invalid callback port")
    if not _CLI_STATE_RE.fullmatch(str(state or "")):
        raise HTTPException(status_code=400, detail="Invalid state")
    if not cli_tokens.valid_challenge(str(challenge or "")):
        raise HTTPException(status_code=400, detail="Invalid PKCE challenge")
    return port_n, str(state), str(challenge)


@app.get("/cli/authorize")
def cli_authorize_page() -> FileResponse:
    # Static page; it validates via /api/me and POST /api/cli/authorize.
    return FileResponse(STATIC / "cli-authorize.html", headers=_CLI_PAGE_HEADERS)


@app.post("/api/cli/authorize")
def api_cli_authorize(
    request: Request,
    port: str = Form(""),
    state: str = Form(""),
    challenge: str = Form(""),
    device: str = Form("", max_length=512),
    allow: str = Form(""),
) -> RedirectResponse:
    """Browser approves a terminal via a plain form POST.

    The one-time code only ever travels in this 303's Location header, which
    page script (even an XSS on the Drive origin) cannot read.
    """
    check_origin(request)
    user = _require_session_user(request)
    port_n, state, challenge = _cli_request_params(port, state, challenge)
    callback = f"http://127.0.0.1:{port_n}/callback"
    if allow != "1":
        return RedirectResponse(f"{callback}?{urlencode({'error': 'access_denied', 'state': state})}", status_code=303)
    try:
        code = cli_tokens.issue_code(str(user["username"]), str(user.get("email") or ""), device, challenge)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e)) from e
    return RedirectResponse(f"{callback}?{urlencode({'code': code, 'state': state})}", status_code=303)


# Codes are 256-bit and PKCE-bound, so this is abuse control, not brute-force
# defence: count failures only, so a class behind one campus IP can all sign in.
_CLI_TOKEN_WINDOW_S = 300.0
_CLI_TOKEN_MAX_FAILURES = 30
_cli_token_failures: dict[str, list[float]] = {}


def _cli_token_blocked(ip: str) -> bool:
    now = time.time()
    recent = [t for t in _cli_token_failures.get(ip, []) if now - t < _CLI_TOKEN_WINDOW_S]
    if recent:
        _cli_token_failures[ip] = recent
    else:
        _cli_token_failures.pop(ip, None)
    return len(recent) >= _CLI_TOKEN_MAX_FAILURES


@app.post("/api/cli/token")
async def api_cli_token(request: Request) -> dict[str, Any]:
    ip = request.client.host if request.client else "unknown"
    if _cli_token_blocked(ip):
        raise HTTPException(status_code=429, detail="Too many attempts. Try again in a few minutes.")
    try:
        body = await request.json()
    except Exception:
        body = None
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid request")
    issued = cli_tokens.redeem_code(str(body.get("code") or ""), str(body.get("verifier") or ""))
    if issued is None:
        _cli_token_failures.setdefault(ip, []).append(time.time())
        raise HTTPException(status_code=401, detail="Sign-in code is invalid or expired. Run `infocus login` again.")
    return {
        "token": issued["token"],
        "id": issued["id"],
        "username": issued["username"],
        "device": issued["device"],
        "idle_expiry_days": cli_tokens.IDLE_TTL_S // 86400,
    }


@app.get("/api/cli/sessions")
def api_cli_sessions(request: Request) -> dict[str, Any]:
    user = _require_user(request)
    current = user.get("cli_token_id")
    rows = cli_tokens.list_for(str(user["username"]))
    return {"sessions": [{**row, "current": row["id"] == current} for row in rows]}


@app.delete("/api/cli/sessions/{token_id}")
def api_cli_revoke(request: Request, token_id: str) -> dict[str, bool]:
    user = _require_user(request)
    if not cli_tokens.revoke(token_id, str(user["username"])):
        raise HTTPException(status_code=404, detail="Terminal sign-in not found")
    return {"ok": True}


@app.post("/api/cli/logout")
def api_cli_logout(request: Request) -> dict[str, bool]:
    token = _bearer_token(request)
    if not token or not cli_tokens.revoke_token(token):
        raise HTTPException(status_code=401, detail="Not signed in")
    return {"ok": True}


@app.get("/cli/install.sh")
def cli_install_script() -> Response:
    server = settings.public_base_url.rstrip("/")
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(:[0-9]+)?", server):
        raise HTTPException(status_code=503, detail="PUBLIC_BASE_URL must be an https origin")
    script = (STATIC / "cli" / "install.sh").read_text(encoding="utf-8")
    return Response(script.replace("__INFOCUS_SERVER__", server), media_type="text/x-shellscript")


@app.get("/{full_path:path}")
def spa_fallback(full_path: str) -> Response:
    # Don't swallow API/auth/public share pages
    if full_path.startswith(("api/", "auth/", "assets/", "s/")):
        raise HTTPException(status_code=404)
    return FileResponse(STATIC / "index.html")
