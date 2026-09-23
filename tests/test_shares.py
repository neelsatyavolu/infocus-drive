"""Samba shared-folder + UGOS personal_folder discovery."""

from __future__ import annotations

import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import shares  # noqa: E402
from config import get_settings  # noqa: E402
from fsops import FSError  # noqa: E402

CONF = """\
[global]
workgroup = WORKGROUP

[personal_folder]
path = %H
valid users = @ughomeusers
writeable = yes
browseable = yes

[homes]
path = /volume1/home/%u
writeable = yes

[printers]
path = /var/spool/samba

[InFocus Drive]
path = /volume2/InFocus Drive
valid users = @users
writeable = yes
browseable = yes

[Photos]
path = /volume2/Photos
valid users = @users
writeable = yes
browseable = yes
"""


@pytest.fixture()
def nas(tmp_path, monkeypatch):
    vol1 = tmp_path / "volume1"
    vol2 = tmp_path / "volume2"
    home_root = tmp_path / "home"
    extra = tmp_path / "extra"
    infocus = vol2 / "InFocus Drive"
    photos = vol2 / "Photos"
    neel_home = home_root / "nasadmin"
    alice_home = home_root / "alice"
    stray = home_root / "not-a-user"
    for p in (infocus, photos, neel_home, alice_home, stray, extra, vol1):
        p.mkdir(parents=True, exist_ok=True)

    conf = tmp_path / "smbshare.conf"
    conf.write_text(CONF, encoding="utf-8")

    monkeypatch.setenv("DRIVE_ROOT", str(infocus))
    monkeypatch.setenv("SHARES_VOLUME", str(vol2))
    monkeypatch.setenv("SHARES_VOLUMES", f"{vol1},{vol2}")
    monkeypatch.setenv("SAMBA_SHARES_CONF", str(conf))
    monkeypatch.setenv("EXTRA_SHARES_DIR", str(extra))
    get_settings.cache_clear()
    shares._samba_cache.update({"mtime": None, "shares": {}, "home_template": None})

    monkeypatch.setattr(
        shares,
        "_HOST_PREFIX_MAP",
        [
            ("/volume2/", str(vol2) + "/"),
            ("/volume1/", str(vol1) + "/"),
            ("/home/", str(home_root) + "/"),
        ],
    )
    monkeypatch.setattr(
        shares,
        "user_group_names",
        lambda username, gid: ["users", "ughomeusers"],
    )
    monkeypatch.setattr(shares, "is_nas_admin", lambda username: False)

    users = {
        "nasadmin": types.SimpleNamespace(
            pw_name="nasadmin", pw_dir=str(neel_home), pw_uid=1001, pw_gid=1001
        ),
        "alice": types.SimpleNamespace(
            pw_name="alice", pw_dir=str(alice_home), pw_uid=1002, pw_gid=1002
        ),
    }

    def getpwnam(name: str):
        if name not in users:
            raise KeyError(name)
        return users[name]

    monkeypatch.setattr(shares.pwd, "getpwnam", getpwnam)
    return {
        "infocus": infocus,
        "photos": photos,
        "nasadmin": neel_home,
        "alice": alice_home,
        "home_root": home_root,
    }


def test_parse_skips_homes_as_team_shares():
    parsed, template = shares._parse_smbshare_conf(CONF)
    assert "InFocus Drive" in parsed
    assert "Photos" in parsed
    assert "personal_folder" not in parsed
    assert "homes" not in parsed
    assert "printers" not in parsed
    assert template is not None
    assert template["path"] == "%H"
    assert "@ughomeusers" in template["valid_users"]


def test_locked_personal_folder_stays_visible_but_cannot_resolve(nas, monkeypatch):
    monkeypatch.setattr(shares.personal_folders, 'configured', lambda: True)
    monkeypatch.setattr(shares.personal_folders.folders, 'status', lambda owner:
        {'encrypted': True, 'locked': True, 'expires_at': None, 'state': 3})
    entries = shares.list_shares_for_user('nasadmin', 1001, 1001)
    mine = next(s for s in entries if s['id'] == '~nasadmin')
    assert mine['locked'] and not mine['can_read']
    with pytest.raises(FSError) as e:
        shares.share_path('~nasadmin')
    assert e.value.status == 423


def test_unlocked_home_requires_decrypted_container_mount(nas, monkeypatch):
    monkeypatch.setattr(shares.personal_folders, 'configured', lambda: True)
    monkeypatch.setattr(shares.personal_folders.folders, 'status', lambda owner:
        {'encrypted': True, 'locked': False, 'expires_at': 100, 'state': 4})
    monkeypatch.setattr(shares, '_encrypted_home_mount', lambda path: False)
    with pytest.raises(FSError) as e:
        shares.share_path('~nasadmin')
    assert e.value.status == 503


def test_discover_share_ids_skips_personal_folder(nas):
    ids = shares.discover_share_ids()
    assert ids[0] == "InFocus Drive"
    assert "Photos" in ids
    assert "personal_folder" not in ids
    assert "homes" not in ids


def test_non_admin_sees_own_personal_drive(nas):
    listed = shares.list_shares_for_user("nasadmin", 1001, 1001)
    by_id = {s["id"]: s for s in listed}
    assert "InFocus Drive" in by_id
    assert "Photos" in by_id
    assert "~nasadmin" in by_id
    assert "~alice" not in by_id
    mine = by_id["~nasadmin"]
    assert mine["kind"] == "personal"
    assert mine["name"] == "nasadmin"
    assert mine["can_read"] is True
    assert by_id["InFocus Drive"]["kind"] == "shared"


def test_admin_sees_other_personal_drives(nas, monkeypatch):
    monkeypatch.setattr(shares, "is_nas_admin", lambda username: username == "nasadmin")
    listed = shares.list_shares_for_user("nasadmin", 1001, 1001)
    ids = [s["id"] for s in listed]
    assert "~nasadmin" in ids
    assert "~alice" in ids
    assert "not-a-user" not in ids
    assert "~not-a-user" not in ids


def test_share_path_personal_and_shared(nas):
    assert shares.share_path("InFocus Drive") == nas["infocus"].resolve()
    assert shares.share_path("~nasadmin") == nas["nasadmin"].resolve()
    with pytest.raises(FSError) as ei:
        shares.share_path("~missing")
    assert ei.value.status == 404


def test_expand_percent_u_template(nas, tmp_path, monkeypatch):
    vol1_home = tmp_path / "volume1" / "home" / "nasadmin"
    vol1_home.mkdir(parents=True)
    conf = tmp_path / "only-homes.conf"
    conf.write_text(
        "[homes]\npath = /volume1/home/%u\nwriteable = yes\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("SAMBA_SHARES_CONF", str(conf))
    get_settings.cache_clear()
    shares._samba_cache.update({"mtime": None, "shares": {}, "home_template": None})
    # Prefer the expanded template path over passwd %H.
    monkeypatch.setattr(
        shares.pwd,
        "getpwnam",
        lambda name: types.SimpleNamespace(
            pw_name=name, pw_dir=str(nas["nasadmin"]), pw_uid=1001, pw_gid=1001
        ),
    )
    assert shares.share_path("~nasadmin") == vol1_home.resolve()


def test_sanitize_personal_share_id():
    assert shares._sanitize_share_id("~nasadmin") == "~nasadmin"
    with pytest.raises(FSError):
        shares._sanitize_share_id("~nasadmin/../etc")
    with pytest.raises(FSError):
        shares._sanitize_share_id("~")


def test_does_not_create_missing_personal_folder(nas, monkeypatch):
    target = nas["home_root"] / "st10001"
    assert not target.exists()

    def getpwnam(name: str):
        mapping = {
            "nasadmin": types.SimpleNamespace(
                pw_name="nasadmin", pw_dir=str(nas["nasadmin"]), pw_uid=1001, pw_gid=1001
            ),
            "st10001": types.SimpleNamespace(
                pw_name="st10001", pw_dir=str(target), pw_uid=1067, pw_gid=10
            ),
        }
        if name not in mapping:
            raise KeyError(name)
        return mapping[name]

    monkeypatch.setattr(shares.pwd, "getpwnam", getpwnam)
    listed = shares.list_shares_for_user("st10001", 1067, 10)
    assert not target.exists()
    assert all(s["id"] != "~st10001" for s in listed)
    assert "InFocus Drive" in {s["id"] for s in listed}


def test_does_not_create_missing_homes_for_other_users(nas, monkeypatch):
    target = nas["home_root"] / "st10001"
    assert not target.exists()

    def getpwnam(name: str):
        mapping = {
            "nasadmin": types.SimpleNamespace(
                pw_name="nasadmin", pw_dir=str(nas["nasadmin"]), pw_uid=1001, pw_gid=1001
            ),
            "alice": types.SimpleNamespace(
                pw_name="alice", pw_dir=str(nas["alice"]), pw_uid=1002, pw_gid=1002
            ),
            "st10001": types.SimpleNamespace(
                pw_name="st10001", pw_dir=str(target), pw_uid=1067, pw_gid=10
            ),
        }
        if name not in mapping:
            raise KeyError(name)
        return mapping[name]

    monkeypatch.setattr(shares.pwd, "getpwnam", getpwnam)
    monkeypatch.setattr(shares, "is_nas_admin", lambda username: username == "nasadmin")
    listed = shares.list_shares_for_user("nasadmin", 1001, 1001)
    assert not target.exists()
    assert "~st10001" not in {s["id"] for s in listed}
