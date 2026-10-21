"""People's names from the Portal and InFocus terms: spellings for the notes model (never whisper)."""

import json

from scribe_fakes import make_cfg  # noqa: F401  (puts scribe/ on sys.path)
from app import jobs, ollama_runtime, pipeline, summarize, vocabulary  # noqa: E402
from app.transcribe import Segment  # noqa: E402


def test_known_names_are_cleaned_without_repeats():
    assert vocabulary.known_names(["Abby Example", "abby example", " Otto ", "", "Sage  Example"]) == [
        "Abby Example", "Otto", "Sage Example"]


def test_known_names_stop_at_the_budget_on_a_whole_name():
    names = vocabulary.known_names([f"Student{i} Example" for i in range(400)])
    assert len(", ".join(names)) <= vocabulary.MAX_CHARS
    assert names[-1].startswith("Student") and names[-1].endswith("Example")


def test_the_notes_prompt_lists_the_class_and_the_terms():
    user = summarize.user_prompt("[00:00:01] Abby: hi", "T", "Monday, Oct 19, 2026, 9:30 PM PDT",
                                 ["Abby Example", "Otto"])
    assert "Participants: Abby.\nClass members: Abby Example, Otto.\n\nTranscript:" in user
    assert "Class members" not in summarize.user_prompt("[00:00:01] Abby: hi", "T", "D")
    assert "Fun Focus" in summarize.SYSTEM and "A-roll" in summarize.SYSTEM


def test_the_class_reaches_the_cloud_and_local_notes(tmp_path, monkeypatch):
    note = json.dumps({"title": "T", "tldr": "x", "sections": [], "decisions": [], "action_items": []})
    users = []

    def chat(system, user, schema, num_predict=None):
        users.append(user)
        return note

    monkeypatch.setattr(ollama_runtime, "WorkersAIChat", lambda cfg: chat)
    cfg = make_cfg(tmp_path, workers_ai_account_id="a" * 32, workers_ai_token="t" * 40)
    ollama_runtime.summarize_meeting(cfg, "T", "D", "[00:00:01] Abby: hi", names=["Otto Example"])
    assert users and all("Class members: Otto Example." in u for u in users)


def test_pipeline_sends_the_meetings_names_to_the_notes(tmp_path, monkeypatch):
    cfg = make_cfg(tmp_path)
    cfg.meetings_dir.mkdir()
    cfg.tmp_dir.mkdir()
    job = tmp_path / "job"
    job.mkdir()
    jobs.write_marker(job, jobs.JobMarker(meeting_id="m1", title="T", starts_at="2026-10-04T04:15:00+00:00",
                                          recording_started_ms=1, state="queued",
                                          vocabulary=["Abby Example", "Otto"]))
    seen = {}
    monkeypatch.setattr(pipeline.portal_client, "post_notes", lambda *a, **kw: True)
    monkeypatch.setattr(pipeline, "transcribe", lambda cfg_, d: ([Segment(1_000, 2_000, "u1", "Abby", "Hi.")], []))

    def fake_summary(cfg_, title, started, text, **kw):
        seen.update(kw)
        return "# Notes\n"

    monkeypatch.setattr(pipeline, "summarize_meeting", fake_summary)
    pipeline.process(cfg, job)
    assert seen["names"] == ["Abby Example", "Otto"]


def test_old_markers_without_names_still_load(tmp_path):
    job = tmp_path / "job"
    job.mkdir()
    (job / jobs.MARKER).write_text('{"meeting_id": "m1", "title": "T", "starts_at": "2026-10-04T04:15:00+00:00", '
                                   '"recording_started_ms": 1}', encoding="utf-8")
    assert jobs.read_marker(job).vocabulary == []
