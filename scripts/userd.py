#!/usr/bin/env python3
"""Host-namespace NAS user provisioner.

Listens on 127.0.0.1 only. Creates Linux + Samba accounts the same way UGOS
does (useradd / usermod / smbpasswd) via nsenter into PID 1. Create-if-missing;
never updates, deletes, or touches protected usernames.
"""

from __future__ import annotations

import hmac
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

USERNAME_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$")
PLACEHOLDER_GECOS = "UGREEN USER"
SHELL = "/bin/bash"
UID_MIN = 1000
UID_MAX = 59999
INCR_PATH = os.environ.get("USERD_UID_INCR", "/ugreen/.config/userid.incr")
PRIMARY_GID = int(os.environ.get("USERD_PRIMARY_GID", "100"))
BIND = os.environ.get("USERD_BIND", "127.0.0.1")
PORT = int(os.environ.get("USERD_PORT", "8791"))


def protected_usernames() -> set[str]:
    raw = os.environ.get("USER_SYNC_PROTECTED_USERNAMES", "")
    return {p.strip().lower() for p in raw.split(",") if p.strip()} | {"infocus-drive-svc"}


def allowed_groups() -> set[str]:
    """Groups POST /users may add a new account to — the sync group, never admin."""
    raw = os.environ.get("USERD_ALLOWED_GROUPS") or os.environ.get("UGOS_SYNC_GROUP") or "InFocus Members"
    return {g.strip() for g in raw.split(",") if g.strip() and g.strip().lower() != "admin"}


def valid_username(name: str) -> bool:
    return bool(name) and bool(USERNAME_RE.match(name)) and name[0] not in ".-"


def allocate_uid(existing: list[int], incr: int | None) -> int:
    taken = {u for u in existing if UID_MIN <= u <= UID_MAX}
    start = incr if incr and incr >= UID_MIN else UID_MIN
    if taken:
        start = max(start, max(taken) + 1)
    uid = start
    while uid in taken:
        uid += 1
    if uid > UID_MAX:
        raise RuntimeError("no free uid in range")
    return uid


def host_run(args: list[str], *, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
    cmd = ["nsenter", "-t", "1", "-m", "-u", "-i", "--", *args]
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)


def host_ok(args: list[str], *, stdin: str | None = None) -> tuple[bool, str]:
    proc = host_run(args, stdin=stdin)
    err = (proc.stderr or proc.stdout or "").strip()
    return proc.returncode == 0, err


def gecos_email(gecos: str) -> str | None:
    raw = (gecos or "").strip()
    if not raw:
        return None
    lower = raw.lower()
    if "<" in lower and ">" in lower:
        inner = lower.split("<", 1)[1].split(">", 1)[0].strip()
        if "@" in inner and " " not in inner:
            return inner
    token = lower.split(",")[0].strip()
    if "@" in token and " " not in token:
        return token
    return None


def parse_passwd(text: str) -> list[tuple[str, int, str]]:
    out: list[tuple[str, int, str]] = []
    for line in text.splitlines():
        parts = line.split(":")
        if len(parts) < 3:
            continue
        try:
            uid = int(parts[2])
        except ValueError:
            continue
        gecos = parts[4] if len(parts) > 4 else ""
        out.append((parts[0], uid, gecos))
    return out


def linux_users() -> dict[str, int]:
    proc = host_run(["/usr/bin/getent", "passwd"])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "getent passwd failed")
    return {name: uid for name, uid, _gecos in parse_passwd(proc.stdout) if UID_MIN <= uid <= UID_MAX}


def linux_user_rows() -> list[dict[str, str | int]]:
    proc = host_run(["/usr/bin/getent", "passwd"])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "getent passwd failed")
    rows: list[dict[str, str | int]] = []
    for name, uid, gecos in parse_passwd(proc.stdout):
        if uid < UID_MIN or uid > UID_MAX:
            continue
        rows.append({"username": name, "uid": uid, "email": gecos_email(gecos) or ""})
    return rows


def user_for_email(email: str) -> str | None:
    want = (email or "").strip().lower()
    if not want or "@" not in want:
        return None
    for row in linux_user_rows():
        if str(row.get("email") or "") == want:
            return str(row["username"])
    return None


def read_incr() -> int | None:
    proc = host_run(["/bin/cat", INCR_PATH])
    if proc.returncode != 0:
        return None
    try:
        return int((proc.stdout or "").strip())
    except ValueError:
        return None


def write_incr(next_uid: int) -> None:
    host_run(
        ["/bin/sh", "-c", f"printf '%s\\n' '{int(next_uid)}' > '{INCR_PATH}'"],
    )


def create_user(
    username: str, password: str, groups: list[str], email: str = ""
) -> dict:
    if not valid_username(username):
        return {"status": "skipped_invalid", "username": username}
    if username.lower() in protected_usernames():
        return {"status": "skipped_protected", "username": username}

    email = (email or "").strip().lower()
    if email and "@" not in email:
        email = ""
    if email:
        owner = user_for_email(email)
        if owner:
            existing = linux_users()
            return {
                "status": "exists",
                "username": owner,
                "uid": existing.get(owner, 0),
                "email": email,
            }

    existing = linux_users()
    if username in existing:
        return {"status": "exists", "username": username, "uid": existing[username]}

    uid = allocate_uid(list(existing.values()), read_incr())
    comment = email if email else PLACEHOLDER_GECOS
    # -M / no home: do not enable UGOS personal folder.
    ok, err = host_ok(
        [
            "/usr/sbin/useradd",
            "-u",
            str(uid),
            "-g",
            str(PRIMARY_GID),
            "-c",
            comment,
            "-d",
            "/",
            "-M",
            "-s",
            SHELL,
            username,
        ]
    )
    if not ok:
        # Race: another admin created it.
        existing = linux_users()
        if username in existing:
            return {"status": "exists", "username": username, "uid": existing[username]}
        return {"status": "error", "username": username, "detail": err or "useradd failed"}

    if password:
        host_ok(["/usr/sbin/chpasswd"], stdin=f"{username}:{password}\n")
        host_ok(["/usr/bin/smbpasswd", "-a", "-s", username], stdin=f"{password}\n{password}\n")

    allowed = allowed_groups()
    for group in groups:
        g = (group or "").strip()
        if g in allowed:
            host_ok(["/usr/sbin/usermod", "-aG", g, username])

    write_incr(uid + 1)
    return {"status": "created", "username": username, "uid": uid, "email": email}


def set_user_email(username: str, email: str) -> dict:
    if not valid_username(username):
        return {"status": "skipped_invalid", "username": username}
    if username.lower() in protected_usernames():
        return {"status": "skipped_protected", "username": username}
    email = (email or "").strip().lower()
    if not email or "@" not in email:
        return {"status": "skipped_invalid", "username": username}
    existing = linux_users()
    if username not in existing:
        return {"status": "absent", "username": username}
    owner = user_for_email(email)
    if owner and owner != username:
        return {"status": "exists", "username": owner, "email": email}
    ok, err = host_ok(["/usr/sbin/usermod", "-c", email, username])
    if not ok:
        return {"status": "error", "username": username, "detail": err or "usermod failed"}
    return {"status": "updated", "username": username, "email": email, "uid": existing[username]}


def delete_user(username: str) -> dict:
    if not valid_username(username):
        return {"status": "skipped_invalid", "username": username}
    if username.lower() in protected_usernames():
        return {"status": "skipped_protected", "username": username}

    existing = linux_users()
    if username not in existing:
        return {"status": "absent", "username": username}

    host_ok(["/usr/bin/smbpasswd", "-x", username])
    host_ok(["/usr/bin/pdbedit", "-x", "-u", username])
    ok, err = host_ok(["/usr/sbin/userdel", username])
    if not ok:
        ok, err = host_ok(["/usr/sbin/userdel", "-f", username])
    if username in linux_users():
        return {"status": "error", "username": username, "detail": err or "userdel failed"}
    return {"status": "deleted", "username": username}


def shadow_hash(username: str) -> str | None:
    proc = host_run(["/usr/bin/getent", "shadow", username])
    if proc.returncode != 0:
        return None
    parts = (proc.stdout or "").split(":")
    if len(parts) < 2:
        return None
    hashed = parts[1].strip()
    return hashed or None


def _crypt_match(password: str, hashed: str) -> bool:
    try:
        import crypt

        got = crypt.crypt(password, hashed)
        if got:
            return hmac.compare_digest(got, hashed)
    except Exception:
        pass
    proc = host_run(
        [
            "/usr/bin/python3",
            "-c",
            "import crypt,hmac,sys\nh=sys.argv[1]; p=sys.stdin.read()\n"
            "g=crypt.crypt(p,h)\nsys.exit(0 if g and hmac.compare_digest(g,h) else 1)",
            hashed,
        ],
        stdin=password,
    )
    return proc.returncode == 0


def otp_required(username: str, uid: int | None = None) -> bool:
    """UGOS 2FA flag is an empty file: /ugreen/.config/.nas/{uid|username}/use_2fa."""
    paths: list[str] = []
    if uid is not None:
        paths.append(f"/ugreen/.config/.nas/{int(uid)}/use_2fa")
    if username:
        paths.append(f"/ugreen/.config/.nas/{username}/use_2fa")
    for path in paths:
        proc = host_run(["/usr/bin/test", "-e", path])
        if proc.returncode == 0:
            return True
    return False


def verify_password(username: str, password: str) -> dict:
    """Check username/password against host /etc/shadow. Never logs the password."""
    if not valid_username(username) or not password:
        return {"status": "denied"}
    existing = linux_users()
    if username not in existing:
        return {"status": "denied"}
    hashed = shadow_hash(username)
    if not hashed or hashed[0] in "*!":
        return {"status": "denied"}
    if not _crypt_match(password, hashed):
        return {"status": "denied"}
    uid = existing[username]
    return {
        "status": "ok",
        "username": username,
        "uid": uid,
        "otp_required": otp_required(username, uid),
    }


def token_ok(header: str) -> bool:
    expected = (os.environ.get("USERD_TOKEN") or "").strip()
    if not expected:
        return False
    if not header.startswith("Bearer "):
        return False
    return hmac.compare_digest(header[len("Bearer ") :].strip().encode(), expected.encode())


def issue_ugos_ticket(username: str, uid: int) -> dict:
    """Issue a one-use PAM credential, without changing passwords or bypassing OTP."""
    error = "UGOS ticket unavailable"
    if (
        not isinstance(username, str)
        or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}", username)
        or username.lower() == "infocus-drive-svc"
        or type(uid) is not int
        or not UID_MIN <= uid <= UID_MAX
    ):
        raise ValueError(error)
    prefix = ["nsenter", "-t", "1", "-m", "-u", "-i", "--"]
    try:
        account = subprocess.run(
            [*prefix, "/usr/bin/getent", "-s", "files", "passwd", username],
            capture_output=True, text=True, check=False, timeout=5,
        )
        rows = account.stdout.splitlines()
        if account.returncode != 0 or len(rows) != 1:
            raise ValueError(error)
        fields = rows[0].split(":")
        if (
            len(fields) != 7 or fields[0] != username or int(fields[2]) != uid
            or not fields[6] or fields[6].rsplit("/", 1)[-1] in ("nologin", "false")
        ):
            raise ValueError(error)
        issued = subprocess.run(
            [*prefix, "/usr/bin/python3", "-I",
             "/usr/local/libexec/infocus-ugos-sso-pam", "--issue", username],
            capture_output=True, text=True, check=False, timeout=5,
        )
        credential = issued.stdout.rstrip("\n")
        if issued.returncode != 0 or not re.fullmatch(r"idsso_[A-Za-z0-9_-]{43}", credential):
            raise RuntimeError(error)
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise RuntimeError(error) from None
    except ValueError:
        raise ValueError(error) from None
    return {"status": "ok", "credential": credential, "uid": uid}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        sys_stderr = __import__("sys").stderr
        sys_stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _json(self, code: int, body: dict) -> None:
        raw = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            self._json(200, {"status": "ok"})
            return
        if path == "/users":
            if not token_ok(self.headers.get("Authorization") or ""):
                self._json(401, {"status": "error", "detail": "unauthorized"})
                return
            try:
                users = linux_user_rows()
            except RuntimeError as e:
                self._json(500, {"status": "error", "detail": str(e)})
                return
            self._json(200, {"users": users})
            return
        self._json(404, {"status": "error", "detail": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path not in ("/users", "/users/email", "/auth", "/ugos-sso/ticket"):
            self._json(404, {"status": "error", "detail": "not found"})
            return
        if not token_ok(self.headers.get("Authorization") or ""):
            self._json(401, {"status": "error", "detail": "unauthorized"})
            return
        if path == "/ugos-sso/ticket":
            try:
                length = int(self.headers.get("Content-Length") or "0")
                if not 0 < length <= 4096:
                    raise ValueError
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError
                result = issue_ugos_ticket(payload.get("username"), payload.get("uid"))
            except (ValueError, UnicodeError):
                self._json(400, {"status": "error", "detail": "UGOS ticket unavailable"})
                return
            except RuntimeError:
                self._json(503, {"status": "error", "detail": "UGOS ticket unavailable"})
                return
            self._json(200, result)
            return
        length = int(self.headers.get("Content-Length") or "0")
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"status": "error", "detail": "invalid json"})
            return
        if not isinstance(payload, dict):
            self._json(400, {"status": "error", "detail": "invalid json"})
            return
        username = str(payload.get("username") or "").strip()
        password = str(payload.get("password") or "")
        email = str(payload.get("email") or "").strip()
        groups = payload.get("groups") or []
        if isinstance(groups, str):
            groups = [groups]
        if not isinstance(groups, list):
            groups = []
        groups = [str(g) for g in groups]
        try:
            if path == "/auth":
                result = verify_password(username, password)
            elif path == "/users/email":
                result = set_user_email(username, email)
            else:
                result = create_user(username, password, groups, email=email)
        except RuntimeError as e:
            self._json(500, {"status": "error", "detail": str(e)})
            return
        self._json(_status_code(result), result)

    def do_DELETE(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path != "/users":
            self._json(404, {"status": "error", "detail": "not found"})
            return
        if not token_ok(self.headers.get("Authorization") or ""):
            self._json(401, {"status": "error", "detail": "unauthorized"})
            return
        length = int(self.headers.get("Content-Length") or "0")
        try:
            payload = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except json.JSONDecodeError:
            self._json(400, {"status": "error", "detail": "invalid json"})
            return
        if not isinstance(payload, dict):
            self._json(400, {"status": "error", "detail": "invalid json"})
            return
        username = str(payload.get("username") or "").strip()
        try:
            result = delete_user(username)
        except RuntimeError as e:
            self._json(500, {"status": "error", "detail": str(e)})
            return
        self._json(_status_code(result), result)


def _status_code(result: dict) -> int:
    status = str(result.get("status") or "")
    if status == "error":
        return 500
    if status == "skipped_invalid":
        return 400
    if status == "skipped_protected":
        return 403
    if status == "denied":
        return 200
    return 200


def main() -> None:
    if not (os.environ.get("USERD_TOKEN") or "").strip():
        raise SystemExit("USERD_TOKEN is required")
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"userd listening on {BIND}:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
