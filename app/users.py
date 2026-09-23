"""Map Google email → local NAS (Linux) username / uid / gid."""

from __future__ import annotations

import json
import pwd
from dataclasses import dataclass
from pathlib import Path

from config import get_settings


@dataclass(frozen=True)
class NasUser:
    username: str
    uid: int
    gid: int
    home: str
    email: str


def _load_overrides() -> dict[str, str]:
    """Optional map: full email (lower) → NAS username."""
    path = Path(get_settings().user_map_path)
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return {}
        return {str(k).lower(): str(v) for k, v in data.items()}
    except (OSError, json.JSONDecodeError):
        return {}


# Directory bind of host /etc — file binds of /etc/passwd go stale after UGOS useradd
# (atomic rename). Opening /host-etc/passwd does a fresh directory lookup.
_HOST_PASSWD = Path("/host-etc/passwd")


@dataclass(frozen=True)
class _Pw:
    pw_name: str
    pw_uid: int
    pw_gid: int
    pw_dir: str
    pw_gecos: str = ""


def gecos_email(gecos: str) -> str | None:
    """Email stored on the NAS user (passwd GECOS), or None."""
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


def _parse_passwd_line(line: str) -> _Pw | None:
    parts = line.split(":")
    if len(parts) < 6:
        return None
    try:
        uid, gid = int(parts[2]), int(parts[3])
    except ValueError:
        return None
    name = parts[0]
    return _Pw(
        pw_name=name,
        pw_uid=uid,
        pw_gid=gid,
        pw_dir=parts[5] or f"/home/{name}",
        pw_gecos=parts[4] if len(parts) > 4 else "",
    )


def _iter_passwd_file(path: Path) -> list[_Pw]:
    if not path.is_file():
        return []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    out: list[_Pw] = []
    for line in text.splitlines():
        pw = _parse_passwd_line(line)
        if pw is not None:
            out.append(pw)
    return out


def _user_from_passwd_file(path: Path, name: str) -> _Pw | None:
    if not name:
        return None
    for pw in _iter_passwd_file(path):
        if pw.pw_name == name:
            return pw
    return None


def _user_from_passwd_email(path: Path, email: str) -> _Pw | None:
    want = (email or "").strip().lower()
    if not want or "@" not in want:
        return None
    for pw in _iter_passwd_file(path):
        if pw.pw_uid < 1000:
            continue
        if gecos_email(pw.pw_gecos) == want:
            return pw
    return None


def _pwd_user(name: str) -> pwd.struct_passwd | _Pw | None:
    host = _user_from_passwd_file(_HOST_PASSWD, name)
    if host is not None:
        return host
    try:
        return pwd.getpwnam(name)
    except KeyError:
        return None


def linux_user_email(name: str) -> str | None:
    pw = _pwd_user(name)
    if pw is None:
        return None
    return gecos_email(getattr(pw, "pw_gecos", "") or "")


def linux_user_by_email(email: str) -> _Pw | None:
    """NAS user whose stored email matches, else None. Never local-part fallback."""
    host = _user_from_passwd_email(_HOST_PASSWD, email)
    if host is not None:
        return host
    want = (email or "").strip().lower()
    if not want or "@" not in want:
        return None
    try:
        for pw in pwd.getpwall():
            if pw.pw_uid < 1000:
                continue
            if gecos_email(pw.pw_gecos) == want:
                return _Pw(
                    pw_name=pw.pw_name,
                    pw_uid=pw.pw_uid,
                    pw_gid=pw.pw_gid,
                    pw_dir=pw.pw_dir or f"/home/{pw.pw_name}",
                    pw_gecos=pw.pw_gecos or "",
                )
    except OSError:
        return None
    return None


def _csv_lower(raw: str) -> set[str]:
    return {p.strip().lower() for p in (raw or "").split(",") if p.strip()}


def _allowed_domains() -> list[str]:
    return [
        d.strip().lower().lstrip("@")
        for d in get_settings().allowed_email_domains.split(",")
        if d.strip()
    ]


def split_email(email: str) -> tuple[str, str] | None:
    email = (email or "").strip().lower()
    if not email or "@" not in email:
        return None
    local, domain = email.split("@", 1)
    if not local or not domain:
        return None
    return local, domain


def username_candidates(
    email: str, *, extra_allow_emails: set[str] | None = None
) -> list[str]:
    """NAS usernames this Google email may map to, in priority order."""
    parts = split_email(email)
    if parts is None:
        return []
    local, domain = parts
    email = f"{local}@{domain}"
    domains = _allowed_domains()
    overrides = _load_overrides()
    mapped = email in overrides
    domain_ok = (not domains) or (domain in domains)
    rostered = bool(extra_allow_emails) and email in extra_allow_emails

    # External domains only if mapped or on the packages roster.
    if not domain_ok and not mapped and not rostered:
        return []

    candidates: list[str] = []
    if mapped:
        candidates.append(overrides[email])
    # Allowed domains and rostered (unmapped) emails use local-part.
    # Mapped external emails use the override name only.
    if domain_ok or (rostered and not mapped):
        candidates.append(local)

    seen: set[str] = set()
    out: list[str] = []
    for name in candidates:
        if not name or name in seen:
            continue
        seen.add(name)
        out.append(name)
    return out


def planned_nas_username(
    email: str, *, extra_allow_emails: set[str] | None = None
) -> str | None:
    """Username we would create/look up. Does not check /etc/passwd."""
    names = username_candidates(email, extra_allow_emails=extra_allow_emails)
    return names[0] if names else None


def linux_user_exists(name: str) -> bool:
    pw = _pwd_user(name)
    return pw is not None and pw.pw_uid >= 1000


def _email_is_allowed(email: str, extra_allow_emails: set[str] | None) -> bool:
    parts = split_email(email)
    if parts is None:
        return False
    local, domain = parts
    email = f"{local}@{domain}"
    domains = _allowed_domains()
    domain_ok = (not domains) or (domain in domains)
    mapped = email in _load_overrides()
    rostered = bool(extra_allow_emails) and email in extra_allow_emails
    protected = email in _csv_lower(get_settings().user_sync_protected_emails)
    return domain_ok or mapped or rostered or protected


def _nas_from_pw(pw: pwd.struct_passwd | _Pw, email: str) -> NasUser | None:
    if pw.pw_uid < 1000:
        return None
    return NasUser(
        username=pw.pw_name,
        uid=pw.pw_uid,
        gid=pw.pw_gid,
        home=pw.pw_dir,
        email=email,
    )


def resolve_nas_user(
    email: str, *, extra_allow_emails: set[str] | None = None
) -> NasUser | None:
    """
    Resolve NAS account for a Google email.

    Login identity is the email stored on the NAS user (passwd GECOS), not the
    local-part of the address. user_map.json and protected admin emails still
    map by configured username.
    """
    parts = split_email(email)
    if parts is None:
        return None
    local, domain = parts
    email = f"{local}@{domain}"
    if not _email_is_allowed(email, extra_allow_emails):
        return None

    overrides = _load_overrides()
    if email in overrides:
        pw = _pwd_user(overrides[email])
        if pw is not None:
            return _nas_from_pw(pw, email)

    pw = linux_user_by_email(email)
    if pw is not None:
        return _nas_from_pw(pw, email)

    # Protected admins were created in UGOS without an email on the account.
    if email in _csv_lower(get_settings().user_sync_protected_emails):
        pw = _pwd_user(local)
        if pw is not None:
            return _nas_from_pw(pw, email)
    return None
