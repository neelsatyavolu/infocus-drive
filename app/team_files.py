"""Read and write InFocus Cut team project files on the Drive.

Layout under the drive root (the only writer is this module)::

    Team Projects/<name>.fcteam/project.json          shared part (items without sequences, bins, …)
    Team Projects/<name>.fcteam/sequences/<id>.json   one sequence item per file
    Team Projects/<name>.fcteam/sequences/.deleted/   deleted sequences, moved aside (never removed)
    Team Projects/<name>.fcteam/meta.json             id, versions, creator, file hashes
    Team Projects/<name> Media/                        originals, uploaded like any Drive file

Every file operation runs as the member (`fsops.as_user`), so NAS ACLs decide
who can open a project. Each call holds `as_user` only for its own short file
reads and writes; callers do locks, SQLite and SSE outside it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

import fsops
from config import TEAM_ROOT_REL
from fsops import FSError

FCTEAM_SUFFIX = ".fcteam"
MEDIA_SUFFIX = " Media"
PROJECT_FILE = "project.json"
META_FILE = "meta.json"
SEQUENCES_DIR = "sequences"
DELETED_DIR = ".deleted"
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_NAME_LEN = 100
_SEQ_FILE = re.compile(r"^([1-9][0-9]{0,15})\.json$")
_BAD_NAME = re.compile(r"[\x00-\x1f\x7f/\\]")
_BAD_MEDIA_PATH = re.compile(r"[\x00-\x1f\x7f\\]")


class TeamConflict(FSError):
    """A 409 with a machine-readable `code` (the `error` field of team API 409 bodies)."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message, 409)
        self.code = code


class FilesChanged(TeamConflict):
    """A project file no longer matches the hash the server recorded."""

    def __init__(self) -> None:
        super().__init__("project files were changed outside InFocus Cut", "files_changed")


def valid_name(name: str) -> str:
    name = (name or "").strip()
    if (
        not name
        or len(name) > MAX_NAME_LEN
        or name.startswith(".")
        or name.startswith("#")
        or _BAD_NAME.search(name)
    ):
        raise FSError("Invalid project name", 400)
    return name


def folder_for(name: str) -> str:
    return f"{TEAM_ROOT_REL}/{valid_name(name)}{FCTEAM_SUFFIX}"


def media_folder_for(folder_rel: str) -> str:
    """`Team Projects/<name>.fcteam` → `Team Projects/<name> Media`."""
    base = Path(folder_rel).name[: -len(FCTEAM_SUFFIX)]
    return f"{TEAM_ROOT_REL}/{base}{MEDIA_SUFFIX}"


def _project_dir(folder_rel: str) -> Path:
    """Resolve a project folder, refusing anything but `Team Projects/<x>.fcteam` itself."""
    parts = Path(folder_rel or "").parts
    if len(parts) != 2 or parts[0] != TEAM_ROOT_REL or not parts[1].endswith(FCTEAM_SUFFIX):
        raise FSError("Invalid team project folder", 400)
    path = fsops.resolve_rel(folder_rel)
    if path != fsops.drive_root().joinpath(*parts):
        # A symlink was swapped in for the project folder.
        raise FSError("Team project not found", 404)
    return path


@contextmanager
def _as(user: dict[str, Any]) -> Iterator[None]:
    try:
        with fsops.as_user(int(user["uid"]), int(user["gid"]), str(user.get("username") or "") or None):
            yield
    except FSError:
        raise
    except PermissionError as e:
        raise FSError("You don't have access to this team project", 403) from e
    except FileExistsError as e:
        raise TeamConflict("A team project with that name already exists", "name_taken") from e
    except FileNotFoundError as e:
        raise FSError("Team project not found", 404) from e
    except (OSError, ValueError) as e:
        raise FSError("Could not read the team project", 500) from e


def _read_bytes(path: Path) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as fh:
        data = fh.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise FSError("Team project file is too large", 413)
    return data


def _write_bytes(path: Path, data: bytes) -> None:
    """Write next to the target and rename over it, so readers never see half a file.

    The file is fsynced before the rename and the folder after it, so a power cut
    leaves the old or the new file, never an empty one. A crash between a data file
    and meta.json can still leave their hashes apart; reads then answer 409
    `files_changed` and an admin repairs it by hand (docs/SYSTEM.md, "Team projects").
    """
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(tmp, flags, 0o664)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
    dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def _dump(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _seq_rel(seq_id: int) -> str:
    return f"{SEQUENCES_DIR}/{int(seq_id)}.json"


def _read_meta(root: Path) -> dict[str, Any]:
    meta = json.loads(_read_bytes(root / META_FILE))
    if not isinstance(meta, dict) or not isinstance(meta.get("id"), str):
        raise TeamConflict("Team project metadata is invalid", "invalid_project")
    return meta


def list_projects(user: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    """(folder_rel, meta) for every team project the member can read."""
    try:
        root = fsops.resolve_rel(TEAM_ROOT_REL)
    except FSError:
        return []
    found: list[tuple[str, dict[str, Any]]] = []
    try:
        with _as(user):
            if not root.is_dir():
                return []
            names = sorted(e.name for e in os.scandir(root) if e.name.endswith(FCTEAM_SUFFIX)
                           and e.is_dir(follow_symlinks=False))
            for name in names:
                try:
                    found.append((f"{TEAM_ROOT_REL}/{name}", _read_meta(root / name)))
                except (OSError, ValueError, FSError):
                    continue  # no access, or not a team project
    except FSError as e:
        if e.status in (403, 404):
            return []
        raise
    return found


def create_project(
    user: dict[str, Any],
    name: str,
    meta: dict[str, Any],
    shared: dict[str, Any],
    sequences: dict[int, dict[str, Any]],
) -> str:
    """Create `<name>.fcteam` and `<name> Media` under Team Projects. Returns the folder."""
    folder_rel = folder_for(name)
    team_root = fsops.resolve_rel(TEAM_ROOT_REL)
    if team_root != fsops.drive_root() / TEAM_ROOT_REL:
        raise FSError("Team Projects folder is not available", 409)
    root = team_root / Path(folder_rel).name
    media = fsops.drive_root() / media_folder_for(folder_rel)
    with _as(user):
        team_root.mkdir(exist_ok=True)
        if os.path.lexists(media):
            # Never adopt a folder someone else made: its files would join the project.
            raise TeamConflict("A folder with that project's media name already exists", "name_taken")
        root.mkdir()
        made_media = False
        try:
            (root / SEQUENCES_DIR).mkdir()
            media.mkdir()
            made_media = True
            hashes: dict[str, str] = {}
            data = _dump(shared)
            _write_bytes(root / PROJECT_FILE, data)
            hashes[PROJECT_FILE] = _sha(data)
            for seq_id, item in sequences.items():
                data = _dump(item)
                _write_bytes(root / _seq_rel(seq_id), data)
                hashes[_seq_rel(seq_id)] = _sha(data)
            _write_bytes(root / META_FILE, _dump({**meta, "file_hashes": hashes}))
        except BaseException:
            shutil.rmtree(root, ignore_errors=True)  # only the folder this call just made
            if made_media:
                try:
                    media.rmdir()  # still empty; never removes files
                except OSError:
                    pass
            raise
    return folder_rel


def read_meta(user: dict[str, Any], folder_rel: str) -> dict[str, Any]:
    """The project's meta.json, read as the member (doubles as the access check)."""
    root = _project_dir(folder_rel)
    with _as(user):
        return _read_meta(root)


def read_project(
    user: dict[str, Any], folder_rel: str
) -> tuple[dict[str, Any], dict[str, Any], dict[int, dict[str, Any]]]:
    """(meta, shared, sequences), refusing files that changed outside the server."""
    root = _project_dir(folder_rel)
    with _as(user):
        meta = _read_meta(root)
        hashes = meta.get("file_hashes") or {}
        raw = _read_bytes(root / PROJECT_FILE)
        if hashes.get(PROJECT_FILE) != _sha(raw):
            raise FilesChanged()
        shared = json.loads(raw)
        sequences: dict[int, dict[str, Any]] = {}
        on_disk = set()
        for entry in os.scandir(root / SEQUENCES_DIR):
            match = _SEQ_FILE.match(entry.name)
            if not match:
                continue
            rel = f"{SEQUENCES_DIR}/{entry.name}"
            on_disk.add(rel)
            raw = _read_bytes(root / rel)
            if hashes.get(rel) != _sha(raw):
                raise FilesChanged()
            sequences[int(match.group(1))] = json.loads(raw)
        if {k for k in hashes if k.startswith(f"{SEQUENCES_DIR}/")} != on_disk:
            raise FilesChanged()
    return meta, shared, sequences


def write_sequence(
    user: dict[str, Any], folder_rel: str, seq_id: int, item: dict[str, Any],
    meta_updates: dict[str, Any] | None = None,
) -> None:
    root = _project_dir(folder_rel)
    data = _dump(item)
    with _as(user):
        meta = _read_meta(root)
        _write_bytes(root / _seq_rel(seq_id), data)
        hashes = {**(meta.get("file_hashes") or {}), _seq_rel(seq_id): _sha(data)}
        _write_bytes(root / META_FILE, _dump({**meta, **(meta_updates or {}), "file_hashes": hashes}))


def delete_sequence(user: dict[str, Any], folder_rel: str, seq_id: int) -> str:
    """Move `sequences/<id>.json` into `sequences/.deleted/` and drop its hash.

    A rename as the member inside the project folder: nothing is removed, and
    the copy goes to `#recycle` with the rest of the project at cleanup. Adds
    `.#1`, `.#2` … when an older copy of the same id is already there. Returns
    the new path relative to the project folder.
    """
    root = _project_dir(folder_rel)
    rel = _seq_rel(seq_id)
    with _as(user):
        meta = _read_meta(root)
        bin_dir = root / SEQUENCES_DIR / DELETED_DIR
        if not os.path.lexists(bin_dir):
            bin_dir.mkdir()
        if bin_dir.is_symlink() or not bin_dir.is_dir():
            raise TeamConflict("The deleted sequences folder is not a plain folder", "invalid_project")
        source = root / rel
        if source.is_symlink() or not source.is_file():
            raise FSError("Sequence not found", 404)
        dest = fsops._versioned_dest(bin_dir / source.name)
        os.rename(source, dest)
        hashes = {k: v for k, v in (meta.get("file_hashes") or {}).items() if k != rel}
        _write_bytes(root / META_FILE, _dump({**meta, "file_hashes": hashes}))
    return str(dest.relative_to(root))


def write_shared(user: dict[str, Any], folder_rel: str, shared: dict[str, Any]) -> None:
    root = _project_dir(folder_rel)
    data = _dump(shared)
    if len(data) > MAX_FILE_BYTES:
        raise FSError("Team project file is too large", 413)  # it could not be read back
    with _as(user):
        meta = _read_meta(root)
        _write_bytes(root / PROJECT_FILE, data)
        hashes = {**(meta.get("file_hashes") or {}), PROJECT_FILE: _sha(data)}
        _write_bytes(root / META_FILE, _dump({**meta, "file_hashes": hashes}))


def _media_path(folder_rel: str, rel: str, *, allow_root: bool) -> tuple[Path, Path, str]:
    """(target, media root, target rel to the drive root) for a path inside `<name> Media/`.

    Always under the drive root (never the member's active share). Refuses
    traversal, absolute paths and backslashes (400), and a symlink anywhere on
    the way, including the media folder itself (404, like `_project_dir`).
    """
    _project_dir(folder_rel)
    media_rel = media_folder_for(folder_rel)
    rel = rel or ""
    segments = rel.split("/") if rel else []
    if (
        (not segments and not allow_root)
        or _BAD_MEDIA_PATH.search(rel)
        or any(s in ("", ".", "..") for s in segments)
    ):
        raise FSError("Invalid media path", 400)
    root = fsops.drive_root()
    media = root.joinpath(*Path(media_rel).parts)
    target = media.joinpath(*segments)
    target_rel = "/".join([media_rel, *segments])
    if fsops.resolve_rel(target_rel) != target or fsops.resolve_rel(media_rel) != media:
        raise FSError("Media file not found", 404)
    return target, media, target_rel


def valid_media_name(name: Any) -> str:
    """A plain file name for an upload into the media folder (no folders, no `.fcteam`)."""
    if (
        not isinstance(name, str)
        or not name
        or len(name) > 255
        or name in (".", "..")
        or _BAD_NAME.search(name)
    ):
        raise FSError("Invalid file name", 400)
    guard_new_name(name)
    return name


def open_media(user: dict[str, Any], folder_rel: str, rel: str) -> fsops.AuthorizedFile:
    """Open an original in the project's media folder as the member, for download."""
    target, media, _ = _media_path(folder_rel, rel, allow_root=False)
    return fsops.open_authorized_path(target, media, int(user["uid"]), int(user["gid"]), name=target.name)


def media_upload_dir(user: dict[str, Any], folder_rel: str, rel_dir: str) -> tuple[Path, str]:
    """(folder, rel to the drive root) to upload into, made as the member if missing."""
    guard_new_name(rel_dir)  # no `.fcteam` folders inside the media folder either
    target, _media, target_rel = _media_path(folder_rel, rel_dir, allow_root=True)
    if not target.is_dir():
        fsops.ensure_dir(target_rel, int(user["uid"]), int(user["gid"]))
        target, _media, target_rel = _media_path(folder_rel, rel_dir, allow_root=True)
        if not target.is_dir():
            raise FSError("Media folder not found", 404)
    return target, target_rel


def _holds_id(project: Path, project_id: str) -> bool:
    """True if the folder's meta.json names `project_id` (call with privileges held)."""
    try:
        return _read_meta(project).get("id") == project_id
    except (OSError, ValueError, FSError):
        return False


def project_present(info: dict[str, Any]) -> bool:
    """True if the row's folder is still this project (its meta.json carries the row's id).

    Read as root, for the daily cleanup: a row whose folder is gone or now holds
    another project is stale, and is forgotten without a notice or a move.
    """
    try:
        project = _project_dir(info["folder"])
    except FSError:
        return False
    with fsops.as_root():
        return _holds_id(project, info["id"])


def folder_holds(user: dict[str, Any], folder_rel: str, project_id: str) -> bool | None:
    """Whether `folder_rel` still holds `project_id`, read as the member.

    None when the member can't tell (no access), so callers leave the row alone.
    """
    try:
        root = _project_dir(folder_rel)
        with _as(user):
            return _holds_id(root, project_id) if os.path.lexists(root / META_FILE) else False
    except FSError as e:
        return False if e.status == 404 else None


def recycle_project(folder_rel: str, project_id: str) -> list[str]:
    """Move `<name>.fcteam` and its `<name> Media` into the share's `#recycle`.

    Used by the daily cleanup, which has no member to act as, so it runs as
    root under the `as_user` lock. Only renames (same share, nothing is copied
    or deleted), keeps the tree like Samba's recycle (`#recycle/Team Projects/…`)
    and adds `.#1`, `.#2` … when an older copy is already in the bin. Refuses
    anything but the two project folders, symlinks, and shares without a bin.
    The folder's meta.json must carry `project_id`; otherwise it is another
    project (or none), and this answers 404 so the stale row is forgotten.
    Returns the recycle paths written.
    """
    project = _project_dir(folder_rel)
    root = fsops.drive_root()
    media = root / media_folder_for(folder_rel)
    moved: list[str] = []
    with fsops.as_root():
        bin_dir = fsops.recycle_dir()
        if not bin_dir.is_dir() or bin_dir.is_symlink():
            raise FSError("This share has no Recycle bin", 409)
        # Media first: if the project move then fails, the next run retries it, and
        # the project is never left in the bin with its media behind.
        sources = [p for p in (media, project) if os.path.lexists(p)]
        if project not in sources or project.is_symlink() or not _holds_id(project, project_id):
            raise FSError("Team project not found", 404)
        for src in sources:
            if src.is_symlink() or not src.is_dir():
                raise FSError("Team project folder is not a plain folder", 409)
        dest_dir = bin_dir / TEAM_ROOT_REL
        if dest_dir.is_symlink():
            raise FSError("Recycle bin folder is not a plain folder", 409)
        dest_dir.mkdir(exist_ok=True)
        try:
            os.chmod(dest_dir, 0o777)  # same as fsops.delete, so members can recycle into it too
        except OSError:
            pass
        for src in sources:
            dest = fsops._versioned_dest(dest_dir / src.name)
            os.rename(src, dest)
            moved.append(str(dest.relative_to(root)))
    return moved


# Web file routes ---------------------------------------------------------------
# Only this module writes inside a `.fcteam` folder. The normal file routes
# (mkdir, rename, move, delete, upload) call these guards inside their share
# root, so a project can't be edited past the server's revisions and hashes.

_IN_CUT = "Team projects can only be changed in InFocus Cut"


def _fcteam(name: str) -> bool:
    return name.lower().endswith(FCTEAM_SUFFIX)


def guard_web_path(rel: str, *, whole_project_ok: bool = False) -> None:
    """Refuse a path inside a `.fcteam` folder (after symlinks), or the folder itself.

    `whole_project_ok` lets the folder itself through (delete into `#recycle`).
    """
    root = fsops.drive_root()
    parts = fsops.resolve_rel(rel).relative_to(root).parts
    if any(_fcteam(p) for p in parts[:-1]):
        raise FSError(_IN_CUT, 403)
    if parts and _fcteam(parts[-1]) and not whole_project_ok:
        raise FSError(_IN_CUT, 403)


def guard_new_name(name: str) -> None:
    """`.fcteam` names are made by InFocus Cut only."""
    if any(_fcteam(p) for p in Path((name or "").strip()).parts):
        raise FSError("Names ending in .fcteam are reserved for InFocus Cut team projects", 400)
