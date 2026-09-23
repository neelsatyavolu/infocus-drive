"""Chunked upload sessions must create staging files even under as_root."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import chunk_upload  # noqa: E402
import fsops  # noqa: E402


@pytest.fixture()
def staging(tmp_path, monkeypatch):
    root = tmp_path / "chunks"
    monkeypatch.setattr(chunk_upload, "SESSION_ROOT", root)
    chunk_upload._sessions.clear()
    return root


def test_create_session_writes_meta(staging):
    session = chunk_upload.create_session(
        username="st10001",
        uid=1067,
        gid=10,
        share="~st10001",
        rel_dir="EGLLFACT",
        filename="big.rar",
        size=64 * 1024 * 1024,
        chunk_size=32 * 1024 * 1024,
    )
    assert session["total_chunks"] == 2
    meta = staging / session["upload_id"] / "meta.json"
    assert meta.is_file()
    assert chunk_upload.peek_session(session["upload_id"])["name"] == "big.rar"


def test_write_chunk_and_complete(staging, tmp_path, monkeypatch):
    drive = tmp_path / "drive"
    drive.mkdir()
    monkeypatch.setenv("DRIVE_ROOT", str(drive))
    from config import get_settings

    get_settings.cache_clear()

    payload = b"abcdefgh" * 1024
    session = chunk_upload.create_session(
        username="nasadmin",
        uid=1001,
        gid=1001,
        share="InFocus Drive",
        rel_dir="",
        filename="clip.bin",
        size=len(payload),
        chunk_size=1024 * 1024,
    )
    chunk_upload.write_chunk(
        session["upload_id"],
        0,
        iter([payload]),
        username="nasadmin",
        uid=1001,
    )
    with fsops.use_share_root(drive):
        result = chunk_upload.complete_session(
            session["upload_id"],
            username="nasadmin",
            uid=1001,
        )
    assert (drive / "clip.bin").read_bytes() == payload
    assert result["name"] == "clip.bin"


def test_as_root_noop_without_privileges():
    with fsops.as_root():
        pass


@pytest.mark.parametrize("kind,gb", [("A-roll", 30), ("B-roll", 15)])
@pytest.mark.parametrize("extra", [0, 1])
def test_package_roll_upload_limit(staging, kind, gb, extra):
    kwargs = dict(
        username="nasadmin", uid=1001, gid=1001, share="InFocus Drive",
        rel_dir=f"Package Storage/Cycle 1/Tom cookbook/A-roll B-roll/{kind}",
        filename="clip.mp4", size=gb * 1024 ** 3 + extra,
    )
    if extra:
        with pytest.raises(fsops.FSError, match=f"max {gb}GB"):
            chunk_upload.create_session(**kwargs)
    else:
        session = chunk_upload.create_session(**kwargs)
        assert session["size"] == gb * 1024 ** 3
