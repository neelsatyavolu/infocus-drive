"""The service API can read the switcher's Shows/ folder but never write to it."""

import hmac
import pwd
import sys
import time
from hashlib import sha256
from pathlib import Path

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
import service_auth  # noqa: E402
from config import get_settings  # noqa: E402

TOKEN = "service-test-token"
BEARER = {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def drive(tmp_path, monkeypatch):
    root = tmp_path / "drive"
    shows = root / "Shows"
    (shows / "sub").mkdir(parents=True)
    (shows / "#recycle").mkdir()
    (shows / "rec.mov").write_bytes(b"recording")
    (shows / ".hidden.mov").write_bytes(b"x")
    (root / "Package Storage" / "Shows" / "2026-10-21").mkdir(parents=True)
    (root / "Package Storage" / "clip.mp4").write_bytes(b"clip")
    (root / "Other").mkdir()
    (root / "Other" / "secret.txt").write_bytes(b"secret")

    monkeypatch.setenv("DRIVE_ROOT", str(root))
    monkeypatch.setenv("PACKAGES_SERVICE_TOKEN", TOKEN)
    monkeypatch.setenv("PACKAGES_SERVICE_USER", "svcuser")
    get_settings.cache_clear()

    def getpwnam(name):
        if name != "svcuser":
            raise KeyError(name)
        return pwd.struct_passwd((name, "x", 1500, 100, "", "/", "/bin/sh"))

    monkeypatch.setattr(service_auth.pwd, "getpwnam", getpwnam)
    return root


@pytest.fixture
def client(drive):
    return TestClient(main.app, base_url="https://drive.example.com")


def read_token(path: str) -> str:
    return service_auth.mint_file_token(path, purpose="r")["token"]


# --- list -------------------------------------------------------------------


def test_list_shows_root_returns_items(client):
    res = client.get("/api/service/list", params={"path": "Shows"}, headers=BEARER)
    assert res.status_code == 200, res.text
    data = res.json()
    assert data["path"] == "Shows"
    by_name = {item["name"]: item for item in data["items"]}
    assert set(by_name) == {"sub", "rec.mov"}  # no dotfiles, no #recycle
    rec = by_name["rec.mov"]
    assert rec == {
        "name": "rec.mov",
        "path": "Shows/rec.mov",
        "isDir": False,
        "size": len(b"recording"),
        "mtime": rec["mtime"],
    }
    assert rec["mtime"].endswith("+00:00")
    assert by_name["sub"]["isDir"] is True


def test_list_package_storage_still_allowed(client):
    res = client.get("/api/service/list", params={"path": "Package Storage"}, headers=BEARER)
    assert res.status_code == 200
    assert {i["name"] for i in res.json()["items"]} == {"Shows", "clip.mp4"}


def test_list_requires_bearer(client):
    assert client.get("/api/service/list", params={"path": "Shows"}).status_code == 401
    token = read_token("Shows")
    res = client.get("/api/service/list", params={"path": "Shows", "token": token})
    assert res.status_code == 401


def test_list_outside_roots_forbidden(client):
    res = client.get("/api/service/list", params={"path": "Other"}, headers=BEARER)
    assert res.status_code == 403


def test_list_missing_folder_404(client):
    res = client.get("/api/service/list", params={"path": "Shows/nope"}, headers=BEARER)
    assert res.status_code == 404


def test_list_traversal_blocked(client):
    res = client.get("/api/service/list", params={"path": "Shows/../Other"}, headers=BEARER)
    assert res.status_code == 400


# --- read -------------------------------------------------------------------


def test_file_read_under_shows_with_bearer(client):
    res = client.get("/api/service/file", params={"path": "Shows/rec.mov"}, headers=BEARER)
    assert res.status_code == 200
    assert res.content == b"recording"


def test_file_read_under_shows_with_read_token(client):
    token = read_token("Shows/rec.mov")
    res = client.get("/api/service/file", params={"path": "Shows/rec.mov", "token": token, "inline": "false"})
    assert res.status_code == 200
    assert res.content == b"recording"


def test_read_token_is_bound_to_its_path(client):
    token = read_token("Shows/rec.mov")
    res = client.get("/api/service/file", params={"path": "Shows/.hidden.mov", "token": token})
    assert res.status_code == 401


def test_mint_read_token_for_shows(client):
    res = client.post("/api/service/mint-token", json={"path": "Shows/rec.mov", "purpose": "r"}, headers=BEARER)
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["purpose"] == "r"
    assert body["path"] == "Shows/rec.mov"
    assert "/api/service/file?path=Shows%2Frec.mov&token=" in body["downloadUrl"]


def test_file_read_traversal_blocked(client):
    res = client.get("/api/service/file", params={"path": "Shows/../Other/secret.txt"}, headers=BEARER)
    assert res.status_code == 400


def test_file_read_outside_roots_forbidden(client):
    res = client.get("/api/service/file", params={"path": "Other/secret.txt"}, headers=BEARER)
    assert res.status_code == 403


# --- write is refused under Shows/ ------------------------------------------


@pytest.mark.parametrize("purpose", ["rw", "w"])
def test_mint_write_token_for_shows_forbidden(client, purpose):
    res = client.post("/api/service/mint-token", json={"path": "Shows/rec.mov", "purpose": purpose}, headers=BEARER)
    assert res.status_code == 403


def test_mint_write_token_helper_refuses_shows():
    with pytest.raises(HTTPException) as exc:
        service_auth.mint_file_token("Shows/new.mov", purpose="rw")
    assert exc.value.status_code == 403


def test_forged_write_token_for_shows_refused(drive):
    exp = int(time.time()) + 600
    msg = f"rw|{exp}|Shows/rec.mov".encode()
    sig = hmac.new(service_auth._service_ser_secret(), msg, sha256).hexdigest()
    with pytest.raises(HTTPException) as exc:
        service_auth.verify_file_token(f"rw.{exp}.{sig}", "Shows/rec.mov", purpose="rw")
    assert exc.value.status_code == 403


def test_upload_init_under_shows_forbidden(client):
    res = client.post(
        "/api/service/upload/init",
        data={"path": "Shows", "name": "x.mov", "size": "4"},
        headers=BEARER,
    )
    assert res.status_code == 403


def test_single_upload_under_shows_forbidden(client):
    res = client.post(
        "/api/service/upload",
        data={"path": "Shows"},
        files={"file": ("x.mov", b"data")},
        headers=BEARER,
    )
    assert res.status_code == 403


def test_ensure_dir_under_shows_forbidden(client):
    res = client.post("/api/service/ensure-dir", json={"path": "Shows/new"}, headers=BEARER)
    assert res.status_code == 403
    assert not (Path(get_settings().drive_root) / "Shows" / "new").exists()


def test_delete_under_shows_forbidden(client, drive):
    res = client.delete("/api/service/file", params={"path": "Shows/rec.mov"}, headers=BEARER)
    assert res.status_code == 403
    assert (drive / "Shows" / "rec.mov").exists()


# --- package roots unchanged ------------------------------------------------


def test_package_write_token_still_reads_and_writes(drive):
    token = service_auth.mint_file_token("Package Storage/Shows/2026-10-21/out.mp4", purpose="rw")["token"]
    service_auth.verify_file_token(token, "Package Storage/Shows/2026-10-21/out.mp4", purpose="rw")
    service_auth.verify_file_token(token, "Package Storage/Shows/2026-10-21/out.mp4", purpose="r")


def test_package_storage_shows_folder_is_writable(client, drive):
    """Package Storage/Shows (the edited output) is not the switcher's Shows/ root."""
    res = client.post(
        "/api/service/ensure-dir", json={"path": "Package Storage/Shows/2026-10-22"}, headers=BEARER
    )
    assert res.status_code == 200, res.text
    assert (drive / "Package Storage" / "Shows" / "2026-10-22").is_dir()


def test_shows_root_can_be_disabled(client, monkeypatch):
    monkeypatch.setenv("SHOWS_ROOT", "")
    get_settings.cache_clear()
    res = client.get("/api/service/list", params={"path": "Shows"}, headers=BEARER)
    assert res.status_code == 403
