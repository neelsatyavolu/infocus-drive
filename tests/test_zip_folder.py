"""Folder zip collection + STORE stream round-trip."""

from __future__ import annotations

import io
import sys
import zipfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import fsops  # noqa: E402
import zipstream  # noqa: E402
from zipstream import stream_zip_store, zip_store_content_length  # noqa: E402


@pytest.fixture()
def share_tree(tmp_path, monkeypatch):
    root = tmp_path / "drive"
    root.mkdir()
    folder = root / "Camp"
    folder.mkdir()
    (folder / "a.txt").write_bytes(b"alpha")
    nested = folder / "clips"
    nested.mkdir()
    (nested / "b.bin").write_bytes(b"beta" * 100)
    # Junk / recycle should be skipped when walking a parent
    (folder / ".DS_Store").write_bytes(b"junk")
    (folder / "note.partial").write_bytes(b"partial")
    recycle = folder / "#recycle"
    recycle.mkdir()
    (recycle / "trashed.txt").write_bytes(b"nope")
    # Sibling file for mixed selection
    (root / "solo.txt").write_bytes(b"solo")
    # Empty folder
    (root / "Empty").mkdir()

    monkeypatch.setenv("DRIVE_ROOT", str(root))
    # Clear settings cache if present
    if hasattr(fsops, "get_settings"):
        try:
            from config import get_settings

            get_settings.cache_clear()
        except Exception:
            pass
    return root


def test_collect_zip_entries_expands_folder(share_tree):
    entries = fsops.collect_zip_entries(
        ["Camp"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    arcs = sorted(a for a, _ in entries)
    assert arcs == ["Camp/a.txt", "Camp/clips/b.bin"]
    # No junk / recycle
    assert all("#recycle" not in a and ".DS_Store" not in a for a in arcs)


def test_collect_zip_entries_mixed_file_and_folder(share_tree):
    entries = fsops.collect_zip_entries(
        ["solo.txt", "Camp"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    arcs = sorted(a for a, _ in entries)
    assert "solo.txt" in arcs
    assert "Camp/a.txt" in arcs
    assert "Camp/clips/b.bin" in arcs


def test_collect_empty_folder_errors(share_tree):
    with pytest.raises(fsops.FSError) as ei:
        fsops.collect_zip_entries(
            ["Empty"],
            uid=0,
            gid=0,
            max_files=100,
            max_total=8 * 1024**3,
        )
    assert ei.value.status == 400


def test_stream_zip_store_roundtrip(share_tree):
    entries = fsops.collect_zip_entries(
        ["Camp"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    blob = b"".join(stream_zip_store(entries))
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        names = sorted(zf.namelist())
        assert names == ["Camp/a.txt", "Camp/clips/b.bin"]
        assert zf.read("Camp/a.txt") == b"alpha"
        assert zf.read("Camp/clips/b.bin") == b"beta" * 100
        # STORE (no compression)
        for info in zf.infolist():
            assert info.compress_type == zipfile.ZIP_STORED
        assert zf.testzip() is None
    # Small archives stay ZIP32 so macOS Archive Utility is happy.
    assert b"PK\x06\x06" not in blob


def test_nested_zip_stays_a_member(share_tree):
    """A .zip inside the folder is stored as a file, not merged into the outer archive."""
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, "w") as zf:
        zf.writestr("secret.txt", b"hello-from-inner")
    pack = share_tree / "Camp" / "mod.zip"
    pack.write_bytes(inner.getvalue())

    entries = fsops.collect_zip_entries(
        ["Camp"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    blob = b"".join(stream_zip_store(entries))
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        names = sorted(zf.namelist())
        assert "Camp/mod.zip" in names
        assert "secret.txt" not in names
        nested = zipfile.ZipFile(io.BytesIO(zf.read("Camp/mod.zip")))
        assert nested.read("secret.txt") == b"hello-from-inner"


def test_zip64_when_offset_exceeds_limit(share_tree, monkeypatch):
    """Regression: EGLLFACT.zip (6.5GiB) aborted before the central directory
    because ZIP32 can't store local-header offsets past 4GiB-1."""
    monkeypatch.setattr(zipstream, "ZIP32_MAX", 200)

    folder = share_tree / "Big"
    folder.mkdir()
    (folder / "a.bin").write_bytes(b"A" * 150)
    (folder / "b.bin").write_bytes(b"B" * 150)
    (folder / "inner.zip").write_bytes(_tiny_zip(b"nested"))

    entries = fsops.collect_zip_entries(
        ["Big"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    blob = b"".join(stream_zip_store(entries))

    assert b"PK\x06\x06" in blob  # zip64 EOCD
    assert b"PK\x06\x07" in blob  # zip64 locator
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        names = sorted(zf.namelist())
        assert names == ["Big/a.bin", "Big/b.bin", "Big/inner.zip"]
        assert zf.read("Big/a.bin") == b"A" * 150
        assert zf.read("Big/b.bin") == b"B" * 150
        nested = zipfile.ZipFile(io.BytesIO(zf.read("Big/inner.zip")))
        assert nested.read("n.txt") == b"nested"
        assert zf.testzip() is None
        for info in zf.infolist():
            assert info.compress_type == zipfile.ZIP_STORED


def test_zip64_when_file_size_exceeds_limit(share_tree, monkeypatch):
    monkeypatch.setattr(zipstream, "ZIP32_MAX", 50)
    big = share_tree / "huge.bin"
    payload = b"Z" * 80
    big.write_bytes(payload)

    entries = fsops.collect_zip_entries(
        ["huge.bin"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    blob = b"".join(stream_zip_store(entries))
    assert b"PK\x06\x06" in blob
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        assert zf.read("huge.bin") == payload
        info = zf.getinfo("huge.bin")
        assert info.file_size == 80
        assert zf.testzip() is None


def test_zip_store_content_length_matches_bytes(share_tree):
    entries = fsops.collect_zip_entries(
        ["Camp", "solo.txt"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    blob = b"".join(stream_zip_store(entries))
    assert zip_store_content_length(entries) == len(blob)


def test_zip64_content_length_matches_bytes(share_tree, monkeypatch):
    monkeypatch.setattr(zipstream, "ZIP32_MAX", 200)
    folder = share_tree / "Len"
    folder.mkdir()
    (folder / "a.bin").write_bytes(b"A" * 150)
    (folder / "b.bin").write_bytes(b"B" * 150)
    (folder / "c.bin").write_bytes(b"C" * 80)
    entries = fsops.collect_zip_entries(
        ["Len"],
        uid=0,
        gid=0,
        max_files=100,
        max_total=8 * 1024**3,
    )
    blob = b"".join(stream_zip_store(entries))
    assert b"PK\x06\x06" in blob
    assert zip_store_content_length(entries) == len(blob)


def _tiny_zip(payload: bytes) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("n.txt", payload)
    return buf.getvalue()
