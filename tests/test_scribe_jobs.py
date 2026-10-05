"""Job markers, processing states and retries: raw audio is only deleted once the
Portal has complete notes (or after 7 days)."""

import errno
import json
from datetime import datetime, timezone

import pytest

from scribe_fakes import MEETING, make_cfg

from app import jobs, pipeline  # noqa: E402
from app.preflight import NOT_WRITABLE  # noqa: E402
from app.summarize import SUMMARY_UNAVAILABLE  # noqa: E402
from app.transcribe import Gap, Segment  # noqa: E402

STARTS = datetime(2026, 10, 5, 4, 15, tzinfo=timezone.utc)  # Sunday 9:15 PM Pacific
REC = int(datetime(2026, 10, 5, 4, 16, tzinfo=timezone.utc).timestamp() * 1000)


def _job(cfg, *, state="queued", part=1, rec=REC, attempts=0, name=None, meeting=MEETING):
    job_dir = cfg.tmp_dir / (name or f"{meeting}-{rec}")
    job_dir.mkdir(parents=True)
    (job_dir / "chunk.webm.part").write_bytes(b"audio")
    jobs.write_marker(job_dir, jobs.JobMarker(meeting_id=meeting, title="Producer meeting",
                                              starts_at=STARTS.isoformat(), recording_started_ms=rec,
                                              part=part, state=state, attempts=attempts))
    return job_dir


@pytest.fixture
def env(tmp_path, monkeypatch):
    cfg = make_cfg(tmp_path)
    cfg.meetings_dir.mkdir()
    cfg.tmp_dir.mkdir()
    sent = []
    acked = {"value": True}

    def post(cfg_, mid, status, **kw):
        sent.append((status, kw))
        return acked["value"]

    monkeypatch.setattr(pipeline.portal_client, "post_notes", post)
    monkeypatch.setattr(pipeline, "summarize_meeting", lambda cfg_, title, started, text: "# Notes\n")
    monkeypatch.setattr(pipeline, "transcribe", lambda cfg_, d: ([Segment(REC + 1_000, REC + 2_000, "u1", "Abby", "Hi.")], []))
    return cfg, sent, acked, monkeypatch


def test_marker_round_trip_ignores_unknown_keys(tmp_path):
    job_dir = tmp_path / "j"
    job_dir.mkdir()
    jobs.write_marker(job_dir, jobs.JobMarker(MEETING, "T", STARTS.isoformat(), REC, speakers={"u1": "Abby"}))
    data = json.loads((job_dir / "job.json").read_text())
    data["future"] = 1
    (job_dir / "job.json").write_text(json.dumps(data))
    marker = jobs.read_marker(job_dir)
    assert marker.speakers == {"u1": "Abby"} and marker.state == "recording" and marker.updated_ms > 0
    assert marker.starts_at_dt == STARTS


def test_complete_notes_delete_the_audio_once_ready_is_acknowledged(env):
    cfg, sent, _, _ = env
    job_dir = _job(cfg)
    assert pipeline.process(cfg, job_dir) == "done"
    assert [s for s, _ in sent] == ["PROCESSING", "READY"]
    ready = sent[-1][1]
    assert ready["drive_path"] == "Meetings/2026-10-04 2115 Producer meeting (abc123) rec 2116"
    folder = cfg.meetings_dir / "2026-10-04 2115 Producer meeting (abc123) rec 2116"
    meta = json.loads((folder / "transcript.json").read_text())
    assert meta["recordingStartedMs"] == REC and meta["part"] == 1 and meta["complete"] is True
    assert "[00:00:01] Abby: Hi." in (folder / "transcript.md").read_text()
    assert not job_dir.exists()


def test_a_later_part_gets_its_own_folder(env):
    cfg, sent, _, _ = env
    pipeline.process(cfg, _job(cfg))
    later = REC + 90 * 60 * 1000
    env[3].setattr(pipeline, "transcribe", lambda cfg_, d: ([Segment(later + 5_000, later + 6_000, "u1", "Abby", "Back.")], []))
    pipeline.process(cfg, _job(cfg, part=2, rec=later))
    names = sorted(p.name for p in cfg.meetings_dir.iterdir())
    assert names == ["2026-10-04 2115 Producer meeting (abc123) rec 2116",
                     "2026-10-04 2115 Producer meeting (abc123) rec 2246 part 2"]
    assert "part 2" in (cfg.meetings_dir / names[1] / "transcript.md").read_text()


def test_gaps_still_deliver_notes_but_keep_the_audio(env):
    cfg, sent, _, monkeypatch = env
    gap = Gap("u2", "Otto", REC + 1_200_000, REC + 2_400_000, "transcriber ran out of memory")
    monkeypatch.setattr(pipeline, "transcribe", lambda cfg_, d: ([Segment(REC + 1_000, REC + 2_000, "u1", "Abby", "Hi.")], [gap]))
    job_dir = _job(cfg)
    assert pipeline.process(cfg, job_dir) == "partial"
    status, kw = sent[-1]
    assert status == "READY" and "could not be transcribed" in kw["summary_markdown"]
    folder = cfg.meetings_dir / kw["drive_path"].split("/", 1)[1]
    md = (folder / "transcript.md").read_text()
    assert "- Otto, 00:20:00–00:40:00: transcriber ran out of memory" in md
    assert json.loads((folder / "transcript.json").read_text())["gaps"][0]["fromMs"] == 1_200_000
    assert job_dir.exists() and jobs.read_marker(job_dir).state == "partial"


def test_a_transcription_crash_keeps_the_audio_for_a_retry(env):
    cfg, sent, _, monkeypatch = env

    def crash(cfg_, d):
        raise RuntimeError("BrokenProcessPool")

    monkeypatch.setattr(pipeline, "transcribe", crash)
    job_dir = _job(cfg)
    assert pipeline.process(cfg, job_dir) == "failed"
    assert sent[-1] == ("FAILED", {"reason": "processing failed (RuntimeError)"})
    marker = jobs.read_marker(job_dir)
    assert marker.state == "failed" and marker.attempts == 1
    assert (job_dir / "chunk.webm.part").exists()


def test_a_write_error_after_transcribing_is_reported_and_kept(env):
    cfg, sent, _, monkeypatch = env

    def denied(*a, **kw):
        raise PermissionError(errno.EACCES, "Permission denied", "/meetings/x")

    monkeypatch.setattr(pipeline, "write_notes", denied)
    job_dir = _job(cfg)
    assert pipeline.process(cfg, job_dir) == "failed"
    assert sent[-1] == ("FAILED", {"reason": NOT_WRITABLE})
    assert job_dir.exists() and jobs.read_marker(job_dir).last_error == NOT_WRITABLE


def test_an_unwritable_notes_folder_fails_before_transcribing(env):
    cfg, sent, _, monkeypatch = env
    cfg.meetings_dir.rmdir()
    called = []
    monkeypatch.setattr(pipeline, "transcribe", lambda cfg_, d: called.append(1) or ([], []))
    job_dir = _job(cfg)
    assert pipeline.process(cfg, job_dir) == "failed"
    assert called == [] and sent == [("FAILED", {"reason": NOT_WRITABLE})]
    assert jobs.read_marker(job_dir).attempts == 0  # not counted: retried until it's fixed


def test_ready_not_acknowledged_is_retried_without_transcribing_again(env):
    cfg, sent, acked, monkeypatch = env
    acked["value"] = False
    job_dir = _job(cfg)
    assert pipeline.process(cfg, job_dir) == "written"
    assert job_dir.exists()
    acked["value"] = True
    monkeypatch.setattr(pipeline, "transcribe", lambda cfg_, d: pytest.fail("transcribed twice"))
    assert pipeline.process(cfg, job_dir) == "done"
    assert sent[-1][0] == "READY" and sent[-1][1]["summary_markdown"] == "# Notes\n"
    assert not job_dir.exists()


def test_summary_failure_still_delivers_the_transcript(env):
    cfg, sent, _, monkeypatch = env
    monkeypatch.setattr(pipeline, "summarize_meeting", lambda *a: SUMMARY_UNAVAILABLE)
    assert pipeline.process(cfg, _job(cfg)) == "done"
    assert sent[-1][0] == "READY" and sent[-1][1]["summary_markdown"] == SUMMARY_UNAVAILABLE


def test_recoverable_states(tmp_path):
    cfg = make_cfg(tmp_path)
    cfg.tmp_dir.mkdir()
    keep = {state: _job(cfg, state=state, name=state) for state in ("recording", "queued", "processing", "written", "failed")}
    _job(cfg, state="partial", name="partial")
    _job(cfg, state="failed", attempts=jobs.MAX_ATTEMPTS, name="gave-up")
    (cfg.tmp_dir / "no-marker").mkdir()
    assert {p.name for p in jobs.recoverable(cfg.tmp_dir)} == set(keep)
    later = jobs.now_ms()
    assert "failed" not in {p.name for p in jobs.recoverable(cfg.tmp_dir, failed_retry_after_ms=3_600_000, now=later)}


def test_next_part_counts_pending_jobs_and_written_notes(tmp_path):
    cfg = make_cfg(tmp_path)
    cfg.tmp_dir.mkdir()
    cfg.meetings_dir.mkdir()
    assert jobs.next_part(cfg.tmp_dir, cfg.meetings_dir, MEETING) == 1
    _job(cfg, state="partial")  # notes written and its audio kept: counted once
    folder = cfg.meetings_dir / "2026-10-04 2115 Producer meeting (abc123) rec 2116"
    folder.mkdir()
    (folder / "transcript.json").write_text(json.dumps({"meetingId": MEETING, "recordingStartedMs": REC}))
    other = cfg.meetings_dir / "2026-10-04 2115 Other (abc123) rec 2116"
    other.mkdir()
    (other / "transcript.json").write_text(json.dumps({"meetingId": "other0000000abc123", "recordingStartedMs": 5}))
    assert jobs.next_part(cfg.tmp_dir, cfg.meetings_dir, MEETING) == 2
    _job(cfg, rec=REC + 1)
    assert jobs.next_part(cfg.tmp_dir, cfg.meetings_dir, MEETING) == 3


def test_cleanup_uses_the_recording_start_and_spares_live_and_queued_jobs(tmp_path):
    cfg = make_cfg(tmp_path)
    cfg.tmp_dir.mkdir()
    old = _job(cfg, rec=1_000, name="old")
    live = _job(cfg, rec=1_000, name="live")
    recent = _job(cfg, name="recent", rec=jobs.now_ms())
    assert pipeline.cleanup_leftovers(cfg.tmp_dir, keep={"live"}) == 1
    assert not old.exists() and live.exists() and recent.exists()
