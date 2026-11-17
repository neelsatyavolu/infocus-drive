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


# 2. Full GET: files and revisions read together ----------------------------------------------


def test_full_get_pairs_json_with_its_revision(client, monkeypatch):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    real = team_files.read_project
    writer: list[threading.Thread] = []

    def racing(user, folder):
        out = real(user, folder)
        if not writer:  # a teammate's save arrives between the file read and the revision read
            t = threading.Thread(target=lambda: put(client, pid, 2, token, 0, json=seq_item(2, clips=[1, 1])))
            writer.append(t)
            t.start()
            t.join(timeout=0.5)
        return out

    monkeypatch.setattr(team_files, "read_project", racing)
    got = client.get(f"/api/team/projects/{pid}", headers=as_("student2")).json()
    writer[0].join(timeout=5)
    seq = got["sequences"]["2"]
    assert (seq["rev"], seq["json"]) in [(0, seq_item(2, clips=[1])), (1, seq_item(2, clips=[1, 1]))]


# 3. POST shared caps and small bodies -----------------------------------------------------------


def _shared(client, pid, body, user="student1"):
    return client.post(f"/api/team/projects/{pid}/shared", json={**APP, **body}, headers=as_(user))


def test_shared_caps_deletes_and_upserts(client, monkeypatch):
    pid = create(client)["id"]
    monkeypatch.setattr(team_projects, "MAX_SHARED_OPS", 3)
    r = _shared(client, pid, {"base_rev": 0, "deletes": [10, 11, 12, 13]})
    assert r.status_code == 413
    ups = {str(i): media_item(i) for i in range(10, 14)}
    assert _shared(client, pid, {"base_rev": 0, "upserts": ups}).status_code == 413
    ups.pop("13")
    assert _shared(client, pid, {"base_rev": 0, "upserts": ups}).status_code == 200


def test_shared_delete_check_still_finds_references(client):
    pid = create(client)["id"]
    r = _shared(client, pid, {"base_rev": 0, "deletes": [5, 1]})
    assert r.status_code == 409 and r.json()["error"] == "item_in_use" and r.json()["item"] == 1


def test_small_routes_refuse_big_bodies(client):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    big = {"token": token, "pad": "x" * (team_projects.SMALL_BODY_BYTES + 1)}
    r = client.post(f"/api/team/projects/{pid}/sequences/2/lock/heartbeat", json=big, headers=as_("student1"))
    assert r.status_code == 413
    # The routes that carry project data keep the large limit.
    assert put(client, pid, 2, token, 0, pad="x" * (team_projects.SMALL_BODY_BYTES + 1)).status_code == 200


# 4. SSE stream caps -------------------------------------------------------------------------------


def _events(client, pid, user):
    return client.stream("GET", f"/api/team/projects/{pid}/events", headers=as_(user))


def test_sse_streams_capped_per_user(client, monkeypatch):
    pid = create(client)["id"]
    monkeypatch.setattr(team_projects, "MAX_STREAMS_PER_USER", 1)
    with _events(client, pid, "student1") as first:
        next(first.iter_lines())
        second = client.get(f"/api/team/projects/{pid}/events", headers=as_("student1"))
        assert second.status_code == 429 and second.json()["error"] == "too_many_streams"
    with _events(client, pid, "student1") as again:
        assert again.status_code == 200


def test_sse_streams_capped_overall(client, monkeypatch):
    pid = create(client)["id"]
    monkeypatch.setattr(team_projects, "MAX_STREAMS", 1)
    with _events(client, pid, "student1") as first:
        next(first.iter_lines())
        other = client.get(f"/api/team/projects/{pid}/events", headers=as_("student2"))
        assert other.status_code == 429 and other.json()["error"] == "too_many_streams"
    assert team_projects._stream_counts == {}


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


# 7. Clients can't raise the project's version bar past what the server knows ---------------------


def _meta(client, name="Robotics"):
    return json.loads((client.drive / TP / f"{name}.fcteam" / "meta.json").read_text())


def test_schema_above_server_max_refused(client):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    too_new = team_projects.MAX_SCHEMA_VERSION + 1
    r = put(client, pid, 2, token, 0, schema_version=too_new)
    assert r.status_code == 400 and r.json()["error"] == "schema_unsupported"
    assert r.json()["max_schema_version"] == team_projects.MAX_SCHEMA_VERSION
    assert _meta(client)["schema_version"] == APP["schema_version"]
    body = {"name": "Other", **APP, "schema_version": too_new}
    made = client.post("/api/team/projects", json=body, headers=as_("student1"))
    assert made.status_code == 400 and made.json()["error"] == "schema_unsupported"


def test_newer_schema_never_raises_min_app_version(client, monkeypatch):
    monkeypatch.setattr(team_projects, "MAX_SCHEMA_VERSION", 18)
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    assert put(client, pid, 2, token, 0, schema_version=18, app_version="999999.0.0").status_code == 200
    meta = _meta(client)
    assert meta["schema_version"] == 18 and meta["min_app_version"] == "0"
    assert put(client, pid, 2, token, 1, schema_version=18, app_version="0.0.1").status_code == 200


# Low: locks on sequences that don't exist ----------------------------------------------------------


def test_lock_needs_an_existing_sequence_or_own_slot(client):
    pid = create(client)["id"]  # student1 has slot 1
    assert lock(client, pid, 9007199254740991).status_code == 404
    assert lock(client, pid, 999).status_code == 404  # slot 0, not on disk
    assert lock(client, pid, (2 << 40) | 1).status_code == 404  # someone else's slot
    assert lock(client, pid, (1 << 40) | 7).status_code == 200  # a new sequence in my slot
    assert lock(client, pid, 3).status_code == 200  # on disk
    client.get(f"/api/team/projects/{pid}", headers=as_("student2"))  # student2 gets slot 2
    assert lock(client, pid, (2 << 40) | 1, user="student2").status_code == 200


def test_expired_lock_rows_are_pruned(tmp_path):
    now = [1_800_000_000.0]
    st = TeamStore(tmp_path / "t.sqlite3", clock=lambda: now[0], lock_ttl_s=10)
    pid = st.create_project(f"{TP}/X.fcteam", "X", "student1")
    for seq in range(1, 6):
        assert st.take_lock(pid, seq, "student1").ok
    now[0] += 11
    assert st.take_lock(pid, 99, "student1").ok
    with st._conn() as conn:
        assert [r[0] for r in conn.execute("SELECT seq_id FROM locks")] == [99]


# Low: POST shared has the same version gate as PUT --------------------------------------------------


def test_shared_post_needs_versions(client):
    pid = create(client)["id"]
    no_versions = client.post(f"/api/team/projects/{pid}/shared", json={"base_rev": 0},
                              headers=as_("student1"))
    assert no_versions.status_code == 400
    old = _shared(client, pid, {"base_rev": 0, "schema_version": APP["schema_version"] - 1})
    assert old.status_code == 426 and old.json()["schema_version"] == APP["schema_version"]
    too_new = _shared(client, pid, {"base_rev": 0, "schema_version": team_projects.MAX_SCHEMA_VERSION + 1})
    assert too_new.status_code == 400 and too_new.json()["error"] == "schema_unsupported"
    assert _shared(client, pid, {"base_rev": 0}).status_code == 200


# Low: media upload folders can't be named .fcteam --------------------------------------------------


def test_media_upload_path_refuses_fcteam_segments(client):
    pid = create(client)["id"]
    for path in ["Fake.fcteam", "a/Fake.FCTEAM", "Fake.fcteam/b"]:
        r = client.post(f"/api/team/projects/{pid}/media/upload/init",
                        json={"name": "A001.mov", "size": 1, "path": path}, headers=as_("student1"))
        assert r.status_code == 400, path
    assert not any(p.name.lower().endswith(".fcteam") for p in (client.drive / TP / "Robotics Media").rglob("*"))


# Low: writes reach the disk before they count ---------------------------------------------------


def test_write_bytes_fsyncs_file_and_folder(tmp_path, monkeypatch):
    synced = []
    real = os.fsync
    monkeypatch.setattr(team_files.os, "fsync", lambda fd: (synced.append(fd), real(fd)))
    team_files._write_bytes(tmp_path / "a.json", b"{}")
    assert (tmp_path / "a.json").read_bytes() == b"{}" and len(synced) == 2
