"""Daily cleanup of InFocus Cut team projects nobody has opened for 30 days.

At 23 days without an open, every member gets a notice (email, with a link to
the Keep page). At 30 days, and at least 7 days after the notice, the project's
`<name>.fcteam` and `<name> Media` folders move to the share's `#recycle`,
where they can be restored like any deleted file. "Keep forever" projects,
projects with a held sequence lock and projects with an export in progress
are never moved.

`run_cleanup` is a pure decision function: email, the move and logging are
passed in, so tests drive it with fakes. `start_worker` runs it once a day at
03:00 server time in a background thread (main process only).
"""

from __future__ import annotations

import datetime as dt
import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable

import httpx

import team_files
from config import get_settings
from fsops import FSError
from team_store import TeamStore
from users import linux_user_email

log = logging.getLogger("infocus.team_cleanup")

DAY_S = 86400
NOTICE_AFTER_S = 23 * DAY_S
MOVE_AFTER_S = 30 * DAY_S
EXPORT_TTL_S = 6 * 3600
RUN_AT_HOUR = 3

SendEmail = Callable[[str, str, str], None]
MoveToRecycle = Callable[[dict[str, Any]], Any]
Log = Callable[[str], None]
Present = Callable[[dict[str, Any]], bool]


class Busy(Exception):
    """The project got a lock or an export between the decision and the move."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass
class CleanupReport:
    notified: list[str] = field(default_factory=list)
    moved: list[str] = field(default_factory=list)
    skipped: dict[str, str] = field(default_factory=dict)


# Exports in progress -----------------------------------------------------------
# In memory (single server process). A mark lapses after 6 h, so an app that
# crashed mid-export can't keep a project from cleanup for good.

_exports: dict[str, float] = {}
_exports_guard = threading.Lock()


def begin_export(project_id: str, now: float) -> None:
    with _exports_guard:
        _exports[project_id] = now


def end_export(project_id: str) -> None:
    with _exports_guard:
        _exports.pop(project_id, None)


def export_active(project_id: str, now: float) -> bool:
    with _exports_guard:
        started = _exports.get(project_id)
    return started is not None and now - started <= EXPORT_TTL_S


# The decision ------------------------------------------------------------------


def _date(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime("%B %-d, %Y")


def _notice(info: dict[str, Any], move_on: float) -> tuple[str, str]:
    name = info["name"]
    base = get_settings().public_base_url.rstrip("/")
    subject = f"Your InFocus Cut project “{name}” will be cleaned up in 7 days"
    text = (
        f"Nobody has opened the team project “{name}” on InFocus Drive for 23 days.\n\n"
        f"On {_date(move_on)} it will move to the Drive's Recycle bin, together with its media folder. "
        "An adviser can restore it from there.\n\n"
        f"To keep it, open it in InFocus Cut or press Keep here:\n{base}/team/keep?project={info['id']}\n"
    )
    return subject, text


def _notify(store: TeamStore, info: dict[str, Any], now: float, send_email: SendEmail, log_line: Log) -> None:
    subject, text = _notice(info, now + (MOVE_AFTER_S - NOTICE_AFTER_S))
    for user in store.members(info["id"]):
        try:
            send_email(user, subject, text)
        except Exception:
            # One member's failed email must not stop the others; never log provider replies.
            log_line(f"team cleanup: could not email the notice for “{info['name']}” to {user}")
    store.mark_notified(info["id"])
    log_line(f"team cleanup: notice sent for “{info['name']}” ({info['folder']})")


def _skip_reason(store: TeamStore, project_id: str, now: float) -> str | None:
    if store.locks(project_id):
        return "lock held"
    if export_active(project_id, now):
        return "export in progress"
    return None


def _move(store: TeamStore, info: dict[str, Any], now: float, move: MoveToRecycle, log_line: Log,
          report: CleanupReport) -> None:
    project_id = info["id"]
    members = ", ".join(store.members(project_id)) or "none"
    try:
        move(info)
    except Busy as e:
        report.skipped[project_id] = e.reason
        log_line(f"team cleanup: kept “{info['name']}” for now: {e.reason}")
        return
    except FSError as e:
        if e.status == 404:
            store.forget(project_id)
            log_line(f"team cleanup: “{info['name']}” ({info['folder']}) is no longer on the Drive; forgot it")
            return
        report.skipped[project_id] = "move failed"
        log_line(f"team cleanup: could not move “{info['name']}” ({info['folder']}): {e}")
        return
    except Exception as e:
        report.skipped[project_id] = "move failed"
        log_line(f"team cleanup: could not move “{info['name']}” ({info['folder']}): {type(e).__name__}")
        return
    store.forget(project_id)
    report.moved.append(project_id)
    log_line(
        f"team cleanup: moved “{info['name']}” ({info['folder']}) to #recycle on {_date(now)}; "
        f"members: {members}"
    )


def cleanup_status(store: TeamStore, project_id: str) -> dict[str, Any] | None:
    """What the app shows about cleanup: a pending move after the notice, or Keep forever.

    None when neither applies (no notice sent, or an open since reset the clock).
    `move_after` is the earliest time the daily run (03:00) may move the project.
    """
    info = store.project(project_id)
    if info is None:
        return None
    if info["keep"]:
        return {"notice_sent_at": None, "move_after": None, "keep": True}
    notified_at = store.notified_at(project_id)
    if not notified_at:
        return None
    move_after = max(info["last_open"] + MOVE_AFTER_S, notified_at + (MOVE_AFTER_S - NOTICE_AFTER_S))
    return {"notice_sent_at": notified_at, "move_after": move_after, "keep": False}


def run_cleanup(store: TeamStore, now: float, send_email: SendEmail, move_to_recycle: MoveToRecycle,
                log: Log, present: Present | None = None) -> CleanupReport:
    """Send due notices and move due projects. Each project is handled on its own.

    `present(info)` says whether the row's folder still holds that project; a row
    that fails it is forgotten with no notice and no move.
    """
    report = CleanupReport()
    for project_id in store.stale_projects(NOTICE_AFTER_S):
        info = store.project(project_id)
        if info is None or info["keep"] or now - info["last_open"] < NOTICE_AFTER_S:
            continue
        if present is not None and not present(info):
            store.forget(project_id)
            log(f"team cleanup: “{info['name']}” ({info['folder']}) is no longer on the Drive; forgot it")
            continue
        notified_at = store.notified_at(project_id)
        if not notified_at:
            _notify(store, info, now, send_email, log)
            report.notified.append(project_id)
            continue
        due = (now - info["last_open"] >= MOVE_AFTER_S
               and now - notified_at >= MOVE_AFTER_S - NOTICE_AFTER_S)
        if not due:
            continue
        reason = _skip_reason(store, project_id, now)
        if reason:
            report.skipped[project_id] = reason
            log(f"team cleanup: kept “{info['name']}” for now: {reason}")
            continue
        _move(store, info, now, move_to_recycle, log, report)
    return report


# Real effects ------------------------------------------------------------------


def send_notice_email(username: str, subject: str, text: str) -> None:
    """Email a member through Resend. A no-op when Resend isn't configured."""
    settings = get_settings()
    if not settings.resend_api_key or not settings.resend_from_email:
        return
    address = linux_user_email(username)
    if not address:
        return
    try:
        with httpx.Client(timeout=20) as client:
            result = client.post("https://api.resend.com/emails", headers={
                "Authorization": f"Bearer {settings.resend_api_key}"
            }, json={"from": settings.resend_from_email, "to": [address], "subject": subject, "text": text})
            result.raise_for_status()
    except httpx.HTTPError:
        # Never surface provider responses or credentials.
        raise RuntimeError("Resend request failed") from None


def _recycle(store: TeamStore, info: dict[str, Any]) -> None:
    """Move the project to `#recycle` under its project lock, after checking locks and exports again.

    Taking a lock and beginning an export also hold the project lock, so neither
    can slip in between this check and the move.
    """
    from team_projects import _project_lock  # late: team_projects imports this module

    with _project_lock(info["id"]):
        reason = _skip_reason(store, info["id"], time.time())
        if reason:
            raise Busy(reason)
        team_files.recycle_project(info["folder"], info["id"])


def recycle_now(store: TeamStore, info: dict[str, Any]) -> None:
    """An admin's "Recycle now": the same checks and move as the daily cleanup."""
    _recycle(store, info)


def run_daily(store: TeamStore) -> CleanupReport:
    return run_cleanup(store, time.time(), send_notice_email, lambda info: _recycle(store, info), log.info,
                       present=team_files.project_present)


# Scheduling ---------------------------------------------------------------------


def seconds_until(hour: int, at: dt.datetime) -> float:
    """Seconds from `at` to the next `hour`:00 (a full day when it is exactly that time)."""
    target = at.replace(hour=hour, minute=0, second=0, microsecond=0)
    if target <= at:
        target += dt.timedelta(days=1)
    return (target - at).total_seconds()


_stop = threading.Event()
_worker: threading.Thread | None = None


def start_worker(store_factory: Callable[[], TeamStore] | None = None) -> bool:
    """Run the cleanup every day at 03:00 server time. False when disabled."""
    global _worker
    if not get_settings().team_cleanup_enabled:
        return False
    if store_factory is None:
        from team_projects import store as store_factory  # late: team_projects imports this module
    _stop.clear()

    def run() -> None:
        while not _stop.wait(seconds_until(RUN_AT_HOUR, dt.datetime.now())):
            try:
                run_daily(store_factory())
            except Exception:
                log.exception("Team project cleanup failed; will retry tomorrow")

    _worker = threading.Thread(target=run, name="team-project-cleanup", daemon=True)
    _worker.start()
    return True


def stop_worker() -> None:
    _stop.set()
    if _worker:
        _worker.join(timeout=20)
