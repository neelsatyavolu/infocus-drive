"""Team project members and invites: who can see and use a project, and how people join."""

import json
import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
import team_members  # noqa: E402
import team_people  # noqa: E402
from fastapi import HTTPException  # noqa: E402
from test_team_projects import APP, USERS, as_, client, create, drive, lock  # noqa: E402,F401

PEOPLE = {
    "student1": "Student One",
    "student2": "Student Two",
    "student3": "Student Three",
    "admin1": "admin1",
}
META = "Team Projects/Robotics.fcteam/meta.json"
MEDIA = "Team Projects/Robotics Media"


@pytest.fixture
def team(client, monkeypatch):
    monkeypatch.setattr(team_people, "directory", lambda: dict(PEOPLE))
    sent = []
    monkeypatch.setattr(team_members, "send_invite_email", lambda *args: sent.append(args))
    monkeypatch.setattr(team_members, "_deliver", lambda fn, *args: fn(*args))  # inline, not a thread

    def require_user(request):  # the suite's members, plus fictional pupil0… for bigger teams
        name = request.headers.get("X-Test-User") or ""
        if name in USERS:
            return dict(USERS[name])
        if name.startswith("pupil"):
            return {"username": name, "uid": 2000 + int(name[5:]), "gid": 100}
        raise HTTPException(status_code=401, detail="Not authenticated")

    monkeypatch.setattr(main, "_require_user", require_user)
    client.sent = sent
    return client


def make(client, user="student1", name="Robotics"):
    return create(client, user=user, name=name, open_to_all=False)["id"]


def meta(client, name="Robotics"):
    return json.loads((client.drive / "Team Projects" / f"{name}.fcteam" / "meta.json").read_text())


def invite(client, pid, users, user="student1"):
    return client.post(f"/api/team/projects/{pid}/invites", json={"users": users}, headers=as_(user))


def listed(client, user):
    return {p["id"]: p for p in client.get("/api/team/projects", headers=as_(user)).json()}


# Create and list -----------------------------------------------------------------


def test_create_makes_the_creator_the_only_member(team):
    pid = make(team)
    m = meta(team)
    assert m["members"] == ["student1"] and m["invites"] == []
    mine = listed(team, "student1")[pid]
    assert mine["role"] == "member" and mine["invited_by"] is None
    assert mine["members"] == [{"username": "student1", "name": "Student One"}]
    assert mine["invites"] == []
    assert listed(team, "student2") == {}


def test_legacy_project_without_members_is_open(team):
    pid = create(team)["id"]  # open_to_all: meta.json has no "members"
    for user in ("student1", "student2"):
        item = listed(team, user)[pid]
        assert item["role"] == "open" and item["members"] == [] and item["invites"] == []
    assert team.get(f"/api/team/projects/{pid}", headers=as_("student2")).status_code == 200


def test_list_counts_media_including_files_added_on_the_website(team):
    pid = make(team)
    (team.drive / MEDIA / "Day 1").mkdir()
    (team.drive / MEDIA / "Day 1" / "A001.mov").write_bytes(b"0123456789")
    (team.drive / MEDIA / "B001.mov").write_bytes(b"abc")
    (team.drive / MEDIA / ".B002.mov.1a2b.partial").write_bytes(b"half")  # an upload in progress
    item = listed(team, "student1")[pid]
    assert item["media_count"] == 2 and item["media_bytes"] == 13


# Non-members ----------------------------------------------------------------------


def project_routes(pid):
    base = f"/api/team/projects/{pid}"
    return [
        ("GET", base, None),
        ("GET", f"{base}/shared", None),
        ("GET", f"{base}/sequences/2", None),
        ("POST", f"{base}/sequences/2/lock", None),
        ("POST", f"{base}/sequences/2/lock/heartbeat", {"token": "x"}),
        ("DELETE", f"{base}/sequences/2/lock", {"token": "x"}),
        ("PUT", f"{base}/sequences/2", {"token": "x", "base_rev": 0, **APP,
                                        "json": {"id": 2, "kind": {"Sequence": {}}}}),
        ("DELETE", f"{base}/sequences/3", {"token": "x", "base_rev": 0}),
        ("POST", f"{base}/shared", {**APP, "base_rev": 0, "upserts": {}, "deletes": []}),
        ("POST", f"{base}/open", None),
        ("POST", f"{base}/keep", {"keep": True}),
        ("GET", f"{base}/media", None),
        ("GET", f"{base}/media?path=A001.mov", None),
        ("POST", f"{base}/media/upload/init", {"name": "x.mov", "size": 1}),
        ("POST", f"{base}/media/upload/complete", {"upload_id": "x"}),
        ("GET", f"{base}/events", None),
        ("POST", f"{base}/invites", {"users": ["student3"]}),
        ("DELETE", f"{base}/invites/student3", None),
        ("POST", f"{base}/leave", None),
        ("POST", f"/api/team/exports/{pid}/begin", None),
        ("POST", f"/api/team/exports/{pid}/end", None),
    ]


@pytest.mark.parametrize("user", ["student2", "student3"])
def test_non_members_and_invitees_get_404_everywhere(team, user):
    pid = make(team)
    assert invite(team, pid, ["student3"]).status_code == 200
    for method, url, body in project_routes(pid):
        r = team.request(method, url, json=body, headers=as_(user))
        assert r.status_code == 404, (method, url, r.status_code, r.text)
    assert meta(team)["members"] == ["student1"]


def test_admin_can_still_force_release_and_set_keep(team):
    pid = make(team)
    assert lock(team, pid, 2).status_code == 200
    r = team.post(f"/api/team/projects/{pid}/sequences/2/lock/force", headers=as_("admin1"))
    assert r.status_code == 200
    r = team.post(f"/api/team/projects/{pid}/keep", json={"keep": True}, headers=as_("admin1"))
    assert r.status_code == 200


# People -----------------------------------------------------------------------------


def test_people_lists_everyone_but_the_caller_without_emails(team):
    r = team.get("/api/team/people", headers=as_("student1"))
    assert r.status_code == 200
    people = r.json()["people"]
    assert {p["username"] for p in people} == {"student2", "student3", "admin1"}
    assert {"username": "student2", "name": "Student Two"} in people
    assert all(set(p) == {"username", "name"} for p in people)
    assert "@" not in r.text
    assert team.get("/api/team/people").status_code == 401


def test_people_from_passwd(tmp_path, monkeypatch):
    passwd = tmp_path / "passwd"
    passwd.write_text("\n".join([
        "root:x:0:0:root:/root:/bin/sh",
        "student1:x:1001:100:Student One <student1@example.org>:/home/student1:/bin/sh",
        "student2:x:1002:100:student2@example.org:/home/student2:/bin/sh",
        "svc:x:1003:100::/home/svc:/bin/sh",  # no email: not a Drive member
        "infocus-drive-svc:x:1004:100:svc@example.org:/home/x:/bin/sh",
        "nobody:x:65534:65534:nobody@example.org:/:/bin/false",
    ]) + "\n")
    monkeypatch.setattr(team_people, "PASSWD_FILES", (passwd,))
    assert team_people.directory() == {"student1": "Student One", "student2": "student2"}


# Invites ------------------------------------------------------------------------------


def test_invite_join_and_use(team):
    pid = make(team)
    r = invite(team, pid, ["student2"])
    assert r.status_code == 200, r.text
    assert r.json() == {"invites": [{"username": "student2", "name": "Student Two", "by": "student1"}]}
    stored = meta(team)["invites"]
    assert stored[0]["user"] == "student2" and stored[0]["by"] == "student1" and isinstance(stored[0]["at"], int)

    seen = listed(team, "student2")[pid]
    assert seen["role"] == "invited" and seen["invited_by"] == "Student One"
    assert seen["invites"] == [{"username": "student2", "name": "Student Two", "by": "student1"}]
    assert seen["members"] == [{"username": "student1", "name": "Student One"}]

    joined = team.post(f"/api/team/projects/{pid}/join", headers={**as_("student2"), "X-Drive-Device": "mac-b"})
    assert joined.status_code == 200, joined.text
    assert joined.json() == {"id": pid, "slot": 2}
    assert meta(team)["members"] == ["student1", "student2"] and meta(team)["invites"] == []
    assert listed(team, "student2")[pid]["role"] == "member"
    assert team.get(f"/api/team/projects/{pid}", headers=as_("student2")).status_code == 200
    again = team.post(f"/api/team/projects/{pid}/join", headers={**as_("student2"), "X-Drive-Device": "mac-b"})
    assert again.json() == {"id": pid, "slot": 2}  # retry-safe


def test_invite_is_idempotent_and_keeps_meta_and_hashes(team):
    pid = make(team)
    before = meta(team)
    assert invite(team, pid, ["student2", "student2"]).status_code == 200
    assert invite(team, pid, ["student2", "student3"]).status_code == 200
    after = meta(team)
    assert [i["user"] for i in after["invites"]] == ["student2", "student3"]
    assert after["file_hashes"] == before["file_hashes"] and after["id"] == pid
    # The project still reads (hashes intact) after the meta.json rewrite.
    assert team.get(f"/api/team/projects/{pid}", headers=as_("student1")).status_code == 200


def test_invite_sends_a_best_effort_email(team):
    pid = make(team)
    invite(team, pid, ["student2"])
    assert team.sent == [("student2", "Student One", "Robotics")]
    invite(team, pid, ["student2"])  # already invited: no second email
    assert len(team.sent) == 1


def test_invite_email_text_and_failures(monkeypatch, caplog):
    calls = []
    monkeypatch.setattr(team_members, "send_notice_email", lambda *a: calls.append(a))
    team_members.send_invite_email("student2", "Student One", "Robotics")
    assert calls == [("student2", "Student One invited you to Robotics in InFocus Cut",
                      "Student One invited you to Robotics in InFocus Cut. Open InFocus Cut ▸ Team to join.")]

    def boom(*a):
        raise RuntimeError("Resend request failed")

    monkeypatch.setattr(team_members, "send_notice_email", boom)
    team_members.send_invite_email("student2", "Student One", "Robotics")  # never raises
    assert "example.org" not in caplog.text


def test_invite_validation(team):
    pid = make(team)
    assert invite(team, pid, []).status_code == 400
    assert invite(team, pid, "student2").status_code == 400
    assert invite(team, pid, [f"user{i}" for i in range(11)]).status_code == 400
    assert invite(team, pid, ["nobody-here"]).status_code == 400
    assert invite(team, pid, ["../etc"]).status_code == 400
    taken = invite(team, pid, ["student1"])
    assert taken.status_code == 409 and taken.json()["error"] == "already_member" and taken.json()["message"]
    assert meta(team)["invites"] == []


def test_team_is_full_at_twelve(team, monkeypatch):
    people = {**PEOPLE, **{f"pupil{i}": f"Pupil {i}" for i in range(20)}}
    monkeypatch.setattr(team_people, "directory", lambda: people)
    pid = make(team)
    assert invite(team, pid, [f"pupil{i}" for i in range(10)]).status_code == 200
    assert invite(team, pid, ["pupil10"]).status_code == 200  # 1 member + 11 invites = 12
    full = invite(team, pid, ["pupil11"])
    assert full.status_code == 409 and full.json()["error"] == "team_full" and full.json()["message"]
    assert len(meta(team)["invites"]) == 11


def test_any_member_cancels_an_invite(team):
    pid = make(team)
    invite(team, pid, ["student2", "student3"])
    team.post(f"/api/team/projects/{pid}/join", headers=as_("student2"))
    r = team.delete(f"/api/team/projects/{pid}/invites/student3", headers=as_("student2"))
    assert r.status_code == 204
    assert meta(team)["invites"] == []
    assert listed(team, "student3") == {}
    assert team.post(f"/api/team/projects/{pid}/join", headers=as_("student3")).status_code == 404


def test_decline(team):
    pid = make(team)
    invite(team, pid, ["student2"])
    assert team.post(f"/api/team/projects/{pid}/decline", headers=as_("student2")).status_code == 204
    assert meta(team)["invites"] == [] and listed(team, "student2") == {}
    assert team.post(f"/api/team/projects/{pid}/decline", headers=as_("student2")).status_code == 404


def test_join_needs_an_invite(team):
    pid = make(team)
    assert team.post(f"/api/team/projects/{pid}/join", headers=as_("student2")).status_code == 404
    assert team.post("/api/team/projects/" + "0" * 32 + "/join", headers=as_("student2")).status_code == 404


def test_open_projects_take_no_invites(team):
    pid = create(team)["id"]
    r = invite(team, pid, ["student2"])
    assert r.status_code == 409 and r.json()["error"] == "open_project"
    assert team.post(f"/api/team/projects/{pid}/join", headers=as_("student2")).json()["id"] == pid


# Leave --------------------------------------------------------------------------------


def test_leave_releases_locks_and_last_member_stays(team):
    pid = make(team)
    invite(team, pid, ["student2"])
    team.post(f"/api/team/projects/{pid}/join", headers=as_("student2"))
    assert lock(team, pid, 2, user="student2").status_code == 200
    assert team.post(f"/api/team/projects/{pid}/leave", headers=as_("student2")).status_code == 204
    assert meta(team)["members"] == ["student1"]
    assert lock(team, pid, 2).status_code == 200  # student2's lock went with them
    assert team.get(f"/api/team/projects/{pid}", headers=as_("student2")).status_code == 404
    last = team.post(f"/api/team/projects/{pid}/leave", headers=as_("student1"))
    assert last.status_code == 409 and last.json()["error"] == "last_member" and last.json()["message"]


# Concurrency ----------------------------------------------------------------------------


def test_concurrent_invites_and_joins_keep_every_change(team, monkeypatch):
    people = {**PEOPLE, **{f"pupil{i}": f"Pupil {i}" for i in range(8)}}
    monkeypatch.setattr(team_people, "directory", lambda: people)
    pid = make(team)
    assert invite(team, pid, [f"pupil{i}" for i in range(4)]).status_code == 200
    errors = []

    def run(fn):
        try:
            fn()
        except Exception as e:  # pragma: no cover - reported below
            errors.append(e)

    jobs = [lambda i=i: team.post(f"/api/team/projects/{pid}/join", headers=as_(f"pupil{i}")) for i in range(4)]
    jobs += [lambda i=i: invite(team, pid, [f"pupil{i}"]) for i in range(4, 8)]
    threads = [threading.Thread(target=run, args=(job,)) for job in jobs]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert not errors
    m = meta(team)
    assert sorted(m["members"]) == sorted(["student1", *(f"pupil{i}" for i in range(4))])
    assert sorted(i["user"] for i in m["invites"]) == [f"pupil{i}" for i in range(4, 8)]


# Media from the Drive website ---------------------------------------------------------------


def test_media_list_shows_files_from_the_website(team, monkeypatch, tmp_path):
    import chunk_upload
    monkeypatch.setattr(chunk_upload, "SESSION_ROOT", tmp_path / "chunks")
    chunk_upload._sessions.clear()
    pid = make(team)
    monkeypatch.setattr(main, "_active_share", lambda request, user: "drive")
    monkeypatch.setattr(main, "share_path", lambda share: team.drive)
    data = b"web footage"
    h = as_("student1")
    init = team.post("/api/upload/init", data={"path": f"{MEDIA}/Day 3", "name": "C001.mov", "size": len(data)},
                     headers=h)
    assert init.status_code == 200, init.text
    upload_id = init.json()["upload_id"]
    assert team.put("/api/upload/chunk", params={"upload_id": upload_id, "index": 0}, content=data,
                    headers=h).status_code == 200
    done = team.post("/api/upload/complete", data={"upload_id": upload_id}, headers=h)
    assert done.status_code == 200, done.text

    r = team.get(f"/api/team/projects/{pid}/media", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["files"] == [{"path": "Day 3/C001.mov", "size": len(data), "mtime": body["files"][0]["mtime"]}]
    assert body["count"] == 1 and body["bytes"] == len(data) and body["truncated"] is False
    got = team.get(f"/api/team/projects/{pid}/media", params={"path": "Day 3/C001.mov"}, headers=h)
    assert got.status_code == 200 and got.content == data


def test_media_list_skips_hidden_and_links(team):
    pid = make(team)
    media = team.drive / MEDIA
    (media / "A001.mov").write_bytes(b"x")
    (media / ".DS_Store").write_bytes(b"x")
    (media / "@eaDir").mkdir()
    (media / "@eaDir" / "thumb.jpg").write_bytes(b"x")
    (media / "link.mov").symlink_to(team.drive / META)
    r = team.get(f"/api/team/projects/{pid}/media", headers=as_("student1"))
    assert [f["path"] for f in r.json()["files"]] == ["A001.mov"]
