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


def assert_under_packages_root(rel: str) -> str:
    """Normalize and ensure path is under Package Cycles or Package Storage."""
    roots = _allowed_package_roots()
    rel = (rel or "").strip().lstrip("/")
    if not rel:
        return roots[0]
    # Block traversal
    parts = [p for p in rel.replace("\\", "/").split("/") if p and p != "."]
    if any(p == ".." for p in parts):
        raise HTTPException(status_code=400, detail="Invalid path")
    joined = "/".join(parts)
    if any(joined == root or joined.startswith(root + "/") for root in roots):
        return joined
    shown = " or ".join(f"{root}/" for root in roots)
    raise HTTPException(status_code=403, detail=f"Path must be under {shown}")


def mint_file_token(rel_path: str, *, ttl_seconds: int = 3600, purpose: str = "rw") -> dict[str, Any]:
    """Short-lived HMAC token for browser upload/download of a single path."""
    exp = int(time.time()) + max(60, min(ttl_seconds, 6 * 3600))
    path = assert_under_packages_root(rel_path)
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
    path = assert_under_packages_root(rel_path)
    msg = f"{pur}|{exp}|{path}".encode("utf-8")
    expect = hmac.new(_service_ser_secret(), msg, sha256).hexdigest()
    if not hmac.compare_digest(expect, sig):
        raise HTTPException(status_code=401, detail="Invalid file token")
