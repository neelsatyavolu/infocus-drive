"""Id slots are per member and Mac, so one member on two Macs never allocates colliding ids."""

import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import team_projects  # noqa: E402
import team_store  # noqa: E402
from team_store import TeamStore  # noqa: E402
from test_team_projects import APP, as_, client, create, drive  # noqa: E402,F401

PID = "b" * 32


def on(user, device=None):
    return as_(user) if device is None else {**as_(user), "X-Drive-Device": device}


def test_same_member_two_macs_get_two_slots(tmp_path):
    st = TeamStore(tmp_path / "t.sqlite3")
    pid = st.create_project("Team Projects/X.fcteam", "X", "student1")
    a = st.slot_for(pid, "student1", "Mac A")
    b = st.slot_for(pid, "student1", "Mac B")
    assert a != b
    assert st.slot_for(pid, "student1", "Mac A") == a and st.slot_for(pid, "student1", "Mac B") == b
    assert st.slot_for(pid, "student1") not in (a, b)  # no header is its own device ""
    assert st.members(pid) == ["student1"]


def test_slot_made_before_devices_stays_for_the_empty_device(tmp_path):
    path = tmp_path / "old.sqlite3"
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE projects (id TEXT PRIMARY KEY, folder TEXT NOT NULL, name TEXT NOT NULL,
            creator TEXT NOT NULL, created_at REAL NOT NULL, last_open REAL NOT NULL,
            keep INTEGER NOT NULL DEFAULT 0, notified REAL NOT NULL DEFAULT 0);
        CREATE TABLE members (project_id TEXT NOT NULL, user TEXT NOT NULL, slot INTEGER, last_open REAL,
            PRIMARY KEY (project_id, user));
        CREATE UNIQUE INDEX members_slot ON members (project_id, slot);
    """)
    conn.execute("INSERT INTO projects VALUES (?, 'Team Projects/X.fcteam', 'X', 'student1', 0, 0, 0, 0)", (PID,))
    conn.execute("INSERT INTO members VALUES (?, 'student1', 1, 0)", (PID,))
    conn.execute("INSERT INTO members VALUES (?, 'student2', 2, 0)", (PID,))
    conn.commit()
    conn.close()
    st = TeamStore(path)
    assert st.slot_for(PID, "student2") == 2 and st.slot_for(PID, "student1", "") == 1
    assert st.slot_for(PID, "student1", "Mac B") == 3
    assert TeamStore(path).slot_for(PID, "student1") == 1  # migration runs again harmlessly


def test_create_and_get_return_the_macs_slot(client):
    made = client.post("/api/team/projects", json={"name": "Robotics", **APP}, headers=on("student1", "Mac A"))
    assert made.status_code == 200 and made.json()["slot"] == 1
    pid = made.json()["id"]
    got = client.get(f"/api/team/projects/{pid}", headers=on("student1", "Mac A")).json()
    assert got["slot"] == 1
    other = client.get(f"/api/team/projects/{pid}", headers=on("student1", "Mac B")).json()
    assert other["slot"] == 2
    bad = client.get(f"/api/team/projects/{pid}", headers=on("student1", "x" * 65))
    assert bad.status_code == 400


def test_new_sequence_lock_uses_the_macs_slot(client):
    pid = create(client)["id"]  # no header: device "", slot 1
    slot_b = client.get(f"/api/team/projects/{pid}", headers=on("student1", "Mac B")).json()["slot"]
    new_b = (slot_b << 40) | 1
    assert client.post(f"/api/team/projects/{pid}/sequences/{new_b}/lock",
                       headers=on("student1", "Mac B")).status_code == 200
    new_a = (1 << 40) | 1
    assert client.post(f"/api/team/projects/{pid}/sequences/{new_a}/lock",
                       headers=on("student1", "Mac B")).status_code == 404


def test_no_slots_left_is_409(client, monkeypatch):
    pid = create(client)["id"]
    monkeypatch.setattr(team_store, "MAX_SLOT", 1)
    r = client.get(f"/api/team/projects/{pid}", headers=on("student1", "Mac B"))
    assert r.status_code == 409 and r.json()["error"] == "no_slots"
    r = client.post("/api/team/projects", json={"name": "Other", **APP}, headers=on("student2"))
    assert r.status_code == 200  # a new project starts at slot 1
    team_projects.store()  # still usable
