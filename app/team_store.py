"""State for InFocus Cut team projects: sequence locks, revisions, id slots, opens.

Only the server's own SQLite file lives here; project files on the Drive are
read and written by `team_files`. Nothing in this module touches the Drive, so
callers never hold `fsops.as_user` while using it.

Take and bump run inside `BEGIN IMMEDIATE`, so two requests racing for one lock
or one revision are serialized by SQLite: exactly one wins.
"""

from __future__ import annotations

import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

HEARTBEAT_S = 20
LOCK_TTL_S = 120
MAX_SLOT = 1023

_SCHEMA = """
CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    folder TEXT NOT NULL,
    name TEXT NOT NULL,
    creator TEXT NOT NULL,
    created_at REAL NOT NULL,
    last_open REAL NOT NULL,
    keep INTEGER NOT NULL DEFAULT 0,
    notified REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS members (
    project_id TEXT NOT NULL,
    user TEXT NOT NULL,
    slot INTEGER,
    last_open REAL,
    PRIMARY KEY (project_id, user)
);
CREATE UNIQUE INDEX IF NOT EXISTS members_slot ON members (project_id, slot);
CREATE TABLE IF NOT EXISTS slots (
    project_id TEXT NOT NULL,
    user TEXT NOT NULL,
    device TEXT NOT NULL,
    slot INTEGER NOT NULL,
    PRIMARY KEY (project_id, user, device)
);
CREATE UNIQUE INDEX IF NOT EXISTS slots_slot ON slots (project_id, slot);
CREATE TABLE IF NOT EXISTS locks (
    project_id TEXT NOT NULL,
    seq_id INTEGER NOT NULL,
    user TEXT NOT NULL,
    token TEXT NOT NULL,
    expires_at REAL NOT NULL,
    device TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (project_id, seq_id)
);
CREATE TABLE IF NOT EXISTS revisions (
    project_id TEXT NOT NULL,
    part TEXT NOT NULL,
    rev INTEGER NOT NULL,
    PRIMARY KEY (project_id, part)
);
"""


class NoSlots(ValueError):
    """Every id slot of the project is taken."""


@dataclass(frozen=True)
class LockResult:
    ok: bool
    token: str | None
    holder: str | None
    expires_at: float
    device: str | None = None


class TeamStore:
    def __init__(self, db_path: Path, clock: Callable[[], float] = time.time, lock_ttl_s: float = LOCK_TTL_S):
        self.db_path = Path(db_path)
        self.clock = clock
        self.lock_ttl_s = lock_ttl_s
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with self._conn() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.executescript(_SCHEMA)
            columns = {r["name"] for r in conn.execute("PRAGMA table_info(locks)")}
            if "device" not in columns:  # databases made before locks were per device
                conn.execute("ALTER TABLE locks ADD COLUMN device TEXT NOT NULL DEFAULT ''")
            # Slots made before they were per Mac (`members.slot`) stay with device "".
            conn.execute(
                "INSERT OR IGNORE INTO slots (project_id, user, device, slot) "
                "SELECT project_id, user, '', slot FROM members WHERE slot IS NOT NULL"
            )

    @contextmanager
    def _conn(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path, timeout=15, isolation_level=None)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
        finally:
            conn.close()

    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        """A write transaction that takes SQLite's write lock up front."""
        with self._conn() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                yield conn
            except BaseException:
                conn.execute("ROLLBACK")
                raise
            conn.execute("COMMIT")

    # Projects ---------------------------------------------------------------

    def create_project(self, folder_rel: str, name: str, creator: str, project_id: str | None = None) -> str:
        """Register a project. `project_id` re-registers one found on disk (e.g. restored).

        Registering an id that is already there keeps the first row: a project list can find a
        new project's folder (and register it) before its create request does. Any other row
        that still points at `folder_rel` is retired: the folder's meta.json now names this id,
        so that row's project is gone (and cleanup must never move this folder for it).
        """
        project_id = project_id or uuid.uuid4().hex
        now = self.clock()
        with self._tx() as conn:
            self._retire_folder(conn, folder_rel, project_id)
            added = conn.execute(
                "INSERT OR IGNORE INTO projects (id, folder, name, creator, created_at, last_open) VALUES (?, ?, ?, ?, ?, ?)",
                (project_id, folder_rel, name, creator, now, now),
            ).rowcount
            if added:
                conn.execute(
                    "INSERT INTO members (project_id, user, last_open) VALUES (?, ?, ?)",
                    (project_id, creator, now),
                )
        return project_id

    def project(self, project_id: str) -> dict | None:
        with self._conn() as conn:
            row = conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,)).fetchone()
        if row is None:
            return None
        return {
            "id": row["id"],
            "folder": row["folder"],
            "name": row["name"],
            "creator": row["creator"],
            "created_at": row["created_at"],
            "last_open": row["last_open"],
            "keep": bool(row["keep"]),
        }

    def set_folder(self, project_id: str, folder_rel: str) -> None:
        with self._tx() as conn:
            self._retire_folder(conn, folder_rel, project_id)
            conn.execute("UPDATE projects SET folder = ? WHERE id = ?", (folder_rel, project_id))

    def forget(self, project_id: str) -> None:
        """Drop every row for a project (after it moved to the recycle bin)."""
        with self._tx() as conn:
            self._forget(conn, project_id)

    @staticmethod
    def _forget(conn: sqlite3.Connection, project_id: str) -> None:
        for table, key in (("projects", "id"), ("members", "project_id"), ("locks", "project_id"),
                           ("revisions", "project_id"), ("slots", "project_id")):
            conn.execute(f"DELETE FROM {table} WHERE {key} = ?", (project_id,))

    def _retire_folder(self, conn: sqlite3.Connection, folder_rel: str, owner: str) -> None:
        """Forget every project but `owner` whose row points at `folder_rel`."""
        rows = conn.execute("SELECT id FROM projects WHERE folder = ? AND id != ?", (folder_rel, owner)).fetchall()
        for row in rows:
            self._forget(conn, row["id"])

    # Id slots ----------------------------------------------------------------

    def slot_for(self, project_id: str, user: str, device: str = "") -> int:
        """The id slot (1..=1023) of this member on this Mac, handed out once and kept for good.

        Per Mac, so one member on two Macs never allocates the same ids. A missing
        device header is the device "" (and holds slots made before slots were per Mac).
        """
        with self._tx() as conn:
            row = conn.execute(
                "SELECT slot FROM slots WHERE project_id = ? AND user = ? AND device = ?",
                (project_id, user, device),
            ).fetchone()
            if row is not None:
                return int(row["slot"])
            top = conn.execute(
                "SELECT MAX(COALESCE((SELECT MAX(slot) FROM slots WHERE project_id = ?), 0), "
                "COALESCE((SELECT MAX(slot) FROM members WHERE project_id = ?), 0))",
                (project_id, project_id),
            ).fetchone()[0]
            slot = int(top) + 1
            if slot > MAX_SLOT:
                raise NoSlots("This project has no free id slots left")
            conn.execute(
                "INSERT INTO slots (project_id, user, device, slot) VALUES (?, ?, ?, ?)",
                (project_id, user, device, slot),
            )
            conn.execute("INSERT OR IGNORE INTO members (project_id, user) VALUES (?, ?)", (project_id, user))
            return slot

    # Locks -----------------------------------------------------------------

    def take_lock(self, project_id: str, seq_id: int, user: str, device: str = "") -> LockResult:
        """Take the lock for `user` on `device` (one Mac). Re-entrant on the same device.

        Taking it again from the same user and device keeps the token and resets
        the expiry. The same user on another device is refused like a teammate,
        so a second Mac can't silently take over a lock the first is using.
        """
        now = self.clock()
        with self._tx() as conn:
            if conn.execute("SELECT 1 FROM projects WHERE id = ?", (project_id,)).fetchone() is None:
                return LockResult(False, None, None, 0.0)
            # Expired rows are dead weight (heartbeat refuses them), so drop them as we go.
            conn.execute("DELETE FROM locks WHERE expires_at <= ?", (now,))
            row = conn.execute(
                "SELECT user, token, device, expires_at FROM locks WHERE project_id = ? AND seq_id = ?",
                (project_id, seq_id),
            ).fetchone()
            expires = now + self.lock_ttl_s
            if row is not None and row["expires_at"] > now:
                if row["user"] != user or row["device"] != device:
                    return LockResult(False, None, row["user"], float(row["expires_at"]), row["device"])
                conn.execute(
                    "UPDATE locks SET expires_at = ? WHERE project_id = ? AND seq_id = ?",
                    (expires, project_id, seq_id),
                )
                return LockResult(True, str(row["token"]), user, expires, device)
            token = secrets.token_urlsafe(24)
            conn.execute(
                "INSERT OR REPLACE INTO locks (project_id, seq_id, user, token, expires_at, device) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (project_id, seq_id, user, token, expires, device),
            )
            return LockResult(True, token, user, expires, device)

    def check_lock(self, project_id: str, seq_id: int, token: str) -> bool:
        """True while `token` is the current, unexpired lock on the sequence."""
        with self._conn() as conn:
            row = conn.execute(
                "SELECT token, expires_at FROM locks WHERE project_id = ? AND seq_id = ?", (project_id, seq_id)
            ).fetchone()
        return (
            row is not None
            and row["expires_at"] > self.clock()
            and secrets.compare_digest(str(row["token"]), str(token or ""))
        )

    def heartbeat(self, project_id: str, seq_id: int, token: str) -> bool:
        """Extend a live lock. An expired lock is lost even if nobody took it yet."""
        now = self.clock()
        with self._tx() as conn:
            cur = conn.execute(
                "UPDATE locks SET expires_at = ? WHERE project_id = ? AND seq_id = ? AND token = ? AND expires_at > ?",
                (now + self.lock_ttl_s, project_id, seq_id, token or "", now),
            )
            return cur.rowcount == 1

    def release(self, project_id: str, seq_id: int, token: str) -> bool:
        with self._tx() as conn:
            cur = conn.execute(
                "DELETE FROM locks WHERE project_id = ? AND seq_id = ? AND token = ?",
                (project_id, seq_id, token or ""),
            )
            return cur.rowcount == 1

    def force_release(self, project_id: str, seq_id: int) -> None:
        with self._tx() as conn:
            conn.execute("DELETE FROM locks WHERE project_id = ? AND seq_id = ?", (project_id, seq_id))

    def locks(self, project_id: str) -> dict[int, tuple[str, float]]:
        """Live locks: seq id → (holder, expires_at)."""
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT seq_id, user, expires_at FROM locks WHERE project_id = ? AND expires_at > ?",
                (project_id, self.clock()),
            ).fetchall()
        return {int(r["seq_id"]): (r["user"], float(r["expires_at"])) for r in rows}

    # Revisions -------------------------------------------------------------

    def revision(self, project_id: str, part: str) -> int:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT rev FROM revisions WHERE project_id = ? AND part = ?", (project_id, part)
            ).fetchone()
        return int(row["rev"]) if row else 0

    def bump_revision(self, project_id: str, part: str, base: int | None) -> int | None:
        """Next revision of `part` ("shared" or "seq:<id>"), or None if `base` is stale.

        `base=None` bumps unconditionally (merge-by-id shared writes).
        """
        with self._tx() as conn:
            row = conn.execute(
                "SELECT rev FROM revisions WHERE project_id = ? AND part = ?", (project_id, part)
            ).fetchone()
            current = int(row["rev"]) if row else 0
            if base is not None and base != current:
                return None
            conn.execute(
                "INSERT OR REPLACE INTO revisions (project_id, part, rev) VALUES (?, ?, ?)",
                (project_id, part, current + 1),
            )
            return current + 1

    # Opens and cleanup -------------------------------------------------------

    def record_open(self, project_id: str, user: str) -> None:
        now = self.clock()
        with self._tx() as conn:
            conn.execute("UPDATE projects SET last_open = ?, notified = 0 WHERE id = ?", (now, project_id))
            conn.execute(
                "INSERT INTO members (project_id, user, last_open) VALUES (?, ?, ?) "
                "ON CONFLICT (project_id, user) DO UPDATE SET last_open = excluded.last_open",
                (project_id, user, now),
            )

    def last_open(self, project_id: str) -> float:
        info = self.project(project_id)
        return float(info["last_open"]) if info else 0.0

    def members(self, project_id: str) -> list[str]:
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT user FROM members WHERE project_id = ? ORDER BY user", (project_id,)
            ).fetchall()
        return [r["user"] for r in rows]

    def set_keep(self, project_id: str, keep: bool) -> None:
        with self._tx() as conn:
            conn.execute("UPDATE projects SET keep = ? WHERE id = ?", (1 if keep else 0, project_id))

    def is_keep(self, project_id: str) -> bool:
        info = self.project(project_id)
        return bool(info and info["keep"])

    def stale_projects(self, older_than_s: float) -> list[str]:
        """Projects not opened for `older_than_s` seconds, minus "Keep forever" ones."""
        cutoff = self.clock() - older_than_s
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT id FROM projects WHERE keep = 0 AND last_open < ? ORDER BY last_open", (cutoff,)
            ).fetchall()
        return [r["id"] for r in rows]

    def mark_notified(self, project_id: str) -> None:
        """Record the cleanup notice; `notified` holds when it went out (0 = not sent)."""
        with self._tx() as conn:
            conn.execute("UPDATE projects SET notified = ? WHERE id = ?", (max(1.0, self.clock()), project_id))

    def notified(self, project_id: str) -> bool:
        return self.notified_at(project_id) > 0

    def notified_at(self, project_id: str) -> float:
        with self._conn() as conn:
            row = conn.execute("SELECT notified FROM projects WHERE id = ?", (project_id,)).fetchone()
        return float(row["notified"]) if row and row["notified"] else 0.0
