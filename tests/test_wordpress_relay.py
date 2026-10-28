import sys
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
import wordpress_relay  # noqa: E402

TOKEN = "t" * 40


class Calls(list):
    reply: dict


AUTH = {"Authorization": f"Bearer {TOKEN}", "X-Wordpress-Authorization": "Basic c2l0ZTpwdw=="}


@pytest.fixture
def site(monkeypatch):
    monkeypatch.setenv("PACKAGES_SERVICE_TOKEN", TOKEN)
    monkeypatch.setenv("WORDPRESS_URL", "https://news.example.org/")
    calls = Calls()
    reply = {"status": 201, "json": {"id": 7}}

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(reply["status"], json=reply["json"])

    real_client = httpx.AsyncClient
    monkeypatch.setattr(wordpress_relay.httpx, "AsyncClient",
                        lambda **kw: real_client(transport=httpx.MockTransport(handler), **kw))
    calls.reply = reply
    return calls


@pytest.fixture
def client():
    return TestClient(main.app)


def test_forwards_method_path_query_body_and_site_auth(client, site):
    res = client.post("/api/service/wordpress/wp-json/wp/v2/media?title=A%20B&alt_text=A", content=b"\xff\xd8jpeg",
                      headers={**AUTH, "Content-Type": "image/jpeg", "Content-Disposition": 'attachment; filename="t.jpg"'})
    assert res.status_code == 201 and res.json() == {"id": 7}
    sent = site[0]
    assert sent.method == "POST"
    assert str(sent.url) == "https://news.example.org/wp-json/wp/v2/media?title=A%20B&alt_text=A"
    assert sent.content == b"\xff\xd8jpeg"
    assert sent.headers["authorization"] == "Basic c2l0ZTpwdw=="
    assert sent.headers["content-disposition"] == 'attachment; filename="t.jpg"'
    assert "x-wordpress-authorization" not in sent.headers


def test_passes_site_errors_through(client, site):
    site.reply.update(status=401, json={"code": "incorrect_password"})
    res = client.get("/api/service/wordpress/wp-json/wp/v2/users/me", headers=AUTH)
    assert res.status_code == 401 and res.json() == {"code": "incorrect_password"}


def test_requires_service_token(client, site):
    res = client.get("/api/service/wordpress/wp-json/wp/v2/users/me",
                     headers={"X-Wordpress-Authorization": AUTH["X-Wordpress-Authorization"]})
    assert res.status_code == 401 and not site


def test_requires_site_auth(client, site):
    res = client.get("/api/service/wordpress/wp-json/wp/v2/users/me", headers={"Authorization": AUTH["Authorization"]})
    assert res.status_code == 400 and not site


def test_refuses_dot_segments(client, site):
    res = client.get("/api/service/wordpress/wp-json/wp/v2/%2E%2E/%2E%2E/wp-login.php", headers=AUTH)
    assert res.status_code in (400, 404) and not site


def test_off_without_wordpress_url(client, site, monkeypatch):
    monkeypatch.setenv("WORDPRESS_URL", "")
    res = client.get("/api/service/wordpress/wp-json/wp/v2/users/me", headers=AUTH)
    assert res.status_code == 503 and not site
