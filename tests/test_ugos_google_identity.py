import sys
import base64
import json
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
import main


@pytest.fixture
def oauth(monkeypatch):
    monkeypatch.setattr(main.settings, "google_client_id", "test-client")
    monkeypatch.setattr(main.settings, "google_client_secret", "test-secret")
    monkeypatch.setattr(main, "_public_config", lambda request: {"via_lan": False})
    monkeypatch.setattr(main, "ensure_for_login", lambda *a: SimpleNamespace(username="student", uid=1001, gid=100))
    seen = []
    info = {"email": "student@pausd.us", "email_verified": True, "sub": "google-sub"}
    class Google:
        def __init__(self, **kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        async def post(self, *args, **kwargs):
            seen.append("exchange")
            return httpx.Response(200, json={"access_token": "test-access"})
        async def get(self, *args, **kwargs):
            return httpx.Response(200, json=info)
    monkeypatch.setattr(main.httpx, "AsyncClient", Google)
    return TestClient(main.app, base_url="https://drive.infocuspaly.com", follow_redirects=False), seen, info


def begin(client):
    response = client.get("/auth/login")
    return parse_qs(urlsplit(response.headers["location"]).query)["state"][0]


def test_google_oauth_is_bound_to_initiating_browser(oauth):
    client, seen, _ = oauth
    state = begin(client)
    other = TestClient(main.app, base_url="https://drive.infocuspaly.com", follow_redirects=False)
    assert other.get("/auth/callback", params={"code": "x", "state": state}).status_code == 400
    assert not seen
    assert client.get("/auth/callback", params={"code": "x", "state": state}).status_code == 307
    assert seen == ["exchange"]
    session = json.loads(base64.b64decode(client.cookies.get(main.settings.session_cookie).split(".")[0]))
    assert session["user"]["auth_provider"] == "google"
    assert client.get("/auth/callback", params={"code": "x", "state": state}).status_code == 400
    assert seen == ["exchange"]


def test_google_email_must_be_explicitly_verified(oauth):
    client, _, info = oauth
    info.pop("email_verified")
    assert client.get("/auth/callback", params={"code": "x", "state": begin(client)}).status_code == 403


def test_lan_login_first_establishes_cookie_on_public_origin(oauth, monkeypatch):
    client, seen, _ = oauth
    monkeypatch.setattr(main, "_public_config", lambda request: {"via_lan": True})
    response = client.get("/auth/login", params={"next": "/example"})
    assert response.headers["location"].startswith("https://drive.infocuspaly.com/auth/login?")
    assert "return_lan=1" in response.headers["location"]
    assert "infocus_drive_session" not in response.headers.get("set-cookie", "")
    assert not seen


def test_transferable_lan_token_cannot_grant_google_sso_assurance(oauth):
    client, _, _ = oauth
    token = main._lan_handoff_ser().dumps({"username": "student", "uid": 1001, "gid": 100, "email": "student@pausd.us", "auth_provider": "google", "google_sub": "attacker-sub"})
    assert client.get("/auth/lan-handoff", params={"token": token}).status_code == 302
    session = json.loads(base64.b64decode(client.cookies.get(main.settings.session_cookie).split(".")[0]))
    assert "auth_provider" not in session["user"]
    assert "google_sub" not in session["user"]
