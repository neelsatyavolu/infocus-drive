"""scandir-based folder listings skip junk and stay sorted."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import fsops  # noqa: E402
from config import get_settings  # noqa: E402


@pytest.fixture()
def share_tree(tmp_path, monkeypatch):
    root = tmp_path / "drive"
    root.mkdir()
    (root / "Zed").mkdir()
    (root / "alpha.txt").write_bytes(b"a")
    (root / "Beta.txt").write_bytes(b"b")
    (root / ".DS_Store").write_bytes(b"junk")
    (root / "clip.partial").write_bytes(b"partial")
    (root / ".ifd-tmp").write_bytes(b"internal")
    nested = root / "Camp"
    nested.mkdir()
    (nested / "take.mp4").write_bytes(b"x")

    monkeypatch.setenv("DRIVE_ROOT", str(root))
    get_settings.cache_clear()
    return root


def test_list_root_skips_hidden_and_sorts_dirs_first(share_tree):
    data = fsops.list_dir("", uid=0, gid=0)
    names = [item["name"] for item in data["items"]]
    assert names == ["Camp", "Zed", "alpha.txt", "Beta.txt"]
    assert data["path"] == ""
    assert data["items"][0]["is_dir"] is True
    assert data["items"][-1]["is_dir"] is False
    alpha = next(item for item in data["items"] if item["name"] == "alpha.txt")
    assert alpha["size"] == 1
    assert alpha["path"] == "alpha.txt"


def test_list_nested_relative_paths(share_tree):
    data = fsops.list_dir("Camp", uid=0, gid=0)
    assert data["path"] == "Camp"
    assert [item["path"] for item in data["items"]] == ["Camp/take.mp4"]


def test_list_missing_folder(share_tree):
    with pytest.raises(fsops.FSError) as ei:
        fsops.list_dir("nope", uid=0, gid=0)
    assert ei.value.status == 404


def test_list_file_is_not_a_directory(share_tree):
    with pytest.raises(fsops.FSError) as ei:
        fsops.list_dir("alpha.txt", uid=0, gid=0)
    assert ei.value.status == 400


def test_rel_to_root_no_stat(share_tree):
    nested = str(share_tree / "Camp" / "take.mp4")
    assert fsops._rel_to_root(nested, share_tree) == "Camp/take.mp4"
    assert fsops._rel_to_root(str(share_tree), share_tree) == ""


def test_symlink_mutations_change_the_link_not_the_target(tmp_path, monkeypatch):
    root = tmp_path / "drive"
    root.mkdir()
    outside = tmp_path / "secret.txt"
    outside.write_text("secret")
    inside = root / "real.txt"
    inside.write_text("keep")
    (root / "outside.txt").symlink_to(outside)
    (root / "alias.txt").symlink_to(inside)
    (root / "dangling.txt").symlink_to(root / "missing.txt")
    (root / "Dest").mkdir()
    monkeypatch.setenv("DRIVE_ROOT", str(root))
    get_settings.cache_clear()
    uid, gid = os.getuid(), os.getgid()

    deleted = fsops.delete("outside.txt", uid, gid)
    assert deleted["action"] == "deleted"
    assert outside.read_text() == "secret"
    assert not (root / "outside.txt").exists()

    fsops.delete("dangling.txt", uid, gid)
    assert not os.path.lexists(root / "dangling.txt")

    renamed = fsops.rename("alias.txt", "renamed.txt", uid, gid)
    assert renamed["name"] == "renamed.txt"
    assert (root / "renamed.txt").is_symlink()
    assert inside.read_text() == "keep"
    assert not os.path.lexists(root / "alias.txt")

    moved = fsops.move_item("renamed.txt", "Dest", uid, gid)
    assert moved["name"] == "renamed.txt"
    assert (root / "Dest" / "renamed.txt").is_symlink()
    assert inside.read_text() == "keep"

    (root / "Folder").mkdir()
    (root / "Folder" / "nested").mkdir()
    with pytest.raises(fsops.FSError, match="into itself"):
        fsops.move_item("Folder", "Folder/nested", uid, gid)
