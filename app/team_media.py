"""Team project footage: the `Team Projects/<name> Media/` folder of each project.

Originals live under the drive root, never the member's active share (unlike
`/api/download` and `/api/upload/*`). Uploads reuse the chunked sessions: init and
complete here, chunks, status and abort through the normal `/api/upload/*` routes.

Any member can add footage, from InFocus Cut, the editing dashboard or the Drive
website. Every change bumps the project's `media` revision and sends a
`media_changed` event on the change feed, so the other Macs fetch new originals
without waiting for a poll.
"""

from __future__ import annotations

import logging
import pwd
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from starlette.concurrency import run_in_threadpool

import team_access
import team_files
import team_people
from chunk_upload import complete_session, create_session, get_session
from config import TEAM_ROOT_REL, get_settings
from fsops import FSError
from team_projects import (
    MEDIA_REV,
    _body,
    _check_access,
    _fs_error,
    _hooks,
    _project_or_404,
    _user,
    publish,
    store,
)

router = APIRouter(prefix="/api/team")
log = logging.getLogger(__name__)

# Reads per send while streaming an original: 1 MiB instead of Starlette's 64 KiB means
# 16x fewer thread hops per GB on the LAN path, and still small next to a 32 MiB upload chunk.
MEDIA_READ_CHUNK = 1024 * 1024


def media_rev(project_id: str) -> int:
    return store().revision(project_id, MEDIA_REV)


def media_changed(project_id: str, path: str, by: str) -> int:
    """Bump the footage revision and tell every open change feed of the project."""
    rev = int(store().bump_revision(project_id, MEDIA_REV, None) or 0)
    publish(project_id, "media_changed", {"rev": rev, "path": path, "by": by})
    return rev


def web_change_target(share_root: Path, rel: str) -> tuple[str, str] | None:
    """(project folder, path inside the media folder) when a website path is footage.

    Only the drive-root share holds `Team Projects/`; the same path on another share
    is some other folder.
    """
    try:
        if Path(share_root).resolve() != Path(get_settings().drive_root).resolve():
            return None
    except OSError:
        return None
    parts = [p for p in (rel or "").split("/") if p]
    if len(parts) < 2 or parts[0] != TEAM_ROOT_REL or not parts[1].endswith(team_files.MEDIA_SUFFIX):
        return None
    base = parts[1][: -len(team_files.MEDIA_SUFFIX)]
    if not base:
        return None
    return f"{TEAM_ROOT_REL}/{base}{team_files.FCTEAM_SUFFIX}", "/".join(parts[2:])


def note_web_change(share_root: Path, rels: list[str], username: str) -> None:
    """After a website upload, delete, move or rename: a `media_changed` per touched project.

    Best effort: a failure here never fails the file operation that already happened.
    """
    try:
        seen: set[str] = set()
        for rel in rels:
            target = web_change_target(share_root, rel)
            if target is None:
                continue
            project_id = store().project_for_folder(target[0])
            if project_id and project_id not in seen:
                seen.add(project_id)
                media_changed(project_id, target[1], username)
    except Exception:  # noqa: BLE001 - the file change already happened
        log.warning("team media: could not announce a website change by %s", username)


def _upload_share(project_id: str) -> str:
    """Marks a session as a team upload. Not a valid share id, so `/api/upload/complete` refuses it."""
    return f"@team:{project_id}"


# Routes ---------------------------------------------------------------------------------


def owner_name(uid: int) -> str:
    """The NAS account that owns a file (uploads are written as the member), or ""."""
    try:
        return pwd.getpwuid(uid).pw_name
    except (KeyError, OverflowError):
        return ""


def _with_added_by(user: dict[str, Any], folder: str, files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The footage list as sent: each file gets `by` (a display name) when a teammate's
    account owns it, so members see who added what. The uid itself never leaves."""
    try:
        meta = team_files.read_meta(user, folder)
    except (FSError, OSError, ValueError, team_files.TeamConflict):
        meta = None
    names = team_people.directory() if files and meta is not None else {}
    team = None if meta is None or team_access.is_open(meta) else set(team_access.members(meta))
    owners: dict[int, str] = {}
    out = []
    for f in files:
        uid = int(f.get("uid", -1))
        if uid not in owners:
            name = owner_name(uid) if names else ""
            ok = name in names and (team is None or name in team)
            owners[uid] = names[name] if ok else ""
        item = {k: v for k, v in f.items() if k != "uid"}
        if owners[uid]:
            item["by"] = owners[uid]
        out.append(item)
    return out


@router.get("/projects/{project_id}/media")
def media_download(request: Request, project_id: str, path: str = "") -> Any:
    """One original (`?path=Day 1/A001.mov`, members only), or without a path the list of
    every original (members, and Drive admins read-only)."""
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        if not path:
            _check_access(user, info, admin_ok=True)
            files, truncated = team_files.list_media(user, info["folder"])
            files = _with_added_by(user, info["folder"], files)
            return {"files": files, "count": len(files), "bytes": sum(int(f["size"]) for f in files),
                    "truncated": truncated, "rev": media_rev(project_id)}
        _check_access(user, info)
        opened = team_files.open_media(user, info["folder"], path)
    except FSError as e:
        return _fs_error(e)
    response = _hooks["file_response"](opened)
    response.chunk_size = MEDIA_READ_CHUNK
    return response


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

    def work() -> tuple[dict[str, Any], str]:
        _check_access(user, info)
        meta = get_session(upload_id, username=username, uid=uid)
        if meta.get("share") != _upload_share(project_id):
            raise FSError("This upload is not for this team project", 400)
        media_rel = team_files.media_folder_for(info["folder"])
        folder = str(meta.get("path") or "").strip("/")
        inside = folder[len(media_rel):].strip("/") if folder.startswith(media_rel) else ""
        rel = f"{inside}/{meta.get('name')}" if inside else str(meta.get("name") or "")
        return complete_session(upload_id, username=username, uid=uid, expect_mtime_ns=expect_mtime_ns), rel

    try:
        result, rel = await run_in_threadpool(work)
    except FSError as e:
        return _fs_error(e)
    media_changed(project_id, rel, username)
    return result
