"""An old public hostname keeps working for apps and moves browsers to PUBLIC_BASE_URL."""
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main.settings, "public_base_url", "https://drive.new.test")
    monkeypatch.setattr(main.settings, "legacy_public_hosts", "drive.old.test")
    return TestClient(main.app, base_url="https://drive.old.test", follow_redirects=False)


def test_browser_pages_move(client):
    response = client.get("/folder/a?view=grid")
    assert response.status_code == 308
    assert response.headers["location"] == "https://drive.new.test/folder/a?view=grid"
    assert client.get("/auth/login").headers["location"].startswith("https://drive.new.test/auth/login")


def test_apps_api_and_callbacks_stay(client):
    for path in ("/api/me", "/auth/callback", "/auth/lan-handoff"):
        assert client.get(path).status_code != 308, path
    assert client.get("/", headers={"Authorization": "Bearer abc"}).status_code != 308
    assert client.post("/auth/logout").status_code != 308


def test_the_public_host_is_untouched(monkeypatch):
    monkeypatch.setattr(main.settings, "public_base_url", "https://drive.new.test")
    monkeypatch.setattr(main.settings, "legacy_public_hosts", "drive.old.test")
    response = TestClient(main.app, base_url="https://drive.new.test", follow_redirects=False).get("/")
    assert response.status_code != 308
