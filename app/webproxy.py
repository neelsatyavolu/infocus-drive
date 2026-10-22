"""Cached browser-safe H.264/AAC proxies for camera originals.

Hub plays Package Cycles / Package Storage videos in <video>. Sony XAVC
(4:2:2 10-bit) and ProRes 4444 QuickTime files parse (duration works) but
decode to a black frame. Transcode once, cache by (path, mtime, size).
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from thumbs import cache_dir, cache_key, _lock_for, _key_locks, _key_locks_guard

log = logging.getLogger("uvicorn.error")

WEB_VIDEO = {"h264", "vp8", "vp9", "av1"}
WEB_PIX = {"yuv420p", "yuvj420p"}
WEB_AUDIO = {"aac", "mp3", "opus", "vorbis"}
MAX_WIDTH = 1280
FFMPEG_TIMEOUT_S = 300

# prepare() transcodes one original at a time: each ffmpeg already uses every core.
_prepare_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="webproxy")
_prepare_guard = threading.Lock()
_preparing: set[str] = set()
# Cache keys whose original is served as-is: already browser-safe, or the transcode failed.
_serves_original: set[str] = set()


def _dev_fd(src: Path) -> int | None:
    """fd number when ``src`` is an authorized ``/dev/fd/N``."""
    text = str(src)
    prefix = "/dev/fd/"
    if not text.startswith(prefix) or not text[len(prefix):].isdigit():
        return None
    return int(text[len(prefix):])


def _run(cmd: list[str], src: Path, timeout: int, *, text: bool = False) -> subprocess.CompletedProcess:
    """``close_fds`` drops every fd except those in ``pass_fds``."""
    fd = _dev_fd(src)
    kwargs: dict = {"capture_output": True, "timeout": timeout, "text": text}
    if fd is not None:
        kwargs["pass_fds"] = (fd,)
    try:
        return subprocess.run(cmd, **kwargs)
    finally:
        if fd is not None:
            try:
                os.set_inheritable(fd, False)
            except OSError:
                pass


def _probe(src: Path) -> dict:
    proc = _run(
        ["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(src)],
        src,
        20,
        text=True,
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
        proc = _run(cmd, src, FFMPEG_TIMEOUT_S)
        return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0
    except (subprocess.TimeoutExpired, OSError):
        log.warning("webproxy: ffmpeg failed for %s", src, exc_info=True)
        return False


def _cache_entry(src: Path, stat) -> tuple[str, Path]:
    key = cache_key(str(src), stat.st_mtime_ns, stat.st_size, MAX_WIDTH)
    return key, cache_dir() / f"{key}.web.mp4"


def prepare(src: Path, stat_result, open_source) -> bool:
    """True when ``web=1`` for ``src`` answers at once; otherwise queue the proxy and return False.

    A long original takes minutes to transcode, longer than a browser or the tunnel waits for a
    first byte, so callers poll this instead. ``open_source()`` opens the file for the background
    job (``.path``, ``.dev_path()``, ``.stat``, ``.close()``).
    """
    key, out = _cache_entry(src, stat_result)
    if out.exists() and out.stat().st_size > 0:
        return True
    with _prepare_guard:
        if key in _serves_original:
            return True
        if key in _preparing:
            return False
        _preparing.add(key)

    def job():
        opened = None
        try:
            opened = open_source()
            made = get_or_create(opened.path, read_path=Path(opened.dev_path()), stat_result=opened.stat)
            if made == opened.path:
                with _prepare_guard:
                    _serves_original.add(key)
        except Exception:
            log.warning("webproxy: prepare failed for %s", src, exc_info=True)
        finally:
            if opened is not None:
                opened.close()
            with _prepare_guard:
                _preparing.discard(key)

    _prepare_pool.submit(job)
    return False


def get_or_create(src: Path, *, read_path: Path | None = None, stat_result=None) -> Path:
    """Return a browser-playable MP4 path (``src`` itself if already safe).

    ``read_path`` is an authorized fd path. Returning ``src`` means the caller
    still has to serve that fd; a different path is a cache file we own.
    """
    source = read_path or src
    try:
        stat = stat_result if stat_result is not None else source.stat()
    except OSError:
        return src
    key, out = _cache_entry(src, stat)
    # A cached proxy answers before ffprobe, which takes seconds on a large original.
    if out.exists() and out.stat().st_size > 0:
        return out
    if is_web_safe(source):
        return src

    with _lock_for(key):
        if out.exists() and out.stat().st_size > 0:
            return out
        cache_dir().mkdir(parents=True, exist_ok=True)
        partial = out.with_name(f".{out.name}.partial")
        made = _transcode(source, partial)
        if made:
            partial.replace(out)
            result = out
        else:
            partial.unlink(missing_ok=True)
            result = src
    with _key_locks_guard:
        _key_locks.pop(key, None)
    return result
