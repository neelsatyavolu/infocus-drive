import importlib.util
import io
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import pytest


spec = importlib.util.spec_from_file_location(
    "ugos_sso_pam", Path(__file__).resolve().parents[1] / "scripts/ugos_sso_pam.py"
)
pam = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pam)


def test_ticket_is_bound_to_username_uid_and_single_use(tmp_path):
    db = tmp_path / "tickets.sqlite3"
    ticket = pam.issue(db, "alice", 1001, now=100)
    assert not pam.consume(db, ticket, "bob", 1002, now=101)
    assert not pam.consume(db, ticket, "alice", 1002, now=101)
    assert pam.consume(db, ticket, "alice", 1001, now=101)
    assert not pam.consume(db, ticket, "alice", 1001, now=101)
    assert ticket.encode() not in db.read_bytes()


@pytest.mark.parametrize("now", [99, 130, 131])
def test_expired_or_future_ticket_is_rejected(tmp_path, now):
    db = tmp_path / "tickets.sqlite3"
    ticket = pam.issue(db, "alice", 1001, now=100)
    assert not pam.consume(db, ticket, "alice", 1001, now=now)


@pytest.mark.parametrize("ticket", ["", "password", "../example", "idsso_" + "a" * 500])
def test_other_credentials_do_not_create_database(tmp_path, ticket):
    db = tmp_path / "tickets.sqlite3"
    assert not pam.consume(db, ticket, "alice", 1001, now=101)
    assert not db.exists()


def test_only_one_concurrent_consumer_succeeds(tmp_path):
    db = tmp_path / "tickets.sqlite3"
    ticket = pam.issue(db, "alice", 1001, now=100)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: pam.consume(db, ticket, "alice", 1001, now=101), range(8)))
    assert results.count(True) == 1


def test_missing_database_fails_closed(tmp_path):
    assert not pam.consume(tmp_path / "missing", "idsso_" + "a" * 43, "alice", 1001, now=100)


@pytest.mark.parametrize("service,kind", [("sshd", "auth"), ("check-passwd", "auth"), ("ugreen-login", "account")])
def test_pam_entrypoint_rejects_other_services(monkeypatch, service, kind):
    monkeypatch.setattr(pam.os, "getuid", lambda: 0)
    monkeypatch.setattr(pam.os, "geteuid", lambda: 0)
    monkeypatch.setattr(pam.sys, "argv", ["helper"])
    monkeypatch.setenv("PAM_SERVICE", service)
    monkeypatch.setenv("PAM_TYPE", kind)
    assert pam.main() == 1


def test_pam_entrypoint_consumes_without_output(tmp_path, monkeypatch, capsys):
    db = tmp_path / "tickets.sqlite3"
    ticket = pam.issue(db, "alice", 1001)
    monkeypatch.setattr(pam.os, "getuid", lambda: 0)
    monkeypatch.setattr(pam.os, "geteuid", lambda: 0)
    monkeypatch.setattr(pam.sys, "argv", ["helper"])
    monkeypatch.setattr(pam.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(ticket.encode() + b"\0")))
    monkeypatch.setattr(pam, "DATABASE", db)
    monkeypatch.setattr(pam, "account_uid", lambda name: 1001 if name == "alice" else None)
    monkeypatch.setenv("PAM_SERVICE", "ugreen-login")
    monkeypatch.setenv("PAM_TYPE", "auth")
    monkeypatch.setenv("PAM_USER", "alice")
    assert pam.main() == 0
    assert capsys.readouterr().out == ""


def test_non_root_cannot_issue(monkeypatch):
    monkeypatch.setattr(pam.os, "getuid", lambda: 1001)
    monkeypatch.setattr(pam.sys, "argv", ["helper", "--issue", "alice"])
    assert pam.main() == 1


@pytest.mark.parametrize("uid,password,expires", [
    (0, "$6$hash", -1), (999, "$6$hash", -1), (60000, "$6$hash", -1),
    (1001, "!locked", -1), (1001, "*", -1), (1001, "", -1),
    (1001, "$6$hash", 0), (1001, "$6$hash", 1),
])
def test_locked_expired_or_system_account_rejected(monkeypatch, uid, password, expires):
    monkeypatch.setattr(pam.pwd, "getpwnam", lambda _: SimpleNamespace(pw_uid=uid))
    shadow = SimpleNamespace(sp_pwdp=password, sp_expire=expires)
    monkeypatch.setitem(pam.sys.modules, "spwd", SimpleNamespace(getspnam=lambda _: shadow))
    monkeypatch.setattr(pam.time, "time", lambda: 86400)
    with pytest.raises(ValueError):
        pam.account_uid("alice")


def test_existing_active_local_account_allowed(monkeypatch):
    monkeypatch.setattr(pam.pwd, "getpwnam", lambda _: SimpleNamespace(pw_uid=1001))
    shadow = SimpleNamespace(sp_pwdp="$6$hash", sp_expire=-1)
    monkeypatch.setitem(pam.sys.modules, "spwd", SimpleNamespace(getspnam=lambda _: shadow))
    assert pam.account_uid("alice") == 1001


def test_firmware_reset_disables_issuance(tmp_path):
    config = tmp_path / "pam"
    helper = Path("/usr/local/libexec/infocus-ugos-sso-pam")
    config.write_text(f"# pam_exec.so expose_authtok {helper}\n@include common-auth-faillock\n")
    assert not pam.pam_ready(config, helper)
    config.write_text(f"auth sufficient pam_exec.so expose_authtok /usr/bin/python3 -I {helper}\n")
    assert pam.pam_ready(config, helper)
    assert not pam.pam_ready(config, Path(str(helper) + "-other"))
