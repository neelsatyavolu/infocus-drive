"""The service API can read All Resources/Graphic Files (the package zips the editing Macs install) but never
write there, and nothing else under All Resources."""

import pwd
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
import service_auth  # noqa: E402
from config import get_settings  # noqa: E402

TOKEN = "service-test-token"
BEARER = {"Authorization": f"Bearer {TOKEN}"}
GRAPHICS = "All Resources/Graphic Files"


@pytest.fixture
def drive(tmp_path, monkeypatch):
    root = tmp_path / "drive"
    (root / GRAPHICS).mkdir(parents=True)
    (root / GRAPHICS / "InFocus Christmas 2026 Package.zip").write_bytes(b"zip")
    (root / "All Resources" / "Past Shows").mkdir(parents=True)
    (root / "Package Storage").mkdir()
    monkeypatch.setenv("DRIVE_ROOT", str(root))
    monkeypatch.setenv("PACKAGES_SERVICE_TOKEN", TOKEN)
    monkeypatch.setenv("PACKAGES_SERVICE_USER", "svcuser")
    get_settings.cache_clear()

    def getpwnam(name):
        if name != "svcuser":
            raise KeyError(name)
        return pwd.struct_passwd((name, "x", 1500, 100, "", "/", "/bin/sh"))

    monkeypatch.setattr(service_auth.pwd, "getpwnam", getpwnam)
    yield root
    get_settings.cache_clear()


@pytest.fixture
def client(drive):
    return TestClient(main.app, base_url="https://drive.example.com")


def test_graphic_files_can_be_listed(client):
    res = client.get("/api/service/list", params={"path": GRAPHICS}, headers=BEARER)
    assert res.status_code == 200, res.text
    assert [i["name"] for i in res.json()["items"]] == ["InFocus Christmas 2026 Package.zip"]


def test_a_read_token_is_minted_for_a_zip(client):
    path = f"{GRAPHICS}/InFocus Christmas 2026 Package.zip"
    res = client.post("/api/service/mint-token", json={"path": path, "purpose": "r"}, headers=BEARER)
    assert res.status_code == 200, res.text


def test_graphic_files_are_read_only(client):
    path = f"{GRAPHICS}/new.zip"
    res = client.post("/api/service/mint-token", json={"path": path, "purpose": "rw"}, headers=BEARER)
    assert res.status_code == 403
    res = client.post("/api/service/ensure-dir", json={"path": f"{GRAPHICS}/x"}, headers=BEARER)
    assert res.status_code == 403


def test_the_rest_of_all_resources_stays_closed(client):
    for path in ("All Resources", "All Resources/Past Shows", "All Resources/Graphic Files Extra"):
        res = client.get("/api/service/list", params={"path": path}, headers=BEARER)
        assert res.status_code == 403, path


def test_graphics_root_can_be_disabled(client, monkeypatch):
    monkeypatch.setenv("GRAPHICS_ROOT", "")
    get_settings.cache_clear()
    res = client.get("/api/service/list", params={"path": GRAPHICS}, headers=BEARER)
    assert res.status_code == 403
