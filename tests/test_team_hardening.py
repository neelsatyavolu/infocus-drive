"""Security-review fixes for team projects: folder ownership, races, caps and gates."""

import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import team_cleanup  # noqa: E402
import team_files  # noqa: E402
import team_projects  # noqa: E402
from team_store import TeamStore  # noqa: E402
from test_team_projects import (  # noqa: E402,F401
    APP, as_, client, create, drive, lock, media_item, put, seq_item,
)

DAY = 86400
TP = "Team Projects"


def _age(st, pid, notified=True):
    with st._tx() as conn:
        conn.execute("UPDATE projects SET last_open = 0, notified = ? WHERE id = ?", (1 if notified else 0, pid))


def _cleanup(st, mails=None):
    sent = mails if mails is not None else []
    return team_cleanup.run_cleanup(
        st, time.time(), lambda user, subject, text: sent.append(user),
        lambda info: team_cleanup._recycle(st, info), lambda line: None,
        present=team_files.project_present,
    )


# 1. Cleanup moves only the folder whose meta.json carries the row's id -------------------------


def test_create_retires_row_whose_folder_it_takes(client):
    a = create(client, name="Robotics")
    tp = client.drive / TP
    (client.drive / "#recycle").mkdir()
    shutil.move(str(tp / "Robotics.fcteam"), str(client.drive / "#recycle" / "A-old.fcteam"))
    shutil.move(str(tp / "Robotics Media"), str(client.drive / "#recycle" / "A-old Media"))
    b = create(client, name="Robotics", user="student2")
    st = team_projects.store()
    assert st.project(a["id"]) is None
    assert st.project(b["id"])["folder"] == f"{TP}/Robotics.fcteam"


def test_cleanup_never_moves_another_projects_folder(client):
    b = create(client, name="Robotics")
    (client.drive / "#recycle").mkdir()
    st = team_projects.store()
    stale = "f" * 32  # a stale row pointing at B's folder (made before rows were retired)
    with st._tx() as conn:
        conn.execute("INSERT INTO projects (id, folder, name, creator, created_at, last_open, notified) "
                     "VALUES (?, ?, 'Robotics', 'student9', 0, 0, 1)", (stale, f"{TP}/Robotics.fcteam"))
        conn.execute("INSERT INTO members (project_id, user, last_open) VALUES (?, 'student9', 0)", (stale,))
    mails = []
    report = _cleanup(st, mails)
    assert report.moved == [] and mails == []
    assert st.project(stale) is None and st.project(b["id"]) is not None
    assert (client.drive / TP / "Robotics.fcteam" / "meta.json").is_file()
    assert (client.drive / TP / "Robotics Media").is_dir()


def test_no_notice_for_a_row_whose_folder_is_gone(client):
    a = create(client, name="Robotics")
    st = team_projects.store()
    (client.drive / "#recycle").mkdir()
    shutil.move(str(client.drive / TP / "Robotics.fcteam"), str(client.drive / "#recycle" / "x.fcteam"))
    _age(st, a["id"], notified=False)
    mails = []
    report = _cleanup(st, mails)
    assert report.notified == [] and mails == [] and st.project(a["id"]) is None


def test_recycle_project_refuses_mismatched_id(client):
    a = create(client, name="Robotics")
    (client.drive / "#recycle").mkdir()
    with pytest.raises(team_files.FSError) as err:
        team_files.recycle_project(f"{TP}/Robotics.fcteam", "0" * 32)
    assert err.value.status == 404
    assert (client.drive / TP / "Robotics.fcteam").is_dir()
    team_files.recycle_project(f"{TP}/Robotics.fcteam", a["id"])
    assert not (client.drive / TP / "Robotics.fcteam").exists()


def test_cleanup_rechecks_locks_under_the_project_lock(client):
    a = create(client, name="Robotics")
    (client.drive / "#recycle").mkdir()
    st = team_projects.store()
    assert lock(client, a["id"], 2).status_code == 200
    info = st.project(a["id"])
    with pytest.raises(team_cleanup.Busy):
        team_cleanup._recycle(st, info)
    assert (client.drive / TP / "Robotics.fcteam").is_dir()
    team_cleanup.begin_export(a["id"], time.time())
    st.force_release(a["id"], 2)
    try:
        with pytest.raises(team_cleanup.Busy):
            team_cleanup._recycle(st, info)
    finally:
        team_cleanup.end_export(a["id"])
    report = team_cleanup.CleanupReport()
    team_cleanup.begin_export(a["id"], time.time())
    try:
        team_cleanup._move(st, info, time.time(), lambda i: team_cleanup._recycle(st, i), lambda m: None, report)
    finally:
        team_cleanup.end_export(a["id"])
    assert report.skipped == {a["id"]: "export in progress"} and st.project(a["id"]) is not None


# 5. A copied .fcteam doesn't take over the project's row --------------------------------------------


def test_copied_fcteam_does_not_hijack_the_row(client):
    a = create(client, name="Robotics")
    tp = client.drive / TP
    shutil.copytree(tp / "Robotics.fcteam", tp / "Zzz.fcteam")
    st = team_projects.store()
    for _ in range(2):
        listed = client.get("/api/team/projects", headers=as_("student1")).json()
        assert [p["folder"] for p in listed] == [f"{TP}/Robotics.fcteam"]
        assert st.project(a["id"])["folder"] == f"{TP}/Robotics.fcteam"


def test_renamed_fcteam_is_followed_once(client):
    a = create(client, name="Robotics")
    tp = client.drive / TP
    shutil.copytree(tp / "Robotics.fcteam", tp / "Aaa.fcteam")
    shutil.copytree(tp / "Robotics.fcteam", tp / "Zzz.fcteam")
    shutil.move(str(tp / "Robotics.fcteam"), str(client.drive / "gone.fcteam"))
    st = team_projects.store()
    for _ in range(2):
        listed = client.get("/api/team/projects", headers=as_("student1")).json()
        assert [p["folder"] for p in listed] == [f"{TP}/Aaa.fcteam"]
        assert st.project(a["id"])["folder"] == f"{TP}/Aaa.fcteam"


# 6. Create refuses a media folder that is already there ------------------------------------------


def test_create_refuses_existing_media_folder(client):
    tp = client.drive / TP
    (tp / "Interview Media").mkdir(parents=True)
    (tp / "Interview Media" / "unrelated.mov").write_bytes(b"x")
    r = client.post("/api/team/projects", json={"name": "Interview", **APP}, headers=as_("student1"))
    assert r.status_code == 409 and r.json()["error"] == "name_taken"
    assert not (tp / "Interview.fcteam").exists()
    assert (tp / "Interview Media" / "unrelated.mov").read_bytes() == b"x"


def test_failed_create_leaves_no_empty_media_folder(client, monkeypatch):
    real = team_files._write_bytes

    def boom(path, data):
        if path.name == team_files.META_FILE:
            raise OSError("disk full")
        real(path, data)

    monkeypatch.setattr(team_files, "_write_bytes", boom)
    r = client.post("/api/team/projects", json={"name": "Interview", **APP}, headers=as_("student1"))
    assert r.status_code == 500
    monkeypatch.setattr(team_files, "_write_bytes", real)
    assert create(client, name="Interview")["slot"] == 1
