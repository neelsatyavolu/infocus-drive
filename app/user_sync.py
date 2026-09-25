"""Create NAS users from the infocus-packages roster. Never duplicate. Never touch protected accounts."""

from __future__ import annotations

import json
import logging
import re
import secrets
import sqlite3
import string
import time
from pathlib import Path
from typing import Any, Callable

import httpx

import cli_tokens
from config import get_settings
from fsops import FSError
from users import (
    NasUser,
    _csv_lower,
    _load_overrides,
    linux_user_by_email,
    linux_user_email,
    linux_user_exists,
    planned_nas_username,
    resolve_nas_user,
    split_email,
)
from ugos_api import UgosClient, UgosError

log = logging.getLogger("user_sync")


class UserdError(RuntimeError):
    pass


class UserdClient:
    """Localhost infocus-userd: host useradd/usermod/smbpasswd."""

    def __init__(self, base_url: str, token: str, timeout: float = 30.0):
        self.base_url = (base_url or "").rstrip("/")
        self.token = token
        self._http = httpx.Client(timeout=timeout)

    def close(self) -> None:
        self._http.close()

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}

    def existing_usernames(self) -> set[str]:
        resp = self._http.get(f"{self.base_url}/users", headers=self._headers())
        if resp.status_code >= 400:
            raise UserdError(resp.text[:300] or f"userd HTTP {resp.status_code}")
        payload = resp.json()
        users = payload.get("users") if isinstance(payload, dict) else payload
        names: set[str] = set()
        if isinstance(users, list):
            for row in users:
                if isinstance(row, dict):
                    name = str(row.get("username") or "").strip()
                    if name:
                        names.add(name)
                elif isinstance(row, str) and row.strip():
                    names.add(row.strip())
        return names

    def existing_emails(self) -> dict[str, str]:
        resp = self._http.get(f"{self.base_url}/users", headers=self._headers())
        if resp.status_code >= 400:
            raise UserdError(resp.text[:300] or f"userd HTTP {resp.status_code}")
        payload = resp.json()
        users = payload.get("users") if isinstance(payload, dict) else payload
        out: dict[str, str] = {}
        if isinstance(users, list):
            for row in users:
                if not isinstance(row, dict):
                    continue
                em = str(row.get("email") or "").strip().lower()
                uname = str(row.get("username") or "").strip()
                if em and "@" in em and uname:
                    out[em] = uname
        return out

    def set_user_email(self, username: str, email: str) -> dict[str, Any]:
        resp = self._http.post(
            f"{self.base_url}/users/email",
            headers=self._headers(),
            json={"username": username, "email": email},
        )
        try:
            data = resp.json()
        except ValueError:
            data = {"status": "error", "detail": resp.text[:300]}
        if not isinstance(data, dict):
            data = {"status": "error", "detail": "userd returned a non-object"}
        if resp.status_code >= 400 and str(data.get("status") or "") == "error":
            raise UserdError(str(data.get("detail") or resp.status_code))
        return data

    def create_user(
        self,
        *,
        username: str,
        password: str,
        email: str,
        description: str,
        groups: list[str],
        **_kwargs: Any,
    ) -> dict[str, Any]:
        resp = self._http.post(
            f"{self.base_url}/users",
            headers=self._headers(),
            json={
                "username": username,
                "password": password,
                "email": email,
                "description": description,
                "groups": groups,
            },
        )
        try:
            data = resp.json()
        except ValueError:
            data = {"status": "error", "detail": resp.text[:300]}
        if not isinstance(data, dict):
            data = {"status": "error", "detail": "userd returned a non-object"}
        status = str(data.get("status") or "")
        if resp.status_code >= 400 and status not in (
            "exists",
            "skipped_protected",
            "skipped_invalid",
        ):
            raise UserdError(str(data.get("detail") or data.get("status") or resp.status_code))
        if status == "error":
            raise UserdError(str(data.get("detail") or "userd create failed"))
        return data

    def verify_password(self, username: str, password: str) -> dict[str, Any]:
        resp = self._http.post(
            f"{self.base_url}/auth",
            headers=self._headers(),
            json={"username": username, "password": password},
        )
        if resp.status_code >= 400:
            raise UserdError(resp.text[:300] or f"userd HTTP {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as e:
            raise UserdError("userd auth returned non-JSON") from e
        if not isinstance(data, dict):
            raise UserdError("userd auth returned a non-object")
        return data

    def issue_ugos_ticket(self, username: str, uid: int) -> dict[str, Any]:
        """Request a short-lived credential for native UGOS login (including OTP)."""
        error = "UGOS ticket unavailable"
        try:
            resp = self._http.post(
                f"{self.base_url}/ugos-sso/ticket",
                headers=self._headers(),
                json={"username": username, "uid": uid},
            )
            if resp.status_code != 200:
                raise UserdError(error)
            data = resp.json()
        except (httpx.HTTPError, ValueError):
            raise UserdError(error) from None
        if (
            not isinstance(data, dict) or data.get("status") != "ok"
            or type(data.get("uid")) is not int or data["uid"] != uid
            or not isinstance(data.get("credential"), str)
            or not re.fullmatch(r"idsso_[A-Za-z0-9_-]{43}", data["credential"])
        ):
            raise UserdError(error)
        return {"status": "ok", "credential": data["credential"], "uid": data["uid"]}

    def delete_user(self, username: str) -> dict[str, Any]:
        resp = self._http.request(
            "DELETE",
            f"{self.base_url}/users",
            headers=self._headers(),
            json={"username": username},
        )
        try:
            data = resp.json()
        except ValueError:
            data = {"status": "error", "detail": resp.text[:300]}
        if not isinstance(data, dict):
            data = {"status": "error", "detail": "userd returned a non-object"}
        status = str(data.get("status") or "")
        if resp.status_code >= 400 and status not in (
            "absent",
            "skipped_protected",
            "skipped_invalid",
        ):
            raise UserdError(str(data.get("detail") or data.get("status") or resp.status_code))
        if status == "error":
            raise UserdError(str(data.get("detail") or "userd delete failed"))
        return data

# UGOS usernames: 1–64 chars; first character cannot be "-".
_USERNAME_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$")

_roster_cache: tuple[float, set[str]] | None = None
_ROSTER_TTL_S = 60.0
_ROSTER_HEADERS_EXTRA = {
    "User-Agent": "InFocusDrive/1.0",
    "Accept": "application/json",
}

UgosFactory = Callable[[], Any]


def protected_usernames() -> set[str]:
    return _csv_lower(get_settings().user_sync_protected_usernames) | {"infocus-drive-svc"}


def protected_emails() -> set[str]:
    return _csv_lower(get_settings().user_sync_protected_emails)


def _snapshot_path() -> Path:
    raw = (get_settings().packages_roster_snapshot_path or "").strip()
    if raw:
        return Path(raw)
    return Path(get_settings().user_map_path).with_name("packages_roster.json")


def load_roster_snapshot() -> set[str]:
    path = _snapshot_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    emails = data.get("emails") if isinstance(data, dict) else data
    out: set[str] = set()
    if isinstance(emails, list):
        for row in emails:
            em = str(row or "").strip().lower()
            if em and "@" in em:
                out.add(em)
    return out


def save_roster_snapshot(emails: set[str]) -> None:
    path = _snapshot_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"emails": sorted(emails)}, indent=2) + "\n",
        encoding="utf-8",
    )


def roster_claimed_usernames(emails: set[str]) -> set[str]:
    claimed: set[str] = set()
    for email in emails:
        name = planned_nas_username(email, extra_allow_emails=emails)
        if name:
            claimed.add(name.lower())
    return claimed


def username_for_email(email: str, roster: set[str]) -> str | None:
    extra = set(roster)
    extra.add(email)
    name = planned_nas_username(email, extra_allow_emails=extra)
    if name:
        return name
    parts = split_email(email)
    return parts[0] if parts else None


def _service_username() -> str:
    return (get_settings().packages_service_user or "").strip().lower()


def is_protected(email: str, username: str | None = None) -> bool:
    parts = split_email(email)
    if parts:
        local, domain = parts
        email = f"{local}@{domain}"
        if email in protected_emails():
            return True
        if local in protected_usernames():
            return True
    if username and username.lower() in protected_usernames():
        return True
    return False


def valid_new_username(name: str) -> bool:
    return bool(name) and bool(_USERNAME_RE.match(name)) and name[0] not in ".-"


def _pausd_email(email: str) -> bool:
    parts = split_email(email)
    if parts is None:
        return False
    return parts[1] in ("pausd.org", "pausd.us")


def allocate_username(email: str, extra_allow: set[str]) -> str | None:
    """Linux username to create. Prefer local-part; never reuse another email's account."""
    preferred = planned_nas_username(email, extra_allow_emails=extra_allow)
    if not preferred or not valid_new_username(preferred):
        return None
    owner = linux_user_by_email(email)
    if owner is not None:
        return owner.pw_name
    if not linux_user_exists(preferred):
        return preferred
    existing_email = linux_user_email(preferred)
    if existing_email == email:
        return preferred
    # Existing UGOS account with no stored email: attach PAUSD roster addresses only.
    if not existing_email and _pausd_email(email):
        return preferred
    parts = split_email(email)
    if parts is None:
        return None
    local, domain = parts
    slug = domain.replace(".", "-")
    base = f"{local}-{slug}"
    if not valid_new_username(base):
        return None
    if not linux_user_exists(base):
        return base
    for i in range(2, 50):
        cand = f"{base}-{i}"
        if valid_new_username(cand) and not linux_user_exists(cand):
            return cand
    return None


def random_nas_password(length: int = 16) -> str:
    """Meet UGOS rules (min 6, mixed case) plus a digit and symbol."""
    special = "!@#$%"
    alphabet = string.ascii_letters + string.digits + special
    while True:
        pwd = "".join(secrets.choice(alphabet) for _ in range(length))
        if (
            any(c.islower() for c in pwd)
            and any(c.isupper() for c in pwd)
            and any(c.isdigit() for c in pwd)
            and any(c in special for c in pwd)
        ):
            return pwd


def fetch_roster_emails(*, force: bool = False) -> set[str]:
    """Packages website users (email lower). Empty if roster is not configured."""
    global _roster_cache
    now = time.time()
    if not force and _roster_cache and now - _roster_cache[0] < _ROSTER_TTL_S:
        return set(_roster_cache[1])
    settings = get_settings()
    url = (settings.packages_roster_url or "").strip()
    token = (settings.packages_service_token or "").strip()
    if not url or not token:
        return set(_roster_cache[1]) if _roster_cache else set()
    try:
        resp = httpx.get(
            url,
            headers={"Authorization": f"Bearer {token}", **_ROSTER_HEADERS_EXTRA},
            timeout=20.0,
        )
        resp.raise_for_status()
        payload = resp.json()
    except (httpx.HTTPError, ValueError) as e:
        log.warning("packages roster fetch failed: %s", e)
        return set(_roster_cache[1]) if _roster_cache else set()
    users = payload.get("users") if isinstance(payload, dict) else payload
    emails: set[str] = set()
    if isinstance(users, list):
        for row in users:
            if isinstance(row, dict):
                em = str(row.get("email") or "").strip().lower()
            else:
                em = str(row or "").strip().lower()
            if em and "@" in em:
                emails.add(em)
    _roster_cache = (now, emails)
    return set(emails)


def fetch_roster_entries() -> list[dict[str, str]]:
    settings = get_settings()
    url = (settings.packages_roster_url or "").strip()
    token = (settings.packages_service_token or "").strip()
    if not url or not token:
        return []
    try:
        resp = httpx.get(
            url,
            headers={"Authorization": f"Bearer {token}", **_ROSTER_HEADERS_EXTRA},
            timeout=20.0,
        )
        resp.raise_for_status()
        payload = resp.json()
    except (httpx.HTTPError, ValueError) as e:
        log.warning("packages roster fetch failed: %s", e)
        return []
    users = payload.get("users") if isinstance(payload, dict) else payload
    out: list[dict[str, str]] = []
    seen: set[str] = set()
    if isinstance(users, list):
        for row in users:
            if not isinstance(row, dict):
                continue
            em = str(row.get("email") or "").strip().lower()
            if not em or "@" not in em or em in seen:
                continue
            seen.add(em)
            out.append({"email": em, "name": str(row.get("name") or "").strip()})
    return out


def _client_factory() -> Any:
    s = get_settings()
    if (s.userd_token or "").strip():
        return UserdClient(s.userd_url, s.userd_token)
    return UgosClient(s.ugos_api_url, s.ugos_admin_user, s.ugos_admin_password)


def ensure_user(
    email: str,
    name: str = "",
    *,
    roster: set[str] | None = None,
    ugos: UgosClient | None = None,
    ugos_usernames: set[str] | None = None,
    ugos_emails: dict[str, str] | None = None,
    close_ugos: bool = False,
) -> dict[str, Any]:
    """Create the NAS user if missing. Never modifies an existing account."""
    parts = split_email(email)
    if parts is None:
        return {"email": email, "status": "skipped_invalid"}
    local, domain = parts
    email = f"{local}@{domain}"

    extra = roster if roster is not None else {email}
    owner = linux_user_by_email(email)
    if owner is not None:
        return {"email": email, "username": owner.pw_name, "status": "exists"}
    if ugos_emails is not None and email in ugos_emails:
        return {
            "email": email,
            "username": ugos_emails[email],
            "status": "exists",
        }
    username = allocate_username(email, extra)
    if not username:
        return {"email": email, "status": "skipped_invalid"}
    if is_protected(email, username):
        return {"email": email, "username": username, "status": "skipped_protected"}
    if not valid_new_username(username):
        return {"email": email, "username": username, "status": "skipped_invalid"}

    own = False
    client = ugos
    if client is None:
        s = get_settings()
        if not (s.userd_token or s.ugos_admin_password or "").strip():
            return {"email": email, "username": username, "status": "skipped_unconfigured"}
        client = _client_factory()
        own = True
    try:
        if ugos_usernames is None or ugos_emails is None:
            try:
                names = client.existing_usernames() if hasattr(client, "existing_usernames") else set()
                mails = client.existing_emails() if hasattr(client, "existing_emails") else {}
            except (UgosError, UserdError, httpx.HTTPError) as e:
                log.warning("user list failed (continuing to create): %s", e)
                names, mails = set(), {}
            if email in mails:
                return {"email": email, "username": mails[email], "status": "exists"}
        if linux_user_exists(username) and not linux_user_email(username) and _pausd_email(email):
            if hasattr(client, "set_user_email"):
                client.set_user_email(username, email)
            return {"email": email, "username": username, "status": "exists"}
        group = (get_settings().ugos_sync_group or "").strip()
        groups = [group] if group else []
        created = client.create_user(
            username=username,
            password=random_nas_password(),
            email=email,
            description=name or "InFocus packages",
            groups=groups,
        )
        if isinstance(created, dict) and created.get("status") == "exists":
            if ugos_usernames is not None:
                ugos_usernames.add(username)
            return {"email": email, "username": username, "status": "exists"}
        if ugos_usernames is not None:
            ugos_usernames.add(username)
        if ugos_emails is not None:
            ugos_emails[email] = username
        return {"email": email, "username": username, "status": "created"}
    except (UgosError, UserdError, httpx.HTTPError) as e:
        # Create raced with another admin, or username taken since list.
        msg = str(e).lower()
        if "exist" in msg or "duplicate" in msg or "already" in msg:
            return {"email": email, "username": username, "status": "exists"}
        log.warning("create %s failed: %s", username, e)
        return {"email": email, "username": username, "status": "error", "detail": str(e)}
    finally:
        if own or close_ugos:
            client.close()


def revoke_user(
    email: str,
    *,
    roster: set[str] | None = None,
    ugos: Any | None = None,
    close_ugos: bool = False,
) -> dict[str, Any]:
    """Delete the NAS user for a packages email that is no longer on the roster."""
    parts = split_email(email)
    if parts is None:
        return {"email": email, "status": "skipped_invalid"}
    local, domain = parts
    email = f"{local}@{domain}"
    roster_emails = set(roster) if roster is not None else fetch_roster_emails()
    if email in roster_emails:
        owner = linux_user_by_email(email)
        return {
            "email": email,
            "username": owner.pw_name if owner else username_for_email(email, roster_emails),
            "status": "kept",
        }
    owner = linux_user_by_email(email)
    username = owner.pw_name if owner is not None else username_for_email(email, roster_emails)
    if not username:
        return {"email": email, "status": "skipped_invalid"}
    if is_protected(email, username) or username.lower() == _service_username():
        return {"email": email, "username": username, "status": "skipped_protected"}
    if owner is None and not linux_user_exists(username):
        return {"email": email, "username": username, "status": "absent"}
    if owner is None:
        return {"email": email, "username": username, "status": "absent"}
    # Only once we know this account is the departing user's: revoke their
    # terminal (`infocus`) sign-ins first, and keep the account if that fails.
    try:
        cli_tokens.revoke_all(username)
    except (OSError, sqlite3.Error, FSError) as e:
        log.warning("revoking terminal sign-ins for %s failed: %s", username, e)
        return {"email": email, "username": username, "status": "error",
                "detail": "could not revoke terminal sign-ins"}

    own = False
    client = ugos
    if client is None:
        s = get_settings()
        if not (s.userd_token or s.ugos_admin_password or "").strip():
            return {"email": email, "username": username, "status": "skipped_unconfigured"}
        client = _client_factory()
        own = True
    try:
        if not hasattr(client, "delete_user"):
            return {"email": email, "username": username, "status": "skipped_unconfigured"}
        deleted = client.delete_user(username)
        status = "deleted"
        if isinstance(deleted, dict):
            raw = str(deleted.get("status") or "deleted")
            if raw in ("deleted", "absent"):
                status = raw
            elif raw == "skipped_protected":
                status = "skipped_protected"
            elif raw == "error":
                raise UserdError(str(deleted.get("detail") or "delete failed"))
        return {"email": email, "username": username, "status": status}
    except (UgosError, UserdError, httpx.HTTPError) as e:
        log.warning("delete %s failed: %s", username, e)
        return {"email": email, "username": username, "status": "error", "detail": str(e)}
    finally:
        if own or close_ugos:
            client.close()


def sync_roster(*, ugos_factory: UgosFactory | None = None) -> dict[str, Any]:
    """Create missing NAS users from packages; delete NAS users who left the roster."""
    entries = fetch_roster_entries()
    roster = {e["email"] for e in entries}
    claimed: set[str] = set()  # usernames we already handled this run
    results: list[dict[str, Any]] = []
    s = get_settings()
    if ugos_factory is None and not (s.userd_token or s.ugos_admin_password or "").strip():
        return {"ok": False, "detail": "userd token not configured", "results": []}

    factory = ugos_factory or _client_factory
    client = factory()
    try:
        try:
            ugos_usernames = (
                client.existing_usernames() if hasattr(client, "existing_usernames") else set()
            )
            ugos_emails = client.existing_emails() if hasattr(client, "existing_emails") else {}
        except (UgosError, UserdError, httpx.HTTPError):
            ugos_usernames, ugos_emails = set(), {}

        for entry in entries:
            email = entry["email"]
            username = allocate_username(email, roster)
            if username and username.lower() in claimed:
                results.append(
                    {
                        "email": email,
                        "username": username,
                        "status": "skipped_duplicate_username",
                    }
                )
                continue
            row = ensure_user(
                email,
                entry.get("name") or "",
                roster=roster,
                ugos=client,
                ugos_usernames=ugos_usernames,
                ugos_emails=ugos_emails,
            )
            if row.get("username"):
                claimed.add(str(row["username"]).lower())
            results.append(row)

        prev = load_roster_snapshot()
        if prev:
            for email in sorted(prev - roster):
                results.append(revoke_user(email, roster=roster, ugos=client))
        save_roster_snapshot(roster)
    finally:
        client.close()

    counts: dict[str, int] = {}
    for row in results:
        st = str(row.get("status") or "unknown")
        counts[st] = counts.get(st, 0) + 1
    return {"ok": True, "counts": counts, "results": results, "roster": len(entries)}


def ensure_for_login(email: str, name: str = "") -> NasUser | None:
    """Allow Drive login only for packages roster (plus protected / user_map)."""
    parts = split_email(email)
    if parts is None:
        return None
    local, domain = parts
    email = f"{local}@{domain}"
    if is_protected(email):
        return resolve_nas_user(email)

    roster = fetch_roster_emails()
    if email not in roster:
        roster = fetch_roster_emails(force=True)
    if email not in roster:
        if email in _load_overrides():
            return resolve_nas_user(email)
        if email in load_roster_snapshot():
            revoke_user(email, roster=roster)
        return None

    nas = resolve_nas_user(email, extra_allow_emails=roster)
    if nas is not None:
        return nas
    result = ensure_user(email, name, roster=roster)
    if result.get("status") in ("created", "exists", "skipped_protected"):
        return resolve_nas_user(email, extra_allow_emails=roster)
    return None
