import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import webproxy  # noqa: E402

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
