"""Terminal (`infocus` CLI) sign-ins: PKCE auth codes and revocable bearer tokens.

Only SHA-256 hashes of codes and tokens are stored. uid/gid are read from
/etc/passwd on every lookup and the uid must match the one the token was
issued to, so a removed (or removed and re-created) NAS user loses access.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import pwd
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from config import get_settings
from fsops import as_root

TOKEN_PREFIX = "ifd_"
CODE_TTL_S = 60
IDLE_TTL_S = 30 * 86400
MAX_AGE_S = 90 * 86400
TOUCH_INTERVAL_S = 60
DEVICE_MAX = 64

_CHALLENGE_RE = re.compile(r"[A-Za-z0-9_-]{43}")
_VERIFIER_RE = re.compile(r"[A-Za-z0-9._~-]{43,128}")


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _pkce_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def valid_challenge(challenge: str) -> bool:
    return bool(_CHALLENGE_RE.fullmatch(challenge or ""))


def clean_device(raw: str | None) -> str:
    text = "".join(ch if ch.isprintable() else " " for ch in (raw or ""))
    text = " ".join(text.split())[:DEVICE_MAX].strip()
    return text or "Unnamed device"


def _nas_account(username: str, uid: int | None = None) -> pwd.struct_passwd | None:
    try:
        pw = pwd.getpwnam(username)
    except KeyError:
        return None
    if pw.pw_uid < 1000 or (uid is not None and pw.pw_uid != uid):
        return None
    return pw


@contextmanager
def _database() -> Iterator[sqlite3.Connection]:
    # as_root: another request thread may be inside fsops.as_user() with a
    # student euid; the root-owned 0600 DB (and its journal) must not race it.
    with as_root(), _connect() as conn:
        yield conn


@contextmanager
def _connect() -> Iterator[sqlite3.Connection]:
    path = Path(get_settings().cli_tokens_db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        with conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS cli_codes (
                code_hash TEXT PRIMARY KEY, username TEXT, uid INTEGER, email TEXT,
                device TEXT, challenge TEXT, expires_at REAL
            )""")
            conn.execute("""CREATE TABLE IF NOT EXISTS cli_tokens (
                id TEXT PRIMARY KEY, token_hash TEXT UNIQUE, username TEXT, uid INTEGER,
                email TEXT, device TEXT, created_at REAL, last_used_at REAL, revoked_at REAL
            )""")
            conn.execute("BEGIN IMMEDIATE")
            yield conn
    finally:
        conn.close()


def issue_code(username: str, email: str, device: str, challenge: str) -> str:
    """Single-use code the approving browser hands to the CLI on 127.0.0.1."""
    if not valid_challenge(challenge):
        raise ValueError("Invalid PKCE challenge")
    account = _nas_account(username)
    if account is None:
        raise ValueError("No InFocus Drive account for this user")
    code = secrets.token_urlsafe(32)
    now = time.time()
    with _database() as conn:
        conn.execute("DELETE FROM cli_codes WHERE expires_at <= ?", (now,))
        conn.execute(
            "INSERT INTO cli_codes VALUES (?, ?, ?, ?, ?, ?, ?)",
            (_hash(code), username, account.pw_uid, email or "", clean_device(device), challenge,
             now + CODE_TTL_S),
        )
    return code


def redeem_code(code: str, verifier: str) -> dict[str, Any] | None:
    """Trade a code + PKCE verifier for a new token. Any attempt burns the code."""
    if not code or not _VERIFIER_RE.fullmatch(verifier or ""):
        return None
    now = time.time()
    with _database() as conn:
        row = conn.execute("SELECT * FROM cli_codes WHERE code_hash = ?", (_hash(code),)).fetchone()
        if row is None:
            return None
        conn.execute("DELETE FROM cli_codes WHERE code_hash = ?", (row["code_hash"],))
        if row["expires_at"] <= now or not hmac.compare_digest(row["challenge"], _pkce_challenge(verifier)):
            return None
        if _nas_account(row["username"], row["uid"]) is None:
            return None
        token = TOKEN_PREFIX + secrets.token_urlsafe(32)
        token_id = secrets.token_hex(8)
        conn.execute(
            "INSERT INTO cli_tokens VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)",
            (token_id, _hash(token), row["username"], row["uid"], row["email"], row["device"], now, now),
        )
    return {"token": token, "id": token_id, "username": row["username"], "device": row["device"]}


def lookup(token: str) -> dict[str, Any] | None:
    """Session-shaped user dict for a live token, else None."""
    if not token or not token.startswith(TOKEN_PREFIX):
        return None
    now = time.time()
    with _database() as conn:
        row = conn.execute(
            "SELECT * FROM cli_tokens WHERE token_hash = ? AND revoked_at IS NULL", (_hash(token),)
        ).fetchone()
        if row is None or now - row["last_used_at"] >= IDLE_TTL_S or now - row["created_at"] >= MAX_AGE_S:
            return None
        pw = _nas_account(row["username"], row["uid"])
        if pw is None:
            return None
        if now - row["last_used_at"] >= TOUCH_INTERVAL_S:
            conn.execute("UPDATE cli_tokens SET last_used_at = ? WHERE id = ?", (now, row["id"]))
    return {
        "email": row["email"],
        "name": pw.pw_name,
        "picture": None,
        "username": pw.pw_name,
        "uid": pw.pw_uid,
        "gid": pw.pw_gid,
        "cli_token_id": row["id"],
    }


def list_for(username: str) -> list[dict[str, Any]]:
    now = time.time()
    with _database() as conn:
        rows = conn.execute(
            """SELECT id, device, created_at, last_used_at FROM cli_tokens
               WHERE username = ? AND revoked_at IS NULL
                 AND last_used_at > ? AND created_at > ?
               ORDER BY last_used_at DESC""",
            (username, now - IDLE_TTL_S, now - MAX_AGE_S),
        ).fetchall()
    return [dict(row) for row in rows]


def revoke(token_id: str, username: str) -> bool:
    with _database() as conn:
        cur = conn.execute(
            "UPDATE cli_tokens SET revoked_at = ? WHERE id = ? AND username = ? AND revoked_at IS NULL",
            (time.time(), token_id, username),
        )
    return cur.rowcount > 0


def revoke_token(token: str) -> bool:
    with _database() as conn:
        cur = conn.execute(
            "UPDATE cli_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL",
            (time.time(), _hash(token or "")),
        )
    return cur.rowcount > 0


def revoke_all(username: str) -> int:
    with _database() as conn:
        cur = conn.execute(
            "UPDATE cli_tokens SET revoked_at = ? WHERE username = ? AND revoked_at IS NULL",
            (time.time(), username),
        )
    return cur.rowcount
