"""Drive website file routes vs team project membership.

On disk, `Team Projects/` is shared by every Drive member (files are 0o664), so the
normal file routes (list, search, download, zip, thumbnails, links, uploads, renames,
deletes) check membership here. A `<name>.fcteam` folder and its `<name> Media`
folder belong to the project whose meta.json is in the `.fcteam` folder:

- members (and everyone, for a legacy project without `members`) may use them;
- Drive admins may read them, but not change them on the website;
- everyone else gets 404, and listings and search results leave them out.

Paths are checked after symlinks, as absolute paths, so it doesn't matter which
share the request came through.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Iterable

import team_access
import team_files
from config import TEAM_ROOT_REL, get_settings
from fsops import FSError

_HIDDEN = "Not found"
_ADMIN_READ_ONLY = "Only the team's members can change a team project's files"
_MANAGED = "Team Projects is managed by InFocus Cut. Add footage inside a project's Media folder."

USE, ADMIN, NONE = "use", "admin", "none"


def team_dir() -> Path:
    return Path(get_settings().drive_root).resolve() / TEAM_ROOT_REL


def project_folder(target: Path) -> tuple[bool, str | None]:
    """(inside `Team Projects/`, the project's `.fcteam` folder rel or None)."""
    try:
        parts = Path(target).relative_to(team_dir()).parts
    except (ValueError, FSError):
        return False, None
    if not parts:
        return True, None
    name = parts[0]
    if name.endswith(team_files.FCTEAM_SUFFIX):
        return True, f"{TEAM_ROOT_REL}/{name}"
    if name.endswith(team_files.MEDIA_SUFFIX) and len(name) > len(team_files.MEDIA_SUFFIX):
        base = name[: -len(team_files.MEDIA_SUFFIX)]
        return True, f"{TEAM_ROOT_REL}/{base}{team_files.FCTEAM_SUFFIX}"
    return True, None


class Checker:
    """Membership answers for one request (each project's meta.json is read once)."""

    def __init__(self, user: dict[str, Any], is_admin: bool) -> None:
        self.user = user
        self.username = str(user.get("username") or "")
        self.is_admin = is_admin
        self._seen: dict[str, str] = {}

    def access(self, folder: str) -> str:
        if folder not in self._seen:
            self._seen[folder] = self._lookup(folder)
        return self._seen[folder]

    def _lookup(self, folder: str) -> str:
        try:
            meta = team_files.read_meta(self.user, folder)
        except (FSError, OSError, ValueError, team_files.TeamConflict):
            # No readable meta.json: not a team project (a Media folder of a removed
            # project, a broken folder). The NAS permissions still apply.
            return USE
        if team_access.can_use(meta, self.username):
            return USE
        return ADMIN if self.is_admin else NONE

    def check(self, target: Path, *, write: bool) -> None:
        """Raise FSError (404 for outsiders, 403 for admins writing) when not allowed."""
        inside, folder = project_folder(target)
        if not inside:
            return
        if folder is None:
            if write and Path(target) == team_dir():
                raise FSError(_MANAGED, 403)
            return
        access = self.access(folder)
        if access == USE:
            return
        if access == ADMIN and not write:
            return
        if access == ADMIN:
            raise FSError(_ADMIN_READ_ONLY, 403)
        raise FSError(_HIDDEN, 404)

    def may_read(self, target: Path) -> bool:
        try:
            self.check(target, write=False)
        except FSError:
            return False
        return True

    def visible(self, root: Path, items: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
        """Listing or search items (with `path` relative to `root`) this person may see."""
        return [item for item in items if self.may_read(Path(root) / str(item.get("path") or ""))]
