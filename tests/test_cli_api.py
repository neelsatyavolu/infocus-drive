import base64
import hashlib
import pwd
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import cli_tokens  # noqa: E402
import fsops  # noqa: E402
import main  # noqa: E402

ORIGIN = "https://drive.example.com"
VERIFIER = "v" * 43
CHALLENGE = base64.urlsafe_b64encode(hashlib.sha256(VERIFIER.encode()).digest()).rstrip(b"=").decode()
STATE = "s" * 32
USER = {"email": "student1@example.org", "name": "Student One", "picture": None,
        "username": "student1", "uid": 1001, "gid": 100}


@pytest.fixture
def web_user():
    return {"user": dict(USER)}


@pytest.fixture
def client(tmp_path, monkeypatch, web_user):
    monkeypatch.setenv("PUBLIC_BASE_URL", ORIGIN)
    monkeypatch.setenv("CLI_TOKENS_DB_PATH", str(tmp_path / "cli.sqlite3"))
    main.get_settings.cache_clear()
    monkeypatch.setattr(main.settings, "public_base_url", ORIGIN)

    def getpwnam(name):
        if name != "student1":
            raise KeyError(name)
        return pwd.struct_passwd((name, "x", 1001, 100, "", "/", "/bin/sh"))

    monkeypatch.setattr(cli_tokens.pwd, "getpwnam", getpwnam)

    def session_user(request):
        if web_user["user"] is None:
            raise HTTPException(status_code=401, detail="Not authenticated")
        return web_user["user"]

    monkeypatch.setattr(main, "_require_session_user", session_user)
    share_root = tmp_path / "share"
    share_root.mkdir()
    (share_root / "notes.txt").write_text("hello")
    monkeypatch.setattr(main, "share_path", lambda share: share_root)
    monkeypatch.setattr(main, "normalize_share_for_user", lambda requested, *a: requested or "InFocus Drive")
    monkeypatch.setattr(main, "list_shares_for_user", lambda *a: ["InFocus Drive"])
    monkeypatch.setattr(main, "is_nas_admin", lambda name: False)
    monkeypatch.setattr(main, "user_group_names", lambda *a: [])
    main._nas_login_hits.clear()
    main._cli_token_failures.clear()
    test_client = TestClient(main.app, base_url=ORIGIN)
    test_client.share_root = share_root
    return test_client


def authorize(client, headers=None, **overrides):
    body = {"port": 49152, "state": STATE, "challenge": CHALLENGE, "device": "Test Mac", "allow": "1"}
    body.update(overrides)
    return client.post("/api/cli/authorize", data=body, headers={"Origin": ORIGIN, **(headers or {})},
                       follow_redirects=False)


def redirect_of(response):
    assert response.status_code == 303, response.text
    return response.headers["location"]


def login(client):
    redirect = redirect_of(authorize(client))
    code = parse_qs(urlparse(redirect).query)["code"][0]
    response = client.post("/api/cli/token", json={"code": code, "verifier": VERIFIER})
    assert response.status_code == 200
    return response.json()


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def test_consent_redirects_only_to_loopback(client):
    response = authorize(client)
    assert "code=" not in response.text  # never readable by page script, only via the 303
    redirect = urlparse(redirect_of(response))
    assert (redirect.scheme, redirect.hostname, redirect.port, redirect.path) == ("http", "127.0.0.1", 49152, "/callback")
    query = parse_qs(redirect.query)
    assert query["state"] == [STATE] and query["code"][0]


def test_deny_redirects_with_error_and_no_code(client):
    query = parse_qs(urlparse(redirect_of(authorize(client, allow="0"))).query)
    assert query == {"error": ["access_denied"], "state": [STATE]}


@pytest.mark.parametrize("field,value", [
    ("port", 80), ("port", 70000), ("state", "short"), ("state", "bad state with spaces!!"),
    ("challenge", "nope"),
])
def test_consent_rejects_bad_parameters(client, field, value):
    assert authorize(client, **{field: value}).status_code == 400


def test_consent_requires_same_origin_and_web_session(client, web_user):
    body = {"port": 49152, "state": STATE, "challenge": CHALLENGE, "device": "Mac", "allow": "1"}
    assert client.post("/api/cli/authorize", data=body).status_code == 403
    assert client.post("/api/cli/authorize", data=body, headers={"Origin": "https://evil.example"}).status_code == 403
    web_user["user"] = None
    assert authorize(client).status_code == 401


def test_full_flow_gives_bearer_access_without_cookies(client):
    issued = login(client)
    assert issued["token"].startswith("ifd_") and issued["username"] == "student1"
    listing = client.get("/api/files", headers=bearer(issued["token"]))
    assert listing.status_code == 200
    assert [item["name"] for item in listing.json()["items"]] == ["notes.txt"]
    assert "set-cookie" not in listing.headers
    me = client.get("/api/me", headers=bearer(issued["token"]))
    assert me.json()["authenticated"] is True and me.json()["nas_username"] == "student1"
    assert "set-cookie" not in me.headers


def test_token_endpoint_rejects_wrong_verifier(client):
    redirect = redirect_of(authorize(client))
    code = parse_qs(urlparse(redirect).query)["code"][0]
    assert client.post("/api/cli/token", json={"code": code, "verifier": "w" * 43}).status_code == 401
    assert client.post("/api/cli/token", json={"code": code, "verifier": VERIFIER}).status_code == 401


def test_token_endpoint_limits_failures_not_successful_logins(client):
    for _ in range(main._CLI_TOKEN_MAX_FAILURES + 5):
        login(client)  # a classroom behind one NAT signing in together
    for _ in range(main._CLI_TOKEN_MAX_FAILURES):
        assert client.post("/api/cli/token", json={"code": "x", "verifier": VERIFIER}).status_code == 401
    assert client.post("/api/cli/token", json={"code": "x", "verifier": VERIFIER}).status_code == 429


def test_invalid_bearer_is_401_and_never_falls_back(client):
    response = client.get("/api/files", headers=bearer("ifd_forged"))
    assert response.status_code == 401
    assert "infocus login" in response.json()["detail"]


def test_bearer_cannot_mint_tokens_or_browser_sessions(client, web_user):
    token = login(client)["token"]
    web_user["user"] = None  # only the bearer is presented
    assert authorize(client, headers=bearer(token)).status_code == 401
    assert client.post("/api/lan-handoff", headers=bearer(token)).status_code == 401
    for endpoint in ("/api/personal/unlock", "/api/personal/auth"):
        assert client.post(endpoint, headers=bearer(token),
                           data={"owner": "student1", "key": "x", "password": "x"}).status_code == 401


def test_share_header_is_used_for_bearer(client, monkeypatch):
    seen = []
    monkeypatch.setattr(main, "normalize_share_for_user", lambda requested, *a: seen.append(requested) or "InFocus Drive")
    token = login(client)["token"]
    client.get("/api/files", headers={**bearer(token), "X-Drive-Share": "Photos"})
    assert seen[-1] == "Photos"


def test_sessions_list_revoke_and_logout(client):
    first, second = login(client), login(client)
    listed = client.get("/api/cli/sessions", headers=bearer(first["token"])).json()["sessions"]
    assert {row["id"] for row in listed} == {first["id"], second["id"]}
    assert [row["current"] for row in listed if row["id"] == first["id"]] == [True]
    assert client.delete("/api/cli/sessions/unknown", headers=bearer(first["token"])).status_code == 404
    assert client.delete(f"/api/cli/sessions/{second['id']}", headers=bearer(first["token"])).status_code == 200
    assert client.get("/api/files", headers=bearer(second["token"])).status_code == 401
    assert client.post("/api/cli/logout", headers=bearer(first["token"])).status_code == 200
    assert client.get("/api/files", headers=bearer(first["token"])).status_code == 401


def test_web_session_can_list_and_revoke(client):
    issued = login(client)
    listed = client.get("/api/cli/sessions").json()["sessions"]
    assert [row["device"] for row in listed] == ["Test Mac"]
    assert client.delete(f"/api/cli/sessions/{issued['id']}").status_code == 200


def test_upload_conflict_guard(client):
    token = login(client)["token"]
    current = client.get("/api/files", headers=bearer(token)).json()["items"][0]["mtime_ns"]

    def put(expect, name="notes.txt"):
        return client.post("/api/upload", headers=bearer(token),
                           data={"path": "", "expect_mtime_ns": str(expect)},
                           files={"file": (name, b"new text")})

    assert put(current - 1).status_code == 409
    assert put(-1).status_code == 409
    assert (client.share_root / "notes.txt").read_text() == "hello"
    assert put(current).status_code == 200
    assert put(-1, "fresh.txt").status_code == 200
    assert (client.share_root / "notes.txt").read_text() == "new text"


@pytest.mark.parametrize("url", [
    f"/cli/authorize?port=49152&state={STATE}&challenge={CHALLENGE}&device=Mac",
    "/assets/cli-authorize.html",
])
def test_consent_page_cannot_be_framed(client, url):
    response = client.get(url)
    assert response.status_code == 200 and "text/html" in response.headers["content-type"]
    csp = response.headers["content-security-policy"]
    assert "frame-ancestors 'none'" in csp and "form-action 'self' http://127.0.0.1:*" in csp
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["referrer-policy"] == "same-origin"
    assert "no-store" in response.headers["cache-control"]


def test_install_script_embeds_server_url(client):
    response = client.get("/cli/install.sh")
    assert response.status_code == 200
    assert f"INFOCUS_SERVER='{ORIGIN}'" in response.text
    assert "__INFOCUS_SERVER__" not in response.text


def test_write_upload_stream_expect_mtime(tmp_path):
    (tmp_path / "a.txt").write_text("one")
    mtime = (tmp_path / "a.txt").stat().st_mtime_ns
    with fsops.use_share_root(tmp_path):
        with pytest.raises(fsops.FSError) as exc:
            fsops.write_upload_stream("", "a.txt", iter([b"two"]), 1001, 100, expect_mtime_ns=mtime + 1)
        assert exc.value.status == 409
        fsops.write_upload_stream("", "a.txt", iter([b"two"]), 1001, 100, expect_mtime_ns=mtime)
    assert (tmp_path / "a.txt").read_text() == "two"
    assert not list(tmp_path.glob(".*.partial"))


def test_must_not_exist_upload_never_replaces_a_file_that_appears_after_the_check(tmp_path, monkeypatch):
    real_check = fsops._check_expected_mtime
    calls = []

    def check_then_someone_creates_it(dest, expect):
        real_check(dest, expect)
        calls.append(dest)
        if len(calls) == 2:  # the final check before the rename
            dest.write_text("theirs")  # lands between that check and the rename

    monkeypatch.setattr(fsops, "_check_expected_mtime", check_then_someone_creates_it)
    with fsops.use_share_root(tmp_path), pytest.raises(fsops.FSError) as exc:
        fsops.write_upload_stream("", "race.txt", iter([b"mine"]), 1001, 100, expect_mtime_ns=-1)
    assert exc.value.status == 409
    assert (tmp_path / "race.txt").read_text() == "theirs"
    assert not list(tmp_path.glob(".*.partial"))
