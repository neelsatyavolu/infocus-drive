"""Team project people: who can be invited, invites, joining, declining and leaving.

Members and invites live in the project's meta.json (`team_access`); every change is a
read-modify-write of meta.json under the project lock (`team_projects._project_lock`),
the same lock every other meta.json writer holds. Auth, CSRF and body limits are the
other team routes' (`team_projects`).
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool

import team_access
import team_files
import team_limits
import team_people
from fsops import FSError
from team_cleanup import send_notice_email
from team_projects import (
    _body,
    _device,
    _error,
    _fs_error,
    _project_lock,
    _project_or_404,
    _slot,
    _user,
    disconnect,
    publish,
    store,
)

router = APIRouter(prefix="/api/team")
log = logging.getLogger(__name__)

MAX_INVITES_PER_CALL = 10
_NOT_FOUND = "Team project not found"


def _not_found() -> HTTPException:
    return HTTPException(status_code=404, detail=_NOT_FOUND)


def _bad_request(code: str, message: str) -> JSONResponse:
    return _error(400, {"error": code, "message": message, "detail": message})


def send_invite_email(username: str, inviter: str, project: str) -> None:
    """Best-effort email to the invitee; never raises and never logs the address.

    The subject carries no text a member chose; the body names the project, shortened
    and without links (`team_limits.email_safe_name`).
    """
    subject = f"{inviter} invited you to a team project in InFocus Cut"
    text = (f"{inviter} invited you to the team project \"{team_limits.email_safe_name(project)}\" "
            "in InFocus Cut. Open InFocus Cut ▸ Team to join.")
    try:
        send_notice_email(username, subject, text)
    except Exception:  # noqa: BLE001 - an email must never fail the invite
        log.warning("team invite email to member %s failed", username)


def _deliver(fn: Callable[..., None], *args: Any) -> None:
    """Send off the request thread (Resend may take seconds)."""
    threading.Thread(target=fn, args=args, name="team-invite-email", daemon=True).start()


def _change_meta(user: dict[str, Any], info: dict[str, Any],
                 change: Callable[[dict[str, Any]], dict[str, Any]]) -> dict[str, Any]:
    with _project_lock(info["id"]):
        return team_files.update_meta(user, info["folder"], change)


def _people_or_error(value: Any, names: dict[str, str]) -> list[str] | JSONResponse:
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_INVITES_PER_CALL:
        return _bad_request("bad_users", f"Pick between 1 and {MAX_INVITES_PER_CALL} people to invite")
    users: list[str] = []
    for name in value:
        if not isinstance(name, str) or not team_people.USERNAME.match(name) or name not in names:
            return _bad_request("unknown_user", "Someone you picked isn't a member of this Drive")
        if name not in users:
            users.append(name)
    return users


# Routes ---------------------------------------------------------------------------


PEOPLE_MIN_QUERY = 2
PEOPLE_MAX_RESULTS = 20


@router.get("/people")
def people(request: Request, q: str = Query("", max_length=80)) -> Any:
    """Drive members the caller can invite whose name or user name contains `q`.

    The Drive's roster includes minors, so it is never handed out whole: `q` needs at
    least 2 characters (shorter gives an empty list), at most 20 matches come back, and
    each member may search 60 times a minute (429 past that).
    """
    username = str(_user(request)["username"])
    query = q.strip().lower()
    if len(query) < PEOPLE_MIN_QUERY:
        return {"people": [], "min_query": PEOPLE_MIN_QUERY}
    if not team_limits.people_searches.allow(username):
        return _error(429, {"error": "slow_down", "message": "Too many searches. Wait a minute and try again.",
                            "detail": "Too many searches"})
    names = team_people.directory()
    found = [{"username": u, "name": n} for u, n in names.items()
             if u != username and (query in u.lower() or query in n.lower())]
    found.sort(key=lambda p: (not (p["name"].lower().startswith(query) or p["username"].startswith(query)),
                              p["name"].lower(), p["username"]))
    return {"people": found[:PEOPLE_MAX_RESULTS], "min_query": PEOPLE_MIN_QUERY}


@router.post("/projects/{project_id}/invites")
async def invite(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    body = await _body(request)
    names = await run_in_threadpool(team_people.directory)
    users = _people_or_error(body.get("users"), names)
    if isinstance(users, JSONResponse):
        return users
    username = str(user["username"])
    before: list[str] = []

    def change(meta: dict[str, Any]) -> dict[str, Any]:
        if team_access.role(meta, username) not in ("member", "open"):
            raise _not_found()
        before.extend(i["user"] for i in team_access.invites(meta))
        return team_access.with_invites(meta, username, users, int(time.time()))

    try:
        meta = await run_in_threadpool(_change_meta, user, info, change)
    except FSError as e:
        return _fs_error(e)
    pending = team_access.invites(meta)
    inviter = names.get(username) or username
    project = str(meta.get("name") or info["name"])
    for invited in pending:
        # Cancel + invite again must not resend: one email per invitee and project a day,
        # and a cap per inviter an hour (team_limits).
        if invited["user"] not in before and team_limits.may_email(project_id, username, invited["user"]):
            _deliver(send_invite_email, invited["user"], inviter, project)
    return {"invites": [{"username": i["user"], "name": names.get(i["user"]) or i["user"],
                         "by": str(i.get("by") or "")} for i in pending]}


@router.delete("/projects/{project_id}/invites/{invitee}")
async def cancel_invite(request: Request, project_id: str, invitee: str) -> Any:
    """Any member can take back an invite (204 also when there was none)."""
    user = _user(request)
    info = _project_or_404(project_id)
    username = str(user["username"])

    def change(meta: dict[str, Any]) -> dict[str, Any]:
        if not team_access.can_use(meta, username):
            raise _not_found()
        return team_access.without_invite(meta, invitee)

    try:
        await run_in_threadpool(_change_meta, user, info, change)
    except FSError as e:
        return _fs_error(e)
    return Response(status_code=204)


@router.post("/projects/{project_id}/join")
async def join(request: Request, project_id: str) -> Any:
    """An invitee becomes a member; members (and anyone, on an open project) just get their slot."""
    user = _user(request)
    info = _project_or_404(project_id)
    device = _device(request)
    username = str(user["username"])

    def change(meta: dict[str, Any]) -> dict[str, Any]:
        role = team_access.role(meta, username)
        if role is None:
            raise _not_found()
        return team_access.with_member(meta, username) if role == "invited" else meta

    def work() -> dict[str, Any]:
        _change_meta(user, info, change)
        return {"id": project_id, "slot": _slot(store(), project_id, username, device)}

    try:
        return await run_in_threadpool(work)
    except FSError as e:
        return _fs_error(e)


@router.post("/projects/{project_id}/decline")
async def decline(request: Request, project_id: str) -> Any:
    user = _user(request)
    info = _project_or_404(project_id)
    username = str(user["username"])

    def change(meta: dict[str, Any]) -> dict[str, Any]:
        if team_access.role(meta, username) != "invited":
            raise _not_found()
        return team_access.without_invite(meta, username)

    try:
        await run_in_threadpool(_change_meta, user, info, change)
    except FSError as e:
        return _fs_error(e)
    return Response(status_code=204)


@router.post("/projects/{project_id}/leave")
async def leave(request: Request, project_id: str) -> Any:
    """A member leaves and their locks go with them; the last member stays (409 `last_member`)."""
    user = _user(request)
    info = _project_or_404(project_id)
    username = str(user["username"])

    def change(meta: dict[str, Any]) -> dict[str, Any]:
        if team_access.role(meta, username) not in ("member", "open"):
            raise _not_found()
        return team_access.without_member(meta, username)

    def work() -> list[int]:
        with _project_lock(project_id):
            team_files.update_meta(user, info["folder"], change)
            return store().release_user(project_id, username)

    try:
        released = await run_in_threadpool(work)
    except FSError as e:
        return _fs_error(e)
    disconnect(project_id, username)
    for seq in released:
        publish(project_id, "lock_changed", {"seq": seq, "holder": None})
    return Response(status_code=204)
