import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import webproxy  # noqa: E402

def test_probe_passes_the_authorized_fd(tmp_path, monkeypatch):
    src = tmp_path / "clip.mp4"
    src.write_bytes(b"x")
    fd = os.open(src, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["pass_fds"] = kwargs.get("pass_fds")
        return subprocess.CompletedProcess(cmd, 0, stdout="{}")

    monkeypatch.setattr(webproxy.subprocess, "run", fake_run)
    try:
        assert webproxy._probe(Path(f"/dev/fd/{fd}")) == {}
    finally:
        os.close(fd)
    assert seen["pass_fds"] == (fd,)


ffmpeg = shutil.which("ffmpeg")
ffprobe = shutil.which("ffprobe")
need_ffmpeg = pytest.mark.skipif(ffmpeg is None or ffprobe is None, reason="ffmpeg/ffprobe not installed")


def _make_clip(dest: Path, pix_fmt: str, codec: str = "libx264", extra: list[str] | None = None) -> None:
    cmd = [
        ffmpeg,
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc=duration=1:size=320x240:rate=10",
        "-c:v",
        codec,
        "-pix_fmt",
        pix_fmt,
        *(extra or []),
        "-y",
        str(dest),
    ]
    subprocess.run(cmd, check=True)


def _pix_fmt(path: Path) -> str:
    out = subprocess.check_output(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,pix_fmt",
            "-of",
            "csv=p=0",
            str(path),
        ],
        text=True,
    ).strip()
    return out


@need_ffmpeg
def test_yuv420p_h264_is_web_safe(tmp_path):
    src = tmp_path / "ok.mp4"
    _make_clip(src, "yuv420p")
    assert webproxy.is_web_safe(src) is True
    assert webproxy.get_or_create(src) == src


@need_ffmpeg
def test_yuv422p_is_not_web_safe_and_gets_transcoded(tmp_path, monkeypatch):
    monkeypatch.setenv("IFD_THUMB_CACHE_DIR", str(tmp_path / "cache"))
    src = tmp_path / "422.mp4"
    _make_clip(src, "yuv422p")
    assert webproxy.is_web_safe(src) is False
    out = webproxy.get_or_create(src)
    assert out != src
    assert out.exists()
    probe = _pix_fmt(out)
    assert probe.startswith("h264,yuv420p")


@need_ffmpeg
def test_quicktime_prores_is_not_web_safe(tmp_path, monkeypatch):
    monkeypatch.setenv("IFD_THUMB_CACHE_DIR", str(tmp_path / "cache"))
    src = tmp_path / "clip.mov"
    extra = []
    _make_clip(src, "yuv422p10le", codec="prores", extra=extra)
    assert src.exists()
    assert webproxy.is_web_safe(src) is False
    out = webproxy.get_or_create(src)
    assert out.suffix == ".mp4"
    assert _pix_fmt(out).startswith("h264,yuv420p")


class _Opened:
    def __init__(self, path: Path):
        self.path = path
        self.stat = path.stat()
        self.closed = False

    def dev_path(self) -> str:
        return str(self.path)

    def close(self) -> None:
        self.closed = True


def _reset_prepare(monkeypatch):
    monkeypatch.setattr(webproxy, "_preparing", set())
    monkeypatch.setattr(webproxy, "_serves_original", set())


def test_cached_proxy_is_served_without_probing(tmp_path, monkeypatch):
    monkeypatch.setenv("IFD_THUMB_CACHE_DIR", str(tmp_path / "cache"))
    src = tmp_path / "rec.mov"
    src.write_bytes(b"original")
    _, out = webproxy._cache_entry(src, src.stat())
    out.parent.mkdir(parents=True)
    out.write_bytes(b"proxy")
    monkeypatch.setattr(webproxy, "is_web_safe", lambda _src: pytest.fail("probed a cached file"))
    assert webproxy.get_or_create(src) == out


def test_prepare_queues_one_job_and_reports_ready_when_cached(tmp_path, monkeypatch):
    monkeypatch.setenv("IFD_THUMB_CACHE_DIR", str(tmp_path / "cache"))
    _reset_prepare(monkeypatch)
    src = tmp_path / "rec.mov"
    src.write_bytes(b"original")
    jobs = []
    monkeypatch.setattr(webproxy._prepare_pool, "submit", jobs.append)
    opened = _Opened(src)

    def fake_get_or_create(path, *, read_path, stat_result):
        _, out = webproxy._cache_entry(path, stat_result)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b"proxy")
        return out

    monkeypatch.setattr(webproxy, "get_or_create", fake_get_or_create)
    assert webproxy.prepare(src, src.stat(), lambda: opened) is False
    assert webproxy.prepare(src, src.stat(), lambda: opened) is False
    assert len(jobs) == 1
    jobs[0]()
    assert opened.closed
    assert webproxy.prepare(src, src.stat(), lambda: opened) is True


def test_prepare_is_ready_when_the_original_is_served(tmp_path, monkeypatch):
    monkeypatch.setenv("IFD_THUMB_CACHE_DIR", str(tmp_path / "cache"))
    _reset_prepare(monkeypatch)
    src = tmp_path / "ok.mp4"
    src.write_bytes(b"original")
    jobs = []
    monkeypatch.setattr(webproxy._prepare_pool, "submit", jobs.append)
    monkeypatch.setattr(webproxy, "get_or_create", lambda path, **_: path)
    assert webproxy.prepare(src, src.stat(), lambda: _Opened(src)) is False
    jobs[0]()
    assert webproxy.prepare(src, src.stat(), lambda: _Opened(src)) is True
    assert len(jobs) == 1
