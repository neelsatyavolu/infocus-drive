"""TeamStore runs every query as root, and never nests the credential lock.

`fsops.as_user` changes the euid of the whole process; a team query that ran while
another request was inside it would run as that member ("attempt to write a readonly
database" on the NAS). Tests run as a normal user, where as_root is a no-op, so this
pretends to be root (with euid changes stubbed) to exercise the real lock.
"""

from __future__ import annotations

import threading

import pytest

import fsops
import team_projects
from team_store import TeamStore


@pytest.fixture
def as_root_counted(monkeypatch):
    calls = {"n": 0}
    monkeypatch.setattr(fsops.os, "getuid", lambda: 0)
    monkeypatch.setattr(fsops.os, "seteuid", lambda _uid: None)
    monkeypatch.setattr(fsops.os, "setegid", lambda _gid: None)
    monkeypatch.setattr(fsops, "_as_user_lock", threading.Lock())
    # A nested as_root would wait for itself: fail fast instead of hanging 90 s.
    monkeypatch.setattr(fsops, "_AS_USER_LOCK_TIMEOUT_S", 0.5)
    real = fsops.as_root

    def counted():
        calls["n"] += 1
        return real()

    monkeypatch.setattr(fsops, "as_root", counted)
    return calls


def test_every_store_operation_runs_as_root_without_nesting(tmp_path, as_root_counted):
    st = TeamStore(tmp_path / "team.sqlite3", lock_ttl_s=60)
    pid = st.create_project("Team Projects/A.fcteam", "A", "student1")
    assert st.project(pid)["name"] == "A"
    slot = st.slot_for(pid, "student1", "mac-1")
    assert slot >= 1
    lock = st.take_lock(pid, 7, "student1", "mac-1")
    assert lock.ok
    assert st.check_lock(pid, 7, lock.token)
    assert st.heartbeat(pid, 7, lock.token)
    assert 7 in st.locks(pid)
    assert st.bump_revision(pid, "shared", st.revision(pid, "shared")) is not None
    st.record_open(pid, "student2")
    assert "student2" in st.members(pid)
    st.set_keep(pid, True)
    assert st.is_keep(pid)
    st.stale_projects(0)
    st.mark_notified(pid)
    assert st.notified(pid)
    assert st.release(pid, 7, lock.token)
    st.force_release(pid, 7)
    st.set_folder(pid, "Team Projects/B.fcteam")
    st.forget(pid)
    assert st.project(pid) is None
    assert as_root_counted["n"] > 10


def test_store_waits_for_a_member_file_operation(tmp_path, as_root_counted):
    st = TeamStore(tmp_path / "team.sqlite3")
    pid = st.create_project("Team Projects/A.fcteam", "A", "student1")
    # While another thread holds the credential lock (as a member), the store cannot run.
    assert fsops._as_user_lock.acquire()
    try:
        with pytest.raises(fsops.FSError):
            st.project(pid)
    finally:
        fsops._as_user_lock.release()
    assert st.project(pid)["id"] == pid
