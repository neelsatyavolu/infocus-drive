import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from config import get_settings  # noqa: E402

# Deployment values the suite was written against (production reads these from .env).
# Set at import time too: main reads settings when it is first imported.
TEST_ENV = {
    "PUBLIC_BASE_URL": "https://drive.infocuspaly.com",
    "UGOS_ADMIN_PATH": "https://ugos.infocuspaly.com/",
    "ALLOWED_EMAIL_DOMAINS": "pausd.org,pausd.us",
    "GOOGLE_HOSTED_DOMAIN": "pausd.org",
}
for _key, _value in TEST_ENV.items():
    os.environ.setdefault(_key, _value)


@pytest.fixture(autouse=True)
def deployment_env(monkeypatch):
    for key, value in TEST_ENV.items():
        monkeypatch.setenv(key, value)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()
