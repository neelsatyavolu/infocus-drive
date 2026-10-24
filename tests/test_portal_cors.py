"""The Portal uploads to Drive from both of its domains (browser CORS)."""
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402


def preflight(origin: str):
    client = TestClient(main.app, base_url="https://drive.test")
    return client.options(
        "/api/service/upload/init",
        headers={"Origin": origin, "Access-Control-Request-Method": "POST"},
    )


@pytest.mark.parametrize("origin", ["https://infocusportal.com", "https://infocuspaly.com"])
def test_both_portal_domains_may_upload(origin):
    response = preflight(origin)
    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == origin


def test_other_sites_may_not():
    assert "access-control-allow-origin" not in preflight("https://evil.example").headers
