"""Drive members a team project can invite: the NAS users that sign in to the Drive.

The same accounts sign-in maps to (`users`): NAS users with uid >= 1000 whose passwd
GECOS carries an email. Only usernames and display names leave this module, never
the emails.
"""

from __future__ import annotations

import pwd
import re
from pathlib import Path

from users import _HOST_PASSWD, _iter_passwd_file, _Pw, gecos_email
from user_sync import protected_usernames

# Read in order; the host's passwd (a directory bind, see `users`) wins when mounted.
PASSWD_FILES: tuple[Path, ...] = (_HOST_PASSWD,)
MIN_UID = 1000
MAX_UID = 60000  # nobody / nfsnobody and other system ids sit above
MAX_NAME_LEN = 80
USERNAME = re.compile(r"^[a-z0-9_][a-z0-9_.-]{0,31}$")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def display_name(username: str, gecos: str) -> str:
    """The person's name from GECOS (`Name <email>` or `Name,…`), else the username."""
    raw = (gecos or "").strip()
    if "<" in raw:
        name = raw.split("<", 1)[0]
    else:
        name = next((f for f in raw.split(",") if f.strip() and "@" not in f), "")
    name = _CONTROL.sub("", name).strip()[:MAX_NAME_LEN].strip()
    return name or username


def _entries() -> list[_Pw]:
    for path in PASSWD_FILES:
        if path.is_file():
            return _iter_passwd_file(path)
    try:
        return [_Pw(p.pw_name, p.pw_uid, p.pw_gid, p.pw_dir, p.pw_gecos or "") for p in pwd.getpwall()]
    except OSError:
        return []


def directory() -> dict[str, str]:
    """username → display name of every Drive member (tests and the dev server replace this)."""
    skip = protected_usernames()
    out: dict[str, str] = {}
    for pw in _entries():
        if not MIN_UID <= pw.pw_uid < MAX_UID or pw.pw_name in skip:
            continue
        if not USERNAME.match(pw.pw_name) or not gecos_email(pw.pw_gecos):
            continue
        out[pw.pw_name] = display_name(pw.pw_name, pw.pw_gecos)
    return out
