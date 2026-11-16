"""Dev-only InFocus Drive for the InFocus Cut team-editing end-to-end check.

Starts the real FastAPI app with uvicorn on 127.0.0.1 only, over a throwaway drive root, with three
fictional members (`student1`, `student2`, `student3`) whose `ifd_` CLI tokens are written to files. It uses
the same stand-ins as `tests/test_team_projects.py`: the token lookup is a fixed table (no NAS
accounts), only the fictional `teacher1` is an admin, and it runs unprivileged, so `fsops.as_user` / `as_root` do
nothing (the setuid switch only happens as root).

Never for production. It refuses to start unless `INFOCUS_DEV_E2E=1`, refuses to run as root,
and binds only to the loopback address.

    INFOCUS_DEV_E2E=1 .venv/bin/python scripts/dev/team_e2e_server.py --dir /tmp/x --port 8791

Writes `<dir>/student1.token`, `<dir>/student2.token` and `<dir>/student3.token` (mode 0600), keeps the drive root in
`<dir>/drive` and the databases in `<dir>/config`, and prints `READY http://127.0.0.1:<port>` once
it answers. For the editing dashboard in a browser, open
`<url>/dev/sign-in?user=student1&next=/editing` (or `teacher1`, the admin) instead of Google.
`INFOCUS_DEV_TEAM_LOCK_TTL_S` shortens the lock expiry (default 120 s).
"""

from __future__ import annotations

import argparse
import os
import secrets
import sys
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any

from fastapi import HTTPException, Request
from fastapi.responses import RedirectResponse

LOOPBACK = "127.0.0.1"
ENABLE_ENV = "INFOCUS_DEV_E2E"
TTL_ENV = "INFOCUS_DEV_TEAM_LOCK_TTL_S"
USERS: dict[str, dict[str, Any]] = {
    "student1": {"username": "student1", "uid": 1001, "gid": 100, "email": "student1@example.org",
                 "name": "Student One"},
    "student2": {"username": "student2", "uid": 1002, "gid": 100, "email": "student2@example.org",
                 "name": "Student Two"},
    "student3": {"username": "student3", "uid": 1003, "gid": 100, "email": "student3@example.org",
                 "name": "Student Three"},
}
# A fictional Drive admin for the editing dashboard's "All projects" view. Browser only: no
# token file, and not in the invite directory.
ADMIN: dict[str, Any] = {"username": "teacher1", "uid": 1090, "gid": 100, "email": "teacher1@example.org",
                         "name": "Teacher One"}
APP_DIR = Path(__file__).resolve().parents[2] / "app"


def refuse(message: str) -> None:
    sys.stderr.write(f"team_e2e_server: {message}\n")
    raise SystemExit(2)


def check_allowed(environ: dict[str, str], uid: int) -> None:
    """Exit unless this is an explicit dev run by an ordinary user."""
    if environ.get(ENABLE_ENV) != "1":
        refuse(f"dev-only server: set {ENABLE_ENV}=1 to run it (never in production)")
    if uid == 0:
        refuse("refusing to run as root (as_user would switch real users)")


def lock_ttl(environ: dict[str, str]) -> int:
    raw = environ.get(TTL_ENV, "120")
    try:
        ttl = int(raw)
    except ValueError:
        refuse(f"{TTL_ENV} must be a whole number of seconds, got {raw!r}")
    if not 1 <= ttl <= 3600:
        refuse(f"{TTL_ENV} must be between 1 and 3600")
    return ttl


def prepare(base: Path, port: int, ttl: int) -> dict[str, str]:
    """Create the dirs and set the app's environment (before `main` is imported). Returns the
    token of each member."""
    drive = base / "drive"
    config = base / "config"
    for d in (drive, config, base / "chunks"):
        d.mkdir(parents=True, exist_ok=True)
    env = {
        "PUBLIC_BASE_URL": f"http://{LOOPBACK}:{port}",
        "SESSION_SECRET": secrets.token_urlsafe(48),
        "DRIVE_ROOT": str(drive),
        "CLI_TOKENS_DB_PATH": str(config / "cli_tokens.sqlite3"),
        "TEAM_DB_PATH": str(config / "team_projects.sqlite3"),
        "TEAM_CLEANUP_ENABLED": "0",
        "TEAM_LOCK_TTL_S": str(ttl),
        "IFD_CHUNK_UPLOAD_DIR": str(base / "chunks"),
        "ALLOWED_EMAIL_DOMAINS": "example.org",
    }
    os.environ.update(env)
    tokens = {}
    for name in USERS:
        token = "ifd_" + secrets.token_urlsafe(32)
        path = base / f"{name}.token"
        fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(token)
        tokens[token] = name
    return tokens


def session_user(name: str) -> dict[str, Any] | None:
    """The browser session for `GET /dev/sign-in?user=…` (the dashboard has no tokens)."""
    found = USERS.get(name) or (ADMIN if name == ADMIN["username"] else None)
    return None if found is None else dict(found, picture=None)


def is_admin(name: str) -> bool:
    return name == ADMIN["username"]


def add_dev_sign_in(app: Any, safe_next: Any) -> None:
    """`GET /dev/sign-in?user=student1&next=/editing`: a cookie session as a fictional member,
    standing in for Google sign-in so the editing dashboard can be used in a browser."""
    @app.get("/dev/sign-in")
    def dev_sign_in(request: Request, user: str = "", next: str = "/editing") -> RedirectResponse:
        found = session_user(user)
        if found is None:
            raise HTTPException(status_code=404, detail="No such dev user")
        request.session["user"] = found
        return RedirectResponse(safe_next(next), status_code=303)

    # Ahead of the app's catch-all page route, which would otherwise answer first.
    app.router.routes.insert(0, app.router.routes.pop())


def patch_app(tokens: dict[str, str]) -> Any:
    """Import the app with the test suite's stand-ins for NAS accounts and admins."""
    sys.path.insert(0, str(APP_DIR))
    import cli_tokens
    import main
    import team_people

    def lookup(token: str) -> dict[str, Any] | None:
        name = tokens.get(token)
        return None if name is None else dict(USERS[name], picture=None, cli_token_id=name)

    cli_tokens.lookup = lookup
    team_people.directory = people
    main.is_nas_admin = is_admin
    main.list_shares_for_user = lambda username, uid, gid: []
    add_dev_sign_in(main.app, main._safe_next_url)
    return main.app


def people() -> dict[str, str]:
    """The invite directory (`GET /api/team/people`): the fictional members, no NAS passwd."""
    return {name: str(user["name"]) for name, user in USERS.items()}


def announce_when_ready(url: str) -> None:
    for _ in range(200):
        try:
            with urllib.request.urlopen(url + "/api/health", timeout=1):
                print(f"READY {url}", flush=True)
                return
        except OSError:
            time.sleep(0.05)
    sys.stderr.write("team_e2e_server: the server did not answer\n")


def main_cli(argv: list[str]) -> None:
    check_allowed(dict(os.environ), os.getuid())
    parser = argparse.ArgumentParser(description="Dev-only local InFocus Drive for the team e2e")
    parser.add_argument("--dir", required=True, type=Path, help="throwaway folder for the drive root, databases and tokens")
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args(argv)
    if not 1024 <= args.port <= 65535:
        refuse("--port must be 1024-65535")
    tokens = prepare(args.dir.resolve(), args.port, lock_ttl(dict(os.environ)))
    app = patch_app(tokens)
    import uvicorn

    url = f"http://{LOOPBACK}:{args.port}"
    threading.Thread(target=announce_when_ready, args=(url,), daemon=True).start()
    uvicorn.run(app, host=LOOPBACK, port=args.port, log_level="warning")


if __name__ == "__main__":
    main_cli(sys.argv[1:])
