"""Notes accuracy: what went wrong in real meeting notes, and the guards against it.

- Relative days ("tomorrow", "Thursday") were swapped between two events: the prompt now names
  the meeting's weekday and asks for real days.
- A person taken off a role later in the meeting stayed in the notes: later corrections win.
- Suggestions and jokes were written up as decisions.
- On Workers AI a second call checks the draft against the transcript and corrects it.
"""

import json
from datetime import datetime, timezone

from scribe_fakes import MEETING, make_cfg  # noqa: F401  (puts scribe/ on sys.path)

from app import jobs, ollama_runtime, pipeline, summarize  # noqa: E402
from app.transcribe import Segment  # noqa: E402

STARTED = "Monday, Oct 19, 2026, 9:30 PM PDT"
DRAFT = {"title": "Show planning", "tldr": "Show on Thursday.", "sections": [], "decisions": [],
         "action_items": [{"owner": "Otto", "task": "Run the show"}]}
FIXED = {**DRAFT, "tldr": "Show tomorrow (Tuesday, Oct 20); Fun Focus on Thursday, Oct 22."}
TRANSCRIPT = "[00:00:01] Abby: We're not doing Fun Focus tomorrow, it's Thursday. Tomorrow we film a show."


class Model:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, system, user, schema, num_predict=None):
        self.calls.append((system, user, schema, num_predict))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def test_prompt_resolves_relative_days_from_the_meeting_date():
    assert "tomorrow" in summarize.SYSTEM and "weekday" in summarize.SYSTEM
    assert "never move an event to another day" in summarize.SYSTEM


def test_prompt_keeps_only_the_final_version_of_a_change():
    assert "report only the final version" in summarize.SYSTEM


def test_prompt_keeps_suggestions_out_of_decisions():
    assert "A suggestion, a question or a joke is not a decision" in summarize.SYSTEM


def test_pipeline_gives_the_model_the_meetings_weekday(tmp_path, monkeypatch):
    cfg = make_cfg(tmp_path)
    cfg.meetings_dir.mkdir()
    cfg.tmp_dir.mkdir()
    rec = int(datetime(2026, 10, 20, 4, 27, tzinfo=timezone.utc).timestamp() * 1000)
    job_dir = cfg.tmp_dir / "job"
    job_dir.mkdir()
    jobs.write_marker(job_dir, jobs.JobMarker(meeting_id=MEETING, title="Producer meeting",
                                              starts_at="2026-10-20T04:30:00+00:00", recording_started_ms=rec,
                                              state="queued"))
    seen = {}
    monkeypatch.setattr(pipeline.portal_client, "post_notes", lambda *a, **kw: True)
    monkeypatch.setattr(pipeline, "transcribe", lambda cfg_, d: ([Segment(rec + 1_000, rec + 2_000, "u1", "Abby", "Hi.")], []))
    monkeypatch.setattr(pipeline, "summarize_meeting",
                        lambda cfg_, title, started, text, **kw: seen.setdefault("started", started) and "# Notes\n")
    pipeline.process(cfg, job_dir)
    assert seen["started"] == STARTED


def test_review_corrects_the_draft_against_the_transcript():
    model = Model([json.dumps(DRAFT), json.dumps(FIXED)])
    note = summarize.summarize(model, "T", STARTED, TRANSCRIPT, review=True)
    assert note.tldr == FIXED["tldr"]
    assert [c[0] for c in model.calls] == [summarize.SYSTEM, summarize.REVIEW_SYSTEM]
    system, user, schema, _ = model.calls[1]
    assert TRANSCRIPT in user and schema == summarize.SCHEMA
    draft_in_prompt = json.loads(user.split("Draft notes:\n", 1)[1])
    assert draft_in_prompt == DRAFT


def test_review_keeps_the_draft_when_its_reply_is_not_json():
    model = Model([json.dumps(DRAFT), "sorry", "still not json"])
    note = summarize.summarize(model, "T", STARTED, TRANSCRIPT, review=True)
    assert note.tldr == DRAFT["tldr"]


def test_review_keeps_the_draft_when_the_call_fails():
    model = Model([json.dumps(DRAFT), RuntimeError("Workers AI returned no text")])
    note = summarize.summarize(model, "T", STARTED, TRANSCRIPT, review=True)
    assert note.tldr == DRAFT["tldr"]


def test_no_review_for_raw_text_fallbacks_or_by_default():
    model = Model(["not json", "still not json"])
    assert summarize.summarize(model, "T", STARTED, TRANSCRIPT, review=True).tldr == "still not json"
    assert len(model.calls) == 2
    model = Model([json.dumps(DRAFT)])
    summarize.summarize(model, "T", STARTED, TRANSCRIPT)
    assert len(model.calls) == 1


def test_no_review_over_digests():
    """Digests have lost the transcript lines a review would check against (local model only)."""
    text = "\n".join("[00:00:01] Sage: " + "z" * 200 for _ in range(30))
    model = Model(["- d1", "- d2", "- d3", json.dumps(DRAFT)])
    summarize.summarize(model, "T", STARTED, text, chunk_budget=2500, review=True)
    assert model.calls[-1][0] == summarize.SYSTEM


def test_workers_ai_summaries_are_reviewed(tmp_path, monkeypatch):
    model = Model([json.dumps(DRAFT), json.dumps(FIXED)])
    monkeypatch.setattr(ollama_runtime, "WorkersAIChat", lambda cfg: model)
    cfg = make_cfg(tmp_path, workers_ai_account_id="a" * 32, workers_ai_token="t" * 40)

    class NoServer:
        def __init__(self, cfg):
            raise AssertionError("the local model should not start")

    out = ollama_runtime.summarize_meeting(cfg, "T", STARTED, TRANSCRIPT, server_factory=NoServer)
    assert FIXED["tldr"] in out and len(model.calls) == 2


# --- transcription ---------------------------------------------------------------------
#
# A test on a real recording: with any whisper `hotwords` (the class list, or only the six
# people in the call) whole minutes of one speaker's audio came back empty, and names nobody
# said were written during silence. Without hotwords the same audio gave about 40% more words.

class Word:
    def __init__(self, start, end, word):
        self.start, self.end, self.word = start, end, word


class WhisperSegment:
    def __init__(self, start, end, text, words=None):
        self.start, self.end, self.text, self.words = start, end, text, words


def _transcriber(monkeypatch, segments, calls):
    import sys

    class FakeModel:
        def __init__(self, *args, **kwargs):
            pass

        def transcribe(self, wav, **kwargs):
            calls.append(kwargs)
            return iter(segments), None

    monkeypatch.setitem(sys.modules, "faster_whisper", type(sys)("faster_whisper"))
    sys.modules["faster_whisper"].WhisperModel = FakeModel
    from app.transcribe import Transcriber
    return Transcriber("small.en", 1)


def test_transcriber_gives_whisper_no_hotwords_and_asks_for_word_times(monkeypatch, tmp_path):
    calls = []
    _transcriber(monkeypatch, [], calls).transcribe(tmp_path / "a.wav", offset_ms=0, uid="u1", name="Abby")
    assert "hotwords" not in calls[0] and "initial_prompt" not in calls[0]
    assert calls[0]["word_timestamps"] is True


def test_a_segment_is_cut_at_long_pauses_and_sentence_ends(monkeypatch, tmp_path):
    words = [Word(72.5, 72.9, " Yeah,"), Word(73.0, 73.4, " let's"), Word(73.5, 73.7, " go."),
             Word(115.0, 115.4, " They"), Word(115.5, 115.9, " can"), Word(116.0, 116.6, " interview"),
             Word(116.7, 117.0, " Sage"), Word(117.1, 117.6, " too")]
    seg = WhisperSegment(72.5, 117.6, " Yeah, let's go. They can interview Sage too", words)
    out = _transcriber(monkeypatch, [seg], []).transcribe(tmp_path / "a.wav", offset_ms=10_000, uid="u1",
                                                          name="Abby")
    assert [(s.start_ms, s.end_ms, s.text) for s in out] == [
        (82_500, 83_700, "Yeah, let's go."),
        (125_000, 127_600, "They can interview Sage too"),
    ]


def test_a_segment_without_word_times_stays_whole(monkeypatch, tmp_path):
    seg = WhisperSegment(1.0, 2.0, " Hi there. ")
    out = _transcriber(monkeypatch, [seg], []).transcribe(tmp_path / "a.wav", offset_ms=0, uid="u1", name="Abby")
    assert [(s.start_ms, s.end_ms, s.text) for s in out] == [(1_000, 2_000, "Hi there.")]


def test_a_question_comes_before_its_answer():
    from app.transcribe import join_turns, merge_segments
    otto = [Segment(56_000, 58_000, "u1", "Otto", "Don't bring one for everybody."),
          Segment(58_200, 60_000, "u1", "Otto", "Just bring food."),
          Segment(84_000, 86_000, "u1", "Otto", "35 people, including the adviser.")]
    abby = [Segment(82_000, 83_500, "u2", "Abby", "How many people are in the class?")]
    lines = join_turns(merge_segments([otto, abby]))
    assert [(s.name, s.text) for s in lines] == [
        ("Otto", "Don't bring one for everybody. Just bring food."),
        ("Abby", "How many people are in the class?"),
        ("Otto", "35 people, including the adviser."),
    ]
    assert (lines[0].start_ms, lines[0].end_ms) == (56_000, 60_000)


def test_a_long_pause_starts_a_new_line():
    from app.transcribe import join_turns
    said = [Segment(0, 2_000, "u1", "Otto", "Okay."), Segment(30_000, 31_000, "u1", "Otto", "Anything else?")]
    assert len(join_turns(said)) == 2


def test_prompt_spells_names_from_the_lists_and_keeps_approvals():
    assert "exactly as those lists spell it" in summarize.SYSTEM
    assert '"Can someone…" that nobody took on has no owner' in summarize.SYSTEM
    assert "Keep every approval or denial" in summarize.SYSTEM
