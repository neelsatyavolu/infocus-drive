"""Long-meeting transcription: 20-minute pieces in a watched child process (no models loaded)."""

import multiprocessing
import shutil
import subprocess

import pytest

import scribe_fakes
from scribe_fakes import fake_transcriber

from app import recorder, whisper_child  # noqa: E402
from app.whisper_child import AudioPiece, parse_segment_list, piece_timeout, transcribe_streams  # noqa: E402

HAS_FFMPEG = shutil.which("ffmpeg") is not None


def test_piece_timeout_is_three_times_real_time_plus_ten_minutes():
    assert piece_timeout(1200) == 3 * 1200 + 600
    assert piece_timeout(1200, first=True) == 3 * 1200 + 600 + whisper_child.MODEL_LOAD_ALLOWANCE_SECONDS


def test_parse_segment_list(tmp_path):
    text = "piece0000.wav,0.000000,1200.000000\npiece0001.wav,1200.000000,2400.020000\n\nbad,row\n"
    pieces = parse_segment_list(text, tmp_path)
    assert pieces == [AudioPiece(tmp_path / "piece0000.wav", 0.0, 1200.0),
                      AudioPiece(tmp_path / "piece0001.wav", 1200.0, 2400.02)]
    assert pieces[1].seconds == pytest.approx(1200.02)


@pytest.mark.skipif(not HAS_FFMPEG, reason="ffmpeg not installed")
def test_split_stream_cuts_pieces_with_their_start_times(tmp_path):
    source = tmp_path / "speaker.webm"
    made = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                           "sine=frequency=440:duration=5", "-c:a", "libopus", str(source)], capture_output=True)
    if made.returncode != 0:  # no libopus in this ffmpeg build
        source = tmp_path / "speaker.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "sine=frequency=440:duration=5", str(source)], check=True, capture_output=True)
    pieces = whisper_child.split_stream(source, tmp_path / "pieces", segment_seconds=2)
    assert len(pieces) == 3
    assert [round(p.start_s) for p in pieces] == [0, 2, 4]
    assert all(p.path.exists() and p.path.suffix == ".wav" for p in pieces)
    assert pieces[-1].end_s == pytest.approx(5, abs=0.1)


def _streams(tmp_path, speakers):
    """Speaker streams on disk: {uid: start_ms}."""
    store = recorder.ChunkStore(tmp_path / "job")
    for uid, start in speakers.items():
        store.append(uid, uid.title(), start, 0, "aGVhZGVy")  # "header"
    return store.root


def _fake_split(plan, seconds=1200):
    """split() stand-in: writes one tiny file per planned piece (its text drives the fake transcriber)."""
    def split(webm, out_dir, segment_seconds):
        uid = webm.parent.name.rsplit("-", 1)[0]
        out_dir.mkdir(parents=True, exist_ok=True)
        pieces = []
        for i, kind in enumerate(plan[uid]):
            if kind == "undecodable":
                raise subprocess.CalledProcessError(1, "ffmpeg")
            path = out_dir / f"piece{i:04d}.wav"
            path.write_text(kind)
            pieces.append(AudioPiece(path, i * seconds, (i + 1) * seconds))
        return pieces
    return split


def _run(audio_dir, plan, **kw):
    return transcribe_streams("small.en", 1, audio_dir, max_mb=2000, factory=fake_transcriber,
                              split=_fake_split(plan), **kw)


def test_pieces_keep_absolute_times_and_failures_become_gaps(tmp_path):
    audio = _streams(tmp_path, {"abby": 1_000_000, "otto": 1_005_000})
    segments, gaps = _run(audio, {"abby": ["ok", "boom", "ok"], "otto": ["crash", "ok"]})
    assert [(s.name, s.start_ms, s.text) for s in segments] == [
        ("Abby", 1_000_000, "ok piece"),
        ("Otto", 1_005_000 + 1_200_000, "ok piece"),        # after a crashed child: a fresh one
        ("Abby", 1_000_000 + 2_400_000, "ok piece"),
    ]
    assert [(g.name, g.from_ms, g.to_ms, g.reason) for g in gaps] == [
        ("Otto", 1_005_000, 1_005_000 + 1_200_000, "transcriber crashed"),
        ("Abby", 1_000_000 + 1_200_000, 1_000_000 + 2_400_000, "transcription error (ValueError)"),
    ]
    assert not list(audio.rglob("*.wav")) and not list(audio.rglob("stream.webm"))  # derived files removed
    assert list(audio.rglob("*.webm.part"))  # raw chunks stay until the notes are delivered
    assert multiprocessing.active_children() == []  # the child exited


def test_a_hung_piece_times_out_and_the_next_one_still_runs(tmp_path):
    audio = _streams(tmp_path, {"abby": 1_000})
    segments, gaps = _run(audio, {"abby": ["hang", "ok"]}, timeout_for=lambda seconds, first=False: 3)
    assert [g.reason for g in gaps] == ["transcription timed out"]
    assert [s.text for s in segments] == ["ok piece"]
    assert multiprocessing.active_children() == []


def test_a_piece_over_the_memory_cap_is_killed(tmp_path):
    audio = _streams(tmp_path, {"abby": 1_000})
    first_pid = []

    def rss(pid):  # the first child "uses" too much memory; the next one is fine
        first_pid.append(pid) if not first_pid else None
        return 99_999 if pid == first_pid[0] else 100

    segments, gaps = _run(audio, {"abby": ["slow", "ok"]}, rss_mb=rss)
    assert [g.reason for g in gaps] == ["transcriber ran out of memory"]
    assert [s.text for s in segments] == ["ok piece"]


def test_an_undecodable_stream_is_a_gap_for_that_speaker_only(tmp_path):
    audio = _streams(tmp_path, {"abby": 1_000, "otto": 2_000})
    segments, gaps = _run(audio, {"abby": ["undecodable"], "otto": ["ok"]})
    assert [(g.name, g.to_ms, g.reason) for g in gaps] == [("Abby", None, "audio could not be decoded")]
    assert [s.name for s in segments] == ["Otto"]


def test_no_streams_means_no_child(tmp_path):
    (tmp_path / "empty").mkdir()
    assert transcribe_streams("small.en", 1, tmp_path / "empty", max_mb=2000, factory=fake_transcriber) == ([], [])
    assert multiprocessing.active_children() == []


def test_rss_reader_handles_missing_proc():
    assert whisper_child.read_rss_mb(10 ** 9) is None


def test_fakes_module_is_importable():  # the spawned child imports it by name
    assert scribe_fakes.fake_transcriber.__module__ == "scribe_fakes"
