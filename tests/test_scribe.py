"""Scribe service (scribe/app): pure helpers and request handling. No models are loaded."""

import base64
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scribe"))
from app import config as scribe_config  # noqa: E402
from app import main as scribe_main  # noqa: E402
from app import portal_client, recorder, session, summarize  # noqa: E402
from app.notes_writer import folder_name, sanitize_title, write_notes  # noqa: E402
from app.pipeline import cleanup_leftovers  # noqa: E402
from app.transcribe import Segment, format_clock, merge_segments, render_markdown, transcript_json  # noqa: E402

TOKEN = "s" * 40
MEETING = "cmeet0000000000abc123"
KEY = "B" * 43


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


# --- transcript merge + formatting -------------------------------------------------

def test_merge_orders_all_speakers_by_time():
    abby = [Segment(1_000, 3_000, "u1", "Abby", "Hi all."), Segment(9_000, 10_000, "u1", "Abby", "Agreed.")]
    otto = [Segment(4_000, 6_000, "u2", "Otto", "Cycle 3 pitch is due Friday.")]
    sage = [Segment(1_000, 2_000, "u3", "Sage", "Hello.")]
    merged = merge_segments([abby, otto, sage])
    assert [s.name for s in merged] == ["Sage", "Abby", "Otto", "Abby"]


def test_markdown_lines_are_relative_to_meeting_start():
    start = 1_700_000_000_000
    segs = [Segment(start + 5_000, start + 6_000, "u1", "Abby", "Hi."),
            Segment(start + 3_725_000, start + 3_726_000, "u2", "Otto", "Done.")]
    md = render_markdown("Producer meeting", "Sunday", segs, start)
    assert md.startswith("# Producer meeting\n\nSunday\n\n")
    assert "[00:00:05] Abby: Hi." in md
    assert "[01:02:05] Otto: Done." in md


def test_clock_clamps_negative_and_formats_hours():
    assert format_clock(-500) == "00:00:00"
    assert format_clock(36_061_000) == "10:01:01"


def test_transcript_json_uses_relative_times():
    start = 10_000
    data = transcript_json({"meetingId": MEETING}, [Segment(12_000, 13_500, "u1", "Abby", "Hi.")], start)
    assert data["meetingId"] == MEETING
    assert data["segments"] == [{"startMs": 2_000, "endMs": 3_500, "uid": "u1", "name": "Abby", "text": "Hi."}]
    assert data["speakers"] == [{"uid": "u1", "name": "Abby"}]


def test_empty_transcript_says_so():
    assert "_No speech was recorded._" in render_markdown("T", "D", [], 0)


# --- chunk keying -----------------------------------------------------------------

def test_chunks_key_streams_by_uid_and_stream_start(tmp_path):
    store = recorder.ChunkStore(tmp_path)
    assert store.append("u1", "Abby", 1000, 0, b64(b"HDR1")) is not None
    assert store.append("u1", "Abby", 11000, 1, b64(b"c1")) is not None
    # Abby reconnects: new recorder, seq restarts at 0.
    assert store.append("u1", "Abby", 50000, 0, b64(b"HDR2")) is not None
    assert store.append("u2", "Otto", 2000, 0, b64(b"HDR3")) is not None
    streams = store.streams()
    assert [(s.uid, s.start_ms) for s in streams] == [("u1", 1000), ("u2", 2000), ("u1", 50000)]
    first = streams[0]
    out = recorder.concat_stream(first, tmp_path / "first.webm")
    assert out.read_bytes() == b"HDR1c1"


def test_chunks_concatenate_in_seq_order(tmp_path):
    store = recorder.ChunkStore(tmp_path)
    store.append("u1", "Abby", 1000, 0, b64(b"a"))
    store.append("u1", "Abby", 1000, 2, b64(b"c"))
    store.append("u1", "Abby", 1000, 1, b64(b"b"))
    out = recorder.concat_stream(store.streams()[0], tmp_path / "s.webm")
    assert out.read_bytes() == b"abc"


@pytest.mark.parametrize("args", [
    ("u9", "Late", 1000, 3, b64(b"x")),  # no header chunk for this speaker
    ("", "Nobody", 1000, 0, b64(b"x")),
    ("u1", "Abby", 1000, -1, b64(b"x")),
    ("u1", "Abby", 0, 0, b64(b"x")),
    ("u1", "Abby", 1000, 0, "not base64!!"),
    ("u1", "Abby", 1000, True, b64(b"x")),
])
def test_bad_chunks_are_dropped(tmp_path, args):
    assert recorder.ChunkStore(tmp_path).append(*args) is None


def test_unsafe_uid_gets_a_safe_directory(tmp_path):
    store = recorder.ChunkStore(tmp_path)
    path = store.append("../../evil", "Eve\nX", 1000, 0, b64(b"x"))
    assert path.parent.parent == tmp_path
    assert store.streams()[0].name == "Eve X"


# --- title sanitization + notes folder ---------------------------------------------

@pytest.mark.parametrize("title, expected", [
    ("Producer meeting", "Producer meeting"),
    ("Cycle 3: pitch / review?", "Cycle 3 pitch review"),
    ("../../etc", "etc"),
    ("  ..  ", "Meeting"),
    ("a\x00b\nc", "a b c"),
    ("x" * 300, "x" * 80),
])
def test_sanitize_title(title, expected):
    assert sanitize_title(title) == expected


def test_folder_name_uses_local_time_id_recording_start_and_part():
    starts = datetime(2026, 10, 5, 4, 15, tzinfo=timezone.utc)  # Sunday 9:15 PM Pacific
    rec = int(datetime(2026, 10, 5, 4, 17, tzinfo=timezone.utc).timestamp() * 1000)
    assert folder_name(starts, "Producer meeting", MEETING, "America/Los_Angeles", rec) == \
        "2026-10-04 2115 Producer meeting (abc123) rec 2117"
    later = rec + 85 * 60 * 1000
    assert folder_name(starts, "Producer meeting", MEETING, "America/Los_Angeles", later, part=2) == \
        "2026-10-04 2115 Producer meeting (abc123) rec 2242 part 2"


def test_write_notes_returns_drive_relative_path(tmp_path):
    (tmp_path / "Meetings").mkdir()
    rel = write_notes(tmp_path / "Meetings", "Meetings", "2026-10-04 2115 Producer meeting (abc123)",
                      transcript_md="# T\n", transcript={"meetingId": MEETING}, summary_md="## Summary\n")
    assert rel == "Meetings/2026-10-04 2115 Producer meeting (abc123)"
    folder = tmp_path / rel
    assert json.loads((folder / "transcript.json").read_text())["meetingId"] == MEETING
    assert sorted(p.name for p in folder.iterdir()) == ["summary.md", "transcript.json", "transcript.md"]


def test_write_notes_needs_the_mounted_folder(tmp_path):
    with pytest.raises(RuntimeError):
        write_notes(tmp_path / "Meetings", "Meetings", "x (abc123)", transcript_md="", transcript={},
                    summary_md="")


def test_cleanup_removes_only_old_leftovers(tmp_path):
    import os
    old = tmp_path / "old"
    live = tmp_path / "live"
    new = tmp_path / "new"
    for d in (old, live, new):
        d.mkdir()
    os.utime(old, (0, 0))
    os.utime(live, (0, 0))
    assert cleanup_leftovers(tmp_path, keep={"live"}) == 1
    assert not old.exists() and new.exists() and live.exists()


# --- summary prompt chunking --------------------------------------------------------

def test_chunk_transcript_respects_limit_and_lines():
    lines = [f"[00:00:{i % 60:02d}] Abby: " + "word " * 30 for i in range(200)]
    chunks = summarize.chunk_transcript("\n".join(lines), max_chars=1000)
    assert len(chunks) > 1
    assert all(len(c) <= 1000 for c in chunks)
    assert "\n".join(chunks).splitlines() == lines  # nothing lost or split mid-line


def test_chunk_transcript_cuts_a_huge_line():
    chunks = summarize.chunk_transcript("short\n" + "x" * 2500, max_chars=1000)
    assert chunks[0] == "short"
    assert [len(c) for c in chunks[1:]] == [1000, 1000, 500]


def test_chunk_budget_suits_a_small_model():
    assert summarize.CHUNK_BUDGET == 12_000 and summarize.NUM_CTX == 8192


# --- Redrule note format: prompts, parser, markdown, summarizer ---------------------

STARTED = "Oct 4, 2026, 9:15 PM PDT"
NOTE_JSON = {
    "title": "Cycle 3 pitch review", "tldr": "Pitches are due Friday.",
    "sections": [{"heading": "Pitches", "bullets": ["Two pitches need a contact", "Sage reviews"]}],
    "decisions": ["Pitch deadline stays Friday"],
    "action_items": [{"owner": "Otto", "task": "Email the contact"}, {"owner": " ", "task": "Book the studio"}],
}


def test_system_prompt_uses_real_speaker_names_and_keeps_redrule_rules():
    assert "participant's own name" in summarize.SYSTEM
    assert '"Me"' not in summarize.SYSTEM and "Numbered" not in summarize.SYSTEM
    assert "sharp chief of staff" in summarize.SYSTEM
    assert '"action_items": [{"owner": string, "task": string}]' in summarize.SYSTEM
    assert "plain text bullets only" in summarize.DIGEST_SYSTEM


def test_user_prompts():
    assert summarize.user_prompt("[00:00:01] Abby: hi", "Producer meeting", STARTED) == (
        'InFocus producer meeting "Producer meeting", started Oct 4, 2026, 9:15 PM PDT.\nParticipants: Abby.\n\n'
        "Transcript:\n[00:00:01] Abby: hi")
    assert summarize.user_from_digests(["- a", "- b"], "T", STARTED) == (
        'InFocus producer meeting "T", started Oct 4, 2026, 9:15 PM PDT.\n\n'
        "Digests of the transcript, in order:\nPart 1:\n- a\n\nPart 2:\n- b")


def test_schema_is_strict():
    schema = summarize.SCHEMA
    assert schema["required"] == ["action_items", "decisions", "sections", "title", "tldr"]
    assert schema["additionalProperties"] is False
    assert schema["properties"]["action_items"]["items"]["required"] == ["owner", "task"]


@pytest.mark.parametrize("wrap", [
    "{}",
    "```json\n{}\n```",
    "Here are the notes:\n{}\nHope this helps!",
])
def test_parse_tolerates_fences_and_prose(wrap):
    note = summarize.parse_note(wrap.replace("{}", json.dumps(NOTE_JSON)))
    assert note.title == "Cycle 3 pitch review"
    assert note.action_items == [summarize.ActionItem(task="Email the contact", owner="Otto"),
                                 summarize.ActionItem(task="Book the studio", owner=None)]


@pytest.mark.parametrize("reply", ["no json here", "{not json}", '{"tldr": "x"}', '{"title": 1, "tldr": "x"}'])
def test_parse_rejects_bad_replies(reply):
    with pytest.raises(summarize.NotJSON):
        summarize.parse_note(reply)


def test_parse_defaults_missing_lists():
    note = summarize.parse_note('{"title": "T", "tldr": "x"}')
    assert note.sections == [] and note.decisions == [] and note.action_items == []


def test_markdown_matches_redrule():
    assert summarize.parse_note(json.dumps(NOTE_JSON)).markdown == (
        "# Cycle 3 pitch review\n\n"
        "Pitches are due Friday.\n\n"
        "## Pitches\n- Two pitches need a contact\n- Sage reviews\n\n"
        "## Decisions\n- Pitch deadline stays Friday\n\n"
        "## Action items\n- [ ] **Otto** — Email the contact\n- [ ] Book the studio\n"
    )
    assert summarize.MeetingNote(title="T", tldr="x").markdown == "# T\n\nx\n"


class FakeModel:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, system, user, schema, num_predict=None):
        self.calls.append((system, user, schema))
        self.limits = getattr(self, "limits", []) + [num_predict]
        return self.replies.pop(0)


def test_summarize_short_transcript_is_one_json_call():
    model = FakeModel([json.dumps(NOTE_JSON)])
    note = summarize.summarize(model, "T", STARTED, "[00:00:01] Abby: hi")
    assert note.title == "Cycle 3 pitch review"
    system, user, schema = model.calls[0]
    assert system == summarize.SYSTEM and schema == summarize.SCHEMA and "Transcript:" in user


def test_summarize_long_transcript_digests_then_writes_json():
    text = "\n".join("[00:00:01] Abby: " + "z" * 200 for _ in range(30))
    model = FakeModel(["- d1", "- d2", "- d3", json.dumps(NOTE_JSON)])
    summarize.summarize(model, "T", STARTED, text, chunk_budget=2500)
    digests = [c for c in model.calls if c[0] == summarize.DIGEST_SYSTEM]
    assert len(digests) == 3 and all(c[2] is None for c in digests)
    assert model.limits == [300, 300, 300, None]  # digests are capped; the final note isn't
    assert "Part 3:\n- d3" in model.calls[-1][1]


def test_summarize_retries_once_then_keeps_raw_text():
    model = FakeModel(["oops", json.dumps(NOTE_JSON)])
    assert summarize.summarize(model, "T", STARTED, "x").title == "Cycle 3 pitch review"
    model = FakeModel(["oops", "  still not json  "])
    note = summarize.summarize(model, "Producer meeting", STARTED, "x")
    assert note == summarize.MeetingNote(title="Producer meeting", tldr="still not json")


def test_ollama_chat_sends_schema_as_format():
    seen = {}

    def handler(request):
        seen.update(json.loads(request.content))
        return httpx.Response(200, json={"message": {"content": "{}"}})

    chat = summarize.OllamaChat("http://127.0.0.1:11434", "qwen2.5:1.5b",
                                client=httpx.Client(transport=httpx.MockTransport(handler)))
    assert chat("sys", "user", summarize.SCHEMA) == "{}"
    assert seen["format"] == summarize.SCHEMA and seen["options"]["num_ctx"] == 8192
    assert seen["messages"][0] == {"role": "system", "content": "sys"}
    assert "num_predict" not in seen["options"]
    seen.clear()
    chat("sys", "user", None, 300)
    assert "format" not in seen and seen["options"]["num_predict"] == 300


# --- on-demand Ollama lifecycle -----------------------------------------------------

class FakeProc:
    def __init__(self):
        self.terminated = self.killed = False
        self.exited = None

    def poll(self):
        return self.exited

    def terminate(self):
        self.terminated = True
        self.exited = 0

    def wait(self, timeout=None):
        return 0

    def kill(self):
        self.killed = True


def _server(tmp_path, *, has_model=True, ready=True, chat_status=200):
    from app import ollama_runtime

    procs, requests = [], []

    def popen(cmd, **kw):
        procs.append((cmd, kw["env"]))
        proc = FakeProc()
        procs.append(proc)
        return proc

    def handler(request):
        requests.append(request.url.path)
        if request.url.path == "/api/version":
            return httpx.Response(200 if ready else 503, json={})
        if request.url.path == "/api/show":
            return httpx.Response(200 if has_model else 404, json={})
        if request.url.path == "/api/chat":
            return httpx.Response(chat_status, json={"message": {"content": json.dumps(NOTE_JSON)}})
        return httpx.Response(200, json={"status": "success"})

    server = ollama_runtime.OllamaServer(_cfg(tmp_path), popen=popen,
                                         client=httpx.Client(transport=httpx.MockTransport(handler)),
                                         sleep=lambda s: None)
    return server, procs, requests


def test_ollama_serve_runs_only_inside_the_block(tmp_path):
    server, procs, requests = _server(tmp_path)
    with server as base_url:
        assert base_url == "http://127.0.0.1:11434"
        cmd, env = procs[0]
        assert cmd == ["ollama", "serve"] and env["OLLAMA_HOST"] == "127.0.0.1:11434"
        assert env["OLLAMA_MODELS"] == str(tmp_path / "models" / "ollama")
        assert not procs[1].terminated
    assert procs[1].terminated and server.process is None
    assert "/api/pull" not in requests


def test_missing_model_is_pulled_on_first_use(tmp_path, caplog):
    server, procs, requests = _server(tmp_path, has_model=False)
    with caplog.at_level("INFO"), server:
        pass
    assert requests.count("/api/pull") == 1
    assert "pulling it now" in caplog.text


def test_server_is_killed_even_when_summarizing_fails(tmp_path):
    from app import ollama_runtime

    server, procs, _ = _server(tmp_path, chat_status=500)
    out = ollama_runtime.summarize_meeting(_cfg(tmp_path), "T", STARTED, "[00:00:01] Abby: hi",
                                           server_factory=lambda cfg: server)
    assert out == summarize.SUMMARY_UNAVAILABLE
    assert procs[1].terminated


def test_summarize_meeting_returns_redrule_markdown(tmp_path, monkeypatch):
    from app import ollama_runtime

    server, procs, _ = _server(tmp_path)
    real_chat = summarize.OllamaChat
    monkeypatch.setattr(ollama_runtime, "OllamaChat",
                        lambda base, model: real_chat(base, model, client=server._client))
    out = ollama_runtime.summarize_meeting(_cfg(tmp_path), "T", STARTED, "[00:00:01] Abby: hi",
                                           server_factory=lambda cfg: server)
    assert out.startswith("# Cycle 3 pitch review\n\nPitches are due Friday.")
    assert procs[1].terminated


def test_server_startup_failure_stops_the_process(tmp_path):
    from app import ollama_runtime

    server, procs, _ = _server(tmp_path)
    server._wait_ready = lambda: (_ for _ in ()).throw(RuntimeError("not ready"))
    assert ollama_runtime.summarize_meeting(_cfg(tmp_path), "T", STARTED, "x",
                                            server_factory=lambda cfg: server) == summarize.SUMMARY_UNAVAILABLE
    assert procs[1].terminated


# --- portal client ------------------------------------------------------------------

def _cfg(tmp_path, **overrides) -> scribe_config.ScribeConfig:
    base = dict(internal_token=TOKEN, drive_url="http://host.docker.internal:8787",
                portal_base_url="https://portal.example.com", meeting_room_url="https://rooms.example.com",
                meetings_dir=tmp_path / "Meetings", meetings_root="Meetings", tmp_dir=tmp_path / "tmp",
                whisper_model="small.en", whisper_threads=2, ollama_model="qwen2.5:1.5b",
                ollama_models_dir=tmp_path / "models" / "ollama", timezone="America/Los_Angeles")
    return scribe_config.ScribeConfig(**{**base, **overrides})


def test_post_notes_goes_to_the_drive_with_the_internal_token(tmp_path):
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        seen["auth"] = request.headers["authorization"]
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"ok": True})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    assert portal_client.post_notes(_cfg(tmp_path), MEETING, "READY", summary_markdown="## Summary",
                                    drive_path="Meetings/x", client=client)
    assert seen["url"] == f"http://host.docker.internal:8787/api/internal/scribe/notes/{MEETING}"
    assert seen["auth"] == f"Bearer {TOKEN}"
    assert seen["body"] == {"status": "READY", "summaryMarkdown": "## Summary", "drivePath": "Meetings/x"}


# --- scribe page URL + API ---------------------------------------------------------

def test_scribe_page_url_keeps_secrets_in_the_fragment():
    req = session.StartRequest(meeting_id=MEETING, title="T", starts_at=datetime.now(timezone.utc),
                               room_url="https://rooms.example.com", room_token="a.b+c/d=",
                               key=KEY, epoch=2, portal_base_url="https://portal.example.com/")
    url = session.scribe_page_url(req)
    base, fragment = url.split("#", 1)
    assert base == "https://portal.example.com/meet-scribe"
    assert "token=a.b%2Bc%2Fd%3D" in fragment and f"key={KEY}" in fragment and "epoch=2" in fragment


class FakeManager:
    def __init__(self):
        self.started = []

    def start(self, req):
        self.started.append(req)
        return "starting", 1

    async def rekey(self, meeting_id, key, epoch, room_token=None):
        self.rekeyed = (meeting_id, room_token)
        return "applied" if meeting_id == MEETING else None

    def stop(self, meeting_id):
        return False


@pytest.fixture
def scribe_client(monkeypatch, tmp_path):
    monkeypatch.setattr(scribe_main, "get_config", lambda: _cfg(tmp_path))
    manager = FakeManager()
    scribe_main.app.state.manager = manager
    return TestClient(scribe_main.app), manager


START = {"meetingId": MEETING, "title": "T", "startsAt": "2026-10-04T04:15:00Z",
         "roomUrl": "https://rooms.example.com", "roomToken": "a.b.c", "key": KEY, "epoch": 0,
         "portalBaseUrl": "https://portal.example.com"}


def test_scribe_api_requires_token_and_matching_portal(scribe_client):
    client, manager = scribe_client
    auth = {"Authorization": f"Bearer {TOKEN}"}
    assert client.post("/sessions/start", json=START).status_code == 401
    res = client.post("/sessions/start", json={**START, "portalBaseUrl": "https://evil.example.com"}, headers=auth)
    assert res.status_code == 422 and KEY not in res.text
    res = client.post("/sessions/start", json={**START, "roomUrl": "https://evil.example.com"}, headers=auth)
    assert res.status_code == 422
    assert client.post("/sessions/start", json=START, headers=auth).json() == {"ok": True, "state": "starting", "part": 1}
    assert manager.started[0].meeting_id == MEETING
    assert client.post("/sessions/rekey", json={"meetingId": "zzzzzzzzzzzz", "key": KEY, "epoch": 1},
                       headers=auth).status_code == 404
    assert client.post("/sessions/stop", json={"meetingId": MEETING}, headers=auth).json()["state"] == "not-recording"


def test_scribe_api_refuses_everything_without_its_token(monkeypatch, tmp_path):
    monkeypatch.setattr(scribe_main, "get_config", lambda: _cfg(tmp_path, internal_token=""))
    scribe_main.app.state.manager = FakeManager()
    res = TestClient(scribe_main.app).post("/sessions/stop", json={"meetingId": MEETING},
                                           headers={"Authorization": "Bearer "})
    assert res.status_code == 503


def test_config_has_no_packages_token_fallback(monkeypatch):
    monkeypatch.setenv("PACKAGES_SERVICE_TOKEN", "p" * 40)
    monkeypatch.delenv("SCRIBE_INTERNAL_TOKEN", raising=False)
    assert scribe_config.load_config().internal_token == ""
