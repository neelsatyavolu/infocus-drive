"""The infocus-graphics repo's Drive sync: its own key may write the package folders in All Resources and the package
zips in Graphic Files, and nothing else. The Portal's service key can't use these routes, and this key can't use
the Portal's."""

import json
import pwd
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
import service_auth  # noqa: E402
from config import get_settings  # noqa: E402

PUBLISH = "publish-test-token"
SERVICE = "service-test-token"
KEY = {"Authorization": f"Bearer {PUBLISH}"}
BASE = "/api/service/graphics-publish"
PKG = "All Resources/InFocus Christmas 2026 Package"
ZIP = "All Resources/Graphic Files/InFocus Christmas 2026 Package.zip"


@pytest.fixture
def drive(tmp_path, monkeypatch):
    root = tmp_path / "drive"
    (root / "All Resources" / "Graphic Files").mkdir(parents=True)
    (root / "All Resources" / "Past Shows").mkdir()
    (root / "All Resources" / "Past Shows" / "show.mp4").write_bytes(b"keep")
    (root / "Package Storage").mkdir()
    monkeypatch.setenv("DRIVE_ROOT", str(root))
    monkeypatch.setenv("PACKAGES_SERVICE_TOKEN", SERVICE)
    monkeypatch.setenv("GRAPHICS_PUBLISH_TOKEN", PUBLISH)
    monkeypatch.setenv("PACKAGES_SERVICE_USER", "svcuser")
    get_settings.cache_clear()
    me = pwd.getpwuid(__import__("os").getuid())

    def getpwnam(name):
        if name != "svcuser":
            raise KeyError(name)
        return pwd.struct_passwd((name, "x", me.pw_uid, me.pw_gid, "", "/", "/bin/sh"))

    monkeypatch.setattr(service_auth.pwd, "getpwnam", getpwnam)
    # The real service user is a NAS account (uid >= 1000); here it's whoever runs the tests.
    monkeypatch.setattr(main, "service_identity",
                        lambda: service_auth.ServiceIdentity(username=me.pw_name, uid=me.pw_uid, gid=me.pw_gid))
    monkeypatch.setattr(main, "share_path", lambda share: root)   # the "InFocus Drive" share is the test drive
    yield root
    get_settings.cache_clear()


@pytest.fixture
def client(drive):
    return TestClient(main.app, base_url="https://drive.example.com")


def upload(client, path, data, headers=KEY):
    res = client.post(f"{BASE}/upload/init", data={"path": path, "size": len(data), "chunk_size": 1024 * 1024},
                      headers=headers)
    if res.status_code != 200:
        return res
    upload_id = res.json()["upload_id"]
    res = client.put(f"{BASE}/upload/chunk", params={"upload_id": upload_id, "index": 0}, content=data, headers=headers)
    assert res.status_code == 200, res.text
    return client.post(f"{BASE}/upload/complete", data={"upload_id": upload_id}, headers=headers)


def test_a_package_file_and_its_zip_are_written_and_replaced(client, drive):
    res = upload(client, f"{PKG}/03 Intro & Outro/Intro.mp4", b"one")
    assert res.status_code == 200, res.text
    assert upload(client, f"{PKG}/03 Intro & Outro/Intro.mp4", b"two!").status_code == 200
    assert (drive / PKG / "03 Intro & Outro" / "Intro.mp4").read_bytes() == b"two!"
    assert upload(client, ZIP, b"PK zip").status_code == 200
    assert (drive / ZIP).read_bytes() == b"PK zip"


@pytest.mark.parametrize("path", [
    "All Resources/Past Shows/show.mp4",                      # the rest of All Resources
    "All Resources/README.md",
    "All Resources/InFocus Christmas 2026 Package",           # the folder itself
    "All Resources/Graphic Files/other.zip",
    "All Resources/Graphic Files/InFocus Christmas 2026 Package/x.mp4",
    f"{PKG}/../Past Shows/show.mp4",
    f"{PKG}/#recycle/x.mp4",
    "Package Storage/x.mp4",
    "All Resources/Not A Package/x.mp4",
])
def test_writes_outside_the_packages_are_refused(client, drive, path):
    assert upload(client, path, b"x").status_code in (400, 403)
    assert (drive / "All Resources" / "Past Shows" / "show.mp4").read_bytes() == b"keep"


def test_the_portal_key_cannot_publish_and_this_key_cannot_use_the_portal_routes(client):
    service = {"Authorization": f"Bearer {SERVICE}"}
    assert upload(client, f"{PKG}/x.mp4", b"x", headers=service).status_code == 401
    assert client.get("/api/service/list", params={"path": "Package Storage"}, headers=KEY).status_code == 401
    assert upload(client, f"{PKG}/x.mp4", b"x", headers={}).status_code == 401


def test_publishing_is_off_without_a_key(client, monkeypatch):
    monkeypatch.setenv("GRAPHICS_PUBLISH_TOKEN", "")
    get_settings.cache_clear()
    assert upload(client, f"{PKG}/x.mp4", b"x").status_code == 503


def test_the_manifest_round_trips_per_package(client, drive):
    res = client.get(f"{BASE}/manifest", params={"package": "InFocus Christmas 2026 Package"}, headers=KEY)
    assert res.status_code == 200 and res.json() == {}
    body = {"files": {"03 Intro & Outro/Intro.mp4": "abc"}, "zip": "def"}
    res = client.put(f"{BASE}/manifest", params={"package": "InFocus Christmas 2026 Package"}, json=body, headers=KEY)
    assert res.status_code == 200, res.text
    res = client.get(f"{BASE}/manifest", params={"package": "InFocus Christmas 2026 Package"}, headers=KEY)
    assert res.json() == body
    assert json.loads((drive / PKG / ".drive-sync.json").read_text()) == body
    bad = client.get(f"{BASE}/manifest", params={"package": "../Past Shows"}, headers=KEY)
    assert bad.status_code == 403


def test_delete_moves_a_package_file_to_the_recycle_bin_and_nothing_else(client, drive):
    (drive / "#recycle").mkdir()
    assert upload(client, f"{PKG}/old.mp4", b"old").status_code == 200
    res = client.post(f"{BASE}/delete", json={"path": f"{PKG}/old.mp4"}, headers=KEY)
    assert res.status_code == 200, res.text
    assert not (drive / PKG / "old.mp4").exists()
    assert (drive / "#recycle" / PKG / "old.mp4").exists()
    res = client.post(f"{BASE}/delete", json={"path": "All Resources/Past Shows/show.mp4"}, headers=KEY)
    assert res.status_code == 403
    res = client.post(f"{BASE}/delete", json={"path": PKG}, headers=KEY)
    assert res.status_code == 403
