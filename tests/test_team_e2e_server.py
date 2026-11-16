"""The dev-only team e2e launcher must never be easy to run by accident."""

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "dev" / "team_e2e_server.py"
spec = importlib.util.spec_from_file_location("team_e2e_server", SCRIPT)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


def test_refuses_without_the_dev_switch():
    for env in ({}, {"INFOCUS_DEV_E2E": "0"}, {"INFOCUS_DEV_E2E": "true"}):
        with pytest.raises(SystemExit):
            launcher.check_allowed(env, 1001)


def test_refuses_root():
    with pytest.raises(SystemExit):
        launcher.check_allowed({"INFOCUS_DEV_E2E": "1"}, 0)


def test_allowed_dev_run():
    launcher.check_allowed({"INFOCUS_DEV_E2E": "1"}, 1001)


def test_binds_loopback_only():
    assert launcher.LOOPBACK == "127.0.0.1"
    assert "0.0.0.0" not in SCRIPT.read_text()


def test_lock_ttl_is_checked():
    assert launcher.lock_ttl({}) == 120
    assert launcher.lock_ttl({"INFOCUS_DEV_TEAM_LOCK_TTL_S": "25"}) == 25
    for bad in ("0", "-3", "x", "99999"):
        with pytest.raises(SystemExit):
            launcher.lock_ttl({"INFOCUS_DEV_TEAM_LOCK_TTL_S": bad})


def test_tokens_are_private_files(tmp_path, monkeypatch):
    monkeypatch.setattr(launcher.os, "environ", {})
    tokens = launcher.prepare(tmp_path, 8791, 25)
    assert sorted(tokens.values()) == ["student1", "student2", "student3"]
    for name in ("student1", "student2", "student3"):
        path = tmp_path / f"{name}.token"
        assert path.read_text().startswith("ifd_")
        assert path.stat().st_mode & 0o077 == 0
    assert launcher.os.environ["PUBLIC_BASE_URL"] == "http://127.0.0.1:8791"
    assert launcher.os.environ["DRIVE_ROOT"] == str(tmp_path / "drive")


def test_three_members_with_display_names():
    assert launcher.people() == {"student1": "Student One", "student2": "Student Two",
                                 "student3": "Student Three"}


def test_browser_sign_in_users_are_fictional_and_only_teacher1_is_admin():
    assert launcher.session_user("student2")["username"] == "student2"
    teacher = launcher.session_user("teacher1")
    assert teacher["username"] == "teacher1" and teacher["uid"] >= 1000
    assert launcher.is_admin("teacher1") and not launcher.is_admin("student1")
    assert launcher.session_user("root") is None and launcher.session_user("") is None
    assert "teacher1" not in launcher.people()
