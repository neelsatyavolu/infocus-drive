import json
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
import main  # noqa: E402
import meetings_service  # noqa: E402

TOKEN = "t" * 40
SCRIBE_TOKEN = "i" * 40
MEETING = "cmeet0000000000abc123"
KEY = "A" * 43
START = {
    "meetingId": MEETING,
    "title": "Producer meeting",
    "startsAt": "2026-10-04T04:15:00.000Z",
    "roomUrl": "https://rooms.example.com",
    "roomToken": "eyJhbGciOi.payload.sig",
    "key": KEY,
    "epoch": 0,
    "portalBaseUrl": "https://portal.example.com",
}
AUTH = {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def forwarded(monkeypatch, tmp_path):
    monkeypatch.setenv("PACKAGES_SERVICE_TOKEN", TOKEN)
    monkeypatch.setenv("SCRIBE_INTERNAL_TOKEN", SCRIBE_TOKEN)
    monkeypatch.setenv("PORTAL_BASE_URL", "https://portal.example.com")
    monkeypatch.setenv("MEETING_ROOM_URL", "https://rooms.example.com")
    monkeypatch.setenv("DRIVE_ROOT", str(tmp_path))
    calls = []

    async def fake_forward(path, payload):
        calls.append((path, payload))
        return 200, {"ok": True, "state": "starting"}

    monkeypatch.setattr(meetings_service, "forward_to_scribe", fake_forward)
    return calls


@pytest.fixture
def client():
    return TestClient(main.app)


def test_start_forwards_validated_body(client, forwarded):
    res = client.post("/api/service/meetings/scribe/start", json=START, headers=AUTH)
    assert res.status_code == 200
    assert res.json() == {"ok": True, "state": "starting"}
    path, payload = forwarded[0]
    assert path == "/sessions/start"
    assert payload["meetingId"] == MEETING and payload["key"] == KEY and payload["epoch"] == 0


def test_requires_service_token(client, forwarded):
    assert client.post("/api/service/meetings/scribe/start", json=START).status_code == 401
    bad = {"Authorization": "Bearer nope"}
    assert client.post("/api/service/meetings/scribe/stop", json={"meetingId": MEETING}, headers=bad).status_code == 401
    assert client.get(f"/api/service/meetings/{MEETING}/transcript").status_code == 401
    assert forwarded == []


@pytest.mark.parametrize("patch", [
    {"meetingId": "Bad-ID"},
    {"meetingId": "short"},
    {"meetingId": "../../etc"},
    {"key": "not a key!"},
    {"epoch": -1},
    {"title": ""},
    {"roomUrl": "javascript:alert(1)"},
    {"portalBaseUrl": "http://portal.example.com"},
    {"portalBaseUrl": "https://user:pw@portal.example.com"},
    {"roomToken": "has space"},
    {"roomUrl": "https://evil.example.net"},
    {"portalBaseUrl": "https://evil.example.net"},
])
def test_start_rejects_bad_input(client, forwarded, patch):
    res = client.post("/api/service/meetings/scribe/start", json={**START, **patch}, headers=AUTH)
    assert res.status_code == 422
    assert KEY not in res.text  # submitted values are never echoed
    assert forwarded == []


def test_rekey_and_stop_forward(client, forwarded):
    assert client.post("/api/service/meetings/scribe/rekey",
                       json={"meetingId": MEETING, "key": KEY, "epoch": 3}, headers=AUTH).status_code == 200
    assert client.post("/api/service/meetings/scribe/stop", json={"meetingId": MEETING}, headers=AUTH).status_code == 200
    assert [p for p, _ in forwarded] == ["/sessions/rekey", "/sessions/stop"]
    assert forwarded[0][1] == {"meetingId": MEETING, "key": KEY, "epoch": 3}
    assert forwarded[1][1] == {"meetingId": MEETING}


def test_rekey_forwards_a_new_room_ticket(client, forwarded):
    body = {"meetingId": MEETING, "key": KEY, "epoch": 4, "roomToken": "new.ticket.sig",
            "roomUrl": "https://rooms.example.com", "ticketExpiresAt": "2026-10-05T08:15:00.000Z"}
    assert client.post("/api/service/meetings/scribe/rekey", json=body, headers=AUTH).status_code == 200
    assert forwarded[-1] == ("/sessions/rekey", {"meetingId": MEETING, "key": KEY, "epoch": 4,
                                                 "roomToken": "new.ticket.sig"})


@pytest.mark.parametrize("patch", [{"roomToken": "has space"}, {"roomUrl": "https://evil.example.net"},
                                   {"ticketExpiresAt": "soon"}])
def test_rekey_rejects_a_bad_ticket(client, forwarded, patch):
    body = {"meetingId": MEETING, "key": KEY, "epoch": 4, **patch}
    assert client.post("/api/service/meetings/scribe/rekey", json=body, headers=AUTH).status_code == 422
    assert forwarded == []


def test_scribe_server_error_becomes_502(client, forwarded, monkeypatch):
    async def broken(path, payload):
        return 500, {"detail": "boom"}

    monkeypatch.setattr(meetings_service, "forward_to_scribe", broken)
    res = client.post("/api/service/meetings/scribe/stop", json={"meetingId": MEETING}, headers=AUTH)
    assert res.status_code == 502


def _notes(root: Path, folder: str, meeting_id: str, markdown: str, recording_started_ms: int | None = None) -> None:
    path = root / ".ifd-meetings" / folder
    path.mkdir(parents=True)
    meta = {"meetingId": meeting_id}
    if recording_started_ms is not None:
        meta["recordingStartedMs"] = recording_started_ms
    (path / "transcript.json").write_text(json.dumps(meta))
    (path / "transcript.md").write_text(markdown)


def test_transcript_found_by_id(client, forwarded, tmp_path):
    _notes(tmp_path, "2026-10-03 2115 Producer meeting (abc123)", "other00000000abc123", "# wrong\n")
    _notes(tmp_path, "2026-10-04 2115 Producer meeting (abc123)", MEETING, "# Producer meeting\n")
    res = client.get(f"/api/service/meetings/{MEETING}/transcript", headers=AUTH)
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/markdown")
    assert res.text == "# Producer meeting\n"


def test_transcript_of_a_meeting_recorded_in_parts_is_all_parts_in_order(client, forwarded, tmp_path):
    _notes(tmp_path, "2026-10-04 2115 Producer meeting (abc123) rec 2246 part 2", MEETING, "# Part 2\n", 2_000)
    _notes(tmp_path, "2026-10-04 2115 Producer meeting (abc123) rec 2116", MEETING, "# Part 1\n", 1_000)
    _notes(tmp_path, "2026-10-04 2115 Producer meeting (abc123) rec 2300", "other00000000abc123", "# Other\n", 3_000)
    res = client.get(f"/api/service/meetings/{MEETING}/transcript", headers=AUTH)
    assert res.text == "# Part 1\n\n---\n\n# Part 2\n"


def test_transcript_missing_or_bad_id(client, forwarded):
    assert client.get(f"/api/service/meetings/{MEETING}/transcript", headers=AUTH).status_code == 404
    assert client.get("/api/service/meetings/BAD_ID/transcript", headers=AUTH).status_code == 422


def test_start_refused_when_origins_not_configured(client, forwarded, monkeypatch):
    monkeypatch.setenv("MEETING_ROOM_URL", "")
    main.get_settings.cache_clear()
    res = client.post("/api/service/meetings/scribe/start", json=START, headers=AUTH)
    assert res.status_code == 422 and forwarded == []


def test_scribe_token_has_no_fallback(client, forwarded, monkeypatch):
    calls = []

    async def real_like(path, payload):
        calls.append(meetings_service._scribe_token())
        return 200, {}

    monkeypatch.setattr(meetings_service, "forward_to_scribe", real_like)
    monkeypatch.setenv("SCRIBE_INTERNAL_TOKEN", "")
    main.get_settings.cache_clear()
    res = client.post("/api/service/meetings/scribe/stop", json={"meetingId": MEETING}, headers=AUTH)
    assert res.status_code == 503 and calls == []


# --- Scribe → Drive → Portal notes relay -----------------------------------------

NOTES = f"/api/internal/scribe/notes/{MEETING}"
SCRIBE_AUTH = {"Authorization": f"Bearer {SCRIBE_TOKEN}"}


@pytest.fixture
def relayed(monkeypatch, forwarded):
    sent = []

    async def fake_portal(meeting_id, payload):
        sent.append((meeting_id, payload))
        return 200

    monkeypatch.setattr(meetings_service, "forward_to_portal", fake_portal)
    monkeypatch.setattr(meetings_service, "_client_host", lambda request: "172.18.0.2")
    return sent


def test_notes_relay_forwards_to_portal(client, relayed):
    body = {"status": "READY", "summaryMarkdown": "## Summary", "drivePath": ".ifd-meetings/2026-10-04 2115 T (abc123)"}
    res = client.post(NOTES, json=body, headers=SCRIBE_AUTH)
    assert res.status_code == 200
    assert relayed == [(MEETING, body)]


def test_notes_relay_forwards_a_failure_reason_and_part_paths(client, relayed):
    failed = {"status": "FAILED", "reason": "notes folder not writable"}
    assert client.post(NOTES, json=failed, headers=SCRIBE_AUTH).status_code == 200
    part = {"status": "READY", "drivePath": ".ifd-meetings/2026-10-04 2115 T (abc123) rec 2246 part 2"}
    assert client.post(NOTES, json=part, headers=SCRIBE_AUTH).status_code == 200
    assert relayed == [(MEETING, failed), (MEETING, part)]
    too_long = {"status": "FAILED", "reason": "x" * 201}
    assert client.post(NOTES, json=too_long, headers=SCRIBE_AUTH).status_code == 422


def test_notes_relay_auth(client, relayed, monkeypatch):
    body = {"status": "RECORDING"}
    assert client.post(NOTES, json=body).status_code == 401
    assert client.post(NOTES, json=body, headers=AUTH).status_code == 401  # packages token is not accepted
    via_proxy = {**SCRIBE_AUTH, "X-Forwarded-For": "203.0.113.9"}
    assert client.post(NOTES, json=body, headers=via_proxy).status_code == 404
    monkeypatch.setattr(meetings_service, "_client_host", lambda request: "8.8.8.8")
    assert client.post(NOTES, json=body, headers=SCRIBE_AUTH).status_code == 404
    assert relayed == []


@pytest.mark.parametrize("body", [
    {"status": "DONE"},
    {"status": "READY", "drivePath": "Package Cycles/x"},
    {"status": "READY", "drivePath": ".ifd-meetings/../secret"},
    {"status": "READY", "drivePath": ".ifd-meetings/a/b"},
    {"status": "READY", "extra": 1},
])
def test_notes_relay_validates(client, relayed, body):
    assert client.post(NOTES, json=body, headers=SCRIBE_AUTH).status_code == 422
    assert relayed == []


def test_notes_relay_portal_down_is_502(client, relayed, monkeypatch):
    async def down(meeting_id, payload):
        return 503

    monkeypatch.setattr(meetings_service, "forward_to_portal", down)
    assert client.post(NOTES, json={"status": "FAILED"}, headers=SCRIBE_AUTH).status_code == 502


def test_start_forwards_the_vocabulary(client, forwarded):
    names = ["Abby Example", "Otto"]
    assert client.post("/api/service/meetings/scribe/start", json={**START, "vocabulary": names},
                       headers=AUTH).status_code == 200
    assert forwarded[0][1]["vocabulary"] == names
    too_long = {**START, "vocabulary": ["x" * 81]}
    assert client.post("/api/service/meetings/scribe/start", json=too_long, headers=AUTH).status_code == 422
