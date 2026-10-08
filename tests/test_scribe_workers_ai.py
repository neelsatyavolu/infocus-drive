"""Scribe summaries through Cloudflare Workers AI, with the local model as a fallback."""

import json

import httpx
import pytest

from scribe_fakes import make_cfg  # noqa: F401  (puts scribe/ on sys.path)
from app import config as scribe_config  # noqa: E402
from app import ollama_runtime, summarize, workers_ai  # noqa: E402

STARTED = "Oct 4, 2026, 9:15 PM PDT"
NOTE_JSON = {
    "title": "Cycle 3 pitch review", "tldr": "Pitches are due Friday.",
    "sections": [{"heading": "Pitches", "bullets": ["Two pitches need a contact"]}],
    "decisions": ["Pitch deadline stays Friday"],
    "action_items": [{"owner": "Otto", "task": "Email the contact"}],
}
ACCOUNT = "a" * 32
CF_TOKEN = "t" * 40


def cloud_cfg(tmp_path, **overrides):
    return make_cfg(tmp_path, workers_ai_account_id=ACCOUNT, workers_ai_token=CF_TOKEN, **overrides)


class FakeModel:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, system, user, schema, num_predict=None):
        self.calls.append((system, user, schema, num_predict))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


class NoServer:
    """Fails the test if the local model would be started."""

    def __init__(self, cfg):
        raise AssertionError("the local model should not start")


# --- bullets ------------------------------------------------------------------------

def test_parse_note_strips_bullet_markers_the_model_adds():
    reply = json.dumps({**NOTE_JSON,
                        "sections": [{"heading": "H", "bullets": ["- a", "* b", "• c", "- - d", "1. e", "plain"]}],
                        "decisions": ["- agreed"], "action_items": [{"owner": "Otto", "task": "- email"}]})
    note = summarize.parse_note(reply)
    assert note.sections[0].bullets == ["a", "b", "c", "d", "e", "plain"]
    assert note.decisions == ["agreed"] and note.action_items[0].task == "email"
    assert "- - " not in note.markdown


def test_system_prompt_asks_for_the_whole_meeting():
    assert "whole meeting" in summarize.SYSTEM


# --- Workers AI client -------------------------------------------------------------

def test_workers_ai_chat_posts_chat_completions(tmp_path):
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        seen["auth"] = request.headers["authorization"]
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"choices": [{"message": {"content": "{\"title\": \"T\"}"}}]})

    chat = workers_ai.WorkersAIChat(cloud_cfg(tmp_path), client=httpx.Client(transport=httpx.MockTransport(handler)))
    assert chat("sys", "user", summarize.SCHEMA) == "{\"title\": \"T\"}"
    assert seen["url"] == f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/ai/v1/chat/completions"
    assert seen["auth"] == f"Bearer {CF_TOKEN}"
    body = seen["body"]
    assert body["model"] == "@cf/openai/gpt-oss-120b"
    assert body["messages"] == [{"role": "system", "content": "sys"}, {"role": "user", "content": "user"}]
    assert body["max_tokens"] == workers_ai.MAX_OUTPUT_TOKENS and body["stream"] is False


def test_workers_ai_chat_raises_on_errors_and_empty_replies(tmp_path):
    for response in (httpx.Response(429, json={"errors": [{"message": "limit"}]}),
                     httpx.Response(200, json={"choices": [{"message": {"content": ""}}]})):
        chat = workers_ai.WorkersAIChat(cloud_cfg(tmp_path),
                                        client=httpx.Client(transport=httpx.MockTransport(lambda r, res=response: res)))
        with pytest.raises(Exception):
            chat("sys", "user", None)


def test_workers_ai_is_configured_only_with_both_values(tmp_path):
    assert workers_ai.configured(cloud_cfg(tmp_path))
    assert not workers_ai.configured(make_cfg(tmp_path))
    assert not workers_ai.configured(make_cfg(tmp_path, workers_ai_account_id=ACCOUNT))


def test_config_reads_workers_ai_from_the_environment(monkeypatch):
    monkeypatch.setenv("SCRIBE_WORKERS_AI_ACCOUNT_ID", ACCOUNT)
    monkeypatch.setenv("SCRIBE_WORKERS_AI_TOKEN", CF_TOKEN)
    cfg = scribe_config.load_config()
    assert (cfg.workers_ai_account_id, cfg.workers_ai_token, cfg.workers_ai_model) == (
        ACCOUNT, CF_TOKEN, "@cf/openai/gpt-oss-120b")
    monkeypatch.setenv("SCRIBE_WORKERS_AI_MODEL", "@cf/qwen/other")
    assert scribe_config.load_config().workers_ai_model == "@cf/qwen/other"


# --- choosing the model --------------------------------------------------------------

def test_cloud_summary_reads_the_whole_long_transcript_in_one_call(tmp_path, monkeypatch):
    model = FakeModel([json.dumps(NOTE_JSON)])
    monkeypatch.setattr(ollama_runtime, "WorkersAIChat", lambda cfg: model)
    transcript = "\n".join(f"[00:{i // 60:02d}:{i % 60:02d}] Abby: " + "z" * 80 for i in range(600))
    assert len(transcript) > summarize.CHUNK_BUDGET  # the local model would digest this in pieces
    out = ollama_runtime.summarize_meeting(cloud_cfg(tmp_path), "T", STARTED, transcript, server_factory=NoServer)
    assert out.startswith("# Cycle 3 pitch review")
    assert len(model.calls) == 1
    system, user, _, _ = model.calls[0]
    assert system == summarize.SYSTEM and transcript in user


def test_cloud_failure_falls_back_to_the_local_model(tmp_path, monkeypatch):
    cloud = FakeModel([httpx.ConnectError("offline")])
    local = FakeModel([json.dumps({**NOTE_JSON, "title": "Local notes"})])
    started = []

    class Server:
        def __init__(self, cfg):
            started.append(cfg)

        def __enter__(self):
            return "http://127.0.0.1:11434"

        def __exit__(self, *exc):
            return None

    monkeypatch.setattr(ollama_runtime, "WorkersAIChat", lambda cfg: cloud)
    monkeypatch.setattr(ollama_runtime, "OllamaChat", lambda base, model: local)
    out = ollama_runtime.summarize_meeting(cloud_cfg(tmp_path), "T", STARTED, "[00:00:01] Abby: hi",
                                           server_factory=Server)
    assert out.startswith("# Local notes") and len(started) == 1


def test_without_workers_ai_the_local_model_is_used(tmp_path, monkeypatch):
    local = FakeModel([json.dumps(NOTE_JSON)])

    class Server:
        def __init__(self, cfg):
            pass

        def __enter__(self):
            return "http://127.0.0.1:11434"

        def __exit__(self, *exc):
            return None

    monkeypatch.setattr(ollama_runtime, "WorkersAIChat", lambda cfg: pytest.fail("cloud should not be called"))
    monkeypatch.setattr(ollama_runtime, "OllamaChat", lambda base, model: local)
    out = ollama_runtime.summarize_meeting(make_cfg(tmp_path), "T", STARTED, "x", server_factory=Server)
    assert out.startswith("# Cycle 3 pitch review")


# --- participant names ---------------------------------------------------------------

def test_participants_come_from_the_speaker_labels_in_order():
    transcript = "[00:00:01] Abby: hi\n[00:00:02] Otto Example: hey\n[00:00:03] Abby: so\nno label here"
    assert summarize.speaker_names(transcript) == ["Abby", "Otto Example"]
    assert "Participants: Abby, Otto Example." in summarize.user_prompt(transcript, "T", STARTED)
    assert "Participants" not in summarize.user_prompt("no labels", "T", STARTED)


def test_digest_prompt_keeps_the_participants(tmp_path):
    text = "\n".join("[00:00:01] Sage: " + "z" * 200 for _ in range(30))
    model = FakeModel(["- d1", "- d2", "- d3", json.dumps(NOTE_JSON)])
    summarize.summarize(model, "T", STARTED, text, chunk_budget=2500)
    assert "Participants: Sage." in model.calls[-1][1]
