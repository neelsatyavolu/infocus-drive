"""userd hardening: constant-time token check, group allowlist on create."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import userd  # noqa: E402


def _ok(stdout: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(args=[], returncode=0, stdout=stdout, stderr="")


def test_token_ok_uses_constant_time_compare(monkeypatch):
    monkeypatch.setenv("USERD_TOKEN", "right-token")
    seen = []
    real = userd.hmac.compare_digest
    monkeypatch.setattr(userd.hmac, "compare_digest", lambda a, b: seen.append((a, b)) or real(a, b))
    assert userd.token_ok("Bearer right-token") is True
    assert userd.token_ok("Bearer wrong-token") is False
    assert len(seen) == 2


def test_token_ok_rejects_missing_or_malformed(monkeypatch):
    monkeypatch.setenv("USERD_TOKEN", "right-token")
    assert userd.token_ok("") is False
    assert userd.token_ok("right-token") is False
    monkeypatch.setenv("USERD_TOKEN", "")
    assert userd.token_ok("Bearer ") is False


def _usermods(monkeypatch, groups):
    calls: list[list[str]] = []

    def fake(args, stdin=None):
        calls.append(list(args))
        if args[:2] == ["/usr/bin/getent", "passwd"]:
            return _ok("st10003:x:1068:100:UGREEN USER:/home/st10003:/bin/bash\n")
        if args[0] == "/bin/cat":
            return _ok("1120\n")
        return _ok()

    monkeypatch.setattr(userd, "host_run", fake)
    out = userd.create_user("kid", "Secret1!", groups)
    assert out["status"] == "created"
    return [c[2] for c in calls if c[0] == "/usr/sbin/usermod"]


@pytest.fixture(autouse=True)
def _clean_group_env(monkeypatch):
    monkeypatch.delenv("USERD_ALLOWED_GROUPS", raising=False)
    monkeypatch.delenv("UGOS_SYNC_GROUP", raising=False)


def test_default_allows_only_sync_group(monkeypatch):
    assert _usermods(monkeypatch, ["admin", "InFocus Members", "wheel", "sudo"]) == ["InFocus Members"]


def test_sync_group_env(monkeypatch):
    monkeypatch.setenv("UGOS_SYNC_GROUP", "Campers")
    assert _usermods(monkeypatch, ["Campers", "InFocus Members", "admin"]) == ["Campers"]


def test_allowed_groups_env_never_admits_admin(monkeypatch):
    monkeypatch.setenv("USERD_ALLOWED_GROUPS", "Staff, admin ,Campers")
    assert _usermods(monkeypatch, ["admin", "Admin", "Staff", "Campers", "Other"]) == ["Staff", "Campers"]
