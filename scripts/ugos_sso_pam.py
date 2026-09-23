#!/usr/bin/python3 -I
"""One-use credentials for UGOS's dedicated PAM stack; never accepts Google tokens.

Install root-owned at /usr/local/libexec/infocus-ugos-sso-pam. The trusted
Drive provisioner calls --issue only after Google authentication and mapping.
PAM calls without arguments, passing its credential on stdin. No secrets are
logged; only credential hashes are stored, in a root-only volatile directory.
"""

import hashlib
from contextlib import closing
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import sqlite3
import sys
import time


STATE_DIR = Path("/run/infocus-ugos-sso")
DATABASE = STATE_DIR / "tickets.sqlite3"
PAM_FILE = Path("/etc/pam.d/ugreen-login")
TICKET_RE = re.compile(r"idsso_[A-Za-z0-9_-]{43}\Z")
USERNAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\Z")
LIFETIME = 30


def issue(database, username, uid, *, now=None):
    now = time.time() if now is None else now
    ticket = "idsso_" + secrets.token_urlsafe(32)
    digest = hashlib.sha256(ticket.encode("ascii")).hexdigest()
    with closing(sqlite3.connect(database, timeout=2)) as conn, conn:
        conn.execute("CREATE TABLE IF NOT EXISTS tickets (digest TEXT PRIMARY KEY, username TEXT, uid INTEGER, issued REAL, expires REAL)")
        conn.execute("DELETE FROM tickets WHERE expires <= ?", (now,))
        conn.execute("INSERT INTO tickets VALUES (?, ?, ?, ?, ?)", (digest, username, uid, now, now + LIFETIME))
    return ticket


def consume(database, ticket, username, uid, *, now=None):
    if not TICKET_RE.fullmatch(ticket) or not Path(database).is_file():
        return False
    now = time.time() if now is None else now
    digest = hashlib.sha256(ticket.encode("ascii")).hexdigest()
    try:
        with closing(sqlite3.connect(database, timeout=2)) as conn, conn:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                "DELETE FROM tickets WHERE digest = ? AND username = ? AND uid = ? AND issued <= ? AND expires > ?",
                (digest, username, uid, now, now),
            )
            return cursor.rowcount == 1
    except sqlite3.Error:
        return False


def account_uid(username):
    # Local accounts only. Never turn a locked/expired account into a valid one.
    import spwd

    if not USERNAME_RE.fullmatch(username) or username == "infocus-drive-svc":
        raise ValueError("Account unavailable")
    user = pwd.getpwnam(username)
    shadow = spwd.getspnam(username)
    if not 1000 <= user.pw_uid < 60000 or not shadow.sp_pwdp or shadow.sp_pwdp[0] in "!*":
        raise ValueError("Account unavailable")
    if shadow.sp_expire >= 0 and time.time() // 86400 >= shadow.sp_expire:
        raise ValueError("Account unavailable")
    return user.pw_uid


def pam_ready(config, helper):
    # A firmware update may restore the vendor stack. Do not submit credentials
    # that UGOS can no longer recognize, which would count as failed passwords.
    for line in config.read_text().splitlines():
        parts = shlex.split(line, comments=True)
        if "pam_exec.so" in parts and str(helper) in parts and "expose_authtok" in parts:
            return True
    return False


def main():
    if os.getuid() != 0 or os.geteuid() != 0:
        return 1
    os.umask(0o077)
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--issue":
            if not pam_ready(PAM_FILE, Path(__file__).resolve()):
                return 1
            username = sys.argv[2]
            uid = account_uid(username)
            STATE_DIR.mkdir(mode=0o700, exist_ok=True)
            st = STATE_DIR.lstat()
            if STATE_DIR.is_symlink() or st.st_uid != 0 or st.st_mode & 0o077:
                return 1
            print(issue(DATABASE, username, uid))
            return 0
        if len(sys.argv) != 1 or os.environ.get("PAM_SERVICE") != "ugreen-login" or os.environ.get("PAM_TYPE") != "auth":
            return 1
        ticket = sys.stdin.buffer.read(128).rstrip(b"\0").decode("ascii")
        if not TICKET_RE.fullmatch(ticket):
            return 1
        username = os.environ.get("PAM_USER", "")
        uid = account_uid(username)
        return 0 if consume(DATABASE, ticket, username, uid) else 1
    except (OSError, ValueError, KeyError, sqlite3.Error):
        return 1


if __name__ == "__main__":
    sys.exit(main())
