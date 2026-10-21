"""Machine-to-machine auth for infocus-packages → Drive storage."""

from __future__ import annotations

import hmac
import pwd
import time
from dataclasses import dataclass
from hashlib import sha256
from typing import Any

from fastapi import HTTPException, Request

from config import get_settings


@dataclass(frozen=True)
class ServiceIdentity:
    username: str
    uid: int
    gid: int


def _service_ser_secret() -> bytes:
    s = get_settings()
    raw = (s.packages_service_token or s.session_secret or "").encode("utf-8")
    if not raw:
        raise HTTPException(status_code=503, detail="Service storage not configured")
    return raw


def require_service_token(request: Request) -> None:
    """Require Authorization: Bearer <PACKAGES_SERVICE_TOKEN>."""
    settings = get_settings()
    expected = (settings.packages_service_token or "").strip()
    if not expected:
        raise HTTPException(status_code=503, detail="Packages service token not configured on drive")
    auth = request.headers.get("authorization") or ""
    if not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    got = auth[7:].strip()
    if not hmac.compare_digest(got, expected):
        raise HTTPException(status_code=401, detail="Invalid service token")


def service_identity() -> ServiceIdentity:
    settings = get_settings()
    name = (settings.packages_service_user or "").strip()
    if not name:
        raise HTTPException(
            status_code=503,
            detail="PACKAGES_SERVICE_USER not set (NAS username for Package Cycles writes)",
        )
    try:
        pw = pwd.getpwnam(name)
    except KeyError as e:
        raise HTTPException(status_code=503, detail=f"NAS user not found: {name}") from e
    if pw.pw_uid < 1000:
        raise HTTPException(status_code=503, detail="Service user must be a normal NAS account")
    return ServiceIdentity(username=pw.pw_name, uid=pw.pw_uid, gid=pw.pw_gid)


# Producer Packages library + student cycle-stage uploads (sibling folders
# on the InFocus Drive share). PACKAGES_ROOT may add another prefix.
SERVICE_ALLOWED_ROOTS = ("Package Cycles", "Package Storage")


def _allowed_package_roots() -> tuple[str, ...]:
    settings = get_settings()
    extra = (settings.packages_root or "").strip().strip("/")
    roots = list(SERVICE_ALLOWED_ROOTS)
    if extra and extra not in roots:
        roots.append(extra)
    return tuple(roots)


def _shows_root() -> str:
    return (get_settings().shows_root or "").strip().strip("/")


def _under(path: str, root: str) -> bool:
    return path == root or path.startswith(root + "/")


def _normalize_service_path(rel: str) -> str:
    """Strip slashes and `.` segments; refuse `..` traversal. "" stays ""."""
    rel = (rel or "").strip().lstrip("/")
    parts = [p for p in rel.replace("\\", "/").split("/") if p and p != "."]
    if any(p == ".." for p in parts):
        raise HTTPException(status_code=400, detail="Invalid path")
    return "/".join(parts)


def assert_under_packages_root(rel: str) -> str:
    """Normalize and ensure path is under Package Cycles or Package Storage.

    This is the write check: the read-only Shows root is refused here even if
    it were configured under a package root.
    """
    roots = _allowed_package_roots()
    if not (rel or "").strip().lstrip("/"):
        return roots[0]
    joined = _normalize_service_path(rel)
    shows = _shows_root()
    if shows and _under(joined, shows):
        raise HTTPException(status_code=403, detail=f"{shows}/ is read-only for the service API")
    if any(_under(joined, root) for root in roots):
        return joined
    shown = " or ".join(f"{root}/" for root in roots)
    raise HTTPException(status_code=403, detail=f"Path must be under {shown}")


def assert_readable_service_path(rel: str) -> str:
    """Read check: the package roots plus the read-only Shows root."""
    joined = _normalize_service_path(rel)
    shows = _shows_root()
    if joined and shows and _under(joined, shows):
        return joined
    roots = _allowed_package_roots()
    if not (rel or "").strip().lstrip("/") or any(_under(joined, root) for root in roots):
        return assert_under_packages_root(rel)
    shown = " or ".join(f"{root}/" for root in (*roots, *((shows,) if shows else ())))
    raise HTTPException(status_code=403, detail=f"Path must be under {shown}")


def _assert_token_path(rel_path: str, purpose: str) -> str:
    if purpose == "r":
        return assert_readable_service_path(rel_path)
    return assert_under_packages_root(rel_path)


def mint_file_token(rel_path: str, *, ttl_seconds: int = 3600, purpose: str = "rw") -> dict[str, Any]:
    """Short-lived HMAC token for browser upload/download of a single path."""
    exp = int(time.time()) + max(60, min(ttl_seconds, 6 * 3600))
    path = _assert_token_path(rel_path, purpose)
    msg = f"{purpose}|{exp}|{path}".encode("utf-8")
    sig = hmac.new(_service_ser_secret(), msg, sha256).hexdigest()
    token = f"{purpose}.{exp}.{sig}"
    return {"token": token, "path": path, "expiresAt": exp, "purpose": purpose}


def verify_file_token(token: str, rel_path: str, *, purpose: str = "rw") -> None:
    try:
        pur, exp_s, sig = token.split(".", 2)
        exp = int(exp_s)
    except (ValueError, AttributeError) as e:
        raise HTTPException(status_code=401, detail="Invalid file token") from e
    if pur != purpose and not (purpose == "r" and pur == "rw"):
        # rw tokens can also read
        if not (pur == "rw" and purpose in ("r", "rw")):
            raise HTTPException(status_code=401, detail="Token purpose mismatch")
    if exp < int(time.time()):
        raise HTTPException(status_code=401, detail="File token expired")
    path = _assert_token_path(rel_path, purpose)
    msg = f"{pur}|{exp}|{path}".encode("utf-8")
    expect = hmac.new(_service_ser_secret(), msg, sha256).hexdigest()
    if not hmac.compare_digest(expect, sig):
        raise HTTPException(status_code=401, detail="Invalid file token")
