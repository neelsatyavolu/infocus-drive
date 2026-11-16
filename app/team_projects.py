"""InFocus Cut team projects API: locks, sequence pushes, shared merges, change feed.

Auth is the same as every other `/api/*` route (bearer `ifd_` token or the
session cookie): `main` binds its `_require_user` and `is_nas_admin` here with
`bind()`, which avoids importing `main` from a router.

File IO goes through `team_files` (as the member, short `as_user` sections).
Locks and revisions live in `team_store` (SQLite), and the event feed is an
in-process queue per subscriber, so none of those run under `as_user`.
"""

from __future__ import annotations

import asyncio
import json
import re
import threading
import time
import uuid
from functools import lru_cache
from pathlib import Path
from typing import Any, AsyncIterator, Callable

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.concurrency import run_in_threadpool

import team_cleanup
import team_files
from chunk_upload import complete_session, create_session, get_session
from config import get_settings
from fsops import FSError
from team_store import TeamStore

router = APIRouter(prefix="/api/team")

KEEPALIVE_S = 15.0
MAX_BODY_BYTES = 64 * 1024 * 1024
MAX_ID = (1 << 53) - 1
SUBSCRIBER_QUEUE = 256
_PROJECT_ID = re.compile(r"^[0-9a-f]{32}$")
_VERSION = re.compile(r"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$")
DEVICE_HEADER = "X-Drive-Device"
MAX_DEVICE_LEN = 64
_BAD_DEVICE = re.compile(r"[\x00-\x1f\x7f]")

_hooks: dict[str, Callable[..., Any]] = {}


def bind(
    *,
    require_user: Callable[[Request], dict[str, Any]],
    is_admin: Callable[[str], bool],
    file_response: Callable[[Any], Any],
) -> None:
    _hooks["require_user"] = require_user
    _hooks["is_admin"] = is_admin
    _hooks["file_response"] = file_response  # main's download response (Range, If-Range, ETag, sandbox CSP)


def _user(request: Request) -> dict[str, Any]:
    return _hooks["require_user"](request)


def _is_admin(user: dict[str, Any]) -> bool:
    return bool(_hooks["is_admin"](str(user.get("username") or "")))


@lru_cache(maxsize=4)
def _store_at(path: str, ttl: int) -> TeamStore:
    return TeamStore(Path(path), lock_ttl_s=ttl)


def store() -> TeamStore:
    s = get_settings()
    return _store_at(s.team_db_path, int(s.team_lock_ttl_s))


# Writes to one project's files are serialized here (single server process).
_project_locks: dict[str, threading.Lock] = {}
_project_locks_guard = threading.Lock()


def _project_lock(project_id: str) -> threading.Lock:
    with _project_locks_guard:
        return _project_locks.setdefault(project_id, threading.Lock())


# Change feed -----------------------------------------------------------------

_subscribers: dict[str, set[tuple[asyncio.AbstractEventLoop, asyncio.Queue]]] = {}
_subscribers_guard = threading.Lock()


def _offer(queue: asyncio.Queue, message: str) -> None:
    try:
        queue.put_nowait(message)
    except asyncio.QueueFull:
        pass  # a stuck reader misses events; its 5 s poll fallback catches up


def publish(project_id: str, event: str, data: dict[str, Any]) -> None:
    """Send an event to every open stream of the project. Safe from any thread."""
    message = f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"
    with _subscribers_guard:
        targets = list(_subscribers.get(project_id, ()))
    for loop, queue in targets:
        try:
            loop.call_soon_threadsafe(_offer, queue, message)
        except RuntimeError:
            pass  # loop closed


# Helpers ------------------------------------------------------------------


def _error(status: int, body: dict[str, Any]) -> JSONResponse:
    return JSONResponse(status_code=status, content=body)


def _fs_error(e: FSError) -> JSONResponse:
    if isinstance(e, team_files.FilesChanged):
        return _error(409, {"error": str(e)})
    return _error(e.status, {"detail": str(e)})


async def _body(request: Request) -> dict[str, Any]:
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > MAX_BODY_BYTES:
            raise HTTPException(status_code=413, detail="Request body too large")
        chunks.append(chunk)
    raw = b"".join(chunks)
    if not raw:
        return {}
    try:
        body = json.loads(raw)
    except ValueError as e:
        raise HTTPException(status_code=400, detail="Body must be JSON") from e
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Body must be a JSON object")
    return body


def _project_or_404(project_id: str) -> dict[str, Any]:
    info = store().project(project_id) if _PROJECT_ID.match(project_id or "") else None
    if info is None:
        raise HTTPException(status_code=404, detail="Team project not found")
    return info


def _seq_or_404(seq: int) -> int:
    if not 1 <= seq <= MAX_ID:
        raise HTTPException(status_code=404, detail="Sequence not found")
    return seq


def _version(value: Any) -> tuple[int, ...]:
    if not isinstance(value, str) or not _VERSION.match(value):
        raise HTTPException(status_code=400, detail="app_version must look like 1.2.3")
    parts = tuple(int(p) for p in value.split("."))
    return parts + (0,) * (4 - len(parts))


def _schema(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 1_000_000:
        raise HTTPException(status_code=400, detail="schema_version must be a number")
    return value


def _device(request: Request) -> str:
    """The Mac taking a lock (`X-Drive-Device`); a missing header counts as one more device."""
    value = (request.headers.get(DEVICE_HEADER) or "").strip()
    if len(value) > MAX_DEVICE_LEN or _BAD_DEVICE.search(value):
        raise HTTPException(status_code=400, detail=f"{DEVICE_HEADER} must be a short device name")
    return value


def _is_sequence(item: Any) -> bool:
    kind = item.get("kind") if isinstance(item, dict) else None
    return isinstance(kind, dict) and "Sequence" in kind


def _item_id(key: Any) -> int:
    try:
        value = int(key)
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail="Item ids must be numbers") from e
    if isinstance(key, bool) or not 1 <= value <= MAX_ID:
        raise HTTPException(status_code=400, detail="Item id out of range")
    return value


def _references(value: Any, item_id: int, depth: int = 0) -> bool:
    """True if a sequence uses `item_id` (a clip's `item`, or a `parent`), at any depth."""
    if depth > 200:
        return False
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("item", "parent") and child == item_id and not isinstance(child, bool):
                return True
            if isinstance(child, (dict, list)) and _references(child, item_id, depth + 1):
                return True
    elif isinstance(value, list):
        return any(_references(child, item_id, depth + 1) for child in value if isinstance(child, (dict, list)))
    return False


def _locks_json(project_id: str) -> dict[str, dict[str, Any]]:
    return {str(seq): {"holder": holder, "expires_at": expires}
            for seq, (holder, expires) in sorted(store().locks(project_id).items())}


def _check_access(user: dict[str, Any], info: dict[str, Any]) -> dict[str, Any]:
    return team_files.read_meta(user, info["folder"])


# Routes --------------------------------------------------------------------


@router.get("/projects")
def list_projects(request: Request) -> list[dict[str, Any]]:
    user = _user(request)
    st = store()
    out = []
    for folder, meta in team_files.list_projects(user):
        project_id = str(meta.get("id") or "")
        if not _PROJECT_ID.match(project_id):
            continue
        info = st.project(project_id)
        if info is None:
            st.create_project(folder, str(meta.get("name") or Path(folder).stem),
                              str(meta.get("created_by") or ""), project_id=project_id)
        elif info["folder"] != folder:
            st.set_folder(project_id, folder)  # renamed on the Drive; the id in meta.json is the anchor
        out.append({
            "id": project_id,
            "name": str(meta.get("name") or ""),
            "folder": folder,
            "locks": _locks_json(project_id),
            "last_open": st.last_open(project_id),
        })
    return out


@router.post("/projects")
async def create_project(request: Request) -> Any:
    user = _user(request)
    body = await _body(request)
    _version(body.get("app_version"))
    schema = _schema(body.get("schema_version"))
    try:
        name = team_files.valid_name(body.get("name"))
    except FSError as e:
        return _fs_error(e)
    project = body.get("project")
    if project is None:
        project = {"name": name, "items": {}}
    if not isinstance(project, dict) or not isinstance(project.get("items", {}), dict):
        raise HTTPException(status_code=400, detail="project must be a FilmCraft project object")
    sequences: dict[int, dict[str, Any]] = {}
    shared_items: dict[str, Any] = {}
    for key, item in project.get("items", {}).items():
        item_id = _item_id(key)
        if not isinstance(item, dict) or item.get("id") != item_id:
            raise HTTPException(status_code=400, detail=f"Item {key} does not match its id")
        if _is_sequence(item):
            sequences[item_id] = item
        else:
            shared_items[str(item_id)] = item
    shared = {**project, "items": shared_items}
    project_id = uuid.uuid4().hex
    username = str(user["username"])
    meta = {
        "id": project_id,
        "name": name,
        "schema_version": schema,
        "min_app_version": "0",
        "created_by": username,
    }

    def work() -> dict[str, Any]:
        folder = team_files.create_project(user, name, meta, shared, sequences)
        st = store()
        st.create_project(folder, name, username, project_id=project_id)
        return {"id": project_id, "slot": st.slot_for(project_id, username)}

    try:
        return await run_in_threadpool(work)
    except FSError as e:
        return _fs_error(e)


@router.get("/projects/{project_id}")
def get_project(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        meta, shared, sequences = team_files.read_project(user, info["folder"])
    except FSError as e:
        return _fs_error(e)
    st = store()
    username = str(user["username"])
    st.record_open(project_id, username)
    return {
        "id": project_id,
        "name": str(meta.get("name") or info["name"]),
        "meta": meta,
        "shared": shared,
        "sequences": {str(seq): {"rev": st.revision(project_id, f"seq:{seq}"), "json": item}
                      for seq, item in sorted(sequences.items())},
        "shared_rev": st.revision(project_id, "shared"),
        "locks": _locks_json(project_id),
        "slot": st.slot_for(project_id, username),
    }


@router.post("/projects/{project_id}/sequences/{seq}/lock")
def take_lock(request: Request, project_id: str, seq: int) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    _seq_or_404(seq)
    try:
        _check_access(user, info)
    except FSError as e:
        return _fs_error(e)
    device = _device(request)
    username = str(user["username"])
    got = store().take_lock(project_id, seq, username, device)
    if not got.ok:
        # `device` only for your own other Mac; a teammate's device name stays private.
        return _error(409, {"holder": got.holder, "expires_at": got.expires_at,
                            "device": got.device if got.holder == username else None})
    publish(project_id, "lock_changed", {"seq": seq, "holder": got.holder})
    return {"token": got.token, "expires_at": got.expires_at}


@router.post("/projects/{project_id}/sequences/{seq}/lock/heartbeat")
async def heartbeat(request: Request, project_id: str, seq: int) -> Any:
    _user(request)
    _project_or_404(project_id)
    _seq_or_404(seq)
    body = await _body(request)
    st = store()
    if not await run_in_threadpool(st.heartbeat, project_id, seq, str(body.get("token") or "")):
        return _error(409, {"error": "lock lost"})
    held = st.locks(project_id).get(seq)
    return {"expires_at": held[1] if held else 0.0}


@router.delete("/projects/{project_id}/sequences/{seq}/lock")
async def release_lock(request: Request, project_id: str, seq: int) -> Any:
    _user(request)
    _project_or_404(project_id)
    _seq_or_404(seq)
    body = await _body(request)
    if not await run_in_threadpool(store().release, project_id, seq, str(body.get("token") or "")):
        return _error(409, {"error": "lock lost"})
    publish(project_id, "lock_changed", {"seq": seq, "holder": None})
    return {"ok": True}


@router.post("/projects/{project_id}/sequences/{seq}/lock/force")
def force_release(request: Request, project_id: str, seq: int) -> Any:
    user = _user(request)
    _project_or_404(project_id)
    _seq_or_404(seq)
    if not _is_admin(user):
        raise HTTPException(status_code=403, detail="Only Drive admins can force-release a lock")
    store().force_release(project_id, seq)
    publish(project_id, "lock_changed", {"seq": seq, "holder": None})
    return {"ok": True}


def _put_sequence(user: dict[str, Any], info: dict[str, Any], seq: int, body: dict[str, Any]) -> JSONResponse | dict:
    project_id = info["id"]
    app_version = _version(body.get("app_version"))
    schema = _schema(body.get("schema_version"))
    base = body.get("base_rev")
    if isinstance(base, bool) or not isinstance(base, int) or base < 0:
        raise HTTPException(status_code=400, detail="base_rev must be a number")
    item = body.get("json")
    if not isinstance(item, dict) or not _is_sequence(item) or item.get("id") != seq:
        raise HTTPException(status_code=400, detail="json must be the sequence item with this id")
    st = store()
    username = str(user["username"])
    with _project_lock(project_id):
        meta = team_files.read_meta(user, info["folder"])
        meta_schema = int(meta.get("schema_version") or 0)
        min_app = str(meta.get("min_app_version") or "0")
        if schema < meta_schema or app_version < _version(min_app):
            return _error(426, {"error": "update InFocus Cut", "schema_version": meta_schema,
                                "min_app_version": min_app})
        if not st.check_lock(project_id, seq, str(body.get("token") or "")):
            return _error(409, {"error": "lock lost"})
        current = st.revision(project_id, f"seq:{seq}")
        if base != current:
            return _error(409, {"error": "stale", "rev": current})
        # A newer schema raises the bar: older apps could drop its new fields.
        updates = ({"schema_version": schema, "min_app_version": body["app_version"]}
                   if schema > meta_schema else None)
        team_files.write_sequence(user, info["folder"], seq, item, updates)
        rev = st.bump_revision(project_id, f"seq:{seq}", base)
    publish(project_id, "sequence_updated", {"seq": seq, "rev": rev, "by": username})
    return {"rev": rev}


@router.put("/projects/{project_id}/sequences/{seq}")
async def put_sequence(request: Request, project_id: str, seq: int) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    _seq_or_404(seq)
    body = await _body(request)
    try:
        return await run_in_threadpool(_put_sequence, user, info, seq, body)
    except FSError as e:
        return _fs_error(e)


def _post_shared(user: dict[str, Any], info: dict[str, Any], body: dict[str, Any]) -> JSONResponse | dict:
    project_id = info["id"]
    base = body.get("base_rev")
    if isinstance(base, bool) or not isinstance(base, int) or base < 0:
        raise HTTPException(status_code=400, detail="base_rev must be a number")
    upserts = body.get("upserts") or {}
    deletes = body.get("deletes") or []
    bins = body.get("bins")
    if not isinstance(upserts, dict) or not isinstance(deletes, list):
        raise HTTPException(status_code=400, detail="upserts must be an object and deletes a list")
    if bins is not None and not isinstance(bins, dict):
        raise HTTPException(status_code=400, detail="bins must be the root bin object")
    clean: dict[str, Any] = {}
    for key, item in upserts.items():
        item_id = _item_id(key)
        if not isinstance(item, dict) or item.get("id") != item_id:
            raise HTTPException(status_code=400, detail=f"Item {key} does not match its id")
        if _is_sequence(item):
            raise HTTPException(status_code=400, detail="Sequences are saved with PUT …/sequences/{id}")
        clean[str(item_id)] = item
    delete_ids = [_item_id(d) for d in deletes]
    st = store()
    with _project_lock(project_id):
        _meta, shared, sequences = team_files.read_project(user, info["folder"])
        current = st.revision(project_id, "shared")
        if bins is not None and base != current:
            # Upserts and deletes merge by id; the bin tree is replaced whole, so it needs the latest base.
            return _error(409, {"error": "stale", "rev": current})
        for item_id in delete_ids:
            if any(_references(seq_json, item_id) for seq_json in sequences.values()):
                return _error(409, {"error": "item is used by a sequence", "item": item_id})
        items = {**(shared.get("items") or {}), **clean}
        for item_id in delete_ids:
            items.pop(str(item_id), None)
        updated = {**shared, "items": items}
        if bins is not None:
            updated["root"] = bins
        team_files.write_shared(user, info["folder"], updated)
        rev = st.bump_revision(project_id, "shared", None)
    publish(project_id, "shared_updated", {"rev": rev})
    return {"rev": rev}


@router.post("/projects/{project_id}/shared")
async def post_shared(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    body = await _body(request)
    try:
        return await run_in_threadpool(_post_shared, user, info, body)
    except FSError as e:
        return _fs_error(e)


@router.post("/projects/{project_id}/keep")
async def keep(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    body = await _body(request)
    value = body.get("keep")
    if not isinstance(value, bool):
        raise HTTPException(status_code=400, detail="keep must be true or false")
    if str(user["username"]) != info["creator"] and not _is_admin(user):
        raise HTTPException(status_code=403, detail="Only the project's creator or a Drive admin can change Keep")
    try:
        await run_in_threadpool(_check_access, user, info)
    except FSError as e:
        return _fs_error(e)
    store().set_keep(project_id, value)
    return {"keep": value}


@router.post("/projects/{project_id}/open")
def open_project(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        _check_access(user, info)
    except FSError as e:
        return _fs_error(e)
    st = store()
    st.record_open(project_id, str(user["username"]))
    return {"ok": True, "last_open": st.last_open(project_id)}


# Media ------------------------------------------------------------------------
# Originals live in `Team Projects/<name> Media/` under the drive root. These
# routes never use the member's active share, unlike `/api/download` and
# `/api/upload/*`. Uploads reuse the chunked sessions: init and complete here,
# chunks, status and abort through the normal `/api/upload/*` routes.


def _upload_share(project_id: str) -> str:
    """Marks a session as a team upload. Not a valid share id, so `/api/upload/complete` refuses it."""
    return f"@team:{project_id}"


@router.get("/projects/{project_id}/media")
def media_download(request: Request, project_id: str, path: str = "") -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        _check_access(user, info)
        opened = team_files.open_media(user, info["folder"], path)
    except FSError as e:
        return _fs_error(e)
    return _hooks["file_response"](opened)


def _int_field(body: dict[str, Any], key: str, *, required: bool) -> int | None:
    value = body.get(key)
    if value is None and not required:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise HTTPException(status_code=400, detail=f"{key} must be a number")
    return value


@router.post("/projects/{project_id}/media/upload/init")
async def media_upload_init(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    body = await _body(request)
    size = _int_field(body, "size", required=True)
    chunk_size = _int_field(body, "chunk_size", required=False)
    rel_dir = body.get("path") or ""
    if not isinstance(rel_dir, str):
        raise HTTPException(status_code=400, detail="path must be a string")

    def work() -> dict[str, Any]:
        _check_access(user, info)
        name = team_files.valid_media_name(body.get("name"))
        dest, dest_rel = team_files.media_upload_dir(user, info["folder"], rel_dir)
        return create_session(
            username=str(user["username"]),
            uid=int(user["uid"]),
            gid=int(user["gid"]),
            share=_upload_share(project_id),
            rel_dir=dest_rel,
            filename=name,
            size=int(size or 0),
            chunk_size=chunk_size,
            dest_dir=dest,
        )

    try:
        return await run_in_threadpool(work)
    except FSError as e:
        return _fs_error(e)


@router.post("/projects/{project_id}/media/upload/complete")
async def media_upload_complete(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    body = await _body(request)
    upload_id = body.get("upload_id")
    if not isinstance(upload_id, str):
        raise HTTPException(status_code=400, detail="upload_id is required")
    expect_mtime_ns = body.get("expect_mtime_ns")
    if expect_mtime_ns is not None and (isinstance(expect_mtime_ns, bool) or not isinstance(expect_mtime_ns, int)):
        raise HTTPException(status_code=400, detail="expect_mtime_ns must be a number")
    username, uid = str(user["username"]), int(user["uid"])

    def work() -> dict[str, Any]:
        _check_access(user, info)
        meta = get_session(upload_id, username=username, uid=uid)
        if meta.get("share") != _upload_share(project_id):
            raise FSError("This upload is not for this team project", 400)
        return complete_session(upload_id, username=username, uid=uid, expect_mtime_ns=expect_mtime_ns)

    try:
        return await run_in_threadpool(work)
    except FSError as e:
        return _fs_error(e)


def _export_mark(request: Request, project_id: str) -> str | JSONResponse:
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        _check_access(user, info)
    except FSError as e:
        return _fs_error(e)
    return info["id"]


@router.post("/exports/{project_id}/begin")
def begin_export(request: Request, project_id: str) -> Any:
    """The app is exporting from this project: daily cleanup leaves it alone (lapses after 6 h)."""
    marked = _export_mark(request, project_id)
    if isinstance(marked, JSONResponse):
        return marked
    team_cleanup.begin_export(marked, time.time())
    return {"ok": True}


@router.post("/exports/{project_id}/end")
def end_export(request: Request, project_id: str) -> Any:
    marked = _export_mark(request, project_id)
    if isinstance(marked, JSONResponse):
        return marked
    team_cleanup.end_export(marked)
    return {"ok": True}


@router.get("/projects/{project_id}/events")
async def events(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        await run_in_threadpool(_check_access, user, info)
    except FSError as e:
        return _fs_error(e)
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue(maxsize=SUBSCRIBER_QUEUE)
    entry = (loop, queue)
    with _subscribers_guard:
        _subscribers.setdefault(project_id, set()).add(entry)

    async def stream() -> AsyncIterator[str]:
        try:
            yield ": subscribed\n\n"
            while True:
                try:
                    yield await asyncio.wait_for(queue.get(), timeout=KEEPALIVE_S)
                except asyncio.TimeoutError:
                    if await request.is_disconnected():
                        return
                    yield ": keepalive\n\n"
        finally:
            with _subscribers_guard:
                subs = _subscribers.get(project_id)
                if subs is not None:
                    subs.discard(entry)
                    if not subs:
                        _subscribers.pop(project_id, None)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
