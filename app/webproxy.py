"""Cached browser-safe H.264/AAC proxies for camera originals.

Hub plays Package Cycles / Package Storage videos in <video>. Sony XAVC
(4:2:2 10-bit) and ProRes 4444 QuickTime files parse (duration works) but
decode to a black frame. Transcode once, cache by (path, mtime, size).
"""

from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

from thumbs import cache_dir, cache_key, _lock_for, _key_locks, _key_locks_guard

log = logging.getLogger("uvicorn.error")

WEB_VIDEO = {"h264", "vp8", "vp9", "av1"}
WEB_PIX = {"yuv420p", "yuvj420p"}
WEB_AUDIO = {"aac", "mp3", "opus", "vorbis"}
MAX_WIDTH = 1280
FFMPEG_TIMEOUT_S = 300


def _probe(src: Path) -> dict:
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_streams",
            "-of",
            "json",
            str(src),
        ],
        capture_output=True,
        text=True,
        timeout=20,
    )
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return {}


def is_web_safe(src: Path) -> bool:
    """True when a browser <video> can decode the file as-is."""
    streams = _probe(src).get("streams") or []
    videos = [s for s in streams if s.get("codec_type") == "video" and s.get("codec_name") != "mjpeg"]
    audios = [s for s in streams if s.get("codec_type") == "audio"]
    if not videos:
        return False
    for stream in videos:
        if stream.get("codec_name") not in WEB_VIDEO:
            return False
        if (stream.get("pix_fmt") or "") not in WEB_PIX:
            return False
    for stream in audios:
        if stream.get("codec_name") not in WEB_AUDIO:
            return False
    return True


def _transcode(src: Path, dest: Path) -> bool:
    cmd = [
        "ffmpeg",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(src),
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-vf",
        f"scale='min({MAX_WIDTH},iw)':-2:flags=bicubic,format=yuv420p",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-c:a",
        "aac",
        "-b:a",
        "160k",
        "-ac",
        "2",
        "-movflags",
        "+faststart",
        "-f",
        "mp4",
        str(dest),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=FFMPEG_TIMEOUT_S)
        return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0
    except (subprocess.TimeoutExpired, OSError):
        log.warning("webproxy: ffmpeg failed for %s", src, exc_info=True)
        return False


def get_or_create(src: Path) -> Path:
    """Return a browser-playable MP4 path (original if already safe)."""
    try:
        stat = src.stat()
    except OSError:
        return src
    if is_web_safe(src):
        return src

    key = cache_key(str(src), stat.st_mtime_ns, stat.st_size, MAX_WIDTH)
    out = cache_dir() / f"{key}.web.mp4"
    if out.exists() and out.stat().st_size > 0:
        return out

    with _lock_for(key):
        if out.exists() and out.stat().st_size > 0:
            return out
        cache_dir().mkdir(parents=True, exist_ok=True)
        partial = out.with_name(f".{out.name}.partial")
        made = _transcode(src, partial)
        if made:
            partial.replace(out)
            result = out
        else:
            partial.unlink(missing_ok=True)
            result = src
    with _key_locks_guard:
        _key_locks.pop(key, None)
    return result
