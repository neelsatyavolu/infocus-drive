"""The editing dashboard (editing.<domain> and /editing): page, host routing, sign-in host,
admin view, project overview, footage events and download speed settings."""

import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
import team_media  # noqa: E402
from test_team_members import MEDIA, invite, listed, make, team  # noqa: E402,F401
from test_team_projects import as_, client, drive, lock, read_event  # noqa: E402,F401

EDITING = "editing.example.org"


@pytest.fixture
def editing(team, monkeypatch):
    monkeypatch.setenv("EDITING_HOST", EDITING)
    main.get_settings.cache_clear()
    yield team
    main.get_settings.cache_clear()


@pytest.fixture
def uploads(team, monkeypatch, tmp_path):
    import chunk_upload
    monkeypatch.setattr(chunk_upload, "SESSION_ROOT", tmp_path / "chunks")
    chunk_upload._sessions.clear()
    return team


def joined(client, pid, user="student2"):
    assert invite(client, pid, [user]).status_code == 200
    assert client.post(f"/api/team/projects/{pid}/join", headers=as_(user)).status_code == 200


def overview(client, pid, user):
    return client.get(f"/api/team/projects/{pid}/overview", headers=as_(user))


def team_upload(client, pid, user, name, data, path=""):
    h = as_(user)
    init = client.post(f"/api/team/projects/{pid}/media/upload/init",
                       json={"name": name, "size": len(data), "path": path}, headers=h)
    assert init.status_code == 200, init.text
    upload_id = init.json()["upload_id"]
    assert client.put("/api/upload/chunk", params={"upload_id": upload_id, "index": 0}, content=data,
                      headers=h).status_code == 200
    return client.post(f"/api/team/projects/{pid}/media/upload/complete", json={"upload_id": upload_id}, headers=h)


# Page and host routing --------------------------------------------------------------------


def test_dashboard_page_at_editing_path_on_any_host(team):
    r = team.get("/editing")
    assert r.status_code == 200 and 'id="editing-app"' in r.text
    csp = r.headers["content-security-policy"]
    assert "script-src 'self'" in csp and "frame-ancestors 'none'" in csp and "form-action 'none'" in csp
    assert r.headers["x-frame-options"] == "DENY"


def test_editing_host_root_serves_the_dashboard(editing):
    r = editing.get("/", headers={"Host": EDITING})
    assert r.status_code == 200 and 'id="editing-app"' in r.text
    assert "frame-ancestors 'none'" in r.headers["content-security-policy"]
    drive = editing.get("/")
    assert drive.status_code == 200 and 'id="editing-app"' not in drive.text


def test_editing_host_keeps_api_auth_and_assets(editing):
    assert editing.get("/api/health", headers={"Host": EDITING}).json()["status"] == "ok"
    assert editing.get("/assets/editing.js", headers={"Host": EDITING}).status_code == 200
    projects = editing.get("/api/team/projects", headers={"Host": EDITING, **as_("student1")})
    assert projects.status_code == 200


def test_other_hosts_do_not_get_the_dashboard_at_root_when_unset(team):
    assert 'id="editing-app"' not in team.get("/", headers={"Host": EDITING}).text


def test_google_sign_in_returns_to_the_host_it_started_on(editing, monkeypatch):
    monkeypatch.setattr(main.settings, "google_client_id", "client-id")
    monkeypatch.setattr(main.settings, "google_client_secret", "client-secret")
    on_editing = editing.get("/auth/login", headers={"Host": EDITING}, follow_redirects=False)
    assert on_editing.status_code in (302, 307)
    query = parse_qs(urlparse(on_editing.headers["location"]).query)
    assert query["redirect_uri"] == [f"https://{EDITING}/auth/callback"]
    on_drive = editing.get("/auth/login", follow_redirects=False)
    query = parse_qs(urlparse(on_drive.headers["location"]).query)
    assert query["redirect_uri"] == [main.settings.public_base_url.rstrip("/") + "/auth/callback"]


def test_editing_host_cross_site_writes_still_blocked(editing):
    pid = make(editing)
    r = editing.post(f"/api/team/projects/{pid}/open",
                     headers={"Host": EDITING, "Origin": "https://evil.example.net", **as_("student1")})
    assert r.status_code == 403
    same = editing.post(f"/api/team/projects/{pid}/open",
                        headers={"Host": EDITING, "Origin": f"https://{EDITING}", **as_("student1")})
    assert same.status_code == 200


# Admin view -------------------------------------------------------------------------------


def test_admin_sees_every_project_only_when_asking_for_all(team):
    pid = make(team)
    assert pid not in listed(team, "admin1")
    everything = {p["id"]: p for p in team.get("/api/team/projects", params={"all": "1"},
                                              headers=as_("admin1")).json()}
    assert everything[pid]["role"] == "admin"
    assert everything[pid]["members"] == [{"username": "student1", "name": "Student One"}]


def test_non_admin_asking_for_all_sees_only_their_own(team):
    pid = make(team)
    mine = make(team, user="student2", name="Band")
    got = {p["id"] for p in team.get("/api/team/projects", params={"all": "1"}, headers=as_("student2")).json()}
    assert got == {mine} and pid not in got


def test_overview_for_a_member(team):
    pid = make(team)
    joined(team, pid)
    assert invite(team, pid, ["student3"]).status_code == 200
    assert lock(team, pid, 2, user="student2").status_code == 200
    team.post(f"/api/team/projects/{pid}/open", headers=as_("student1"))
    (team.drive / MEDIA / "A001.mov").write_bytes(b"0123456789")
    r = overview(team, pid, "student1")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["id"] == pid and body["name"] == "Robotics" and body["role"] == "member"
    assert body["creator"] == {"username": "student1", "name": "Student One"}
    members = {m["username"]: m for m in body["members"]}
    assert set(members) == {"student1", "student2"}
    assert members["student1"]["last_seen"] > 0 and members["student1"]["online"] is False
    assert members["student2"]["editing"] == [2]
    assert body["invites"] == [{"username": "student3", "name": "Student Three", "by": "student1"}]
    seqs = {s["id"]: s for s in body["sequences"]}
    assert set(seqs) == {2, 3} and seqs[2]["name"] == "Seq 2"
    assert seqs[2]["holder"] == {"username": "student2", "name": "Student Two"} and seqs[3]["holder"] is None
    assert body["media_count"] == 1 and body["media_bytes"] == 10
    assert body["can_edit"] is True and body["can_keep"] is True and body["is_admin"] is False
    assert body["media_folder"] == "Team Projects/Robotics Media"


def test_overview_member_who_is_not_the_creator_cannot_keep(team):
    pid = make(team)
    joined(team, pid)
    assert overview(team, pid, "student2").json()["can_keep"] is False


def test_overview_shows_who_is_online(team):
    pid = make(team)
    with team.stream("GET", f"/api/team/projects/{pid}/events", headers=as_("student1")) as stream:
        next(stream.iter_lines())
        members = {m["username"]: m for m in overview(team, pid, "student1").json()["members"]}
        assert members["student1"]["online"] is True
    members = {m["username"]: m for m in overview(team, pid, "student1").json()["members"]}
    assert members["student1"]["online"] is False


def test_admin_overview_and_footage_list_are_read_only(team):
    pid = make(team)
    (team.drive / MEDIA / "A001.mov").write_bytes(b"abc")
    body = overview(team, pid, "admin1").json()
    assert body["role"] == "admin" and body["can_edit"] is False and body["is_admin"] is True
    assert body["can_keep"] is True
    listing = team.get(f"/api/team/projects/{pid}/media", headers=as_("admin1"))
    assert listing.status_code == 200 and listing.json()["count"] == 1
    # Read-only: no downloads, uploads, invites or edits for an admin who isn't a member.
    assert team.get(f"/api/team/projects/{pid}/media", params={"path": "A001.mov"},
                    headers=as_("admin1")).status_code == 404
    assert team.post(f"/api/team/projects/{pid}/media/upload/init", json={"name": "x.mov", "size": 1},
                     headers=as_("admin1")).status_code == 404
    assert invite(team, pid, ["student3"], user="admin1").status_code == 404
    assert team.get(f"/api/team/projects/{pid}", headers=as_("admin1")).status_code == 404


@pytest.mark.parametrize("user", ["student2", "student3"])
def test_non_admin_non_members_get_404_on_dashboard_routes(team, user):
    pid = make(team)
    assert invite(team, pid, ["student3"]).status_code == 200
    for url in (f"/api/team/projects/{pid}/overview", f"/api/team/projects/{pid}/media"):
        assert team.get(url, headers=as_(user)).status_code == 404, url
    assert team.get("/api/team/projects/" + "0" * 32 + "/overview", headers=as_("student1")).status_code == 404


def test_overview_needs_sign_in(team):
    pid = make(team)
    assert team.get(f"/api/team/projects/{pid}/overview").status_code == 401


# Footage from any member -------------------------------------------------------------------


def test_any_member_can_upload_and_everyone_hears_about_it(uploads):
    pid = make(uploads)
    joined(uploads, pid)
    with uploads.stream("GET", f"/api/team/projects/{pid}/events", headers=as_("student1")) as stream:
        lines = stream.iter_lines()
        next(lines)
        done = team_upload(uploads, pid, "student2", "B001.mov", b"footage", path="Day 2")
        assert done.status_code == 200, done.text
        assert read_event(lines) == ("media_changed", {"rev": 1, "path": "Day 2/B001.mov", "by": "student2"})
    item = listed(uploads, "student1")[pid]
    assert item["media_rev"] == 1 and item["media_count"] == 1
    body = uploads.get(f"/api/team/projects/{pid}/media", headers=as_("student1")).json()
    assert body["rev"] == 1 and body["files"][0]["path"] == "Day 2/B001.mov"


def test_website_upload_into_the_media_folder_bumps_the_footage_rev(uploads, monkeypatch):
    pid = make(uploads)
    monkeypatch.setattr(main, "_active_share", lambda request, user: "drive")
    monkeypatch.setattr(main, "share_path", lambda share: uploads.drive)
    h = as_("student1")
    with uploads.stream("GET", f"/api/team/projects/{pid}/events", headers=h) as stream:
        lines = stream.iter_lines()
        next(lines)
        init = uploads.post("/api/upload/init", data={"path": f"{MEDIA}/Day 3", "name": "C001.mov", "size": 3},
                            headers=h)
        upload_id = init.json()["upload_id"]
        uploads.put("/api/upload/chunk", params={"upload_id": upload_id, "index": 0}, content=b"abc", headers=h)
        assert uploads.post("/api/upload/complete", data={"upload_id": upload_id}, headers=h).status_code == 200
        assert read_event(lines) == ("media_changed", {"rev": 1, "path": "Day 3/C001.mov", "by": "student1"})
        assert uploads.post("/api/delete", data={"path": f"{MEDIA}/Day 3/C001.mov"}, headers=h).status_code == 200
        assert read_event(lines) == ("media_changed", {"rev": 2, "path": "Day 3/C001.mov", "by": "student1"})


def test_website_change_on_another_share_is_not_a_team_change(uploads, monkeypatch, tmp_path):
    other = tmp_path / "other"
    (other / MEDIA).mkdir(parents=True)
    assert team_media.web_change_target(other, f"{MEDIA}/A.mov") is None
    assert team_media.web_change_target(uploads.drive, "Team Projects/Robotics.fcteam/meta.json") is None
    assert team_media.web_change_target(uploads.drive, "Other/Robotics Media/A.mov") is None
    assert team_media.web_change_target(uploads.drive, f"{MEDIA}/Day 1/A.mov") == (
        "Team Projects/Robotics.fcteam", "Day 1/A.mov")


# Download and upload speed ----------------------------------------------------------------


def test_media_download_streams_in_big_reads_and_resumes(team):
    pid = make(team)
    data = bytes(range(256)) * (12 * 1024)  # 3 MiB
    (team.drive / MEDIA / "big.mov").write_bytes(data)
    url = f"/api/team/projects/{pid}/media"
    full = team.get(url, params={"path": "big.mov"}, headers=as_("student1"))
    assert full.content == data and full.headers["accept-ranges"] == "bytes"
    start = 1024 * 1024 + 7
    rest = team.get(url, params={"path": "big.mov"}, headers={**as_("student1"), "Range": f"bytes={start}-"})
    assert rest.status_code == 206 and rest.content == data[start:]
    assert team_media.MEDIA_READ_CHUNK == 1024 * 1024


def test_four_parallel_chunks_per_file_are_allowed(uploads):
    pid = make(uploads)
    h = as_("student1")
    mib = 1024 * 1024
    data = b"".join(bytes([i]) * mib for i in range(4))
    init = uploads.post(f"/api/team/projects/{pid}/media/upload/init",
                        json={"name": "four.mov", "size": len(data), "chunk_size": mib}, headers=h).json()
    assert init["total_chunks"] == 4
    for index in (3, 1, 0, 2):  # any order, as parallel PUTs land
        r = uploads.put("/api/upload/chunk", params={"upload_id": init["upload_id"], "index": index},
                        content=data[index * mib:(index + 1) * mib], headers=h)
        assert r.status_code == 200, r.text
    status = uploads.get("/api/upload/status", params={"upload_id": init["upload_id"]}, headers=h).json()
    assert sorted(status["received"]) == [0, 1, 2, 3]
    done = uploads.post(f"/api/team/projects/{pid}/media/upload/complete",
                        json={"upload_id": init["upload_id"]}, headers=h)
    assert done.status_code == 200 and (uploads.drive / MEDIA / "four.mov").read_bytes() == data

