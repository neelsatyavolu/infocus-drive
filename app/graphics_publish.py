"""Write access for the infocus-graphics repo's Drive sync workflow (GitHub Actions).

It mirrors each package folder ("InFocus 2026 Package", "InFocus Christmas 2026 Package", ...) into All Resources and
replaces the package zips in Graphic Files (GRAPHICS_ROOT), which the editing Macs install. It has its own key,
GRAPHICS_PUBLISH_TOKEN, kept as a GitHub secret: that key works only on /api/service/graphics-publish/*, and those
routes accept only it. They can write files inside a package folder and the "<package>.zip" files, nothing else.
Deletes go to the Recycle folder. A per-package manifest (.drive-sync.json in the package folder) records what the
workflow put there, so it only uploads what changed and only deletes what it wrote.
"""

from __future__ import annotations

import hmac
import re

from fastapi import HTTPException, Request

from config import get_settings
from fsops import FSError, resolve_rel
from service_auth import _normalize_service_path

PACKAGE_RE = re.compile(r"^InFocus [A-Za-z0-9][A-Za-z0-9 ]{0,40} Package$")
MANIFEST_NAME = ".drive-sync.json"
MAX_MANIFEST_BYTES = 2 * 1024 * 1024


def require_publish_token(request: Request) -> None:
    expected = (get_settings().graphics_publish_token or "").strip()
    if not expected:
        raise HTTPException(status_code=503, detail="Graphics publishing is not set up on this Drive")
    auth = request.headers.get("authorization") or ""
    got = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
    if not got or not hmac.compare_digest(got, expected):
        raise HTTPException(status_code=401, detail="Invalid graphics publish key")


def _graphics_root() -> str:
    root = (get_settings().graphics_root or "").strip().strip("/")
    if not root or "/" not in root:
        raise HTTPException(status_code=503, detail="GRAPHICS_ROOT isn't set")
    return root


def resources_root() -> str:
    """The folder the package folders live in: GRAPHICS_ROOT's parent ("All Resources")."""
    return _graphics_root().rsplit("/", 1)[0]


def package_dir(package: str) -> str:
    if not PACKAGE_RE.match(package or ""):
        raise HTTPException(status_code=403, detail="Not a package folder name")
    folder = f"{resources_root()}/{package}"
    _not_linked_away(folder)
    return folder


def _not_linked_away(folder: str) -> None:
    """A package folder must really be in All Resources, not a symlink to somewhere else."""
    try:
        real, parent = resolve_rel(folder), resolve_rel(resources_root())
    except FSError as e:
        raise HTTPException(status_code=403, detail="Not a publishable path") from e
    if real != parent / folder.rsplit("/", 1)[1]:
        raise HTTPException(status_code=403, detail="That package folder leads somewhere else")


def publish_path(rel: str) -> str:
    """A file the workflow may write or delete: inside a package folder, or a package zip in Graphic Files."""
    path = _normalize_service_path(rel)
    parts = path.split("/")
    graphics, resources = _graphics_root(), resources_root()
    if any(p.startswith("#") for p in parts):
        raise HTTPException(status_code=403, detail="Not a publishable path")
    head, _, name = path.rpartition("/")
    if head == graphics and name.endswith(".zip") and PACKAGE_RE.match(name[:-4]):
        return _inside(path, graphics)
    depth = len(resources.split("/"))
    if path.startswith(resources + "/") and len(parts) > depth + 1 and PACKAGE_RE.match(parts[depth]) \
            and name != MANIFEST_NAME:
        _not_linked_away(f"{resources}/{parts[depth]}")
        return _inside(path, f"{resources}/{parts[depth]}")
    raise HTTPException(status_code=403, detail="Only package folders and package zips can be published")


def _inside(path: str, base: str) -> str:
    """The same rule on disk: a symlink inside a package folder must not lead out of it."""
    try:
        real, root = resolve_rel(path), resolve_rel(base)
    except FSError as e:
        raise HTTPException(status_code=403, detail="Not a publishable path") from e
    if real != root and root not in real.parents:
        raise HTTPException(status_code=403, detail="That path leads outside the package")
    return path
