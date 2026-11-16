"""Who may use a team project: `members` and `invites` in its meta.json.

Pure functions over the meta dict; each change returns a new dict. A meta.json
without a `members` key is a project from before invites, open to every Drive
member (role "open"). Conflicts raise `team_files.TeamConflict` (a 409 with a code).
"""

from __future__ import annotations

from typing import Any

from team_files import TeamConflict

MAX_TEAM = 12  # members + open invites per project


def is_open(meta: dict[str, Any]) -> bool:
    return "members" not in meta


def members(meta: dict[str, Any]) -> list[str]:
    value = meta.get("members")
    return [m for m in value if isinstance(m, str)] if isinstance(value, list) else []


def invites(meta: dict[str, Any]) -> list[dict[str, Any]]:
    value = meta.get("invites")
    if not isinstance(value, list):
        return []
    return [i for i in value if isinstance(i, dict) and isinstance(i.get("user"), str)]


def invite_of(meta: dict[str, Any], username: str) -> dict[str, Any] | None:
    return next((i for i in invites(meta) if i["user"] == username), None)


def role(meta: dict[str, Any], username: str) -> str | None:
    """"open", "member", "invited", or None when the project is not for this person."""
    if is_open(meta):
        return "open"
    if username in members(meta):
        return "member"
    if invite_of(meta, username) is not None:
        return "invited"
    return None


def can_use(meta: dict[str, Any], username: str) -> bool:
    return role(meta, username) in ("open", "member")


def new_project(creator: str) -> dict[str, Any]:
    return {"members": [creator], "invites": []}


def _require_closed(meta: dict[str, Any]) -> None:
    if is_open(meta):
        raise TeamConflict("Everyone on the Drive can already open this project", "open_project")


def with_invites(meta: dict[str, Any], by: str, users: list[str], now: int) -> dict[str, Any]:
    """Meta with `users` invited by `by` (already invited ones stay as they were)."""
    _require_closed(meta)
    current = members(meta)
    for user in users:
        if user in current:
            raise TeamConflict(f"{user} is already in this project", "already_member")
    pending = invites(meta)
    fresh = [u for u in dict.fromkeys(users) if all(i["user"] != u for i in pending)]
    if len(current) + len(pending) + len(fresh) > MAX_TEAM:
        raise TeamConflict(f"A team project can have at most {MAX_TEAM} people, counting invites",
                           "team_full")
    added = [{"user": u, "by": by, "at": int(now)} for u in fresh]
    return {**meta, "invites": [*pending, *added]}


def without_invite(meta: dict[str, Any], username: str) -> dict[str, Any]:
    return {**meta, "invites": [i for i in invites(meta) if i["user"] != username]}


def with_member(meta: dict[str, Any], username: str) -> dict[str, Any]:
    """An invitee joins: off the invites, onto the members."""
    _require_closed(meta)
    current = members(meta)
    joined = current if username in current else [*current, username]
    return {**without_invite(meta, username), "members": joined}


def without_member(meta: dict[str, Any], username: str) -> dict[str, Any]:
    _require_closed(meta)
    current = members(meta)
    if current == [username]:
        raise TeamConflict("You're the last member, so you can't leave this project", "last_member")
    return {**meta, "members": [m for m in current if m != username]}


def people_fields(meta: dict[str, Any], username: str, role: str, names: dict[str, str]) -> dict[str, Any]:
    """`role`, `members`, `invites` (an invitee sees only their own) and `invited_by` of a list item."""
    def person(name: str) -> dict[str, str]:
        return {"username": name, "name": names.get(name) or name}

    pending = invites(meta)
    if role == "invited":
        pending = [i for i in pending if i["user"] == username]
    mine = invite_of(meta, username) if role == "invited" else None
    return {
        "role": role,
        "members": [person(m) for m in members(meta)],
        "invites": [{**person(i["user"]), "by": str(i.get("by") or "")} for i in pending],
        "invited_by": (names.get(str(mine.get("by") or "")) or str(mine.get("by") or "") or None) if mine else None,
    }
