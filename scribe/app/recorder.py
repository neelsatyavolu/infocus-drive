"""Per-speaker audio chunks from the scribe page, kept on disk until processing.

The page records each remote audio track with its own MediaRecorder and sends
10-second WebM/Opus chunks. Chunks of one recorder concatenate (in `seq`
order) into a valid WebM: chunk 0 carries the header. A speaker who
reconnects gets a new recorder, so `seq` starts again at 0. Streams are keyed
by (uid, startMs of chunk 0).
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("scribe.recorder")

MAX_CHUNK_BYTES = 4 * 1024 * 1024
MAX_SEQ = 100_000
MAX_NAME_LEN = 80
_SAFE_UID = re.compile(r"[^A-Za-z0-9_-]")


@dataclass(frozen=True)
class StreamInfo:
    uid: str
    name: str
    start_ms: int
    path: Path

    def chunk_files(self) -> list[Path]:
        return sorted(self.path.glob("*.webm.part"))


def clean_name(name: object) -> str:
    text = " ".join(str(name or "").split())[:MAX_NAME_LEN]
    return text or "Speaker"


def stream_dir_name(uid: str, start_ms: int) -> str:
    safe = _SAFE_UID.sub("", uid)[:48]
    if safe != uid:
        safe = f"{safe}-{hashlib.sha256(uid.encode()).hexdigest()[:8]}"
    return f"{safe}-{start_ms}"


class ChunkStore:
    """Writes chunks under `root/<uid>-<startMs>/<seq>.webm.part`."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self._current: dict[str, StreamInfo] = {}

    def append(self, uid: object, name: object, start_ms: object, seq: object, b64: object) -> Path | None:
        """Store one chunk. Returns its path, or None when it was dropped."""
        if not isinstance(uid, str) or not uid or len(uid) > 128:
            return None
        if not isinstance(seq, int) or isinstance(seq, bool) or not 0 <= seq <= MAX_SEQ:
            return None
        if not isinstance(start_ms, (int, float)) or isinstance(start_ms, bool) or start_ms <= 0:
            return None
        data = _decode(b64)
        if data is None:
            return None
        if seq == 0:
            stream = self._open_stream(uid, clean_name(name), int(start_ms))
        else:
            stream = self._current.get(uid)
            if stream is None:  # no header chunk: undecodable on its own
                log.info("dropping chunk %s without a stream start", seq)
                return None
        path = stream.path / f"{seq:06d}.webm.part"
        path.write_bytes(data)
        return path

    def _open_stream(self, uid: str, name: str, start_ms: int) -> StreamInfo:
        path = self.root / stream_dir_name(uid, start_ms)
        path.mkdir(parents=True, exist_ok=True)
        (path / "meta.json").write_text(json.dumps({"uid": uid, "name": name, "startMs": start_ms}))
        stream = StreamInfo(uid=uid, name=name, start_ms=start_ms, path=path)
        self._current[uid] = stream
        return stream

    def streams(self) -> list[StreamInfo]:
        return load_streams(self.root)


def load_streams(root: Path) -> list[StreamInfo]:
    """Every stream recorded under `root`, oldest first."""
    found: list[StreamInfo] = []
    for meta_path in root.glob("*/meta.json"):
        try:
            meta = json.loads(meta_path.read_text())
            found.append(StreamInfo(uid=str(meta["uid"]), name=clean_name(meta.get("name")),
                                    start_ms=int(meta["startMs"]), path=meta_path.parent))
        except (OSError, ValueError, KeyError, TypeError):
            log.warning("skipping unreadable stream %s", meta_path.parent.name)
    return sorted(found, key=lambda s: (s.start_ms, s.uid))


def concat_stream(stream: StreamInfo, out: Path) -> Path | None:
    """Join a stream's chunks in seq order into one WebM file."""
    parts = stream.chunk_files()
    if not parts:
        return None
    with out.open("wb") as fh:
        for part in parts:
            fh.write(part.read_bytes())
    return out


def _decode(b64: object) -> bytes | None:
    if not isinstance(b64, str) or not b64 or len(b64) > MAX_CHUNK_BYTES * 4 // 3 + 4:
        return None
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError):
        return None
    return data or None
