"""The Drive website's file routes keep team projects to their members (team_web_access)."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
from test_team_members import MEDIA, invite, make, team  # noqa: E402,F401
from test_team_projects import as_, client, create, drive  # noqa: E402,F401

PROJECT = "Team Projects/Robotics.fcteam"


@pytest.fixture
def web(team, monkeypatch, tmp_path):
    import chunk_upload
    monkeypatch.setattr(chunk_upload, "SESSION_ROOT", tmp_path / "chunks")
    chunk_upload._sessions.clear()
    monkeypatch.setattr(main, "_active_share", lambda request, user: "drive")
    monkeypatch.setattr(main, "share_path", lambda share: team.drive)
    team.pid = make(team)
    (team.drive / MEDIA / "A001.mov").write_bytes(b"footage")
    (team.drive / "Elsewhere").mkdir()
    return team


def reads(path):
    return [
        ("GET", "/api/files", {"params": {"path": path}}),
        ("GET", "/api/search", {"params": {"q": "A001", "path": path}}),
        ("GET", "/api/download", {"params": {"path": f"{path}/A001.mov" if "Media" in path else f"{path}/meta.json"}}),
        ("GET", "/api/download/zip", {"params": {"path": path}}),
        ("GET", "/api/folder-sizes", {"params": {"path": path}}),
        ("POST", "/api/file-link", {"json": {"path": path}}),
    ]


def writes(path):
    return [
        ("POST", "/api/mkdir", {"data": {"path": path, "name": "New"}}),
        ("POST", "/api/rename", {"data": {"path": f"{path}/A001.mov", "new_name": "B.mov"}}),
        ("POST", "/api/move", {"data": {"path": f"{path}/A001.mov", "dest": "Elsewhere"}}),
        ("POST", "/api/delete", {"data": {"path": path}}),
        ("POST", "/api/upload/init", {"data": {"path": path, "name": "C.mov", "size": 3}}),
        ("POST", "/api/upload", {"data": {"path": path}, "files": {"file": ("C.mov", b"abc")}}),
    ]


@pytest.mark.parametrize("user", ["student2", "student3"])
@pytest.mark.parametrize("path", [MEDIA, PROJECT])
def test_outsiders_and_invitees_get_404_on_every_file_route(web, user, path):
    assert invite(web, web.pid, ["student3"]).status_code == 200
    for method, url, kw in reads(path) + writes(MEDIA):
        r = web.request(method, url, headers=as_(user), **kw)
        assert r.status_code == 404, (method, url, kw, r.status_code, r.text)
    assert (web.drive / MEDIA / "A001.mov").read_bytes() == b"footage"
    assert (web.drive / PROJECT).is_dir()


def test_listing_and_search_leave_out_other_teams(web):
    open_pid = create(web, user="student1", name="Open Club")["id"]  # legacy: everyone
    assert open_pid
    h = as_("student2")
    names = {i["name"] for i in web.get("/api/files", params={"path": "Team Projects"}, headers=h).json()["items"]}
    assert names == {"Open Club.fcteam", "Open Club Media"}
    found = web.get("/api/search", params={"q": "Robotics"}, headers=h).json()
    assert found["results"] == [] and found["count"] == 0
    mine = {i["name"] for i in web.get("/api/files", params={"path": "Team Projects"},
                                       headers=as_("student1")).json()["items"]}
    assert {"Robotics.fcteam", "Robotics Media"} <= mine


def test_zip_of_the_drive_root_skips_other_teams(web):
    (web.drive / "notes.txt").write_bytes(b"hi")
    r = web.get("/api/download/zip", params={"path": "Team Projects"}, headers=as_("student2"))
    assert r.status_code == 200, r.text
    assert b"A001.mov" not in r.content and b"meta.json" not in r.content
    r = web.get("/api/download/zip", params={"path": "Team Projects"}, headers=as_("student1"))
    assert b"A001.mov" in r.content


def test_members_use_the_website(web):
    h = as_("student1")
    assert web.get("/api/files", params={"path": MEDIA}, headers=h).status_code == 200
    assert web.get("/api/download", params={"path": f"{MEDIA}/A001.mov"}, headers=h).content == b"footage"
    r = web.post("/api/rename", data={"path": f"{MEDIA}/A001.mov", "new_name": "A002.mov"}, headers=h)
    assert r.status_code == 200, r.text


def test_joined_member_gets_access(web):
    assert invite(web, web.pid, ["student2"]).status_code == 200
    assert web.post(f"/api/team/projects/{web.pid}/join", headers=as_("student2")).status_code == 200
    r = web.get("/api/download", params={"path": f"{MEDIA}/A001.mov"}, headers=as_("student2"))
    assert r.status_code == 200 and r.content == b"footage"


def test_admins_read_but_dont_change(web):
    h = as_("admin1")
    assert web.get("/api/files", params={"path": MEDIA}, headers=h).status_code == 200
    assert web.get("/api/download", params={"path": f"{MEDIA}/A001.mov"}, headers=h).status_code == 200
    for method, url, kw in writes(MEDIA):
        r = web.request(method, url, headers=h, **kw)
        assert r.status_code == 403, (url, r.status_code, r.text)


def test_nobody_writes_into_the_team_projects_folder_itself(web):
    h = as_("student1")
    r = web.post("/api/mkdir", data={"path": "Team Projects", "name": "Stray"}, headers=h)
    assert r.status_code == 403
    assert not (web.drive / "Team Projects" / "Stray").exists()
    r = web.post("/api/file-link", json={"path": "Team Projects"}, headers=h)
    assert r.status_code == 400
