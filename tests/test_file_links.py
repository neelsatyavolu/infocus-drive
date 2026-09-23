"""Signed public file-share links."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from config import get_settings  # noqa: E402


@pytest.fixture()
def secret(monkeypatch):
    monkeypatch.setenv("SESSION_SECRET", "test-file-link-secret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://drive.infocuspaly.com")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_mint_default_and_max_days(secret):
    import file_links

    token7 = file_links.mint(
        share="InFocus Drive", path="clip.mp4", days=7, uid=1001, gid=1001, name="clip.mp4"
    )
    payload = file_links.verify(token7)
    assert payload["v"] == 1
    assert payload["share"] == "InFocus Drive"
    assert payload["path"] == "clip.mp4"
    assert payload["name"] == "clip.mp4"
    assert payload["uid"] == 1001
    assert payload["gid"] == 1001
    assert payload["exp"] > time.time() + 6 * 86400
    assert payload["exp"] < time.time() + 8 * 86400

    token30 = file_links.mint(
        share="InFocus Drive", path="clip.mp4", days=30, uid=1001, gid=1001, name="clip.mp4"
    )
    p30 = file_links.verify(token30)
    assert p30["exp"] > time.time() + 29 * 86400
    assert p30["exp"] < time.time() + 31 * 86400


def test_mint_rejects_days_out_of_range(secret):
    import file_links

    with pytest.raises(ValueError):
        file_links.mint(share="InFocus Drive", path="a.txt", days=0, uid=1, gid=1, name="a.txt")
    with pytest.raises(ValueError):
        file_links.mint(share="InFocus Drive", path="a.txt", days=31, uid=1, gid=1, name="a.txt")


def test_tampered_token_is_invalid(secret):
    import file_links

    token = file_links.mint(
        share="InFocus Drive", path="a.txt", days=7, uid=1, gid=1, name="a.txt"
    )
    bad = token[:-2] + ("A" if token[-2] != "A" else "B") + token[-1]
    with pytest.raises(file_links.LinkError) as ei:
        file_links.verify(bad)
    assert ei.value.code == "invalid"


def test_expired_token(secret):
    import file_links

    token = file_links._ser().dumps(
        {
            "v": 1,
            "share": "InFocus Drive",
            "path": "a.txt",
            "exp": int(time.time()) - 10,
            "name": "a.txt",
            "uid": 1,
            "gid": 1,
        }
    )
    with pytest.raises(file_links.LinkError) as ei:
        file_links.verify(token)
    assert ei.value.code == "expired"
    assert ei.value.payload["name"] == "a.txt"


def test_public_url(secret):
    import file_links

    url = file_links.public_url("abc.token")
    assert url == "https://drive.infocuspaly.com/s/abc.token"


def test_preview_kind():
    import file_links

    assert file_links.preview_kind("clip.mp4") == "video"
    assert file_links.preview_kind("pic.png") == "image"
    assert file_links.preview_kind("notes.txt") == "text"
    assert file_links.preview_kind("pack.zip") is None


# ---------------------------------------------------------------------------
# HTTP routes
# ---------------------------------------------------------------------------


@pytest.fixture()
def drive_root(tmp_path, monkeypatch, secret):
    root = tmp_path / "InFocus Drive"
    root.mkdir()
    (root / "clip.mp4").write_bytes(b"fake-mp4-bytes")
    nested = root / "Camp"
    nested.mkdir()
    (nested / "take.mp4").write_bytes(b"nested-bytes")
    (root / "notes.txt").write_text("hello share")
    monkeypatch.setenv("DRIVE_ROOT", str(root))
    get_settings.cache_clear()
    return root


@pytest.fixture()
def client(drive_root, monkeypatch):
    import main

    uid, gid = os.getuid(), os.getgid()

    monkeypatch.setattr(
        main,
        "_require_user",
        lambda request: {"uid": uid, "gid": gid, "username": "tester", "email": "t@pausd.org"},
    )
    monkeypatch.setattr(main, "_active_share", lambda request, user: "InFocus Drive")
    monkeypatch.setattr(main, "share_path", lambda share: drive_root)
    return TestClient(main.app)


def test_mint_and_public_get_without_session(client, drive_root):
    res = client.post("/api/file-link", json={"path": "clip.mp4", "days": 7})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["url"].startswith("https://drive.infocuspaly.com/s/")
    assert "expires_at" in body
    token = body["url"].rsplit("/", 1)[-1]

    # No session cookie on a fresh client for public routes.
    public = TestClient(client.app)
    meta = public.get(f"/api/s/{token}")
    assert meta.status_code == 200, meta.text
    data = meta.json()
    assert data["name"] == "clip.mp4"
    assert data["size"] == len(b"fake-mp4-bytes")
    assert data["kind"] == "video"
    assert data["previewable"] is True
    assert data.get("error") in (None, "")
    assert "path" not in data
    assert "Camp" not in meta.text
    assert "tester" not in meta.text
    assert "uid" not in data

    page = public.get(f"/s/{token}")
    assert page.status_code == 200
    assert "share.js" in page.text
    assert "noindex" in page.text


def test_mint_rejects_directory_and_bad_days(client):
    assert client.post("/api/file-link", json={"path": "Camp", "days": 7}).status_code == 400
    assert client.post("/api/file-link", json={"path": "clip.mp4", "days": 0}).status_code == 400
    assert client.post("/api/file-link", json={"path": "clip.mp4", "days": 31}).status_code == 400


def test_public_tampered_and_expired(client, secret):
    import file_links
    import main

    public = TestClient(main.app)
    token = file_links.mint(
        share="InFocus Drive", path="clip.mp4", days=7, uid=1, gid=1, name="clip.mp4"
    )
    bad = token[:-2] + ("A" if token[-2] != "A" else "B") + token[-1]
    res = public.get(f"/api/s/{bad}")
    assert res.status_code == 404
    assert res.json()["error"] == "invalid"

    expired = file_links._ser().dumps(
        {
            "v": 1,
            "share": "InFocus Drive",
            "path": "clip.mp4",
            "exp": int(time.time()) - 5,
            "name": "clip.mp4",
            "uid": 1,
            "gid": 1,
        }
    )
    res = public.get(f"/api/s/{expired}")
    assert res.status_code == 404
    assert res.json()["error"] == "expired"


def test_missing_file_after_mint(client, drive_root):
    res = client.post("/api/file-link", json={"path": "clip.mp4", "days": 7})
    token = res.json()["url"].rsplit("/", 1)[-1]
    (drive_root / "clip.mp4").unlink()
    public = TestClient(client.app)
    meta = public.get(f"/api/s/{token}")
    assert meta.status_code == 404
    assert meta.json()["error"] == "unavailable"


def test_path_traversal_payload_rejected(client, secret, drive_root):
    import file_links

    uid, gid = os.getuid(), os.getgid()
    token = file_links._ser().dumps(
        {
            "v": 1,
            "share": "InFocus Drive",
            "path": "../etc/passwd",
            "exp": int(time.time()) + 86400,
            "name": "passwd",
            "uid": uid,
            "gid": gid,
        }
    )
    public = TestClient(client.app)
    res = public.get(f"/api/s/{token}")
    assert res.status_code in (400, 404)
    body = res.json()
    assert body.get("error") in ("unavailable", "invalid") or res.status_code == 400


def test_parent_path_not_in_public_json(client):
    res = client.post("/api/file-link", json={"path": "Camp/take.mp4", "days": 7})
    token = res.json()["url"].rsplit("/", 1)[-1]
    public = TestClient(client.app)
    data = public.get(f"/api/s/{token}").json()
    assert data["name"] == "take.mp4"
    assert "path" not in data
    assert "Camp" not in str(data)


def test_file_inline_vs_attachment(client):
    res = client.post("/api/file-link", json={"path": "notes.txt", "days": 7})
    token = res.json()["url"].rsplit("/", 1)[-1]
    public = TestClient(client.app)

    att = public.get(f"/api/s/{token}/file")
    assert att.status_code == 200
    assert att.content == b"hello share"
    disp = att.headers.get("content-disposition", "").lower()
    assert "attachment" in disp

    inline = public.get(f"/api/s/{token}/file", params={"inline": "1"})
    assert inline.status_code == 200
    disp = inline.headers.get("content-disposition", "").lower()
    assert "inline" in disp
