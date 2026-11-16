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
import weakref
from functools import lru_cache
from pathlib import Path
from typing import Any, AsyncIterator, Callable

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.concurrency import run_in_threadpool

import team_cleanup
import team_files
from chunk_upload import complete_session, create_session, get_session
from config import get_settings
from fsops import FSError
from team_store import TeamStore

router = APIRouter(prefix="/api/team")

KEEPALIVE_S = 15.0
# Request bodies: project data (create, PUT sequence, POST shared) may be as big as a
# project file; every other team route takes a small JSON object.
MAX_BODY_BYTES = 64 * 1024 * 1024
SMALL_BODY_BYTES = 64 * 1024
# Upserts and deletes in one `POST …/shared` (each list), far above one real edit.
MAX_SHARED_OPS = 10_000
# Open change feeds, per user and in all (uvicorn runs with --limit-concurrency 200).
MAX_STREAMS_PER_USER = 4
MAX_STREAMS = 60
# The newest FilmCraft project schema this server knows. A client can raise a project's
# schema up to here and no further; bump it with the InFocus Cut release that adds one.
MAX_SCHEMA_VERSION = 17
MAX_ID = (1 << 53) - 1
ID_SLOT_SHIFT = 40  # FilmCraft team ids: member slot << 40, plus a counter
SUBSCRIBER_QUEUE = 256
_PROJECT_ID = re.compile(r"^[0-9a-f]{32}$")
_VERSION = re.compile(r"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$")
DEVICE_HEADER = "X-Drive-Device"
MAX_DEVICE_LEN = 64
_BAD_DEVICE = re.compile(r"[\x00-\x1f\x7f]")

# Project-level keys of the FilmCraft `Project` JSON that `POST …/shared` takes in
# `fields`, with their JSON type. Not `items`/`root` (upserts and bins), `next_id`
# (ids come from each member's slot) or `name` (the project's folder name).
SHARED_FIELDS: dict[str, type] = {
    "settings": dict,
    "custom_colors": list,
    "custom_color_names": dict,
    "luts": list,
    "transcripts": dict,
    "search_bins": list,
    "source_graphics": dict,
    "narrations": dict,
    "notes": str,
}

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
_stream_counts: dict[str, int] = {}  # open streams per user, under `_subscribers_guard`


def _reserve_stream(username: str) -> bool:
    with _subscribers_guard:
        if (_stream_counts.get(username, 0) >= MAX_STREAMS_PER_USER
                or sum(_stream_counts.values()) >= MAX_STREAMS):
            return False
        _stream_counts[username] = _stream_counts.get(username, 0) + 1
        return True


def _release_stream(username: str) -> None:
    with _subscribers_guard:
        left = _stream_counts.get(username, 0) - 1
        if left > 0:
            _stream_counts[username] = left
        else:
            _stream_counts.pop(username, None)


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


def _conflict(code: str, message: str, **extra: Any) -> JSONResponse:
    """Every team 409: `error` is a stable code, `message` is for people, plus route fields."""
    return _error(409, {"error": code, "message": message, **extra})


_LOCK_LOST = "Your lock on this sequence expired or was released"


def _fs_error(e: FSError) -> JSONResponse:
    if e.status == 409:
        return _conflict(getattr(e, "code", "conflict"), str(e), detail=str(e))
    return _error(e.status, {"detail": str(e)})


async def _body(request: Request, limit: int | None = None) -> dict[str, Any]:
    """The JSON object body, refusing more than `limit` bytes (default `SMALL_BODY_BYTES`)."""
    limit = SMALL_BODY_BYTES if limit is None else limit
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
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


def _schema_unsupported() -> JSONResponse:
    return _error(400, {"error": "schema_unsupported",
                        "detail": "This Drive doesn't know that project schema yet; update the Drive",
                        "max_schema_version": MAX_SCHEMA_VERSION})


def _app_gate(meta: dict[str, Any], app_version: tuple[int, ...], schema: int) -> JSONResponse | None:
    """426 when the app is older than the project (its schema, or an operator-set minimum)."""
    meta_schema = int(meta.get("schema_version") or 0)
    min_app = str(meta.get("min_app_version") or "0")
    if schema < meta_schema or app_version < _version(min_app):
        return _error(426, {"error": "update InFocus Cut", "schema_version": meta_schema,
                            "min_app_version": min_app})
    return None


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


def _referenced_ids(value: Any, found: set[int], depth: int = 0) -> None:
    """Every id a sequence uses (a clip's `item`, or a `parent`), at any depth, into `found`."""
    if depth > 200:
        return
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("item", "parent") and isinstance(child, int) and not isinstance(child, bool):
                found.add(child)
            elif isinstance(child, (dict, list)):
                _referenced_ids(child, found, depth + 1)
    elif isinstance(value, list):
        for child in value:
            if isinstance(child, (dict, list)):
                _referenced_ids(child, found, depth + 1)


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


def _binned_ids(node: Any, found: set[int], depth: int = 0) -> None:
    """Item ids in a FilmCraft bin tree: `{"Item": id}` or `{"Bin": {id, name, children}}` entries."""
    children = node.get("children") if isinstance(node, dict) else None
    if depth > 200 or not isinstance(children, list):
        return
    for entry in children:
        if not isinstance(entry, dict):
            continue
        item = entry.get("Item")
        if isinstance(item, int) and not isinstance(item, bool):
            found.add(item)
        elif "Bin" in entry:
            _binned_ids(entry["Bin"], found, depth + 1)


def _file_unbinned_media(root: Any, items: dict[str, Any]) -> Any:
    """Root bin with every media item no bin lists appended to it.

    The bin tree is replaced whole (last writer wins), so a teammate's import
    would otherwise vanish from every bin when someone saves an older tree.
    """
    if not isinstance(root, dict) or not isinstance(root.get("children"), list):
        return root
    found: set[int] = set()
    _binned_ids(root, found)
    missing = sorted(
        int(key) for key, item in items.items()
        if key.isdigit() and int(key) not in found
        and isinstance(item, dict) and isinstance(item.get("kind"), dict) and "Media" in item["kind"]
    )
    if not missing:
        return root
    return {**root, "children": [*root["children"], *({"Item": item_id} for item_id in missing)]}


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
            # Follow a rename only: while the row's folder still holds this id (or we can't
            # tell), this folder is a copy, and the copy is left out instead of taking over.
            if team_files.folder_holds(user, info["folder"], project_id) is not False:
                continue
            st.set_folder(project_id, folder)
        out.append({
            "id": project_id,
            "name": str(meta.get("name") or ""),
            "folder": folder,
            "locks": _locks_json(project_id),
            "last_open": st.last_open(project_id),
            "cleanup": team_cleanup.cleanup_status(st, project_id),
        })
    return out


@router.post("/projects")
async def create_project(request: Request) -> Any:
    user = _user(request)
    body = await _body(request, MAX_BODY_BYTES)
    _version(body.get("app_version"))
    schema = _schema(body.get("schema_version"))
    if schema > MAX_SCHEMA_VERSION:
        return _schema_unsupported()
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
    st = store()
    try:
        # Files and revisions together, like `_read_part`, so no json carries a newer rev.
        with _project_lock(project_id):
            meta, shared, sequences = team_files.read_project(user, info["folder"])
            seq_revs = {seq: st.revision(project_id, f"seq:{seq}") for seq in sequences}
            shared_rev = st.revision(project_id, "shared")
    except FSError as e:
        return _fs_error(e)
    username = str(user["username"])
    st.record_open(project_id, username)
    return {
        "id": project_id,
        "name": str(meta.get("name") or info["name"]),
        "meta": meta,
        "shared": shared,
        "sequences": {str(seq): {"rev": seq_revs[seq], "json": item}
                      for seq, item in sorted(sequences.items())},
        "shared_rev": shared_rev,
        "locks": _locks_json(project_id),
        "slot": st.slot_for(project_id, username),
        "cleanup": team_cleanup.cleanup_status(st, project_id),
    }


def _read_part(user: dict[str, Any], info: dict[str, Any], key: str) -> tuple[dict, dict, dict, int]:
    """`read_project` plus one revision, under the project lock so the pair matches.

    Unlike `GET …/{id}` this records no open, so change-feed refetches don't
    reset the cleanup clock.
    """
    with _project_lock(info["id"]):
        meta, shared, sequences = team_files.read_project(user, info["folder"])
        return meta, shared, sequences, store().revision(info["id"], key)


def _cached(request: Request, rev: int, file_hash: Any, body: dict[str, Any]) -> Any:
    """`body` with an ETag of rev + file hash, or 304 when `If-None-Match` has it."""
    etag = f'"{rev}-{str(file_hash or "")[:16]}"'
    if etag in [t.strip() for t in (request.headers.get("If-None-Match") or "").split(",")]:
        return Response(status_code=304, headers={"ETag": etag})
    return JSONResponse(body, headers={"ETag": etag})


@router.get("/projects/{project_id}/sequences/{seq}")
def get_sequence(request: Request, project_id: str, seq: int) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    _seq_or_404(seq)
    try:
        meta, _shared, sequences, rev = _read_part(user, info, f"seq:{seq}")
    except FSError as e:
        return _fs_error(e)
    if seq not in sequences:
        raise HTTPException(status_code=404, detail="Sequence not found")
    file_hash = (meta.get("file_hashes") or {}).get(f"{team_files.SEQUENCES_DIR}/{seq}.json")
    return _cached(request, rev, file_hash, {"seq": seq, "rev": rev, "json": sequences[seq]})


@router.get("/projects/{project_id}/shared")
def get_shared(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        meta, shared, _sequences, rev = _read_part(user, info, "shared")
    except FSError as e:
        return _fs_error(e)
    file_hash = (meta.get("file_hashes") or {}).get(team_files.PROJECT_FILE)
    return _cached(request, rev, file_hash, {"rev": rev, "shared": shared})


@router.post("/projects/{project_id}/sequences/{seq}/lock")
def take_lock(request: Request, project_id: str, seq: int) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    _seq_or_404(seq)
    try:
        meta = _check_access(user, info)
    except FSError as e:
        return _fs_error(e)
    device = _device(request)
    username = str(user["username"])
    st = store()
    known = (f"{team_files.SEQUENCES_DIR}/{seq}.json" in (meta.get("file_hashes") or {})
             or st.revision(project_id, f"seq:{seq}") > 0)  # saved now, or once (deleted, then undone)
    # Any other id can only be a new sequence from the caller's own id slot.
    if not known and seq >> ID_SLOT_SHIFT != st.slot_for(project_id, username):
        raise HTTPException(status_code=404, detail="Sequence not found")
    with _project_lock(project_id):  # cleanup checks locks under this lock before a move
        got = st.take_lock(project_id, seq, username, device)
    if not got.ok:
        # `device` only for your own other Mac; a teammate's device name stays private.
        return _conflict("lock_held", f"{got.holder} is editing this sequence", holder=got.holder,
                         expires_at=got.expires_at, device=got.device if got.holder == username else None)
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
        return _conflict("lock_lost", _LOCK_LOST)
    held = st.locks(project_id).get(seq)
    return {"expires_at": held[1] if held else 0.0}


@router.delete("/projects/{project_id}/sequences/{seq}/lock")
async def release_lock(request: Request, project_id: str, seq: int) -> Any:
    _user(request)
    _project_or_404(project_id)
    _seq_or_404(seq)
    body = await _body(request)
    if not await run_in_threadpool(store().release, project_id, seq, str(body.get("token") or "")):
        return _conflict("lock_lost", _LOCK_LOST)
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
    if schema > MAX_SCHEMA_VERSION:
        return _schema_unsupported()
    st = store()
    username = str(user["username"])
    with _project_lock(project_id):
        meta = team_files.read_meta(user, info["folder"])
        meta_schema = int(meta.get("schema_version") or 0)
        refused = _app_gate(meta, app_version, schema)
        if refused is not None:
            return refused
        if not st.check_lock(project_id, seq, str(body.get("token") or "")):
            return _conflict("lock_lost", _LOCK_LOST)
        current = st.revision(project_id, f"seq:{seq}")
        if base != current:
            return _conflict("stale", "This sequence changed since you loaded it", rev=current)
        # A newer schema raises the bar: older apps (older schema) could drop its new fields.
        # Clients never raise `min_app_version`; only an operator sets it in meta.json.
        updates = {"schema_version": schema} if schema > meta_schema else None
        team_files.write_sequence(user, info["folder"], seq, item, updates)
        rev = st.bump_revision(project_id, f"seq:{seq}", base)
    publish(project_id, "sequence_updated", {"seq": seq, "rev": rev, "by": username})
    return {"rev": rev}


@router.put("/projects/{project_id}/sequences/{seq}")
async def put_sequence(request: Request, project_id: str, seq: int) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    _seq_or_404(seq)
    body = await _body(request, MAX_BODY_BYTES)
    try:
        return await run_in_threadpool(_put_sequence, user, info, seq, body)
    except FSError as e:
        return _fs_error(e)


def _delete_sequence(user: dict[str, Any], info: dict[str, Any], seq: int, body: dict[str, Any]) -> JSONResponse | dict:
    project_id = info["id"]
    base = body.get("base_rev")
    if isinstance(base, bool) or not isinstance(base, int) or base < 0:
        raise HTTPException(status_code=400, detail="base_rev must be a number")
    token = str(body.get("token") or "")
    st = store()
    username = str(user["username"])
    with _project_lock(project_id):
        _meta, _shared, sequences = team_files.read_project(user, info["folder"])
        if not st.check_lock(project_id, seq, token):
            return _conflict("lock_lost", _LOCK_LOST)
        current = st.revision(project_id, f"seq:{seq}")
        if base != current:
            return _conflict("stale", "This sequence changed since you loaded it", rev=current)
        if seq not in sequences:
            raise HTTPException(status_code=404, detail="Sequence not found")
        if any(_references(other, seq) for other_id, other in sequences.items() if other_id != seq):
            return _conflict("item_in_use", "sequence is used by another sequence", item=seq)
        team_files.delete_sequence(user, info["folder"], seq)
        rev = st.bump_revision(project_id, f"seq:{seq}", base)
        st.release(project_id, seq, token)
    publish(project_id, "sequence_deleted", {"seq": seq, "rev": rev, "by": username})
    publish(project_id, "lock_changed", {"seq": seq, "holder": None})
    return {"rev": rev}


@router.delete("/projects/{project_id}/sequences/{seq}")
async def delete_sequence(request: Request, project_id: str, seq: int) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    _seq_or_404(seq)
    body = await _body(request)
    try:
        return await run_in_threadpool(_delete_sequence, user, info, seq, body)
    except FSError as e:
        return _fs_error(e)


def _shared_fields(value: Any) -> dict[str, Any]:
    """`fields` of a shared post: allowlisted project-level keys, each replaced whole."""
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise HTTPException(status_code=400, detail="fields must be an object")
    for key, field in value.items():
        kind = SHARED_FIELDS.get(key)
        if kind is None:
            raise HTTPException(status_code=400, detail=f"fields.{key} is not a shared project field")
        if not isinstance(field, kind):
            raise HTTPException(status_code=400, detail=f"fields.{key} must be a JSON {kind.__name__}")
    return dict(value)


def _post_shared(user: dict[str, Any], info: dict[str, Any], body: dict[str, Any]) -> JSONResponse | dict:
    project_id = info["id"]
    app_version = _version(body.get("app_version"))
    schema = _schema(body.get("schema_version"))
    if schema > MAX_SCHEMA_VERSION:
        return _schema_unsupported()
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
    if len(upserts) > MAX_SHARED_OPS or len(deletes) > MAX_SHARED_OPS:
        raise HTTPException(status_code=413, detail=f"At most {MAX_SHARED_OPS} upserts and {MAX_SHARED_OPS} deletes per change")
    clean: dict[str, Any] = {}
    for key, item in upserts.items():
        item_id = _item_id(key)
        if not isinstance(item, dict) or item.get("id") != item_id:
            raise HTTPException(status_code=400, detail=f"Item {key} does not match its id")
        if _is_sequence(item):
            raise HTTPException(status_code=400, detail="Sequences are saved with PUT …/sequences/{id}")
        clean[str(item_id)] = item
    delete_ids = [_item_id(d) for d in deletes]
    fields = _shared_fields(body.get("fields"))
    st = store()
    with _project_lock(project_id):
        meta, shared, sequences = team_files.read_project(user, info["folder"])
        refused = _app_gate(meta, app_version, schema)
        if refused is not None:
            return refused
        current = st.revision(project_id, "shared")
        if bins is not None and base != current:
            # Upserts and deletes merge by id; the bin tree is replaced whole, so it needs the latest base.
            return _conflict("stale", "The bins changed since you loaded them", rev=current)
        if delete_ids:
            used: set[int] = set()
            for seq_json in sequences.values():
                _referenced_ids(seq_json, used)
            for item_id in delete_ids:
                if item_id in used:
                    return _conflict("item_in_use", "item is used by a sequence", item=item_id)
        items = {**(shared.get("items") or {}), **clean}
        for item_id in delete_ids:
            items.pop(str(item_id), None)
        updated = {**shared, **fields, "items": items}
        if bins is not None:
            updated["root"] = bins
        if "root" in updated:
            updated["root"] = _file_unbinned_media(updated["root"], items)
        team_files.write_shared(user, info["folder"], updated)
        rev = st.bump_revision(project_id, "shared", None)
    publish(project_id, "shared_updated", {"rev": rev, "fields": sorted(fields)} if fields else {"rev": rev})
    return {"rev": rev}


@router.post("/projects/{project_id}/shared")
async def post_shared(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    body = await _body(request, MAX_BODY_BYTES)
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
    with _project_lock(marked):  # cleanup checks exports under this lock before a move
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
    username = str(user["username"])
    if not _reserve_stream(username):
        return _error(429, {"error": "too_many_streams",
                            "detail": "Too many open change feeds; close another InFocus Cut window"})
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
            done()

    def unsubscribe() -> None:
        with _subscribers_guard:
            subs = _subscribers.get(project_id)
            if subs is not None:
                subs.discard(entry)
                if not subs:
                    _subscribers.pop(project_id, None)
        _release_stream(username)

    body = stream()
    # Runs once: when the stream ends, or when a stream that never started is collected.
    done = weakref.finalize(body, unsubscribe)
    return StreamingResponse(
        body,
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
