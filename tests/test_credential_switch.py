"""as_user/as_root must not mistake another thread's switched euid for "not root"."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import fsops  # noqa: E402


@pytest.fixture
def root_process_mid_switch(monkeypatch):
    """Real uid 0 (container runs as root) while another thread holds euid 1001."""
    state = {"euid": 1001, "egid": 100, "calls": []}
    monkeypatch.setattr(fsops.os, "getuid", lambda: 0)
    monkeypatch.setattr(fsops.os, "geteuid", lambda: state["euid"])
    monkeypatch.setattr(fsops.os, "getegid", lambda: state["egid"])
    monkeypatch.setattr(fsops.os, "getgroups", lambda: [])

    def seteuid(uid):
        state["calls"].append(("seteuid", uid))
        state["euid"] = uid

    def setegid(gid):
        state["calls"].append(("setegid", gid))
        state["egid"] = gid

    monkeypatch.setattr(fsops.os, "seteuid", seteuid)
    monkeypatch.setattr(fsops.os, "setegid", setegid)
    monkeypatch.setattr(fsops.os, "setgroups", lambda groups: state["calls"].append(("setgroups", groups)))
    monkeypatch.setattr(fsops, "_HOST_GROUP", Path("/nonexistent/group"))
    monkeypatch.setattr(fsops.os, "initgroups", lambda name, gid: None, raising=False)
    return state


def test_as_user_switches_to_the_requested_user_even_if_euid_is_not_zero(root_process_mid_switch):
    with fsops.as_user(1002, 100, "student2"):
        assert fsops._as_user_lock.locked()
        assert root_process_mid_switch["euid"] == 1002
    assert not fsops._as_user_lock.locked()


def test_as_root_takes_the_lock_and_elevates(root_process_mid_switch):
    with fsops.as_root():
        assert fsops._as_user_lock.locked()
        assert root_process_mid_switch["euid"] == 0
    assert not fsops._as_user_lock.locked()


def test_non_root_process_skips_switching(monkeypatch):
    monkeypatch.setattr(fsops.os, "getuid", lambda: 1000)
    monkeypatch.setattr(fsops.os, "seteuid", lambda uid: pytest.fail("must not switch"))
    with fsops.as_user(1002, 100, "student2"), fsops.as_root():
        pass
