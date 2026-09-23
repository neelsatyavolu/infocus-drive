"""Packages roster → NAS user provisioning. Create-if-missing; never duplicate."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from config import get_settings  # noqa: E402
import user_sync  # noqa: E402
from users import _Pw, gecos_email, planned_nas_username, resolve_nas_user  # noqa: E402


@pytest.fixture(autouse=True)
def settings(monkeypatch, tmp_path):
    monkeypatch.setenv("ALLOWED_EMAIL_DOMAINS", "pausd.org,pausd.us")
    monkeypatch.setenv("USER_MAP_PATH", str(tmp_path / "user_map.json"))
    monkeypatch.setenv("USER_SYNC_PROTECTED_USERNAMES", "nasadmin,st10001")
    monkeypatch.setenv("USER_SYNC_PROTECTED_EMAILS", "nasadmin@pausd.org,st10001@pausd.us")
    monkeypatch.setenv("UGOS_ADMIN_PASSWORD", "test-admin-pass")
    monkeypatch.setenv("USERD_TOKEN", "test-userd-token")
    monkeypatch.setenv("PACKAGES_ROSTER_SNAPSHOT_PATH", str(tmp_path / "packages_roster.json"))
    get_settings.cache_clear()
    user_sync._roster_cache = None
    yield
    get_settings.cache_clear()
    user_sync._roster_cache = None


def test_passwd_file_lookup(tmp_path, monkeypatch):
    from users import _user_from_passwd_file

    p = tmp_path / "passwd"
    p.write_text(
        "root:x:0:0:root:/root:/bin/sh\n"
        "jane.doe:x:1200:1000:someone.personal@gmail.com:/home/jane.doe:/bin/sh\n"
    )
    pw = _user_from_passwd_file(p, "jane.doe")
    assert pw is not None
    assert pw.pw_uid == 1200
    assert pw.pw_gid == 1000
    assert pw.pw_gecos == "someone.personal@gmail.com"
    assert _user_from_passwd_file(p, "missing") is None


def test_gecos_email_parse():
    assert gecos_email("someone.personal@gmail.com") == "someone.personal@gmail.com"
    assert gecos_email("UGREEN USER") is None
    assert gecos_email("Name <st10003@pausd.us>") == "st10003@pausd.us"


def test_login_matches_stored_email_not_local_part(tmp_path, monkeypatch):
    import users as users_mod

    p = tmp_path / "passwd"
    p.write_text(
        "st10003:x:1068:100:st10003@pausd.us:/:/bin/bash\n"
        "alice-gmail:x:1201:100:alice@gmail.com:/:/bin/bash\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(users_mod, "_HOST_PASSWD", p)
    nas = resolve_nas_user("alice@gmail.com", extra_allow_emails={"alice@gmail.com"})
    assert nas is not None
    assert nas.username == "alice-gmail"
    # Local-part collision must not grant the PAUSD student's account.
    assert resolve_nas_user("alice@pausd.org", extra_allow_emails={"alice@pausd.org"}) is None


def test_host_group_names_include_infocus_members(tmp_path, monkeypatch):
    from fsops import host_group_names
    import fsops

    g = tmp_path / "group"
    g.write_text(
        "users:x:100:st10003\n"
        "InFocus Members:x:1000:st10003,jane.doe\n"
        "admin:x:10:nasadmin\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(fsops, "_HOST_GROUP", g)
    names = host_group_names("jane.doe", 100)
    assert names[0] == "users"
    assert "InFocus Members" in names


def test_planned_username_local_part():
    assert planned_nas_username("st10003@pausd.us") == "st10003"
    assert planned_nas_username("Nasadmin@pausd.org") == "nasadmin"


def test_gmail_denied_without_map_or_roster():
    assert planned_nas_username("jdoe2@gmail.com") is None


def test_gmail_allowed_when_on_roster():
    assert (
        planned_nas_username(
            "jdoe2@gmail.com", extra_allow_emails={"jdoe2@gmail.com"}
        )
        == "jdoe2"
    )


def test_protected_neel_and_student_id():
    assert user_sync.is_protected("nasadmin@pausd.org", "nasadmin")
    assert user_sync.is_protected("st10001@pausd.us", "st10001")
    assert not user_sync.is_protected("st10003@pausd.us", "st10003")


def test_protected_tsmith_and_st10002(monkeypatch):
    monkeypatch.setenv(
        "USER_SYNC_PROTECTED_USERNAMES",
        "nasadmin,st10001,tsmith,st10002",
    )
    monkeypatch.setenv(
        "USER_SYNC_PROTECTED_EMAILS",
        "nasadmin@pausd.org,st10001@pausd.us,tsmith@pausd.org",
    )
    get_settings.cache_clear()
    assert user_sync.is_protected("tsmith@pausd.org", "tsmith")
    assert user_sync.is_protected("st10002@pausd.us", "st10002")
    assert user_sync.revoke_user("tsmith@pausd.org", roster=set(), ugos=object())["status"] == "skipped_protected"
    assert user_sync.revoke_user("st10002@pausd.us", roster=set(), ugos=object())["status"] == "skipped_protected"


def test_skip_protected_even_if_missing(monkeypatch):
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: False)
    result = user_sync.ensure_user("nasadmin@pausd.org", "Nasadmin")
    assert result["status"] == "skipped_protected"
    result2 = user_sync.ensure_user("st10001@pausd.us")
    assert result2["status"] == "skipped_protected"


def test_skip_when_linux_user_already_exists(monkeypatch):
    created = []
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: name == "st10003")
    monkeypatch.setattr(user_sync, "linux_user_by_email", lambda email: None)
    monkeypatch.setattr(user_sync, "linux_user_email", lambda name: None)

    class Fake:
        def existing_usernames(self):
            raise AssertionError("should not list UGOS when Linux user exists")

        def create_user(self, **kwargs):
            created.append(kwargs)

        def close(self):
            pass

    result = user_sync.ensure_user(
        "st10003@pausd.us",
        ugos=Fake(),
        ugos_usernames=set(),
        ugos_emails={},
    )
    assert result["status"] == "exists"
    assert result["username"] == "st10003"
    assert created == []


def test_skip_when_ugos_already_has_username(monkeypatch):
    created = []
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: False)
    monkeypatch.setattr(user_sync, "linux_user_by_email", lambda email: None)
    monkeypatch.setattr(user_sync, "linux_user_email", lambda name: None)

    class Fake:
        def create_user(self, **kwargs):
            created.append(kwargs)

        def close(self):
            pass

    result = user_sync.ensure_user(
        "newkid@pausd.us",
        ugos=Fake(),
        ugos_usernames={"newkid"},
        ugos_emails={},
    )
    assert result["status"] == "created"
    assert created[0]["email"] == "newkid@pausd.us"


def test_skip_when_ugos_already_has_email(monkeypatch):
    created = []
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: False)
    monkeypatch.setattr(user_sync, "linux_user_by_email", lambda email: None)

    class Fake:
        def create_user(self, **kwargs):
            created.append(kwargs)

        def close(self):
            pass

    result = user_sync.ensure_user(
        "alias@pausd.org",
        ugos=Fake(),
        ugos_usernames={"othername"},
        ugos_emails={"alias@pausd.org": "othername"},
    )
    assert result["status"] == "exists"
    assert result["username"] == "othername"
    assert created == []


def test_same_local_part_two_emails_get_distinct_users(monkeypatch):
    created = []
    emails_by_user: dict[str, str] = {}

    monkeypatch.setattr(
        user_sync, "linux_user_exists", lambda name: name in emails_by_user
    )
    monkeypatch.setattr(
        user_sync, "linux_user_email", lambda name: emails_by_user.get(name)
    )
    monkeypatch.setattr(user_sync, "linux_user_by_email", lambda email: None)

    class Fake:
        def existing_usernames(self):
            return set(emails_by_user)

        def existing_emails(self):
            return {em: name for name, em in emails_by_user.items()}

        def create_user(self, **kwargs):
            created.append(kwargs["username"])
            emails_by_user[kwargs["username"]] = kwargs["email"]
            return {"status": "created", "username": kwargs["username"]}

        def close(self):
            pass

    monkeypatch.setattr(user_sync, "fetch_roster_entries", lambda: [
        {"email": "same@pausd.org", "name": "A"},
        {"email": "same@pausd.us", "name": "B"},
    ])
    monkeypatch.setattr(user_sync, "_client_factory", lambda: Fake())
    out = user_sync.sync_roster(ugos_factory=Fake)
    statuses = {r["email"]: r["status"] for r in out["results"]}
    assert statuses["same@pausd.org"] == "created"
    assert statuses["same@pausd.us"] == "created"
    assert created[0] == "same"
    assert created[1] == "same-pausd-us"


def test_create_new_student(monkeypatch):
    created = []
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: False)
    monkeypatch.setattr(user_sync, "linux_user_by_email", lambda email: None)
    monkeypatch.setattr(user_sync, "linux_user_email", lambda name: None)

    class Fake:
        def create_user(self, **kwargs):
            created.append(kwargs)

        def close(self):
            pass

    result = user_sync.ensure_user(
        "brandnew@pausd.us",
        "Brand New",
        ugos=Fake(),
        ugos_usernames=set(),
        ugos_emails={},
    )
    assert result["status"] == "created"
    assert result["username"] == "brandnew"
    assert created[0]["username"] == "brandnew"
    assert created[0]["email"] == "brandnew@pausd.us"
    assert created[0]["groups"] == ["InFocus Members"]


def test_login_denied_when_removed_from_roster(monkeypatch):
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: name == "gonekid")
    monkeypatch.setattr(
        user_sync,
        "linux_user_by_email",
        lambda email: _Pw("gonekid", 1200, 100, "/", email) if email == "gonekid@pausd.us" else None,
    )
    monkeypatch.setattr(
        user_sync,
        "resolve_nas_user",
        lambda email, extra_allow_emails=None: None,
    )
    monkeypatch.setattr(user_sync, "fetch_roster_emails", lambda force=False: set())
    user_sync.save_roster_snapshot({"gonekid@pausd.us"})
    revoked = []

    class Fake:
        def delete_user(self, username):
            revoked.append(username)
            return {"status": "deleted", "username": username}

        def close(self):
            pass

    monkeypatch.setattr(user_sync, "_client_factory", lambda: Fake())
    assert user_sync.ensure_for_login("gonekid@pausd.us") is None
    assert revoked == ["gonekid"]


def test_login_protected_still_works_off_roster(monkeypatch):
    nas = user_sync.NasUser("nasadmin", 1029, 10, "/home/nasadmin", "nasadmin@pausd.org")
    monkeypatch.setattr(user_sync, "fetch_roster_emails", lambda force=False: set())
    monkeypatch.setattr(
        user_sync,
        "resolve_nas_user",
        lambda email, extra_allow_emails=None: nas,
    )
    assert user_sync.ensure_for_login("nasadmin@pausd.org") == nas


def test_revoke_keeps_if_email_still_on_roster(monkeypatch):
    deleted = []
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: True)
    monkeypatch.setattr(
        user_sync,
        "linux_user_by_email",
        lambda email: _Pw("same", 1200, 100, "/", email),
    )

    class Fake:
        def delete_user(self, username):
            deleted.append(username)
            return {"status": "deleted"}

        def close(self):
            pass

    result = user_sync.revoke_user(
        "same@pausd.org",
        roster={"same@pausd.org"},
        ugos=Fake(),
    )
    assert result["status"] == "kept"
    assert deleted == []


def test_sync_deletes_users_who_left_roster(monkeypatch):
    deleted = []
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: name == "oldkid")
    monkeypatch.setattr(
        user_sync,
        "linux_user_by_email",
        lambda email: _Pw("oldkid", 1200, 100, "/", email) if email == "oldkid@pausd.us" else None,
    )
    monkeypatch.setattr(user_sync, "linux_user_email", lambda name: None)
    user_sync.save_roster_snapshot({"oldkid@pausd.us", "keep@pausd.us"})

    class Fake:
        def existing_usernames(self):
            return {"oldkid", "keep"}

        def existing_emails(self):
            return {}

        def create_user(self, **kwargs):
            return {"status": "exists"}

        def delete_user(self, username):
            deleted.append(username)
            return {"status": "deleted", "username": username}

        def close(self):
            pass

    monkeypatch.setattr(
        user_sync,
        "fetch_roster_entries",
        lambda: [{"email": "keep@pausd.us", "name": "Keep"}],
    )
    monkeypatch.setattr(user_sync, "_client_factory", lambda: Fake())
    out = user_sync.sync_roster(ugos_factory=Fake)
    assert deleted == ["oldkid"]
    statuses = {r["email"]: r["status"] for r in out["results"]}
    assert statuses["oldkid@pausd.us"] == "deleted"
    assert user_sync.load_roster_snapshot() == {"keep@pausd.us"}


def test_revoke_skips_protected(monkeypatch):
    deleted = []
    monkeypatch.setattr(user_sync, "linux_user_exists", lambda name: True)

    class Fake:
        def delete_user(self, username):
            deleted.append(username)

        def close(self):
            pass

    result = user_sync.revoke_user("nasadmin@pausd.org", roster=set(), ugos=Fake())
    assert result["status"] == "skipped_protected"
    assert deleted == []
