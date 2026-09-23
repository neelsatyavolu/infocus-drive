"""Host userd: create-if-missing Linux users. Never touch protected accounts."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import userd  # noqa: E402


def _ok(stdout: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(args=[], returncode=0, stdout=stdout, stderr="")


def _fail(stderr: str) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr=stderr)


def test_allocate_uid_uses_incr_and_skips_taken():
    assert userd.allocate_uid([1000, 1001], 1120) == 1120
    assert userd.allocate_uid([1119, 1120], 1120) == 1121
    assert userd.allocate_uid([2000], 1000) == 2001


def test_rejects_protected(monkeypatch):
    monkeypatch.setenv("USER_SYNC_PROTECTED_USERNAMES", "nasadmin,st10001")
    called = []
    monkeypatch.setattr(userd, "host_run", lambda *a, **k: called.append(a) or _ok())
    out = userd.create_user("nasadmin", "x", ["InFocus Members"])
    assert out["status"] == "skipped_protected"
    assert called == []


def test_exists_if_getent_has_user(monkeypatch):
    def fake(args, stdin=None):
        if args[:2] == ["/usr/bin/getent", "passwd"]:
            return _ok("jane.doe:x:1200:100:UGREEN USER:/home/jane.doe:/bin/bash\n")
        raise AssertionError(args)

    monkeypatch.setattr(userd, "host_run", fake)
    out = userd.create_user("jane.doe", "Secret1!", ["InFocus Members"])
    assert out == {"status": "exists", "username": "jane.doe", "uid": 1200}


def test_create_useradd_usermod_smb(monkeypatch):
    calls: list[list[str]] = []

    def fake(args, stdin=None):
        calls.append(list(args))
        if args[:2] == ["/usr/bin/getent", "passwd"]:
            return _ok("st10003:x:1068:100:UGREEN USER:/home/st10003:/bin/bash\n")
        if args[0] == "/bin/cat":
            return _ok("1120\n")
        return _ok()

    monkeypatch.setattr(userd, "host_run", fake)
    out = userd.create_user("kid", "Secret1!", ["InFocus Members"], email="kid@pausd.us")
    assert out["status"] == "created"
    assert out["uid"] == 1120
    assert out["email"] == "kid@pausd.us"
    kinds = [c[0] for c in calls]
    assert "/usr/sbin/useradd" in kinds
    assert "/usr/sbin/chpasswd" in kinds
    assert "/usr/bin/smbpasswd" in kinds
    assert "/usr/sbin/usermod" in kinds
    useradd = next(c for c in calls if c[0] == "/usr/sbin/useradd")
    assert "kid" in useradd
    assert "1120" in useradd
    assert "kid@pausd.us" in useradd
    usermod = next(c for c in calls if c[0] == "/usr/sbin/usermod")
    assert usermod == ["/usr/sbin/usermod", "-aG", "InFocus Members", "kid"]


def test_delete_user_calls_userdel(monkeypatch):
    calls: list[list[str]] = []
    alive = {"kid"}

    def fake(args, stdin=None):
        calls.append(list(args))
        if args[:2] == ["/usr/bin/getent", "passwd"]:
            if "kid" in alive:
                return _ok("kid:x:1120:100:UGREEN USER:/:/bin/bash\n")
            return _ok("")
        if args[0] == "/usr/sbin/userdel":
            alive.discard("kid")
        return _ok()

    monkeypatch.setattr(userd, "host_run", fake)
    out = userd.delete_user("kid")
    assert out["status"] == "deleted"
    kinds = [c[0] for c in calls]
    assert "/usr/sbin/userdel" in kinds
    assert "/usr/bin/smbpasswd" in kinds


def test_verify_password_ok_and_denied(monkeypatch):
    def fake(args, stdin=None):
        if args[:2] == ["/usr/bin/getent", "passwd"]:
            return _ok("kid:x:1120:100:UGREEN USER:/:/bin/bash\n")
        if args[:3] == ["/usr/bin/getent", "shadow", "kid"]:
            return _ok("kid:$6$salt$hash:1:0:99999:7:::\n")
        if args[:2] == ["/usr/bin/test", "-e"]:
            return _fail("missing")
        raise AssertionError(args)

    monkeypatch.setattr(userd, "host_run", fake)
    monkeypatch.setattr(
        userd,
        "_crypt_match",
        lambda password, hashed: password == "Secret1!" and hashed.startswith("$6$"),
    )
    assert userd.verify_password("kid", "Secret1!") == {
        "status": "ok",
        "username": "kid",
        "uid": 1120,
        "otp_required": False,
    }
    assert userd.verify_password("kid", "wrong") == {"status": "denied"}
    assert userd.verify_password("missing", "Secret1!") == {"status": "denied"}
    assert userd.verify_password("kid", "") == {"status": "denied"}


def test_verify_password_locked_hash(monkeypatch):
    def fake(args, stdin=None):
        if args[:2] == ["/usr/bin/getent", "passwd"]:
            return _ok("kid:x:1120:100:UGREEN USER:/:/bin/bash\n")
        if args[:3] == ["/usr/bin/getent", "shadow", "kid"]:
            return _ok("kid:!:1:0:99999:7:::\n")
        raise AssertionError(args)

    monkeypatch.setattr(userd, "host_run", fake)
    monkeypatch.setattr(userd, "_crypt_match", lambda *a, **k: True)
    assert userd.verify_password("kid", "Secret1!") == {"status": "denied"}


def test_verify_password_otp_required_flag(monkeypatch):
    def fake(args, stdin=None):
        if args[:2] == ["/usr/bin/getent", "passwd"]:
            return _ok("nasadmin:x:1029:10:UGREEN USER:/home/nasadmin:/bin/bash\n")
        if args[:3] == ["/usr/bin/getent", "shadow", "nasadmin"]:
            return _ok("nasadmin:$6$salt$hash:1:0:99999:7:::\n")
        if args[:2] == ["/usr/bin/test", "-e"]:
            if args[-1] == "/ugreen/.config/.nas/1029/use_2fa":
                return _ok()
            return _fail("missing")
        raise AssertionError(args)

    monkeypatch.setattr(userd, "host_run", fake)
    monkeypatch.setattr(userd, "_crypt_match", lambda *a, **k: True)
    out = userd.verify_password("nasadmin", "Secret1!")
    assert out["status"] == "ok"
    assert out["otp_required"] is True


def test_delete_protected(monkeypatch):
    monkeypatch.setenv("USER_SYNC_PROTECTED_USERNAMES", "nasadmin,st10001")
    called = []
    monkeypatch.setattr(userd, "host_run", lambda *a, **k: called.append(a) or _ok())
    out = userd.delete_user("nasadmin")
    assert out["status"] == "skipped_protected"
    assert called == []
