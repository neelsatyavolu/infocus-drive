import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import team_cleanup  # noqa: E402
import team_files  # noqa: E402
from team_cleanup import MOVE_AFTER_S, NOTICE_AFTER_S, run_cleanup  # noqa: E402
from team_store import TeamStore  # noqa: E402
from test_team_projects import as_, client, create, drive, lock  # noqa: E402,F401

DAY = 86400


class Clock:
    def __init__(self, now: float = 1_800_000_000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def store(tmp_path, clock):
    return TeamStore(tmp_path / "team.sqlite3", clock=clock)


@pytest.fixture(autouse=True)
def no_exports():
    team_cleanup._exports.clear()
    yield
    team_cleanup._exports.clear()


class Effects:
    def __init__(self):
        self.mails = []
        self.moved = []
        self.logs = []

    def send_email(self, user, subject, text):
        self.mails.append((user, subject, text))

    def move(self, info):
        self.moved.append(info["folder"])

    def log(self, message):
        self.logs.append(message)


def run(store, clock, fx):
    return run_cleanup(store, clock.now, fx.send_email, fx.move, fx.log)


def test_constants():
    assert NOTICE_AFTER_S == 23 * DAY and MOVE_AFTER_S == 30 * DAY


def test_nothing_happens_before_23_days(store, clock):
    store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    fx = Effects()
    clock.now += 22 * DAY
    report = run(store, clock, fx)
    assert report.notified == [] and report.moved == [] and fx.mails == []


def test_notice_sent_once_at_23_days(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.record_open(pid, "student2")
    fx = Effects()
    clock.now += 23 * DAY + 60
    report = run(store, clock, fx)
    assert report.notified == [pid]
    assert sorted(m[0] for m in fx.mails) == ["student1", "student2"]
    subject, text = fx.mails[0][1], fx.mails[0][2]
    assert subject == "Your InFocus Cut project “Robotics” will be cleaned up in 7 days"
    assert f"/team/keep?project={pid}" in text
    clock.now += DAY
    assert run(store, clock, fx).notified == []
    assert len(fx.mails) == 2


def test_moved_at_30_days_to_recycle(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    fx = Effects()
    clock.now += 23 * DAY + 60
    run(store, clock, fx)
    clock.now += 7 * DAY
    report = run(store, clock, fx)
    assert report.moved == [pid]
    assert fx.moved == ["Team Projects/Robotics.fcteam"]
    assert store.project(pid) is None


def test_never_moved_without_a_notice_first(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    fx = Effects()
    clock.now += 31 * DAY  # the server was down on day 23
    report = run(store, clock, fx)
    assert report.moved == [] and report.notified == [pid]
    assert fx.moved == []


def test_keep_forever_never_moved(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.set_keep(pid, True)
    fx = Effects()
    for _ in range(40):
        clock.now += DAY
        run(store, clock, fx)
    assert fx.moved == [] and fx.mails == []


def test_locked_project_skipped(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.mark_notified(pid)
    clock.now += 30 * DAY + 60
    store.take_lock(pid, 2, "student1")
    fx = Effects()
    report = run(store, clock, fx)
    assert report.moved == [] and report.skipped == {pid: "lock held"}


def test_export_in_progress_skipped(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.mark_notified(pid)
    clock.now += 30 * DAY + 60
    team_cleanup.begin_export(pid, clock.now)
    fx = Effects()
    assert run(store, clock, fx).skipped == {pid: "export in progress"}
    team_cleanup.end_export(pid)
    assert run(store, clock, fx).moved == [pid]


def test_export_mark_expires_after_6_hours(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    team_cleanup.begin_export(pid, clock.now)
    assert team_cleanup.export_active(pid, clock.now + 5 * 3600)
    assert not team_cleanup.export_active(pid, clock.now + 6 * 3600 + 1)


def test_open_resets_clock(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    fx = Effects()
    clock.now += 23 * DAY + 60
    run(store, clock, fx)
    clock.now += 5 * DAY
    store.record_open(pid, "student2")
    clock.now += 3 * DAY
    report = run(store, clock, fx)
    assert report.moved == [] and report.notified == [] and not store.notified(pid)


def test_move_logged(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.record_open(pid, "student2")
    store.mark_notified(pid)
    clock.now += 30 * DAY + 60
    fx = Effects()
    run(store, clock, fx)
    moved_logs = [line for line in fx.logs if "moved" in line]
    assert len(moved_logs) == 1
    assert "Robotics" in moved_logs[0] and "student1" in moved_logs[0] and "student2" in moved_logs[0]


def test_failed_move_is_skipped_and_logged(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.mark_notified(pid)
    clock.now += 30 * DAY + 60
    fx = Effects()

    def broken(info):
        raise OSError("disk full")

    report = run_cleanup(store, clock.now, fx.send_email, broken, fx.log)
    assert report.moved == [] and pid in report.skipped
    assert store.project(pid) is not None


def test_failed_email_does_not_stop_others(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.record_open(pid, "student2")
    clock.now += 23 * DAY + 60
    sent = []

    def flaky(user, subject, text):
        if user == "student1":
            raise RuntimeError("provider down")
        sent.append(user)

    report = run_cleanup(store, clock.now, flaky, lambda info: None, lambda m: None)
    assert report.notified == [pid] and sent == ["student2"]


def test_only_project_folders_moved(drive):
    (drive / "#recycle").mkdir()
    team = drive / "Team Projects"
    (team / "Robotics.fcteam" / "sequences").mkdir(parents=True)
    (team / "Robotics.fcteam" / "meta.json").write_text("{}")
    (team / "Robotics Media").mkdir()
    (team / "Robotics Media" / "A001.mov").write_bytes(b"x")
    (team / "Robotics Extras").mkdir()
    (team / "Other.fcteam").mkdir()
    team_files.recycle_project("Team Projects/Robotics.fcteam")
    assert not (team / "Robotics.fcteam").exists() and not (team / "Robotics Media").exists()
    assert (drive / "#recycle" / "Team Projects" / "Robotics.fcteam" / "meta.json").is_file()
    assert (drive / "#recycle" / "Team Projects" / "Robotics Media" / "A001.mov").is_file()
    assert (team / "Robotics Extras").is_dir() and (team / "Other.fcteam").is_dir()


def test_recycle_refused_without_recycle_bin(drive):
    (drive / "Team Projects" / "Robotics.fcteam").mkdir(parents=True)
    with pytest.raises(team_files.FSError):
        team_files.recycle_project("Team Projects/Robotics.fcteam")
    assert (drive / "Team Projects" / "Robotics.fcteam").is_dir()


def test_recycle_refuses_other_folders(drive):
    (drive / "#recycle").mkdir()
    (drive / "Shows").mkdir()
    for rel in ["Shows", "Team Projects", "Team Projects/../Shows"]:
        with pytest.raises(team_files.FSError):
            team_files.recycle_project(rel)
    assert (drive / "Shows").is_dir()


def test_export_routes(client):
    pid = create(client)["id"]
    r = client.post(f"/api/team/exports/{pid}/begin", headers=as_("student1"))
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert team_cleanup.export_active(pid, team_cleanup.time.time())
    assert client.post(f"/api/team/exports/{pid}/end", headers=as_("student1")).json() == {"ok": True}
    assert not team_cleanup.export_active(pid, team_cleanup.time.time())
    assert client.post(f"/api/team/exports/{pid}/begin", headers=as_("outsider")).status_code == 403


def test_keep_page_served(client):
    r = client.get("/team/keep?project=" + "a" * 32)
    assert r.status_code == 200 and "team-keep.js" in r.text


def test_seconds_until_3am():
    import datetime as dt

    at = dt.datetime(2026, 11, 15, 2, 0, 0)
    assert team_cleanup.seconds_until(3, at) == 3600
    at = dt.datetime(2026, 11, 15, 3, 0, 0)
    assert team_cleanup.seconds_until(3, at) == 24 * 3600


def test_late_notice_still_gives_7_days(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    fx = Effects()
    clock.now += 31 * DAY  # the server was down on day 23
    assert run(store, clock, fx).notified == [pid]
    clock.now += 6 * DAY
    assert run(store, clock, fx).moved == []
    clock.now += DAY
    assert run(store, clock, fx).moved == [pid]


def test_missing_project_folder_is_forgotten(store, clock):
    pid = store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")
    store.mark_notified(pid)
    clock.now += 30 * DAY + 60
    fx = Effects()

    def gone(info):
        raise team_files.FSError("Team project not found", 404)

    report = run_cleanup(store, clock.now, fx.send_email, gone, fx.log)
    assert report.moved == [] and store.project(pid) is None
    assert any("no longer on the Drive" in line for line in fx.logs)


def test_recycle_moves_project_when_media_folder_missing(drive):
    (drive / "#recycle").mkdir()
    (drive / "Team Projects" / "Robotics.fcteam").mkdir(parents=True)
    team_files.recycle_project("Team Projects/Robotics.fcteam")
    assert (drive / "#recycle" / "Team Projects" / "Robotics.fcteam").is_dir()


def test_recycle_keeps_older_copy_in_bin(drive):
    (drive / "#recycle" / "Team Projects" / "Robotics.fcteam").mkdir(parents=True)
    (drive / "Team Projects" / "Robotics.fcteam").mkdir(parents=True)
    team_files.recycle_project("Team Projects/Robotics.fcteam")
    assert (drive / "#recycle" / "Team Projects" / "Robotics.fcteam").is_dir()
    assert (drive / "#recycle" / "Team Projects" / "Robotics.fcteam.#1").is_dir()


def test_recycle_refuses_symlinked_media_folder(drive, tmp_path):
    (drive / "#recycle").mkdir()
    (drive / "Team Projects" / "Robotics.fcteam").mkdir(parents=True)
    elsewhere = drive / "Shows"
    elsewhere.mkdir()
    (drive / "Team Projects" / "Robotics Media").symlink_to(elsewhere)
    with pytest.raises(team_files.FSError):
        team_files.recycle_project("Team Projects/Robotics.fcteam")
    assert (drive / "Team Projects" / "Robotics.fcteam").is_dir() and elsewhere.is_dir()


def test_resend_sender_is_noop_when_unconfigured(monkeypatch):
    monkeypatch.setenv("RESEND_API_KEY", "")
    monkeypatch.setenv("RESEND_FROM_EMAIL", "")
    team_cleanup.get_settings.cache_clear()

    def boom(*a, **k):
        raise AssertionError("must not send")

    monkeypatch.setattr(team_cleanup.httpx, "Client", boom)
    team_cleanup.send_notice_email("student1", "subject", "text")


def test_resend_sender_posts_to_member_address(monkeypatch):
    monkeypatch.setenv("RESEND_API_KEY", "re_test")
    monkeypatch.setenv("RESEND_FROM_EMAIL", "drive@example.org")
    team_cleanup.get_settings.cache_clear()
    monkeypatch.setattr(team_cleanup, "linux_user_email", lambda name: f"{name}@example.org")
    sent = []

    class FakeClient:
        def __init__(self, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def post(self, url, headers, json):
            sent.append((url, json))

            class R:
                def raise_for_status(self):
                    return None

            return R()

    monkeypatch.setattr(team_cleanup.httpx, "Client", FakeClient)
    team_cleanup.send_notice_email("student1", "Hello", "Body")
    assert sent == [("https://api.resend.com/emails",
                     {"from": "drive@example.org", "to": ["student1@example.org"], "subject": "Hello", "text": "Body"})]


def test_worker_not_started_when_disabled(monkeypatch):
    monkeypatch.setenv("TEAM_CLEANUP_ENABLED", "0")
    team_cleanup.get_settings.cache_clear()
    assert team_cleanup.start_worker() is False


def test_cleanup_status_none_until_notice(store, clock):
    pid = store.create_project("Team Projects/A.fcteam", "A", "student1")
    assert team_cleanup.cleanup_status(store, pid) is None
    clock.now += NOTICE_AFTER_S + DAY
    assert team_cleanup.cleanup_status(store, pid) is None


def test_cleanup_status_after_notice(store, clock):
    pid = store.create_project("Team Projects/A.fcteam", "A", "student1")
    opened = clock.now
    clock.now += NOTICE_AFTER_S + 2 * DAY
    run(store, clock, Effects())
    assert team_cleanup.cleanup_status(store, pid) == {
        "notice_sent_at": clock.now,
        "move_after": clock.now + (MOVE_AFTER_S - NOTICE_AFTER_S),  # 7 days after the notice, past 30 days
        "keep": False,
    }
    assert clock.now + (MOVE_AFTER_S - NOTICE_AFTER_S) > opened + MOVE_AFTER_S
    store.record_open(pid, "student2")
    assert team_cleanup.cleanup_status(store, pid) is None


def test_cleanup_status_keep_forever(store):
    pid = store.create_project("Team Projects/A.fcteam", "A", "student1")
    store.set_keep(pid, True)
    assert team_cleanup.cleanup_status(store, pid) == {"notice_sent_at": None, "move_after": None, "keep": True}


def test_cleanup_status_in_list_and_get(client):
    pid = create(client)["id"]
    import team_projects
    st = team_projects.store()
    listed = client.get("/api/team/projects", headers=as_("student2")).json()
    assert listed[0]["cleanup"] is None
    st.mark_notified(pid)
    notice = st.notified_at(pid)
    listed = client.get("/api/team/projects", headers=as_("student2")).json()
    assert listed[0]["cleanup"]["notice_sent_at"] == notice and listed[0]["cleanup"]["keep"] is False
    assert listed[0]["cleanup"]["move_after"] >= notice + (MOVE_AFTER_S - NOTICE_AFTER_S)
    # Opening the project resets the clock, so the project GET no longer has a pending move.
    assert client.get(f"/api/team/projects/{pid}", headers=as_("student2")).json()["cleanup"] is None
    st.set_keep(pid, True)
    got = client.get(f"/api/team/projects/{pid}", headers=as_("student2")).json()
    assert got["cleanup"] == {"notice_sent_at": None, "move_after": None, "keep": True}
