import json
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import cli_tokens  # noqa: E402
import fsops  # noqa: E402
import main  # noqa: E402
import team_projects  # noqa: E402

ORIGIN = "https://drive.example.com"
USERS = {
    "student1": {"username": "student1", "uid": 1001, "gid": 100, "email": "student1@example.org"},
    "student2": {"username": "student2", "uid": 1002, "gid": 100, "email": "student2@example.org"},
    "outsider": {"username": "outsider", "uid": 1009, "gid": 100, "email": "outsider@example.org"},
    "admin1": {"username": "admin1", "uid": 1010, "gid": 100, "email": "admin@example.org"},
}
DENIED_UIDS = {1009}
APP = {"app_version": "0.3.0", "schema_version": 17}


def seq_item(seq_id, clips=()):
    return {"id": seq_id, "name": f"Seq {seq_id}", "label": "Forest",
            "kind": {"Sequence": {"video_tracks": [{"clips": [{"id": 900 + i, "item": item}
                                                              for i, item in enumerate(clips)]}]}}}


def media_item(item_id, name="A001.mov"):
    return {"id": item_id, "name": name, "label": "Iris",
            "kind": {"Media": {"path": f"drive:/Team Projects/Robotics Media/{name}", "fingerprint": "ab"}}}


def demo_project():
    return {"name": "Robotics", "settings": {}, "root": {"name": "root", "children": []},
            "items": {"1": media_item(1), "2": seq_item(2, clips=[1]), "3": seq_item(3)},
            "next_id": 4}


@pytest.fixture
def drive(tmp_path, monkeypatch):
    root = tmp_path / "drive"
    root.mkdir()
    monkeypatch.setenv("DRIVE_ROOT", str(root))
    main.get_settings.cache_clear()

    @contextmanager
    def fake_as_user(uid, gid, username=None):
        # Stand-in for the setuid switch: holds the real lock and lets the
        # "OS" refuse members without access to the project folder.
        assert fsops._as_user_lock.acquire(timeout=2), "as_user lock held elsewhere"
        try:
            if uid in DENIED_UIDS:
                raise PermissionError(13, "Permission denied")
            yield
        finally:
            fsops._as_user_lock.release()

    monkeypatch.setattr(fsops, "as_user", fake_as_user)
    return root


@pytest.fixture
def client(drive, monkeypatch):
    def require_user(request):
        name = request.headers.get("X-Test-User")
        if name not in USERS:
            raise HTTPException(status_code=401, detail="Not authenticated")
        return dict(USERS[name])

    monkeypatch.setattr(main, "_require_user", require_user)
    monkeypatch.setattr(main, "is_nas_admin", lambda name: name == "admin1")
    monkeypatch.setattr(team_projects, "KEEPALIVE_S", 0.05)
    test_client = TestClient(main.app, base_url=ORIGIN)
    test_client.drive = drive
    return test_client


def as_(user):
    return {"X-Test-User": user}


def create(client, user="student1", name="Robotics", project=None):
    body = {"name": name, "project": project if project is not None else demo_project(), **APP}
    r = client.post("/api/team/projects", json=body, headers=as_(user))
    assert r.status_code == 200, r.text
    return r.json()


def lock(client, pid, seq, user="student1", device=None):
    headers = as_(user) if device is None else {**as_(user), "X-Drive-Device": device}
    return client.post(f"/api/team/projects/{pid}/sequences/{seq}/lock", headers=headers)


def put(client, pid, seq, token, base_rev, user="student1", **extra):
    body = {"token": token, "base_rev": base_rev, "json": seq_item(seq, clips=[1]), **APP, **extra}
    return client.put(f"/api/team/projects/{pid}/sequences/{seq}", json=body, headers=as_(user))


def test_requires_auth(client):
    assert client.get("/api/team/projects").status_code == 401


def test_bearer_token_accepted(drive, monkeypatch):
    monkeypatch.setattr(cli_tokens, "lookup", lambda token: dict(USERS["student1"], cli_token_id="t1")
                        if token == "ifd_test" else None)
    c = TestClient(main.app, base_url=ORIGIN)
    r = c.get("/api/team/projects", headers={"Authorization": "Bearer ifd_test"})
    assert r.status_code == 200 and r.json() == []
    assert c.get("/api/team/projects", headers={"Authorization": "Bearer ifd_bad"}).status_code == 401


def test_create_and_get(client):
    made = create(client)
    assert len(made["id"]) == 32 and made["slot"] == 1
    folder = client.drive / "Team Projects" / "Robotics.fcteam"
    assert (folder / "project.json").is_file() and (folder / "sequences" / "2.json").is_file()
    assert (client.drive / "Team Projects" / "Robotics Media").is_dir()
    meta = json.loads((folder / "meta.json").read_text())
    assert meta["id"] == made["id"] and meta["created_by"] == "student1"
    assert meta["schema_version"] == 17 and set(meta["file_hashes"]) == {
        "project.json", "sequences/2.json", "sequences/3.json"}

    listed = client.get("/api/team/projects", headers=as_("student2")).json()
    assert [p["id"] for p in listed] == [made["id"]]
    assert listed[0]["name"] == "Robotics" and listed[0]["folder"] == "Team Projects/Robotics.fcteam"
    assert listed[0]["locks"] == {}

    got = client.get(f"/api/team/projects/{made['id']}", headers=as_("student2")).json()
    assert got["id"] == made["id"] and got["name"] == "Robotics" and got["slot"] == 2
    assert set(got["shared"]["items"]) == {"1"}
    assert got["sequences"]["2"] == {"rev": 0, "json": seq_item(2, clips=[1])}
    assert got["shared_rev"] == 0 and got["locks"] == {}
    assert got["meta"]["id"] == made["id"]


def test_create_duplicate_name_conflict(client):
    create(client)
    r = client.post("/api/team/projects", json={"name": "Robotics", **APP}, headers=as_("student1"))
    assert r.status_code == 409


def test_create_rejects_bad_name(client):
    for name in ["", "../x", "a/b", ".hidden"]:
        r = client.post("/api/team/projects", json={"name": name, **APP}, headers=as_("student1"))
        assert r.status_code == 400, name


def test_lock_conflict_returns_holder(client):
    pid = create(client)["id"]
    first = lock(client, pid, 2)
    assert first.status_code == 200 and first.json()["token"] and first.json()["expires_at"] > time.time()
    second = lock(client, pid, 2, user="student2")
    assert second.status_code == 409 and second.json()["holder"] == "student1"
    listed = client.get("/api/team/projects", headers=as_("student2")).json()
    assert listed[0]["locks"]["2"]["holder"] == "student1"


def test_lock_same_account_two_macs(client):
    pid = create(client)["id"]
    first = lock(client, pid, 2, device="Edit Mac")
    assert first.status_code == 200
    again = lock(client, pid, 2, device="Edit Mac")
    assert again.status_code == 200 and again.json()["token"] == first.json()["token"]
    other = lock(client, pid, 2, device="Home Mac")
    assert other.status_code == 409
    body = other.json()
    assert body["holder"] == "student1" and body["device"] == "Edit Mac" and body["expires_at"] > time.time()
    # The first Mac's token still works.
    assert put(client, pid, 2, first.json()["token"], 0).status_code == 200


def test_lock_held_by_teammate_hides_device(client):
    pid = create(client)["id"]
    lock(client, pid, 2, device="Edit Mac")
    body = lock(client, pid, 2, user="student2", device="Home Mac").json()
    assert body["holder"] == "student1" and body["device"] is None


def test_lock_rejects_bad_device_header(client):
    pid = create(client)["id"]
    assert lock(client, pid, 2, device="x" * 65).status_code == 400
    assert lock(client, pid, 2, device="bad\tname").status_code == 400


def test_heartbeat_and_release(client):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    hb = client.post(f"/api/team/projects/{pid}/sequences/2/lock/heartbeat", json={"token": token},
                     headers=as_("student1"))
    assert hb.status_code == 200 and hb.json()["expires_at"] > time.time()
    bad = client.post(f"/api/team/projects/{pid}/sequences/2/lock/heartbeat", json={"token": "nope"},
                      headers=as_("student1"))
    assert bad.status_code == 409
    rel = client.request("DELETE", f"/api/team/projects/{pid}/sequences/2/lock", json={"token": token},
                         headers=as_("student1"))
    assert rel.status_code == 200
    assert lock(client, pid, 2, user="student2").status_code == 200


def test_put_requires_current_lock(client):
    pid = create(client)["id"]
    assert put(client, pid, 2, "no-token", 0).status_code == 409
    token = lock(client, pid, 2).json()["token"]
    ok = put(client, pid, 2, token, 0)
    assert ok.status_code == 200 and ok.json() == {"rev": 1}
    client.post(f"/api/team/projects/{pid}/sequences/2/lock/force", headers=as_("admin1"))
    lost = put(client, pid, 2, token, 1)
    assert lost.status_code == 409 and lost.json()["error"] == "lock_lost"


def test_put_stale_base_rejected(client):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    assert put(client, pid, 2, token, 0).json() == {"rev": 1}
    stale = put(client, pid, 2, token, 0)
    assert stale.status_code == 409 and stale.json()["error"] == "stale" and stale.json()["rev"] == 1


def test_put_sequence_must_match_path(client):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    body = {"token": token, "base_rev": 0, "json": seq_item(3), **APP}
    assert client.put(f"/api/team/projects/{pid}/sequences/2", json=body, headers=as_("student1")).status_code == 400
    body["json"] = media_item(2)
    assert client.put(f"/api/team/projects/{pid}/sequences/2", json=body, headers=as_("student1")).status_code == 400


def test_new_sequence_via_put(client):
    pid = create(client)["id"]
    seq = (1 << 40) | 1
    token = lock(client, pid, seq).json()["token"]
    assert put(client, pid, seq, token, 0).json() == {"rev": 1}
    got = client.get(f"/api/team/projects/{pid}", headers=as_("student2")).json()
    assert got["sequences"][str(seq)]["rev"] == 1


def test_shared_add_merges_concurrent(client):
    pid = create(client)["id"]
    a = client.post(f"/api/team/projects/{pid}/shared",
                    json={"base_rev": 0, "upserts": {"10": media_item(10, "B.mov")}, "deletes": []},
                    headers=as_("student1"))
    b = client.post(f"/api/team/projects/{pid}/shared",
                    json={"base_rev": 0, "upserts": {"11": media_item(11, "C.mov")}, "deletes": []},
                    headers=as_("student2"))
    assert a.status_code == 200 and b.status_code == 200
    assert {a.json()["rev"], b.json()["rev"]} == {1, 2}
    got = client.get(f"/api/team/projects/{pid}", headers=as_("student1")).json()
    assert set(got["shared"]["items"]) == {"1", "10", "11"} and got["shared_rev"] == 2


def bin_tree(*children):
    """FilmCraft's root bin: entries are {"Item": id} or {"Bin": {id, name, children}}."""
    return {"id": 0, "name": "Robotics", "children": list(children)}


def binned(node):
    out = []
    for entry in node["children"]:
        out += [entry["Item"]] if "Item" in entry else binned(entry["Bin"])
    return out


def shared_post(client, pid, user, base, upserts=None, bins=None):
    body = {"base_rev": base, "upserts": upserts or {}, "deletes": []}
    if bins is not None:
        body["bins"] = bins
    r = client.post(f"/api/team/projects/{pid}/shared", json=body, headers=as_(user))
    assert r.status_code == 200, r.text
    return r.json()["rev"]


def test_concurrent_imports_never_lose_a_bin_entry(client):
    pid = create(client)["id"]
    # student1 imports A002 and files it in the root bin.
    shared_post(client, pid, "student1", 0, {"10": media_item(10, "A002.mov")}, bin_tree({"Item": 1}, {"Item": 10}))
    # student2 imported B001 at the same time, without seeing student1's import …
    rev = shared_post(client, pid, "student2", 0, {"11": media_item(11, "B001.mov")})
    # … then saves its own bin tree (made before A002 arrived) at the latest rev.
    shared_post(client, pid, "student2", rev, None,
                bin_tree({"Item": 1}, {"Bin": {"id": 50, "name": "Day 2", "children": [{"Item": 11}]}}))
    root = client.get(f"/api/team/projects/{pid}", headers=as_("student1")).json()["shared"]["root"]
    assert sorted(binned(root)) == [1, 10, 11]
    assert root["children"][-1] == {"Item": 10}  # the repair puts it in the root bin
    assert root["children"][1]["Bin"]["children"] == [{"Item": 11}]


def test_upsert_without_bins_files_new_media_in_root(client):
    pid = create(client, project={**demo_project(), "root": bin_tree({"Item": 1})})["id"]
    shared_post(client, pid, "student2", 0, {"11": media_item(11, "B001.mov")})
    root = client.get(f"/api/team/projects/{pid}", headers=as_("student1")).json()["shared"]["root"]
    assert root == bin_tree({"Item": 1}, {"Item": 11})


def test_shared_bins_need_current_base(client):
    pid = create(client)["id"]
    client.post(f"/api/team/projects/{pid}/shared", json={"base_rev": 0, "upserts": {}, "deletes": []},
                headers=as_("student1"))
    stale = client.post(f"/api/team/projects/{pid}/shared",
                        json={"base_rev": 0, "upserts": {}, "deletes": [], "bins": {"name": "root"}},
                        headers=as_("student2"))
    assert stale.status_code == 409 and stale.json()["error"] == "stale" and stale.json()["rev"] == 1
    ok = client.post(f"/api/team/projects/{pid}/shared",
                     json={"base_rev": 1, "upserts": {}, "deletes": [], "bins": bin_tree({"Item": 1})},
                     headers=as_("student2"))
    assert ok.status_code == 200
    got = client.get(f"/api/team/projects/{pid}", headers=as_("student1")).json()
    assert got["shared"]["root"] == bin_tree({"Item": 1})


def test_shared_rejects_sequence_upsert(client):
    pid = create(client)["id"]
    r = client.post(f"/api/team/projects/{pid}/shared",
                    json={"base_rev": 0, "upserts": {"5": seq_item(5)}, "deletes": []}, headers=as_("student1"))
    assert r.status_code == 400
    r = client.post(f"/api/team/projects/{pid}/shared",
                    json={"base_rev": 0, "upserts": {"5": media_item(6)}, "deletes": []}, headers=as_("student1"))
    assert r.status_code == 400


def test_delete_referenced_item_refused(client):
    pid = create(client)["id"]
    client.post(f"/api/team/projects/{pid}/shared",
                json={"base_rev": 0, "upserts": {"10": media_item(10)}, "deletes": []}, headers=as_("student1"))
    used = client.post(f"/api/team/projects/{pid}/shared", json={"base_rev": 1, "upserts": {}, "deletes": [1]},
                       headers=as_("student1"))
    assert used.status_code == 409 and used.json()["item"] == 1
    free = client.post(f"/api/team/projects/{pid}/shared", json={"base_rev": 1, "upserts": {}, "deletes": [10]},
                       headers=as_("student1"))
    assert free.status_code == 200
    got = client.get(f"/api/team/projects/{pid}", headers=as_("student1")).json()
    assert set(got["shared"]["items"]) == {"1"}


def test_old_app_rejected_426(client):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    old_schema = put(client, pid, 2, token, 0, schema_version=16)
    assert old_schema.status_code == 426 and old_schema.json()["schema_version"] == 17
    newer = put(client, pid, 2, token, 0, schema_version=18, app_version="0.4.0")
    assert newer.status_code == 200
    old_app = put(client, pid, 2, token, 1, schema_version=18, app_version="0.3.9")
    assert old_app.status_code == 426 and old_app.json()["min_app_version"] == "0.4.0"
    assert put(client, pid, 2, token, 1, app_version="x.y").status_code == 400


def test_hash_mismatch_409(client):
    pid = create(client)["id"]
    seq_file = client.drive / "Team Projects" / "Robotics.fcteam" / "sequences" / "2.json"
    seq_file.write_text(json.dumps(seq_item(2)))
    r = client.get(f"/api/team/projects/{pid}", headers=as_("student1"))
    assert r.status_code == 409
    assert r.json()["error"] == "files_changed"
    assert r.json()["message"] == "project files were changed outside InFocus Cut"


def test_extra_sequence_file_is_a_mismatch(client):
    pid = create(client)["id"]
    extra = client.drive / "Team Projects" / "Robotics.fcteam" / "sequences" / "99.json"
    extra.write_text(json.dumps(seq_item(99)))
    assert client.get(f"/api/team/projects/{pid}", headers=as_("student1")).status_code == 409


def test_user_without_folder_access_403(client):
    pid = create(client)["id"]
    assert client.get(f"/api/team/projects/{pid}", headers=as_("outsider")).status_code == 403
    assert lock(client, pid, 2, user="outsider").status_code == 403
    assert client.get("/api/team/projects", headers=as_("outsider")).json() == []
    r = client.post(f"/api/team/projects/{pid}/shared", json={"base_rev": 0, "upserts": {}, "deletes": []},
                    headers=as_("outsider"))
    assert r.status_code == 403
    assert client.get(f"/api/team/projects/{pid}/events", headers=as_("outsider")).status_code == 403


def test_unknown_project_404(client):
    assert client.get("/api/team/projects/" + "0" * 32, headers=as_("student1")).status_code == 404
    assert client.get("/api/team/projects/not-an-id", headers=as_("student1")).status_code == 404


def test_force_release_admin_only(client):
    pid = create(client)["id"]
    lock(client, pid, 2)
    assert client.post(f"/api/team/projects/{pid}/sequences/2/lock/force", headers=as_("student2")).status_code == 403
    assert lock(client, pid, 2, user="student2").status_code == 409
    assert client.post(f"/api/team/projects/{pid}/sequences/2/lock/force", headers=as_("admin1")).status_code == 200
    assert lock(client, pid, 2, user="student2").status_code == 200


def test_keep_creator_or_admin(client):
    pid = create(client)["id"]
    url = f"/api/team/projects/{pid}/keep"
    assert client.post(url, json={"keep": True}, headers=as_("student2")).status_code == 403
    assert client.post(url, json={"keep": True}, headers=as_("student1")).json() == {"keep": True}
    assert client.post(url, json={"keep": False}, headers=as_("admin1")).json() == {"keep": False}
    assert team_projects.store().is_keep(pid) is False


def test_open_records_last_open(client):
    pid = create(client)["id"]
    store = team_projects.store()
    store.mark_notified(pid)
    r = client.post(f"/api/team/projects/{pid}/open", headers=as_("student2"))
    assert r.status_code == 200 and r.json()["ok"] is True
    assert not store.notified(pid) and "student2" in store.members(pid)


def read_event(lines):
    """Next SSE event (name, data), skipping comments."""
    name, data = None, None
    for line in lines:
        if line.startswith(":") or not line:
            if name is not None and not line:
                return name, data
            continue
        key, _, value = line.partition(": ")
        if key == "event":
            name = value
        elif key == "data":
            data = json.loads(value)
    raise AssertionError("stream ended")


def test_events_stream_sends_sequence_updated(client):
    pid = create(client)["id"]
    token = lock(client, pid, 2).json()["token"]
    with client.stream("GET", f"/api/team/projects/{pid}/events", headers=as_("student2")) as stream:
        assert stream.status_code == 200
        assert stream.headers["content-type"].startswith("text/event-stream")
        lines = stream.iter_lines()
        assert next(lines).startswith(":")  # subscribed
        assert put(client, pid, 2, token, 0).status_code == 200
        assert read_event(lines) == ("sequence_updated", {"seq": 2, "rev": 1, "by": "student1"})
        client.post(f"/api/team/projects/{pid}/shared", json={"base_rev": 0, "upserts": {}, "deletes": []},
                    headers=as_("student1"))
        assert read_event(lines) == ("shared_updated", {"rev": 1})
        client.request("DELETE", f"/api/team/projects/{pid}/sequences/2/lock", json={"token": token},
                       headers=as_("student1"))
        assert read_event(lines) == ("lock_changed", {"seq": 2, "holder": None})


def test_as_user_lock_not_held_during_sse(client):
    pid = create(client)["id"]
    with client.stream("GET", f"/api/team/projects/{pid}/events", headers=as_("student2")) as stream:
        lines = stream.iter_lines()
        next(lines)
        assert not fsops._as_user_lock.locked()
        # Other members' file work goes through while the stream is open.
        assert lock(client, pid, 2).status_code == 200
        assert client.get(f"/api/team/projects/{pid}", headers=as_("student1")).status_code == 200
        assert not fsops._as_user_lock.locked()


FCTEAM = "Team Projects/Robotics.fcteam"


@pytest.fixture
def web(client, monkeypatch):
    """The client, with the normal file routes pointed at the test drive."""
    monkeypatch.setattr(main, "share_path", lambda share: client.drive)
    return client


def test_web_mutation_inside_fcteam_refused(web):
    client = web
    create(client)
    h = as_("student1")
    attempts = [
        ("/api/mkdir", {"path": FCTEAM, "name": "x"}),
        ("/api/mkdir", {"path": f"{FCTEAM}/sequences", "name": "x"}),
        ("/api/rename", {"path": f"{FCTEAM}/project.json", "new_name": "p.json"}),
        ("/api/rename", {"path": FCTEAM, "new_name": "Other.fcteam"}),
        ("/api/delete", {"path": f"{FCTEAM}/meta.json"}),
        ("/api/move", {"path": f"{FCTEAM}/sequences/2.json", "dest": "Team Projects"}),
        ("/api/move", {"path": FCTEAM, "dest": "Team Projects/Robotics Media"}),
        ("/api/move", {"path": "Team Projects/Robotics Media", "dest": FCTEAM}),
        ("/api/upload/init", {"path": f"{FCTEAM}/sequences", "name": "9.json", "size": "3"}),
        ("/api/upload/init", {"path": "Team Projects", "name": "Fake.fcteam", "size": "3"}),
    ]
    for url, data in attempts:
        r = client.post(url, data=data, headers=h)
        assert r.status_code in (400, 403), (url, data, r.status_code, r.text)
    r = client.post("/api/upload", data={"path": FCTEAM}, files={"file": ("x.json", b"{}")}, headers=h)
    assert r.status_code == 403
    r = client.post("/api/upload", data={"path": f"{FCTEAM}/deep/er"}, files={"file": ("x.json", b"{}")}, headers=h)
    assert r.status_code == 403
    folder = client.drive / FCTEAM
    assert sorted(p.name for p in folder.iterdir()) == ["meta.json", "project.json", "sequences"]
    assert client.get(f"/api/team/projects/{client.get('/api/team/projects', headers=h).json()[0]['id']}",
                      headers=h).status_code == 200


def test_web_refuses_new_fcteam_names(web):
    client = web
    (client.drive / "Shows").mkdir()
    h = as_("student1")
    assert client.post("/api/mkdir", data={"path": "Shows", "name": "Fake.fcteam"}, headers=h).status_code == 400
    assert client.post("/api/rename", data={"path": "Shows", "new_name": "Shows.fcteam"},
                       headers=h).status_code == 400
    assert (client.drive / "Shows").is_dir() and not (client.drive / "Shows" / "Fake.fcteam").exists()


def test_web_can_still_delete_whole_project_and_use_media_folder(web):
    client = web
    create(client)
    h = as_("student1")
    (client.drive / "#recycle").mkdir()
    r = client.post("/api/upload", data={"path": "Team Projects/Robotics Media"},
                    files={"file": ("A002.mov", b"xx")}, headers=h)
    assert r.status_code == 200, r.text
    r = client.post("/api/delete", data={"path": FCTEAM}, headers=h)
    assert r.status_code == 200, r.text
    assert (client.drive / "#recycle" / FCTEAM).is_dir()


def test_symlink_into_fcteam_refused(web):
    client = web
    create(client)
    (client.drive / "Shortcut").symlink_to(client.drive / FCTEAM)
    r = client.post("/api/delete", data={"path": "Shortcut/meta.json"}, headers=as_("student1"))
    assert r.status_code in (400, 403)
    assert (client.drive / FCTEAM / "meta.json").is_file()


MEDIA = "Team Projects/Robotics Media"


@pytest.fixture
def media(client, tmp_path, monkeypatch):
    """A project with one original, while the member's active share is some other folder."""
    import chunk_upload
    monkeypatch.setattr(chunk_upload, "SESSION_ROOT", tmp_path / "chunks")
    chunk_upload._sessions.clear()
    other = tmp_path / "other share"
    (other / MEDIA).mkdir(parents=True)
    (other / MEDIA / "A001.mov").write_bytes(b"wrong share")
    monkeypatch.setattr(main, "share_path", lambda share: other)
    pid = create(client)["id"]
    (client.drive / MEDIA / "Day 1").mkdir()
    (client.drive / MEDIA / "Day 1" / "A001.mov").write_bytes(b"0123456789")
    client.pid = pid
    return client


def get_media(client, path, user="student1", **headers):
    return client.get(f"/api/team/projects/{client.pid}/media", params={"path": path},
                      headers={**as_(user), **headers})


def test_media_download_reads_team_folder_not_active_share(media):
    r = get_media(media, "Day 1/A001.mov")
    assert r.status_code == 200 and r.content == b"0123456789"
    assert r.headers["accept-ranges"] == "bytes" and r.headers["etag"]
    assert r.headers["content-security-policy"] == "sandbox"


def test_media_download_range_and_if_range(media):
    full = get_media(media, "Day 1/A001.mov")
    etag = full.headers["etag"]
    part = get_media(media, "Day 1/A001.mov", Range="bytes=2-5")
    assert part.status_code == 206 and part.content == b"2345"
    assert part.headers["content-range"] == "bytes 2-5/10"
    same = get_media(media, "Day 1/A001.mov", Range="bytes=8-", **{"If-Range": etag})
    assert same.status_code == 206 and same.content == b"89"
    changed = get_media(media, "Day 1/A001.mov", Range="bytes=8-", **{"If-Range": '"old"'})
    assert changed.status_code == 200 and changed.content == b"0123456789"


def test_media_download_refuses_paths_outside_media(media):
    (media.drive / MEDIA / "link.json").symlink_to(media.drive / FCTEAM / "meta.json")
    (media.drive / MEDIA / "Linked").symlink_to(media.drive / FCTEAM)
    (media.drive / "Team Projects" / "secret.mov").write_bytes(b"no")
    for bad in ["", "../secret.mov", "/etc/passwd", "Day 1/../../secret.mov", "./A.mov", "a\\b.mov",
                "../Robotics.fcteam/meta.json"]:
        assert get_media(media, bad).status_code == 400, bad
    for hidden in ["link.json", "Linked/meta.json", "Day 1", "missing.mov"]:
        assert get_media(media, hidden).status_code == 404, hidden


def test_media_download_needs_project_access(media):
    assert get_media(media, "Day 1/A001.mov", user="outsider").status_code == 403
    assert media.get(f"/api/team/projects/{media.pid}/media", params={"path": "Day 1/A001.mov"}).status_code == 401
    assert media.get("/api/team/projects/" + "0" * 32 + "/media", params={"path": "A001.mov"},
                     headers=as_("student1")).status_code == 404


def upload_init(client, user="student1", **body):
    return client.post(f"/api/team/projects/{client.pid}/media/upload/init", json=body, headers=as_(user))


def test_media_upload_lands_in_team_media_folder(media):
    data = b"fresh footage"
    init = upload_init(media, path="Day 2", name="B001.mov", size=len(data))
    assert init.status_code == 200, init.text
    upload_id = init.json()["upload_id"]
    r = media.put("/api/upload/chunk", params={"upload_id": upload_id, "index": 0}, content=data,
                  headers=as_("student1"))
    assert r.status_code == 200, r.text
    # The generic complete resolves a share; the team marker is no valid share id (400), and
    # even a share that resolves elsewhere can't take the partial file (409).
    import shares
    with pytest.raises(fsops.FSError):
        shares.share_path(f"@team:{media.pid}")
    assert media.post("/api/upload/complete", data={"upload_id": upload_id},
                      headers=as_("student1")).status_code in (400, 409)
    done = media.post(f"/api/team/projects/{media.pid}/media/upload/complete", json={"upload_id": upload_id},
                      headers=as_("student1"))
    assert done.status_code == 200, done.text
    assert (media.drive / MEDIA / "Day 2" / "B001.mov").read_bytes() == data
    assert get_media(media, "Day 2/B001.mov").content == data


def test_media_upload_complete_checks_project_and_owner(media):
    upload_id = upload_init(media, name="B001.mov", size=4).json()["upload_id"]
    assert media.post(f"/api/team/projects/{media.pid}/media/upload/complete", json={"upload_id": upload_id},
                      headers=as_("student2")).status_code in (403, 404)
    other = create(media, name="Band")["id"]
    assert media.post(f"/api/team/projects/{other}/media/upload/complete", json={"upload_id": upload_id},
                      headers=as_("student1")).status_code == 400


def test_media_upload_init_validation(media):
    assert upload_init(media, path="../Robotics.fcteam", name="x.mov", size=4).status_code == 400
    assert upload_init(media, name="../x.mov", size=4).status_code == 400
    assert upload_init(media, name="Fake.fcteam", size=4).status_code == 400
    assert upload_init(media, name="x.mov", size=-1).status_code == 400
    assert upload_init(media, name="x.mov", size=60 * 1024 ** 4).status_code == 413
    assert upload_init(media, user="outsider", name="x.mov", size=4).status_code == 403


def test_every_409_has_an_error_code(client):
    pid = create(client)["id"]
    h = as_("student1")
    token = lock(client, pid, 2).json()["token"]
    held = lock(client, pid, 2, user="student2")
    assert held.json()["error"] == "lock_held" and held.json()["holder"] == "student1"
    assert held.json()["expires_at"] > time.time() and held.json()["message"]
    assert put(client, pid, 2, token, 0).json()["rev"] == 1
    stale = put(client, pid, 2, token, 0).json()
    assert stale["error"] == "stale" and stale["rev"] == 1
    lost = put(client, pid, 2, "nope", 1).json()
    assert lost["error"] == "lock_lost" and lost["message"]
    hb = client.post(f"/api/team/projects/{pid}/sequences/2/lock/heartbeat", json={"token": "nope"}, headers=h)
    assert hb.status_code == 409 and hb.json()["error"] == "lock_lost"
    rel = client.request("DELETE", f"/api/team/projects/{pid}/sequences/2/lock", json={"token": "nope"}, headers=h)
    assert rel.status_code == 409 and rel.json()["error"] == "lock_lost"
    used = client.post(f"/api/team/projects/{pid}/shared", json={"base_rev": 0, "upserts": {}, "deletes": [1]},
                       headers=h)
    assert used.status_code == 409 and used.json()["error"] == "item_in_use" and used.json()["item"] == 1
    dup = client.post("/api/team/projects", json={"name": "Robotics", **APP}, headers=h)
    assert dup.status_code == 409 and dup.json()["error"] == "name_taken" and dup.json()["detail"]
    seq_file = client.drive / "Team Projects" / "Robotics.fcteam" / "sequences" / "3.json"
    seq_file.write_text(json.dumps(seq_item(3, clips=[1])))
    changed = client.get(f"/api/team/projects/{pid}", headers=h)
    assert changed.status_code == 409 and changed.json()["error"] == "files_changed"
    assert "changed outside" in changed.json()["message"]
