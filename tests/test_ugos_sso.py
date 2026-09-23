import re
import sys
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi import FastAPI, Request
from fastapi.testclient import TestClient
from starlette.middleware.sessions import SessionMiddleware

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
import ugos_sso
from config import get_settings

DRIVE = "https://drive.infocuspaly.com"
UGOS = "https://ugos.infocuspaly.com"
IDENTITY = {"username": "student", "uid": 1001, "gid": 100, "email": "student@pausd.us", "auth_provider": "google", "google_sub": "google-user-id"}
LOGIN = {"token": "secret-native-session", "username": "student", "uid": 1001, "public_key": "cHVibGljLWtleQ==", "role": "user"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("UGOS_SSO_ENABLED", "true")
    get_settings.cache_clear()
    ugos_sso._flows.clear()
    ugos_sso._hits.clear()
    monkeypatch.setattr(ugos_sso, "resolve_nas_user", lambda email: SimpleNamespace(username="student", uid=1001))
    monkeypatch.setattr(ugos_sso, "issue_ticket", lambda username, uid: "idsso_ticket")
    monkeypatch.setattr(ugos_sso, "nas_password_login", lambda *a, **kw: {"ok": True, "login_data": dict(LOGIN)})
    app = FastAPI()
    app.add_middleware(SessionMiddleware, secret_key="test-secret", https_only=True)
    app.include_router(ugos_sso.router)
    @app.post("/test-login")
    async def login(request: Request):
        request.session["user"] = await request.json()
        return {"ok": True}
    with TestClient(app, base_url=DRIVE, follow_redirects=False) as c:
        c.post("/test-login", json=IDENTITY)
        yield c
    get_settings.cache_clear()


def start(client):
    response = client.get(UGOS + "/infocus-sso/start")
    assert response.status_code == 302
    return parse_qs(urlsplit(response.headers["location"]).query)["state"][0]


def complete(client, state):
    response = client.get("/auth/ugos/continue", params={"state": state})
    assert response.status_code == 200, response.text
    assert LOGIN["token"] not in response.text
    # no-referrer makes browsers serialize Origin as null for form navigation.
    assert response.headers["referrer-policy"] == "strict-origin"
    return re.search(r'name="code" value="([A-Za-z0-9_-]+)"', response.text)[1]


def finish(client, state, code):
    return client.post(UGOS + "/infocus-sso/finish", data={"state": state, "code": code}, headers={"Origin": DRIVE})


def test_google_login_transfers_only_to_bound_browser_once(client):
    state = start(client)
    code = complete(client, state)
    response = finish(client, state, code)
    assert response.status_code == 200
    assert LOGIN["token"] in response.text
    assert "no-store" in response.headers["cache-control"]
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
    assert finish(client, state, code).status_code == 400


@pytest.mark.parametrize("identity", [{}, {**IDENTITY, "auth_provider": "nas"}, {**IDENTITY, "google_sub": ""}])
def test_non_google_session_redirects_to_google_without_issuing(client, monkeypatch, identity):
    client.post("/test-login", json=identity)
    monkeypatch.setattr(ugos_sso, "issue_ticket", lambda *a: pytest.fail("must not issue"))
    response = client.get("/auth/ugos/continue", params={"state": start(client)})
    assert response.status_code == 302
    assert response.headers["location"].startswith("/auth/login?")


def test_changed_nas_mapping_rejected(client, monkeypatch):
    monkeypatch.setattr(ugos_sso, "resolve_nas_user", lambda _: SimpleNamespace(username="someone-else", uid=1002))
    monkeypatch.setattr(ugos_sso, "issue_ticket", lambda *a: pytest.fail("must not issue"))
    assert client.get("/auth/ugos/continue", params={"state": start(client)}).status_code == 403


def test_wrong_browser_or_code_cannot_redeem(client):
    state = start(client)
    code = complete(client, state)
    assert finish(client, state, "wrong").status_code == 400
    with TestClient(client.app, base_url=UGOS) as other:
        assert finish(other, state, code).status_code == 400
    assert finish(client, state, code).status_code == 200


def test_wrong_origin_cannot_redeem(client):
    state = start(client)
    code = complete(client, state)
    response = client.post(UGOS + "/infocus-sso/finish", data={"state": state, "code": code}, headers={"Origin": "https://evil.test"})
    assert response.status_code == 403
    assert finish(client, state, code).status_code == 200


def test_flow_expiry(client, monkeypatch):
    state = start(client)
    code = complete(client, state)
    monkeypatch.setattr(ugos_sso.time, "time", lambda: 10**12)
    assert finish(client, state, code).status_code == 400


def test_repeated_continue_does_not_mint_again(client, monkeypatch):
    state = start(client)
    complete(client, state)
    monkeypatch.setattr(ugos_sso, "issue_ticket", lambda *a: pytest.fail("must not issue twice"))
    assert client.get("/auth/ugos/continue", params={"state": state}).status_code == 400


def test_native_identity_mismatch_never_transferred(client, monkeypatch):
    monkeypatch.setattr(ugos_sso, "nas_password_login", lambda *a, **kw: {"ok": True, "login_data": {**LOGIN, "uid": 1002}})
    response = client.get("/auth/ugos/continue", params={"state": start(client)})
    assert response.status_code == 502
    assert LOGIN["token"] not in response.text


def test_otp_required_and_bound_to_drive_browser(client, monkeypatch):
    monkeypatch.setattr(ugos_sso, "nas_password_login", lambda *a, **kw: {"ok": True, "need_otp": True, "token_id": "private-challenge"})
    state = start(client)
    response = client.get("/auth/ugos/continue", params={"state": state})
    assert 'name="otp"' in response.text
    assert "private-challenge" not in response.text
    monkeypatch.setattr(ugos_sso, "nas_otp_login", lambda *a, **kw: {"ok": True, "login_data": dict(LOGIN)})
    with TestClient(client.app, base_url=DRIVE) as other:
        other.post("/test-login", json=IDENTITY)
        assert other.post("/auth/ugos/otp", data={"state": state, "otp": "123456"}, headers={"Origin": DRIVE}).status_code == 403
    response = client.post("/auth/ugos/otp", data={"state": state, "otp": "123456"}, headers={"Origin": DRIVE})
    code = re.search(r'name="code" value="([A-Za-z0-9_-]+)"', response.text)[1]
    assert finish(client, state, code).status_code == 200


def test_disabled_and_wrong_host_fail_closed(client, monkeypatch):
    assert client.get(DRIVE + "/infocus-sso/start").status_code == 403
    monkeypatch.setattr(get_settings(), "ugos_sso_enabled", False)
    assert client.get(UGOS + "/infocus-sso/start").status_code == 404


def test_email_otp_is_native_browser_bound_and_rate_limited(client, monkeypatch):
    monkeypatch.setattr(ugos_sso, "nas_password_login", lambda *a, **kw: {"ok": True, "need_otp": True, "token_id": "challenge", "can_email_otp": True})
    sent = []
    monkeypatch.setattr(ugos_sso, "nas_send_otp_email", lambda base, username: sent.append(username) or True)
    state = start(client)
    response = client.get("/auth/ugos/continue", params={"state": state})
    assert "Email a code" in response.text
    assert not sent
    assert client.post("/auth/ugos/otp/email", data={"state": state}, headers={"Origin": "https://evil.test"}).status_code == 403
    response = client.post("/auth/ugos/otp/email", data={"state": state}, headers={"Origin": DRIVE})
    assert response.status_code == 200
    assert sent == ["student"]
    assert 'value="2" selected' in response.text
    assert client.post("/auth/ugos/otp/email", data={"state": state}, headers={"Origin": DRIVE}).status_code == 429
    assert sent == ["student"]


def test_login_json_cannot_escape_script_element(client, monkeypatch):
    monkeypatch.setattr(ugos_sso, "nas_password_login", lambda *a, **kw: {"ok": True, "login_data": {**LOGIN, "nas_name": "</script><img src=x onerror=alert(1)>"}})
    state = start(client)
    response = finish(client, state, complete(client, state))
    assert response.status_code == 200
    assert "<img" not in response.text
    assert "\\u003c/script\\u003e" in response.text
