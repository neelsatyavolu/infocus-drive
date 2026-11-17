"""Small in-process limits for team routes that reach people: name search and invite emails.

The Drive runs as one process, so a dict under a lock is enough. Counts reset on restart,
which only ever allows a little more, never less.
"""

from __future__ import annotations

import re
import threading
import time
from collections import deque

# Name search (`GET /api/team/people?q=`): enough for typing names into a picker.
PEOPLE_PER_MINUTE = 60
# Invite emails: one per invitee and project a day, and at most this many per inviter an hour.
EMAIL_COOLDOWN_S = 24 * 3600
EMAILS_PER_INVITER_HOUR = 20
# A project name in an email body: short, plain words only (no links, no markup).
EMAIL_NAME_MAX = 40
_UNSAFE = re.compile(r"[^\w ,'()&-]+", re.UNICODE)  # dots too, so no domain names


class Window:
    """At most `limit` events per `key` in any `seconds` long window."""

    def __init__(self, limit: int, seconds: float) -> None:
        self.limit = limit
        self.seconds = seconds
        self._lock = threading.Lock()
        self._events: dict[str, deque[float]] = {}

    def allow(self, key: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        with self._lock:
            events = self._events.setdefault(key, deque())
            while events and now - events[0] >= self.seconds:
                events.popleft()
            if len(events) >= self.limit:
                return False
            events.append(now)
            if len(self._events) > 10_000:  # forget idle keys
                for k in [k for k, v in self._events.items() if not v]:
                    del self._events[k]
            return True


people_searches = Window(PEOPLE_PER_MINUTE, 60)
inviter_emails = Window(EMAILS_PER_INVITER_HOUR, 3600)
invitee_emails = Window(1, EMAIL_COOLDOWN_S)


def may_email(project_id: str, inviter: str, invitee: str) -> bool:
    """True when an invite email may go out now (and counts it)."""
    if not invitee_emails.allow(f"{project_id}\0{invitee}"):
        return False
    return inviter_emails.allow(inviter)


def email_safe_name(name: str) -> str:
    """A project name made harmless for an email body: no links or markup, at most 40 characters."""
    plain = _UNSAFE.sub(" ", (name or "").replace("://", " ")).strip()
    plain = re.sub(r"\s+", " ", plain)
    if len(plain) > EMAIL_NAME_MAX:
        plain = plain[: EMAIL_NAME_MAX - 1].rstrip() + "…"
    return plain or "a team project"
