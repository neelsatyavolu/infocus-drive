"""Transcription hotwords: InFocus terms and people's names from the Portal."""

import functools

from scribe_fakes import make_cfg  # noqa: F401  (puts scribe/ on sys.path)
from app import jobs, pipeline, vocabulary  # noqa: E402
from app.transcribe import Transcriber  # noqa: E402


def test_hotwords_put_terms_first_then_names_without_repeats():
    text = vocabulary.hotwords(["Abby Example", "abby example", " Otto ", "InFocus"])
    assert text.startswith("InFocus, Paly, A-roll")
    assert text.endswith(", Abby Example, Otto")
    assert text.count("InFocus") == 1


def test_hotwords_stop_at_the_budget_on_a_whole_name():
    names = [f"Student{i} Example" for i in range(200)]
    text = vocabulary.hotwords(names)
    assert len(text) <= vocabulary.MAX_CHARS
    assert text.split(", ")[-1].startswith("Student") and text.split(", ")[-1].endswith("Example")


def test_transcriber_passes_hotwords_to_whisper(tmp_path):
    seen = {}

    class FakeModel:
        def transcribe(self, path, **kwargs):
            seen.update(kwargs)
            return [], None

    transcriber = Transcriber.__new__(Transcriber)
    transcriber._model, transcriber._hotwords = FakeModel(), "InFocus, Abby"
    transcriber.transcribe(tmp_path / "a.wav", offset_ms=0, uid="u1", name="Abby")
    assert seen["hotwords"] == "InFocus, Abby" and seen["vad_filter"] is True


def test_pipeline_builds_the_transcriber_with_the_meetings_names(tmp_path, monkeypatch):
    job = tmp_path / "job"
    job.mkdir()
    jobs.write_marker(job, jobs.JobMarker(meeting_id="m1", title="T", starts_at="2026-10-04T04:15:00+00:00",
                                          recording_started_ms=1, vocabulary=["Abby Example", "Otto"]))
    seen = {}

    def fake_streams(model, threads, audio_dir, *, max_mb, factory):
        seen["factory"] = factory
        return [], []

    monkeypatch.setattr(pipeline, "transcribe_streams", fake_streams)
    pipeline.transcribe(make_cfg(tmp_path), job)
    factory = seen["factory"]
    assert isinstance(factory, functools.partial) and factory.func is Transcriber
    assert factory.keywords["hotwords"].endswith("Abby Example, Otto")


def test_old_markers_without_names_still_load(tmp_path):
    job = tmp_path / "job"
    job.mkdir()
    (job / jobs.MARKER).write_text('{"meeting_id": "m1", "title": "T", "starts_at": "2026-10-04T04:15:00+00:00", '
                                   '"recording_started_ms": 1}', encoding="utf-8")
    assert jobs.read_marker(job).vocabulary == []
