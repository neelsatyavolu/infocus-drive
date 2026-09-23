import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "scripts/install_ugos_sso.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def test_pam_wrapper_preserves_unrelated_and_account_sections():
    original = "auth optional pam_faildelay.so delay=3000000\n@include common-auth-faillock\naccount required pam_unix.so\n"
    changed = installer.pam_config(original)
    assert changed.startswith("auth optional pam_faildelay.so delay=3000000\n")
    assert changed.endswith("account required pam_unix.so\n")
    assert "auth substack common-auth-faillock" in changed
    assert installer.pam_config(changed) == changed


def test_unexpected_pam_is_not_replaced():
    with pytest.raises(RuntimeError):
        installer.pam_config("auth required custom.so\n")


def test_root_redirect_changes_only_public_ugos_and_is_idempotent():
    original = "prefix\n" + installer.OLD_ROOT + "\nsuffix\n"
    changed = installer.root_config(original)
    assert changed == "prefix\n" + installer.NEW_ROOT + "\nsuffix\n"
    assert 'or "/desktop/?os=ugospro"' in changed
    assert installer.root_config(changed) == changed


def test_failed_atomic_replace_cleans_temp_for_rollback(tmp_path, monkeypatch):
    target = tmp_path / "config"
    target.write_text("original")
    original_replace = installer.os.replace
    def fail(*args):
        raise OSError("replace failed")
    monkeypatch.setattr(installer.os, "replace", fail)
    with pytest.raises(OSError):
        installer.write_atomic(target, b"changed", 0o600)
    assert list(tmp_path.iterdir()) == [target]
    assert target.read_text() == "original"
    monkeypatch.setattr(installer.os, "replace", original_replace)
    installer.write_atomic(target, b"restored", 0o600)
    assert target.read_text() == "restored"
