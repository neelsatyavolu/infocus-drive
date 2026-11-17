"""The editing dashboard: a web page for team projects at `EDITING_HOST` (e.g.
`editing.example.org`) and at `/editing` on any host.

The page is static (`static/editing.html` + `editing*.js`) and uses the normal team
API with the Drive's session cookie. This module serves it, routes the editing host's
root to it, picks the Google sign-in return address for that host, and adds the one
read route the page needs beyond the app's: `GET /api/team/projects/{id}/overview`.

Members see their projects. A Drive admin also sees every other project, read-only
(role "admin"): overview and footage list only, plus the admin actions the team API
already has (Keep, force-release a lock).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse

import team_access
import team_cleanup
import team_files
import team_people
from config import get_settings
from fsops import FSError
from team_projects import (
    MEDIA_REV,
    _fs_error,
    _is_admin,
    _project_lock,
    _project_or_404,
    _user,
    online_users,
    store,
)

router = APIRouter()
STATIC = Path(__file__).parent / "static"

# Same lockdown as the other standalone pages (team keep, CLI consent): own scripts only,
# fetches to this origin only, no forms, no framing.
PAGE_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; connect-src 'self'; img-src 'self' data:; "
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
        "form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    ),
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "same-origin",
    "Cache-Control": "no-cache",
}


def editing_host() -> str:
    return (get_settings().editing_host or "").strip().lower()


def is_editing_host(host_header: str | None) -> bool:
    configured = editing_host()
    host = (host_header or "").split(":")[0].strip().lower()
    return bool(configured) and host == configured


def oauth_origin(host_header: str | None, default: str) -> str:
    """Where Google returns after sign-in: the editing host when the sign-in began there
    (its cookie must be set on that host), else the Drive's public address."""
    if is_editing_host(host_header):
        return f"https://{editing_host()}"
    return default.rstrip("/")


def page() -> FileResponse:
    return FileResponse(STATIC / "editing.html", headers=PAGE_HEADERS)


@router.api_route("/editing", methods=["GET", "HEAD"])
def editing_page() -> FileResponse:
    return page()


def _person(username: str, names: dict[str, str]) -> dict[str, str]:
    return {"username": username, "name": names.get(username) or username}


def _overview(user: dict[str, Any], info: dict[str, Any]) -> dict[str, Any]:
    project_id = info["id"]
    username = str(user["username"])
    with _project_lock(project_id):
        meta, _shared, sequences = team_files.read_project(user, info["folder"])
    admin = _is_admin(user)
    role = team_access.role(meta, username)
    if role not in ("member", "open"):
        if not admin:
            raise HTTPException(status_code=404, detail="Team project not found")
        role = "admin"
    st = store()
    names = team_people.directory()
    locks = st.locks(project_id)
    opens = st.member_opens(project_id)
    online = online_users(project_id)
    people = team_access.members(meta) if not team_access.is_open(meta) else sorted(opens)
    members = [{
        **_person(m, names),
        "last_seen": opens.get(m, 0.0),
        "online": m in online,
        "editing": sorted(seq for seq, (holder, _exp) in locks.items() if holder == m),
    } for m in people]
    seqs = [{
        "id": seq,
        "name": str(item.get("name") or f"Sequence {seq}"),
        "rev": st.revision(project_id, f"seq:{seq}"),
        "holder": _person(locks[seq][0], names) if seq in locks else None,
        "expires_at": locks[seq][1] if seq in locks else None,
    } for seq, item in sorted(sequences.items())]
    fields = team_access.people_fields(meta, username, role, names)
    return {
        "id": project_id,
        "name": str(meta.get("name") or info["name"]),
        "role": role,
        "open_to_all": team_access.is_open(meta),
        "creator": _person(info["creator"], names),
        "created_at": info["created_at"],
        "last_open": info["last_open"],
        "members": members,
        "invites": fields["invites"],
        "sequences": seqs,
        "media_folder": team_files.media_folder_for(info["folder"]),
        **team_files.cached_media_usage(user, info["folder"], st.revision(project_id, MEDIA_REV)),
        "media_rev": st.revision(project_id, MEDIA_REV),
        "cleanup": team_cleanup.cleanup_status(st, project_id),
        "keep": st.is_keep(project_id),
        "can_edit": role in ("member", "open"),
        "can_keep": admin or username == info["creator"],
        "is_admin": admin,
    }


@router.get("/api/team/projects/{project_id}/overview")
def overview(request: Request, project_id: str) -> Any:
    """Everything the dashboard shows about one project. Members, and Drive admins read-only."""
    user = _user(request)
    info = _project_or_404(project_id)
    try:
        return _overview(user, info)
    except FSError as e:
        return _fs_error(e)
